# Why this is not an ActiveJob adapter

It would be a day's work and it is deliberately not here. This page is the
argument, because "we did not get round to it" and "we decided not to" look the
same from outside, and only one of them is true.

## They are different things

ActiveJob is an abstraction over **background jobs**: work this application wants
done later, by this application. A job is a Ruby class name and some arguments,
serialised, put somewhere, and pulled back out by a worker that has the same
codebase.

AMQP messaging is **integration**: an event this service publishes, and whoever
is listening reads. The other end may be a Java service, a Python one, or nobody
yet. The message is a contract, not a method call.

Almost everything ActiveJob offers is about the first, and is either meaningless
or actively wrong for the second.

## What breaks, specifically

**Delivery is at-least-once, and ActiveJob has no concept of that.** A broker
redelivers whenever a worker dies before acknowledging, and a handler has to be
idempotent. `perform` has no such contract — the whole mental model of ActiveJob
is that a job runs once — so an adapter would quietly hand people a
double-charging bug and a stack trace that says nothing about why.

**There is no job identity to restore.** ActiveJob serialises a class name and
its arguments; deserialising means `constantize` on a string off the wire. For a
queue only this application publishes to, that is a pit of despair with a known
name — `Marshal`-adjacent remote code execution — and for a queue anything else
publishes to, it simply does not work: a message from a Java producer carries no
Ruby class name, and never will.

**Retries would be counted twice.** ActiveJob has `retry_on`, with its own
attempt counting, its own backoff, and its own dead-letter idea
(`discard_on`). AceMQ has a retry ladder with rung queues in the broker, an
attempt count carried in `x-acemq-attempt` on the message, and `{queue}.dlq` with
the failure reason attached — and that arithmetic is the same in the Java, Go,
.NET and Python libraries, on purpose, so one runbook covers an estate. An
adapter would have to pick one and silently disable the other. Whichever it
picked would be wrong for somebody, and the failure would show up as "why did
this retry eleven times".

**The queue name means something else.** ActiveJob's `queue_as` is a priority
lane inside one application. An AMQP queue is a binding on an exchange with a
routing key, a durability, a type, and a dead-letter policy that two services in
two languages have to agree on. Mapping the first onto the second means either
ignoring everything that makes the second work, or inventing a configuration
language for it that is not ActiveJob's.

**`perform_later` cannot report failure honestly.** ActiveJob's contract is
enqueue-and-forget. `AceMQ::Rails.publish` waits for the broker to confirm and
raises `PublishError` if it does not, which is the difference between "the bytes
reached a socket" and "the broker has it". An adapter would have to swallow that
or block inside `perform_later`, and both are surprises.

## What to do instead

If you want background jobs, use ActiveJob with a job backend — Solid Queue,
Sidekiq, GoodJob. They are good at it, and none of them is trying to also be an
integration bus.

If you want messaging, use this gem. They coexist happily in one application, and
the combination is often the right one:

```ruby
class OrdersConsumer < AceMQ::Rails::Consumer
  queue "shop.orders"

  def call(message)
    # The message is the integration contract. The job is this application's
    # own work, with this application's own retry semantics.
    FulfilmentJob.perform_later(message.payload["order_id"])
    accept
  end
end
```

That handler is short, idempotent and fast, which is what a handler wants to be,
and the slow unreliable part runs where Rails can see it. The seam between the
two is explicit, which is the thing an adapter would have hidden.

## The one thing an adapter would have given us

A familiar name. `OrdersJob.perform_later` reads more like Rails than
`AceMQ::Rails.publish(..., to:, exchange:)` does, and there is a real cost to
that.

It is not worth what it hides. Every one of the problems above is silent — a
duplicate charge, a retry count that does not match the dashboard, a message from
another language that cannot be deserialised at all. Familiarity that leads
somewhere wrong is worse than a name somebody has to learn once.
