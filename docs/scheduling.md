# Scheduling

A message delivered later. No plugin, no scheduler process of its own, no table.

```ruby
scheduler.in(4 * 3600, invoice.as_json, to: "invoice.due", exchange: "shop-billing")
scheduler.at(policy.renews_at, policy.as_json, to: "policy.renew", exchange: "shop-policies")
```

## When this is the wrong tool

**If the work is this application's own, use ActiveJob.** `SomeJob.set(wait: 4.hours)
.perform_later` with Solid Queue behind it is a better fit for "do this later, here",
and this gem [has an opinion about why](not-activejob.md) the two are different
things. A delayed job is a note to self. A delayed *message* is a note to whoever is
listening, which may be a Java service, and that is the case this page is for.

**If the delay has to be exact, this is not it.** The mechanism is TTL queues, and
the section below says what that costs.

**If you want a cron, this is not it either.** There is no recurring anything here:
each scheduled message is scheduled once, by something that decided to. A cron is
`whenever`, `cron`, a Kubernetes `CronJob`, or `solid_queue`'s recurring tasks —
publishing a message from one of those is the normal shape.

## How it works, because the cost follows from it

Five queues, each with an `x-message-ttl` — an hour, ten minutes, a minute, ten
seconds, a second — that dead-letter into one control queue. A message due in four
hours goes onto the hour rung four times, then onto the shorter rungs to make up the
remainder, and arrives at the control queue when the total has elapsed. The control
consumer reads it and republishes it to where it was actually addressed.

Two consequences, both worth knowing before this appears in a runbook:

**Delivery is accurate to about the smallest rung.** Ask for three seconds and you
may get two. The library's own example prints exactly that, on purpose. For an
invoice due in four hours nobody notices; for "retry this in 500ms" it is not a
mechanism at all.

**It costs a round trip per hop.** A four-hour delay is several passes through the
broker. Cheap, and not free, and a million long-delayed messages is a million
messages sitting in rung queues on disk — which is fine, because that is what a
broker is, but it is not a database row.

## Running it

`Patterns::Scheduler.on(connection)` **declares its topology and subscribes to the
control queue as it is constructed.** So it is not something a web process builds:
building one in Puma gives every worker a control consumer, and the same message
republished by whichever one got it. It belongs in the consumer process.

```ruby
# config/initializers/acemq_scheduler.rb
require "acemq/amqp/patterns"

# Only in the process that runs consumers — the one whose program is the
# executable. `acemq-consumer` sets no flag of its own, so this is the question
# that distinguishes it from Puma and from a rake task.
if $PROGRAM_NAME.end_with?("acemq-consumer")
  Rails.application.config.after_initialize do
    ACEMQ_SCHEDULER = AceMQ::AMQP::Patterns::Scheduler.new(AceMQ::Rails.connection)
    at_exit { ACEMQ_SCHEDULER.close }
  end
end
```

`at_exit` registered here runs before the Railtie's own, which closes the connection
— `at_exit` handlers run in reverse order of registration, and this one is
registered later because `config.after_initialize` in an initializer runs after the
Railtie's.

The control consumer subscribes on the raw transport rather than through
`Connection#consume`, which means it deliberately has **no dead-letter queue and no
parked queue of its own**. A malformed scheduled message is dropped and counted
rather than kept. That is the library's decision and there is nothing to configure;
`ACEMQ_SCHEDULER.malformed` is the counter, and anything above nought means somebody
is publishing to `acemq.schedule` by hand.

### Declaring the queues in a deploy step

`Scheduler.declare(connection)` makes the queues without subscribing, which is what
belongs beside `bin/rails acemq:topology`:

```ruby
# lib/tasks/acemq_scheduler.rake
namespace :acemq do
  desc "Declare the scheduler's rung queues"
  task schedule_topology: :environment do
    require "acemq/amqp/patterns"

    names = AceMQ::AMQP::Patterns::Scheduler.declare(AceMQ::Rails.connection)
    puts "declared #{names.join(", ")}"
    AceMQ::Rails.disconnect!
  end
end
```

Worth doing rather than leaving it to the first consumer process, for the reason
[topology.md](topology.md) gives about everything else: the rung names, their TTLs
and the exchange are a **cross-language contract**. `acemq.schedule`,
`acemq.schedule.due` and the rung TTLs are the same in the Java, Go, .NET and Python
libraries. Declare one rung with a different TTL and the next service to declare it
is refused with `PRECONDITION_FAILED` and cannot schedule at all.

Which is also the reason not to reach into `Scheduler`'s queues and change anything.

## Scheduling from a request

**You cannot, and there is no configuration key that changes that.** `Scheduler.new`
subscribes to the control queue as part of being constructed, so a web process
cannot hold one merely to publish with — and a control consumer in each of four Puma
workers is the failure this page opened with.

Nor is publishing into the rung queues by hand an answer. It looks like three
headers and it is not: the due time is milliseconds since the epoch rather than a
timestamp, the body is the codec's bytes rather than a payload, the content type
travels as a fourth header so the eventual consumer can choose a codec, and the rung
a message starts on is arithmetic against the time remaining. The library says those
queues "are an implementation detail of this class", and it counts every message that
arrives in them looking wrong as `malformed`. A reimplementation here would be a
copy of a private contract, wrong on the first release that changed it.

The answer is to not schedule from a request:

```ruby
# The controller publishes an ordinary event. A consumer decides that something
# should happen later, and that consumer is in the process that has a scheduler.
class InvoicesController < ApplicationController
  def create
    invoice = Invoice.create!(invoice_params)
    AceMQ::Rails.publish(invoice.as_json, to: "invoice.raised", exchange: "shop-billing")
    head :created
  end
end
```

```ruby
class InvoicesConsumer < AceMQ::Rails::Consumer
  queue "shop.invoices"

  def call(message)
    invoice = Invoice.find(message.payload["id"])
    ACEMQ_SCHEDULER.at(invoice.due_at, invoice.as_json,
                       to: "invoice.due", exchange: "shop-billing")
    accept
  end
end
```

The controller stays fast, the scheduling lives in the process that owns a scheduler,
and the seam between them is a message — which is the shape this whole site keeps
arriving at.

## Receiving a scheduled message

Nothing special. It arrives at the exchange and routing key it was addressed to, as
an ordinary message, so the consumer is an ordinary consumer:

```ruby
class InvoiceDueConsumer < AceMQ::Rails::Consumer
  queue "shop.invoices.due"

  def call(message)
    # Scheduled delivery is at-least-once like everything else, and a rung hop that
    # is retried is a second copy. Check rather than assume.
    invoice = Invoice.find(message.payload["id"])
    return accept if invoice.paid?

    Reminders.send!(invoice)
    accept
  end
end
```

The `type` is `ScheduledMessage` on the way through the rungs and whatever the
original publisher set once it arrives, so a consumer cannot tell a scheduled message
from an immediate one — which is the point, and the reason the check above is about
the invoice rather than about the message.

## What to watch

| | |
|---|---|
| `ACEMQ_SCHEDULER.scheduled` | Messages accepted for later delivery |
| `ACEMQ_SCHEDULER.delivered` | Messages that came due and were republished |
| `ACEMQ_SCHEDULER.hops` | Rung passes. Divided by `delivered`, how many round trips a delay is costing |
| `ACEMQ_SCHEDULER.malformed` | Dropped. Should be nought |

`delivered` lagging `scheduled` by more than the longest delay in flight means the
control consumer is not running — most often because nothing started a scheduler in
the process that was supposed to have one. The rung queues fill up quietly in that
case: the messages are safe and nothing is delivering them.

[observability.md](observability.md) has the reporter these hand to.

## See also

- [Patterns](patterns.md) — the require, and where each pattern runs
- [Why this is not an ActiveJob adapter](not-activejob.md) — the delayed-job
  distinction, at length
- [Topology](topology.md) — declaration, drift and `PRECONDITION_FAILED`
- [The library's patterns page](https://acemq.org/acemq-ruby-amqp/patterns.html)
