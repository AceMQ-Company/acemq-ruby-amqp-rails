# Request and reply

A message that expects an answer. Useful, and the pattern most likely to be reached
for when something else was wanted — so the first section is about that.

## Before you use it in a request

**A request/reply over AMQP from inside a Rails action is an HTTP call with more
moving parts.** It blocks the Puma thread, it can time out, it fails when the broker
is unavailable, and the caller is waiting. Everything true of calling the other
service's HTTP API is true of this, plus a broker in the middle.

What it buys, and the only things it buys, are:

- **The caller does not need to know where the responder is.** A routing key rather
  than a hostname, so a responder can move, scale or be replaced without the caller
  being redeployed.
- **The broker queues the request** when no responder is running, so a restart on
  the other side is a slow request rather than a connection refused.
- **It is one connection** for this and for everything else, with the same
  credentials and the same TLS.

What it does not buy is a way to make a synchronous call asynchronous. If the answer
is not needed in order to render the response, publish an event and let a consumer
deal with it — that is the rest of this site.

## Responding

The responder side is the one that fits Rails cleanly, because it is a consumer
process doing what a consumer process does.

A consumer class can do it, and this is the version worth preferring, because it
gets the executor, the error reporter and the drain for free:

```ruby
# app/consumers/price_requests_consumer.rb
class PriceRequestsConsumer < AceMQ::Rails::Consumer
  queue "shop.price.requests"

  def call(message)
    price = Catalogue.price(message.payload["sku"])

    AceMQ::Rails.publish({ "price" => price },
                         to: AceMQ::AMQP::Patterns.reply_address(message),
                         correlation_id: message.envelope.correlation_id)
    accept
  end
end
```

`Patterns.reply_address(message)` is the one piece of the protocol worth not
reinventing: it reads the `acemq-reply-to` header first and falls back to AMQP's own
`reply-to` property, because the library writes both and the other four AceMQ
libraries read them in that order. The reply goes to the **default exchange** — a
queue name as a routing key — which is why `exchange:` is left off.

`correlation_id` is what lets the caller match the answer to the question. Copy it or
the requester times out holding a reply it cannot place.

### `Patterns.serve` instead

The library's own responder handles the address and the correlation id for you, and
sends a failure back to the caller instead of retrying:

```ruby
# config/initializers/acemq_responders.rb
require "acemq/amqp/patterns"

if $PROGRAM_NAME.end_with?("acemq-consumer")
  Rails.application.config.after_initialize do
    responder = AceMQ::AMQP::Patterns.serve(AceMQ::Rails.connection, "shop.price.requests") do |message|
      # The answer, not an Ack. Raising sends the failure to the caller.
      Rails.application.executor.wrap { { "price" => Catalogue.price(message.payload["sku"]) } }
    end

    at_exit { responder.cancel(timeout: 10) }
  end
end
```

Two things this costs, which is why the consumer class is listed first:

**`Rails.application.executor.wrap` is yours to write.** `serve` subscribes on the
connection directly, so nothing wraps the block. Without it the bunny thread checks
an ActiveRecord connection out of the pool and never checks it back in.
[patterns.md](patterns.md#the-executor-once-for-all-of-them).

**The drain is yours to arrange.** `AceMQ::Rails::Runner` drains the consumers it
made; a responder started in an initializer is not one of them. The `at_exit` above
is what stops it, and it has to be registered after the Railtie's — which it is,
because `config.after_initialize` in an initializer runs after the Railtie's own.

What it buys is the failure path: an exception inside the block is sent to the caller
as `ResponderFailed` and the request is **settled, not retried**, which is almost
always right. Retrying a request whose caller gave up thirty seconds ago is work
nobody is waiting for.

`responder.answered` and `responder.unanswerable` are counters worth graphing;
`unanswerable` counts requests that arrived with no reply address, which means a
caller that is not speaking this protocol.

## Requesting

```ruby
# config/initializers/acemq_requesters.rb
require "acemq/amqp/patterns"

Rails.application.config.after_initialize do
  PRICES = AceMQ::AMQP::Patterns::Requester.new(
    AceMQ::Rails.connection, to: "shop.price.requests", timeout: 2
  )
end
```

```ruby
class ProductsController < ApplicationController
  def show
    @price = PRICES.call({ "sku" => params[:sku] })
  rescue AceMQ::AMQP::Patterns::RequestTimedOut
    @price = nil          # render the page without it
  rescue AceMQ::AMQP::Patterns::ResponderFailed => e
    Rails.error.report(e)
    @price = nil
  end
end
```

**Build one requester and keep it.** A `Requester` holds a reply queue and a
consumer on it; one per request means a queue declared and torn down per request,
which is a round trip to the broker each way and a management interface full of
queues. This is the single most common way to get this pattern wrong.

It is thread-safe in the sense that matters — concurrent `call`s on one requester
each get their own answer, matched by correlation id — so one per process is right
and one per Puma thread is not needed.

Without `reply_to:` it declares an **exclusive, auto-delete, classic** queue of its
own. That combination is deliberate: exclusive means the broker deletes it when this
connection goes, so a restart does not leave a queue behind, and it is why the queue
cannot be a quorum queue (RabbitMQ refuses to replicate a queue that does not
outlive its connection).

### The timeout

`timeout: 2` rather than the library's default of thirty, because this is a web
request. Thirty seconds of a Puma thread is a thread not serving anything, and a
user who left. Pick a number smaller than whatever the load balancer will wait for,
and handle `RequestTimedOut` as a rendered page rather than a 500.

A request that times out is **not** cancelled at the responder. It is still on the
queue, the responder will still handle it, and the reply will arrive at a queue
nobody is reading. So a responder must be safe to run for a caller that has gone —
which mostly means a price lookup is fine and a charge is not.

### Where a requester must not be

`connect_on_boot` is false by default, and the initializer above reaches
`AceMQ::Rails.connection` — so building a requester at boot opens the socket at
boot, which is the thing lazy connecting exists to avoid. Either accept that and set
`connect_on_boot: true` so the failure is at least honest, or build it lazily:

```ruby
def prices
  @prices ||= AceMQ::AMQP::Patterns::Requester.new(
    AceMQ::Rails.connection, to: "shop.price.requests", timeout: 2
  )
end
```

Memoised on a singleton, not on the controller: a controller instance is one
request.

## Testing it

The responder half is a consumer class, so it is tested as one — call it and assert
on what was published:

```ruby
RSpec.describe PriceRequestsConsumer do
  before { AceMQ::Rails.connection = AceMQ::AMQP::Connection.new(transport: FakeTransport.new) }
  after  { AceMQ::Rails.connection = nil }

  it "answers on the reply address the caller gave" do
    message = AceMQ::AMQP::Message.new(
      payload: { "sku" => "X-1" },
      envelope: AceMQ::AMQP::Envelope.new(correlation_id: "c-1",
                                          headers: { "acemq-reply-to" => "reply.queue" })
    )

    expect(described_class.new.call(message)).to be_accept

    published = AceMQ::Rails.connection.transport.published.last
    expect(published.routing_key).to eq("reply.queue")
    expect(published.exchange).to eq("")
  end
end
```

The requester half needs a responder, which means a real broker. Tag it
`:integration` and give it a queue name with a random suffix — see
[testing.md](testing.md).

## See also

- [Patterns](patterns.md) — the require, and the executor
- [Consumers](consumers.md) — what a consumer class gets for free
- [The library's request/reply page](https://acemq.org/acemq-ruby-amqp/request-reply.html)
