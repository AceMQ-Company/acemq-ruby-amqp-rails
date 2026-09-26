# Sagas

A saga is several steps that each change the world, and a way to undo the ones that
succeeded when a later one fails. It is what you use when the steps are not all in
your database, because `ActiveRecord::Base.transaction` is the better answer
whenever they are.

```ruby
ActiveRecord::Base.transaction do
  payment = Payment.create!(...)      # your database
  Stripe::Charge.create(...)          # not your database
  Order.update!(status: "paid")       # your database
end
```

That transaction rolls back two of the three. The charge stands. A saga is the
pattern for the third line: an explicit list of steps, each with the thing that
undoes it.

## What it is not

**Not durable.** `AceMQ::AMQP::Patterns::Saga` runs in one process and keeps its
state on the Ruby stack. A process killed mid-saga leaves the world half-changed and
nothing anywhere to resume from. This is the single most important sentence on the
page: if the steps must survive a deploy, a saga object is not enough and you want
the steps to be messages, with the outbox behind each one.

**Not a distributed transaction.** Compensation is a *new* fact, not an erasure. A
refund is a refund; the charge is still in the statement. Design the steps knowing
that somebody will read the audit trail.

**Not a broker pattern at all.** Nothing in `Saga` touches AMQP. It needs no
connection, no queue and no topology. It is here because the library ships it and
because a consumer is where you usually want one.

## Building one

```ruby
# app/models/order_placement.rb
require "acemq/amqp/patterns"

class OrderPlacement
  SAGA = AceMQ::AMQP::Patterns::Saga.named("place-order") do |saga|
    saga.step("take-payment") { |order| Payments.charge!(order) }
        .compensate_with       { |order| Payments.refund!(order) }

    saga.step("reserve-stock") { |order| Inventory.reserve!(order) }
        .compensate_with       { |order| Inventory.release!(order) }

    # No compensation, and last on purpose. An email cannot be unsent, so it goes
    # where nothing after it can fail.
    saga.step("tell-the-customer") { |order| OrderMailer.placed(order).deliver_now }
  end

  def self.run(order) = SAGA.run(order)
end
```

Every step is handed the same subject — the `order` — and the compensation for a
step is handed the same subject again. There is no accumulated context object: if a
step needs something a previous one produced, put it on the subject.

`compensate_with` attaches to the step immediately above it and raises if there is
no step yet, so the two cannot drift apart. A duplicate step name raises too, which
matters because the name is what a result reports.

Built once, in a constant, because a saga is a description and not a run. `run` is
what has state, and it takes it as arguments.

## Running one

```ruby
class OrdersConsumer < AceMQ::Rails::Consumer
  queue "shop.orders"

  def call(message)
    order = Order.find(message.payload["order_id"])
    result = OrderPlacement.run(order)

    return accept if result.complete?

    if result.unresolved?
      # Compensation itself failed. Somebody has to look: the world is in a state
      # no code here knows how to fix.
      Rails.error.report(result.failure, context: { saga: "place-order",
                                                    failed_at: result.failed_at,
                                                    unresolved: result.unresolved })
      return park("compensation failed at #{result.failed_at}")
    end

    # Compensated cleanly, so nothing is half-done. Whether to retry depends on why
    # it failed, which is what `failure` says.
    retry_later("#{result.failed_at}: #{result.failure.message}")
  end
end
```

`run` **never raises for a step failure** — that is the whole interface. It returns
a `SagaResult`, and the three questions to ask it are:

| | |
|---|---|
| `complete?` | Every step ran |
| `compensated?` | A step failed and every compensation succeeded |
| `unresolved?` | A compensation *also* failed. The one to alert on |
| `failed_at` | The name of the step that failed |
| `failure` | The exception it raised |
| `completed` | The step names that ran |
| `unresolved` | The compensations that failed |

Compensation runs **most recent first**, and it keeps going through failures rather
than stopping at the first — so `unresolved` may have several entries, and a saga
that failed at step four reports what it could not undo of steps one to three.

The exception to "never raises" is anything that is not a `StandardError` —
`Interrupt`, `SignalException`. Those travel out uncaught and **uncompensated**,
which means a `SIGTERM` arriving mid-saga leaves the work half-done. That is the
non-durability again, and it is the argument for keeping sagas short and for setting
`shutdown_timeout` longer than the slowest one. [lifecycle.md](lifecycle.md).

## The ActiveRecord parts of a step

A step that touches the database is a step running on a bunny thread, so it needs
what every handler needs. Inside a consumer class that is already true — the runner
wraps `#call` in `Rails.application.executor.wrap` — so the steps inherit it and
nothing more is needed.

Driven from anywhere else (a rake task, a `Patterns.serve` responder) it is not
true, and [patterns.md](patterns.md#the-executor-once-for-all-of-them) is the page
about that.

What the executor does not give you is a transaction, and a step should usually have
one:

```ruby
saga.step("reserve-stock") do |order|
  ActiveRecord::Base.transaction { Inventory.reserve!(order) }
end.compensate_with do |order|
  ActiveRecord::Base.transaction { Inventory.release!(order) }
end
```

A step that half-committed is a step whose compensation does not know what to undo.
Wrap the step, not the saga: a transaction around `run` would roll back the
database work and leave the third-party calls standing, which is the problem the
saga was for.

## Durable steps instead

When the saga has to survive a restart, each step becomes a message and the saga
becomes the queues:

```
order.placed      -> PaymentsConsumer   -> publishes payment.taken   (or payment.refused)
payment.taken     -> InventoryConsumer  -> publishes stock.reserved  (or stock.refused)
stock.refused     -> RefundsConsumer    -> refunds the payment
```

Each consumer writes its outgoing message through the [outbox](outbox.md) in the same
transaction as its own work, so a step either happened and announced itself or did
neither. Restarting the process changes nothing: the messages are on queues.

The library has a shape for this, and it is [routing
slips](patterns.md#routing-slips-and-declared-pipelines) — `Patterns::Pipeline`
declares the exchange, the routing keys and the queue per step, so the itinerary is
declared once rather than being three consumers that happen to agree.

The cost is that compensation stops being a block and becomes a consumer, and the
saga stops being readable in one screen. Which is why `Saga` exists for the cases
that fit in one process, and why this section exists for the ones that do not.

## Testing one

A saga is plain Ruby, so this is the easiest thing on the whole site to test:

```ruby
RSpec.describe OrderPlacement do
  it "refunds the payment when stock cannot be reserved" do
    allow(Inventory).to receive(:reserve!).and_raise(Inventory::Unavailable)

    result = described_class.run(order)

    expect(result).to be_compensated
    expect(result.failed_at).to eq("reserve-stock")
    expect(Payments).to have_received(:refund!).with(order)
  end

  it "reports what it could not undo" do
    allow(Inventory).to receive(:reserve!).and_raise(Inventory::Unavailable)
    allow(Payments).to receive(:refund!).and_raise(Payments::Unreachable)

    result = described_class.run(order)

    expect(result).to be_unresolved
    expect(result.unresolved.size).to eq(1)
  end
end
```

No broker, no connection, no queue. The second example is the one most suites are
missing, and it is the one that fails in production.

## See also

- [Patterns](patterns.md) — the require, and where each pattern runs
- [Outbox](outbox.md) — what makes a durable step durable
- [The library's patterns page](https://acemq.org/acemq-ruby-amqp/patterns.html)
