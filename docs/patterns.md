# Patterns from Rails

The library ships the messaging patterns: an outbox, an idempotency store, a saga,
a scheduler, request/reply, claim check, replay, pipelines, consumer groups, a
schema registry. **This gem wraps none of them**, and that is the design rather
than a gap — [index.md](index.md) says so in one line and this page is the long
form.

What a Rails application needs in order to use them is not a wrapper. It is three
things, and they are the same three every time:

1. **The connection**, which `AceMQ::Rails.connection` already holds.
2. **A require**, because `AceMQ::AMQP::Patterns` is not loaded by
   `require "acemq/amqp"`.
3. **Somewhere to run**, because most of these patterns want a thread or a process
   and neither belongs in Puma.

Get those three right and every pattern is the library's own documentation. Get
the third one wrong and the failure is a connection pool exhausted after five
messages.

## The require

```ruby
require "acemq/amqp/patterns"
```

`AceMQ::AMQP::Patterns` is a `NameError` without it. This is deliberate in the
library — reading an AceMQ envelope should not load a SQL adapter, a scheduler and
a saga engine — and it catches people in Rails more than anywhere else, because
Rails autoloading makes every other constant appear by magic and this one does not.

Put it at the top of the initializer, rake task or consumer that uses it. Not in
`config/application.rb`: a require there is a require in the web process, which
does not need it.

## Where a pattern runs

| | Runs in | |
|---|---|---|
| Outbox relay | A process of its own | A thread that publishes for ever. See [outbox.md](outbox.md) |
| Idempotency store | Inside a handler | Nothing of its own. See [idempotency.md](idempotency.md) |
| Saga | Wherever the work is | Plain Ruby, no broker. See [saga.md](saga.md) |
| Request/reply — requester | A request, carefully | Blocks. See [request-reply.md](request-reply.md) |
| Request/reply — responder | The consumer process | A subscription like any other |
| Scheduler | The consumer process | Holds a subscription. See [scheduling.md](scheduling.md) |
| Claim check | A codec | `config.acemq.codec`, and nothing else |
| Replay | A rake task | Finishes and exits |
| Pipelines | Inside a handler | Wraps the handler |
| Consumer groups | Nothing — use `concurrency` | See below |
| Schema registry | A codec, plus a table | See [serialization.md](serialization.md) |

## The executor, once, for all of them

`AceMQ::Rails::Runner` wraps every consumer-class handler in
`Rails.application.executor.wrap`. Nothing wraps a handler you subscribe yourself.

So a pattern that subscribes directly — `Patterns.serve`, `Patterns.read_stream`,
`Patterns::ConsumerGroup`, `Patterns::Scheduler`, `connection.consume` in a rake
task — is running on a bunny thread Rails has never seen. Touch ActiveRecord from
there without the executor and the thread checks a connection out of the pool on
first use and never checks it back in. A pool of five is exhausted after five
messages and the sixth waits for ever. No exception, no log line, a consumer that
looks alive and does nothing.

```ruby
AceMQ::AMQP::Patterns.serve(AceMQ::Rails.connection, "shop.price.requests") do |message|
  Rails.application.executor.wrap { { "price" => Catalogue.price(message.payload["sku"]) } }
end
```

`executor.wrap` returns what the block returns, so wrapping costs a line and
nothing else. It is also what returns the query cache and any `CurrentAttributes`
to a clean state between messages, which matters as soon as two messages are
handled on one thread.

The exception is a pattern that touches no database at all — a saga over HTTP
calls, `Patterns.replay` moving messages between queues. Wrapping those is
harmless and pointless.

## Consumer groups: use `concurrency` instead

`Patterns::ConsumerGroup` starts *n* subscriptions on one queue so that *n*
messages are handled at once. A consumer class already has that:

```ruby
class InvoicesConsumer < AceMQ::Rails::Consumer
  queue "shop.invoices"
  concurrency 4
end
```

`concurrency` is a keyword the library's own `consume` takes, and the runner passes
it. So the group buys nothing here except a second lifecycle to drain, and the
runner's drain already covers the consumer it made. Reach for `ConsumerGroup` only
when you are subscribing outside the runner and want the group's own shared-deadline
`close`.

Scaling *past* one process is a second consumer process, not a bigger number: a
Deployment with `replicas: 4` and the same `acemq-consumer` command. Four processes
reading one queue is the competing-consumers shape the broker was built for, and
it survives one of them being killed.

## Claim check

A codec, so it needs no new setting:

```ruby
# config/initializers/acemq.rb
require "acemq/amqp/patterns"

Rails.application.config.acemq.codec = AceMQ::AMQP::Patterns::ClaimCheckCodec.wrapping(
  AceMQ::AMQP::JSONCodec.new,
  AceMQ::AMQP::Patterns::FilesystemClaimCheckStore.new("/mnt/claims")
)
```

Anything over 64 KB is written to the store and a key goes on the wire; anything
under it travels whole, in bytes identical to what the delegate codec would have
written. `threshold: 0` offloads everything.

Two things to decide before using it, neither of which the library can decide for
you:

**The store has to outlive every message.** Longer than the queue's TTL, longer
than a dead-letter queue nobody drains, longer than a replay somebody might run
next quarter. Nothing deletes a claim automatically — `delete` exists and is never
called for you — so retention is a job you have taken on, and a claim deleted too
early is a message that cannot be decoded at all.

**Every consumer needs the same store.** A filesystem store means a shared volume,
in this Deployment and in every other service's. `InMemoryClaimCheckStore` is for
tests: the payload lives in the publisher's own memory, so nothing else can read
it.

In Rails, the natural store is not either of those — it is Active Storage or an S3
bucket you already have. The store contract is three methods (`put(content)` →
key, `get(key)` → content or nil, `delete(key)`), so writing one is short:

```ruby
# app/models/active_storage_claim_store.rb
class ActiveStorageClaimStore
  def put(content)
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(content), filename: "claim", identify: false
    )
    blob.key
  end

  def get(key) = ActiveStorage::Blob.service.download(key)
  def delete(key) = ActiveStorage::Blob.service.delete(key)
end
```

`get` returning nil for a missing key is what makes the library raise `DecodeError`
naming the claim rather than something further away, so check what your service
does on a missing object before trusting it.

## Replay

Moving dead letters back where they came from. It finishes, so it is a rake task:

```ruby
# lib/tasks/acemq_replay.rake
namespace :acemq do
  desc "Replay timed-out orders out of the dead-letter queue"
  task replay_orders: :environment do
    require "acemq/amqp/patterns"

    result = AceMQ::AMQP::Patterns.replay(
      AceMQ::Rails.connection,
      from: "shop.orders.dlq", exchange: "shop-events",
      limit: 500
    ) { |envelope, _body| envelope.error.to_s.include?("timeout") }

    puts result          # "moved 37, skipped 463 (drained)"
  ensure
    AceMQ::Rails.disconnect!
  end
end
```

The block decides: truthy moves the message, falsy leaves it where it is. Without
a block everything moves.

Three things worth knowing. `limit:` and `deadline:` both default to `0`, meaning
unbounded — set one against a live queue, because a replay with neither reads until
the queue is empty and a queue something is still dead-lettering into is never
empty. Messages the filter declines are held unacknowledged for the whole pass, so
a very large pass is a very large prefetch. And `restart: true`, the default, means
the message goes back through the exchange as a new delivery with `attempt` reset,
which is usually what you want and is not what you want if the reason it died was
that it will always die.

Each replayed message carries `acemq-replayed-from`, `acemq-replayed-at` and
`acemq-replay-count`, so a message on its third trip through can be told from a new
one.

## Pipelines

Middleware around a handler. In a consumer class, `#call` is already the place to
put a `rescue` and a log line, so most of this is unnecessary — the one that earns
its keep is composing behaviour across several consumers:

```ruby
class ApplicationConsumer < AceMQ::Rails::Consumer
  private

  # The pipeline built once per instance rather than per message, because the
  # runner keeps one instance of each consumer class for the life of the process.
  def pipeline
    @pipeline ||= AceMQ::AMQP::Patterns.chain(
      method(:handle),
      AceMQ::AMQP::Patterns.with_logging { |line| Rails.logger.info(line) },
      AceMQ::AMQP::Patterns.with_timeout(10)
    )
  end
end

class OrdersConsumer < ApplicationConsumer
  queue "shop.orders"

  def call(message) = pipeline.call(message)

  private

  def handle(message)
    Fulfilment.begin!(message.payload)
    accept
  end
end
```

Middleware runs outside-in, first-named outermost. `with_timeout` **reports** an
overrun and never interrupts anything — there is no `Timeout.timeout` in it, so the
handler still runs to the end and the message is still held while it does. It turns
a slow handler into an `Ack.retry` and a metric, which is useful; it is not a
safety net.

`Patterns.with_idempotency(store)` is the same thing as
[idempotency.md](idempotency.md) in middleware form, and `Patterns.then_publish`
turns a handler into a step that publishes its result — returning `nil` from the
block accepts the message and publishes nothing, which is how a chain ends early.

## Routing slips and declared pipelines

A message that carries its own itinerary. `Patterns::RoutingSlip` writes the route
into an `acemq-routing-slip` header; `Patterns::Pipeline` declares the exchange,
the routing keys and the queues for a fixed sequence of steps instead.

From Rails, the declared form is the one that fits, because its topology is a
`Topology` the connection can apply and its queue names are a fixed cross-language
contract rather than something each service invents:

```ruby
# config/initializers/acemq.rb
require "acemq/amqp/patterns"

ORDERS_PIPELINE = AceMQ::AMQP::Patterns::Pipeline.new("orders", %w[validate charge ship])
```

```ruby
# lib/tasks/acemq_pipeline.rake — beside acemq:topology in the deploy step
task pipeline: :environment do
  AceMQ::Rails.connection.apply(ORDERS_PIPELINE.topology)
  AceMQ::Rails.disconnect!
end
```

```ruby
# app/consumers/charge_step_consumer.rb
class ChargeStepConsumer < AceMQ::Rails::Consumer
  queue ORDERS_PIPELINE.queue_for("charge")

  def call(message)
    # `follow_slip` advances the itinerary and publishes onwards, so this returns
    # the payload for the next step rather than an Ack.
    AceMQ::AMQP::Patterns.follow_slip(AceMQ::Rails.connection, pipeline: ORDERS_PIPELINE) do |m|
      Payments.charge!(m.payload)
    end.call(message)
  end
end
```

`queue_for` raises for a step the pipeline does not have, which is the whole
advantage over writing the queue name as a string: a renamed step is a boot-time
failure rather than a consumer subscribed to a queue nothing publishes to.

Note that the constant is in an initializer and the consumer reads it at class-body
time. That is one of the few places in a Rails application where a top-level
constant is the right answer — the queue name has to be the same in the topology
task and in the consumer, and two strings is how they stop being the same.

## Ordering

`Patterns.ordered` serialises handling by a key, so `concurrency 16` still handles
one order's messages one at a time:

```ruby
class OrdersConsumer < AceMQ::Rails::Consumer
  queue "shop.orders"
  concurrency 16

  def call(message)
    @ordered ||= AceMQ::AMQP::Patterns.ordered("x-order-id") do |m|
      Order.apply!(m.payload)
      accept
    end
    @ordered.call(message)
  end
end
```

**Within one process only.** It cannot reorder what the broker already delivered
out of order, and it does nothing across two consumer processes reading one queue
— which is the shape any real deployment has. Ordering across processes is a
routing problem, solved on the publishing side:

```ruby
AceMQ::Rails.publish(order.as_json,
                     to: AceMQ::AMQP::Patterns.partitioned_routing_key("orders", order.id, 8),
                     exchange: "shop-events")
```

Eight routing keys, eight queues, each read by one consumer, and one order's
messages always land on the same one. `partition` uses FNV-1a rather than Ruby's
`Object#hash`, which is randomised per process — so the same key maps to the same
slot in this process, in the next deploy, and in the Java service beside it.

## See also

- [Outbox](outbox.md) · [Idempotency](idempotency.md) · [Saga](saga.md)
- [Request/reply](request-reply.md) · [Scheduling](scheduling.md) · [Streams](streams.md)
- [Serialization](serialization.md) · [Interceptors](interceptors.md) · [Observability](observability.md)
- [The library's patterns page](https://acemq.org/acemq-ruby-amqp/patterns.html) —
  each of these without Rails around it
