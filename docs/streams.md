# Streams

A queue is a to-do list: a message is delivered, acknowledged, and gone. A stream
is a log: messages are appended, every consumer reads the whole thing from
wherever it likes, and acknowledging moves *your* position rather than deleting
anything.

That difference is the only reason to reach for one. Two Rails-shaped cases make
it worth the trouble:

- **A projection that has to be rebuilt.** A read model, a search index, a report
  table. On a queue, rebuilding means somebody kept a copy of the messages. On a
  stream, it means starting a consumer at `first`.
- **Several unrelated readers of the same events.** On a queue that is a queue
  each, an exchange binding each, and a topology that grows a line every time a
  team wants a copy. On a stream it is another consumer with another name.

Everything on this page is the library's `AceMQ::AMQP::Patterns` plus one
declaration in `config/acemq.yml`. Nothing about streams is specific to this gem
except where the pieces go.

## Declaring one

`type: stream` in the ordinary topology section. It is the same key that chooses
`classic` or `quorum`:

```yaml
# config/acemq.yml
shared:
  topology:
    queues:
      - name: shop.orders.log
        type: stream
        arguments:
          x-max-age: "7D"
          x-max-length-bytes: 10737418240
```

```bash
bin/rails acemq:topology
```

```
declare queue shop.orders.log (stream, durable, x-max-age=7D, x-max-length-bytes=10737418240)
```

**Retention is not optional in practice.** A stream with neither argument grows
until the disk is full, and a stream is on disk by design. `x-max-age` is a
duration RabbitMQ parses — `"7D"`, `"36h"`, `"90s"`; the unit suffix is required
and a bare number is not the same thing. `x-max-length-bytes` is a byte count.
Either is a floor on how far back `first` can reach: retention discards from the
front, so "the oldest message the stream still holds" is not "the first message
ever written".

Both arguments are part of the queue's identity to the broker. Change one and the
next declaration is refused with `PRECONDITION_FAILED` — the same rule
[topology.md](topology.md) describes for a queue's type, and the reason the
topology is declared in one file rather than inferred from whoever starts first.

**`auto_delete` and `exclusive` are refused**, with a message that says why:

```
AceMQ::AMQP::QueueTypeError: queue "shop.orders.log" cannot be a stream queue
while it is auto-delete: RabbitMQ only replicates a queue that outlives the
connection that declared it. Leave it classic, or drop the flag.
```

**Do not set `dead_letter: true`.** The declaration is accepted and the arguments
are written, and it buys nothing: a stream has no dead-letter behaviour, because
there is nothing to move a message *out of*. Neither `retries:` nor `{queue}.dlq`
means anything here. The next section is the part that follows from that.

### Declaring it from Ruby instead

`Patterns.declare_stream` takes the retention as numbers and renders the suffixed
duration itself, which is friendlier than writing `"7D"` by hand:

```ruby
require "acemq/amqp/patterns"

AceMQ::AMQP::Patterns.declare_stream(
  AceMQ::Rails.connection, "shop.orders.log",
  max_age: 7 * 24 * 3600, max_bytes: 10 * 1024**3
)
```

Worth knowing rather than worth using: a declaration in `config/acemq.yml` is
applied by `bin/rails acemq:topology` in a deploy step and by the consumer process
on boot, and a declaration in Ruby is applied by whatever remembers to run it.
`segment_bytes:` is the third keyword and is left out unless you have a reason —
an invented default would be a value the first declarer sends and every other
language's library does not.

## Reading one

A consumer class, as usual. Two things it needs that an ordinary consumer does
not:

```ruby
# app/consumers/orders_projection_consumer.rb
class OrdersProjectionConsumer < AceMQ::Rails::Consumer
  queue "shop.orders.log"

  # Where to start when this consumer has no recorded position. `first` for a
  # projection that must see everything; `next` — the library's default — for one
  # that only cares about what happens from now on.
  arguments "x-stream-offset" => "first"

  # A stream consumer needs a prefetch and RabbitMQ refuses one without it. Ten
  # is the library's own choice for a stream; the default here is the
  # application's `consumer.prefetch`, which is 20, and either is fine.
  prefetch 100

  # No retries. See below — this is the important line.
  retries AceMQ::AMQP::RetryPolicy.none

  def call(message)
    OrderProjection.apply!(message.payload, offset: message.envelope.headers["x-stream-offset"])
    accept
  end
end
```

```bash
bundle exec acemq-consumer --queues shop.orders.log
```

The **consumer tag** is what the broker tracks a position against, and it defaults
to the class name — `OrdersProjectionConsumer`. That is the right default here for
once by luck rather than by design: a position keyed to a stable name is a
position that survives a restart, whereas a tag containing a hostname or a process
id would start from `x-stream-offset` again on every deploy. Do not set `tag` on a
stream consumer unless you have thought about that.

`x-stream-offset` arrives *back* on every delivery as an ordinary header holding an
integer counting from zero, which is how a projection records where it got to.
Resume from a recorded position with `AceMQ::AMQP::Patterns::StreamOffset.at(n +
1)` — the offsets are inclusive, so `at(n)` re-reads the message you last handled.

### Where to start

| | |
|---|---|
| `StreamOffset.next` | Only what is published from now on. The library's default |
| `StreamOffset.first` | The oldest message the stream still holds |
| `StreamOffset.last` | The last chunk — roughly "recently", not "the last message" |
| `StreamOffset.at(n)` | Exactly offset `n` |
| `StreamOffset.since(time)` | The first message at or after a `Time` |

As a consumer-class argument these are the strings and values the broker takes
directly: `"first"`, `"next"`, `"last"`, an integer, or a `Time`. `StreamOffset`
is the same thing with a name on it, and is what `Patterns.read_stream` takes.

## Retries do not work on a stream, and the default is wrong for you

This is the one trap worth the page.

The library's retry ladder works by **republishing**: a failed message goes to a
rung queue, waits out a TTL, and comes back. On a stream, "comes back" means
*appended again* — the original is still there, at its own offset, and now there
is a second copy further along. A projection reading `first` sees both.

`AceMQ::AMQP::Patterns.read_stream` handles this by passing `RetryPolicy.none`
whatever the connection carries. **A consumer class does not**, because a consumer
class inherits `config.acemq.consumer.max_attempts`, and an application that set
that globally — which is the sensible thing to do for queues — has just given its
stream consumer a retry ladder.

So a stream consumer says so:

```ruby
retries AceMQ::AMQP::RetryPolicy.none
```

Then decide what a failure means, because nothing else will:

- **Accept and record it.** The handler catches, writes the failure somewhere it
  can be looked at, and accepts. The position advances, the stream is not
  corrupted, and the message is still at its offset if you want to come back to
  it. This is almost always the right answer for a projection.
- **Stop.** Let the exception out. The delivery is not acknowledged, the position
  does not advance, and the consumer stops. Correct when the order matters
  absolutely and a gap is worse than an outage — and it is an outage, so it needs
  an alert rather than a hope.

`reject` and `park` are the same trap wearing a different hat: both republish to
`{queue}.dlq` or `{queue}.parked`, and neither queue exists for a stream unless
somebody declared it. Use `accept` and your own record.

## Rebuilding a projection

The thing streams exist for. A rake task, not a consumer class, because it has an
end:

```ruby
# lib/tasks/acemq_rebuild.rake
namespace :acemq do
  desc "Rebuild the order projection from the whole stream"
  task rebuild_orders: :environment do
    require "acemq/amqp/patterns"

    OrderProjection.delete_all

    offset = nil
    seen_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    consumer = AceMQ::AMQP::Patterns.read_stream(
      AceMQ::Rails.connection, "shop.orders.log",
      offset: AceMQ::AMQP::Patterns::StreamOffset.first,
      prefetch: 200,
      # A name of its own, so this does not move the live consumer's position.
      name: "rebuild-#{Time.now.utc.strftime("%Y%m%dT%H%M%S")}"
    ) do |message|
      Rails.application.executor.wrap { OrderProjection.apply!(message.payload) }
      offset = message.envelope.headers["x-stream-offset"]
      seen_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      AceMQ::AMQP::Ack.accept
    end

    # A stream has no end and sends no "you have caught up" event, so there is
    # nothing to wait for. A quiet period is what is available: thirty seconds
    # with nothing delivered means the backlog is done, on a stream that is also
    # taking live traffic it means nothing happened, and either way stopping is
    # right.
    sleep 1 while Process.clock_gettime(Process::CLOCK_MONOTONIC) - seen_at < 30
    consumer.cancel(timeout: 30)
    puts "rebuilt to offset #{offset}"
  ensure
    AceMQ::Rails.disconnect!
  end
end
```

Three things in there are not decoration:

**`name:` is a different consumer tag**, so the rebuild has its own server-side
position and does not move the live projection's.

**`Rails.application.executor.wrap`** is what the `Runner` does around every
handler and what nothing does here. `Patterns.read_stream` subscribes on the
library's connection directly, so a handler that touches ActiveRecord is a handler
on a bunny thread with a connection checked out of the pool and never checked back
in — a pool of five exhausted after five messages, and the sixth waiting for ever.
Any pattern driven from a rake task has this problem; [patterns.md](patterns.md)
says it once for all of them.

**`consumer.cancel` cannot be called from inside its own handler.** It waits for
in-flight handlers, so a handler waiting on it waits on itself. Record a position,
signal, and cancel from the thread that started it.

## What a stream cannot do

| On a queue | On a stream |
|---|---|
| The retry ladder | Does not apply — nothing can be moved to a rung and back |
| `{queue}.dlq` | None. A failed message stays where it is |
| `{queue}.parked` | None, for the same reason |
| Requeue on shutdown | Nothing to put back; a position simply does not advance |
| Reject one message | No. Positions move forward and never skip holes |
| Destructive read | No. Every other consumer still sees what you consumed |

The drain is the one place where a stream is *easier*: an unacknowledged delivery
at shutdown is a position that did not advance, so the messages are read again on
the next start rather than needing the broker to redeliver them. Everything
[lifecycle.md](lifecycle.md) says about `shutdown_timeout` and handlers in flight
still applies; the rest of its arithmetic about rung queues does not.

## Health, and what is not measured

`AceMQ::Rails.health` declares and deletes a throwaway classic queue. It says the
broker is reachable and this process's consumers are running. It says nothing
about how far behind a stream consumer is, and there is no API here that does —
RabbitMQ knows the stream's committed offset and this library does not ask for it.

What is available from the application side is the offset the last handled message
carried. Record it and compare it to the clock:

```ruby
def call(message)
  OrderProjection.apply!(message.payload)
  Telemetry.gauge("projection.offset", message.envelope.headers["x-stream-offset"].to_i)
  accept
end
```

[observability.md](observability.md) has the reporter this hands to.

## Single active consumer, super streams

Not implemented in this library, and not wrapped by this gem. RabbitMQ has both.
If you need either, the queue arguments go in the topology section's `arguments:`
like any other — and you are on your own with the semantics, so read RabbitMQ's
own documentation rather than assuming anything here covers it.

## See also

- [Topology](topology.md) — how a declaration is applied, and drift
- [Patterns](patterns.md) — the library's patterns from Rails, and the executor
- [The library's streams page](https://acemq.org/acemq-ruby-amqp/streams.html)
