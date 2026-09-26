# Publishing

```ruby
AceMQ::Rails.publish(order.as_json, to: "order.placed",
                     exchange: "shop-events", type: "order.placed.v2")
```

That is the whole surface. It is a delegation to
`AceMQ::AMQP::Connection#publish`, and every keyword is the library's: `to:` is
the routing key, `exchange:` the exchange, `envelope:` or the envelope fields
(`type:`, `version:`, `correlation_id:`, `causation_id:`, `subject:`,
`headers:`), `codec:` for one message in a different format, `persistent:`,
`reply_to:`, `mandatory:`.

Thin on purpose. The library's publisher is already the right shape, and a
wrapper that renamed its keywords would be a second API to document, a second one
to keep in step with the first, and the place where an integration starts making
decisions the library deliberately left to the caller.

## The connection

One per process, opened on first use and memoised. A connection is a socket and a
heartbeat; opening one per request is the single most expensive mistake available
here, and it is why this exists rather than every caller writing
`Connection.open`.

`AceMQ::Rails.connection` is the object itself, for everything this gem does not
wrap — `Patterns::Requester`, the outbox relay, the scheduler, `pull`.
[patterns.md](patterns.md) is the page about reaching for it, and the two things to
get right when you do.

Interceptors are the exception: they go in a setting rather than through the
connection.

```ruby
# config/application.rb
config.acemq.interceptors = [TenantStamp.new]
```

```ruby
class TenantStamp
  def before_publish(context)
    context.set_header("tenant", Current.tenant)
    context
  end
end
```

The setting exists because `intercept_publish` is an instance method, so registering
one from an initializer means reaching for the connection — which **opens the socket
during boot**, undoing `connect_on_boot: false` quietly. The list is applied on the
way out of `Connection.open` instead. [interceptors.md](interceptors.md).

A publisher reads the list at the moment it publishes rather than copying it, so one
added later does apply — but a message already on its way will not see it.

## Confirms, and what "published" means

A publish waits for the broker to confirm it and raises `PublishError` if it does
not. That is the difference between "the bytes reached a socket" and "the broker
has it", and it is why `publish` returns rather than being fire-and-forget.

`mandatory: true` adds a second question: was it routed to any queue at all? A
message the broker had nowhere to put is returned, and the resulting
`PublishError` answers `unroutable?`. It costs a round trip only when a message
really did go nowhere, which makes it cheap enough to leave on for the publishes
that would be a bug to lose.

## Batches

0.6.0 of the library added `publish_all`, which hands every message to the broker
before asking for any confirm and then waits for all of them together:

```ruby
envelopes = AceMQ::Rails.publish_all(orders.map(&:as_json),
                                     to: "order.placed", exchange: "shop-events",
                                     type: "order.placed.v2")
```

A thousand messages take about as long as one, instead of a thousand round trips
in a row. The envelopes come back **in the order the payloads were given**,
whatever order the broker confirmed them in, so a result can be matched to the
payload that produced it.

**It is not atomic**, and no library can make it so: AMQP has no way to publish a
hundred messages such that all or none arrive. What it does instead is say how
much did arrive — `3 of 500 messages were not confirmed; 497 were` — so a caller
does not republish hundreds of messages that are already on a queue. Java's
`sendAll` and .NET's `SendAllAsync` raise that sentence word for word.

How many messages may be unconfirmed at once is `max_outstanding_publishes`. A
batch larger than the ceiling is written in waves rather than held whole in this
process, which is what stops a large batch becoming a memory problem.

## Publishing from a request

Nothing special is needed and nothing should be built. The connection is already
open, it is thread-safe, and the publish is a round trip to the broker measured in
the same units as a database query.

Two things are worth knowing:

**A publish inside a database transaction is a lie waiting to happen.** The
message goes out when `publish` returns; the transaction commits later, or does
not. A consumer can read an event about a row that was rolled back.
`after_commit` narrows that window and does not close it, and the
[outbox](outbox.md) is what closes it — the message is written as a row in the same
transaction as the work, and a relay publishes what committed.

**A slow broker is a slow request.** `publish` waits for a confirm. That is
usually a millisecond or two and occasionally, on a broker under memory pressure
that has blocked the connection, not. [health.md](health.md) covers what blocking
means and why it is not a reason to restart anything; the ceiling that stops a
runaway loop holding a million messages in memory is
[`max_outstanding_publishes`](observability.md#the-publish-ceiling), and reaching it
raises rather than waiting.
