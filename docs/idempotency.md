# The idempotent consumer

**A handler will be called twice.** Not often, not by design, and not avoidably: a
broker redelivers whenever a consumer dies between doing the work and
acknowledging, the retry ladder redelivers on purpose, and the
[outbox](outbox.md) republishes what it could not confirm. AMQP has no
exactly-once delivery and neither does anything built on it.

So a handler either does not mind being called twice, or it is made not to mind.
This page is the second one.

It is also the reason this gem is not an ActiveJob adapter — `perform` has no
at-least-once contract and an adapter would hand people a double-charging bug with
a stack trace that says nothing about why. [not-activejob.md](not-activejob.md).

## The cheapest answer is usually not this page

Before reaching for a store, ask whether the work is already idempotent, because a
surprising amount of it is and a unique index is a shorter runbook entry than a
table with a lease in it.

```ruby
def call(message)
  # `find_or_create_by!` under a unique index is idempotent by construction. The
  # second delivery finds the row.
  Fulfilment.find_or_create_by!(order_id: message.payload["order_id"])
  accept
end
```

```ruby
def call(message)
  # An upsert is idempotent. So is any assignment: `status = "shipped"` twice is
  # `status = "shipped"`.
  Order.where(id: message.payload["order_id"]).update_all(status: "shipped")
  accept
end
```

What is *not* idempotent is an increment, an append, a charge, an email, and
anything that calls somebody else's API. Those are what the rest of this page is
for.

## The store

The library's contract is small: an object answering `first_time?(key)`, and
optionally `forget(key)` and `confirm(key)`. `Patterns.idempotent` wraps a handler
in it.

`AceMQ::AMQP::Patterns::SQLIdempotencyStore` drives a raw driver connection and has
the same problem `SQLOutboxStore` does under ActiveRecord on SQLite — see the box in
[outbox.md](outbox.md#the-store). An ActiveRecord store is shorter anyway, because
the whole mechanism is one insert:

```ruby
# db/migrate/20260926000100_create_acemq_idempotency.rb
class CreateAcemqIdempotency < ActiveRecord::Migration[7.1]
  def change
    create_table :acemq_idempotency, id: false do |t|
      t.string   :message_id,  null: false, limit: 255, primary_key: true
      t.string   :state,       null: false, limit: 16
      t.string   :claimed_by,  limit: 64
      t.datetime :recorded_at, null: false
      t.datetime :expires_at,  null: false
    end

    add_index :acemq_idempotency, :expires_at, name: "acemq_idempotency_expiry"
  end
end
```

```ruby
# app/models/handled_message.rb
class HandledMessage < ApplicationRecord
  self.table_name = "acemq_idempotency"
  self.primary_key = "message_id"
end
```

```ruby
# app/models/active_record_idempotency_store.rb
#
# The claim is the INSERT. That is the entire design: a primary key is the only
# thing in a database that two concurrent transactions cannot both win, so the row
# appearing *is* the answer to "am I the first?" — no read, no lock, no window
# between checking and deciding.
class ActiveRecordIdempotencyStore
  CLAIMED = "CLAIMED"
  CONFIRMED = "CONFIRMED"

  # How long a key is remembered. It has to be longer than the longest a duplicate
  # can take to arrive: the top rung of the retry ladder, a dead-letter queue
  # somebody drains by hand next week, a replay. A day is a starting point, not an
  # answer.
  RETENTION = 24 * 3600

  # How long a claim that never finished is honoured. Longer than the slowest
  # handler, or two consumers will work on one message at once; shorter than
  # anybody's patience, because a consumer killed mid-handler leaves the claim
  # behind and nothing retries the message until it expires.
  CLAIM_TIMEOUT = 300

  def initialize(worker: "#{Socket.gethostname}:#{Process.pid}")
    @worker = worker
  end

  def first_time?(key)
    now = Time.now.utc
    HandledMessage.create!(message_id: key.to_s, state: CLAIMED, claimed_by: @worker,
                           recorded_at: now, expires_at: now + RETENTION)
    true
  rescue ActiveRecord::RecordNotUnique
    # Somebody has the key. Take it over only if their claim has gone stale — and
    # only from a CLAIMED row, never from a CONFIRMED one, which is a message that
    # really was handled.
    taken = HandledMessage.where(message_id: key.to_s, state: CLAIMED)
                          .where(recorded_at: ...(now - CLAIM_TIMEOUT))
                          .update_all(claimed_by: @worker, recorded_at: now,
                                      expires_at: now + RETENTION)
    taken.positive?
  end

  # The handler finished. The key is now a fact rather than a claim, and no stale
  # claim takeover can touch it.
  def confirm(key)
    HandledMessage.where(message_id: key.to_s).update_all(state: CONFIRMED)
    nil
  end

  # The handler did not finish, so the key must not stand: the retry has to be
  # allowed to run. Only this worker's own live claim, and never a CONFIRMED row.
  def forget(key)
    HandledMessage.where(message_id: key.to_s, state: CLAIMED, claimed_by: @worker).delete_all
    nil
  end

  # Nothing on the handling path deletes a row. Schedule this.
  def purge_expired = HandledMessage.where(expires_at: ...Time.now.utc).delete_all
end
```

The three-state distinction is the part worth reading twice. `CLAIMED` means a
handler is working on it; `CONFIRMED` means one finished. Without that difference, a
consumer killed mid-handler leaves a key that looks handled and the redelivery is
dropped — the message is lost, by the machinery that exists to stop messages being
lost twice.

## Using it in a consumer

`Patterns.idempotent` returns a handler, and a consumer class is a handler, so the
two meet in `#call`:

```ruby
# app/consumers/payments_consumer.rb
class PaymentsConsumer < AceMQ::Rails::Consumer
  queue "shop.payments"
  retries max_attempts: 5, initial_delay: 1, max_delay: 300

  STORE = ActiveRecordIdempotencyStore.new

  def call(message)
    once.call(message)
  end

  private

  # Built once per instance, because the runner keeps one instance of each
  # consumer class for the life of the process.
  def once
    @once ||= AceMQ::AMQP::Patterns.idempotent(STORE) do |m|
      Payments.charge!(m.payload["order_id"], m.payload["amount_cents"])
      accept
    end
  end
end
```

`AceMQ::AMQP::Patterns.idempotent(store) { ... }` returns a `Proc`, so the block is
the real handler and `accept` inside it is the consumer's own private `accept` —
the block closes over `self`.

What the wrapper does, in order: ask the store whether this is the first time;
if it is not, **`Ack.accept` without running the handler**; if it is, run it, and
`forget` the key unless the handler accepted so that a retry is genuinely retried.

> **A duplicate is accepted, not rejected.** It is not an error — it is the
> broker doing its job — so it is settled and forgotten. A `reject` here would fill
> `{queue}.dlq` with correctly-handled messages, which is a dead-letter queue nobody
> can trust.

### Which key

By default, `message.envelope.id` — the `x-acemq-id` the publisher generated,
carried unchanged through every retry and every rung queue. That is the right key
for "the same message arrived twice".

It is the wrong key for "the same *thing* happened twice", which is what you
usually want. Two publishes of the same order from a user who double-clicked are
two message ids and one business event:

```ruby
AceMQ::AMQP::Patterns.idempotent(STORE, key: ->(m) { "charge:#{m.payload["order_id"]}" }) do |m|
  Payments.charge!(m.payload["order_id"], m.payload["amount_cents"])
  accept
end
```

Prefix the key. The table is shared by every consumer in the application, and
`A-1` meaning both an order id and an invoice id is a charge that silently never
happens.

A key function that returns nothing — a payload missing the field — is
`Ack.reject` with a `FatalError`, not a retry: the same function will produce the
same nothing next time, and a guard that cannot key a message is not guarding it.
So the message lands in `{queue}.dlq` with the reason attached, which is the
outcome you want for a payload that is not the shape the consumer was written for.

A store that raises is the other way round: `Ack.retry`, because the store is what
is broken and not the message, and carrying on would risk the duplicate the store
exists to prevent. A database outage therefore stops this consumer rather than
letting it charge twice — worth knowing before setting `max_attempts` low.

### As middleware instead

`Patterns.with_idempotency(store, key: nil)` is the same thing in
[pipeline](patterns.md#pipelines) form, for a consumer that is already composing
middleware. Identical semantics; pick whichever reads better in the class.

## The transaction question

The store's row and the handler's work are two writes. Committing them together is
the difference between "handled once" and "claimed once and possibly handled
nought times":

```ruby
def call(message)
  once.call(message)
end

private

def once
  @once ||= AceMQ::AMQP::Patterns.idempotent(STORE) do |m|
    # The claim is already committed by the time this block runs — `first_time?`
    # is its own INSERT, deliberately, because a claim inside the handler's
    # transaction is a claim that rolls back with it and stops being a claim.
    ActiveRecord::Base.transaction do
      Payments.charge!(m.payload["order_id"], m.payload["amount_cents"])
      STORE.confirm(m.envelope.id)
    end
    accept
  end
end
```

Calling `confirm` inside the transaction is what makes "the work committed" and
"the key is a fact" one event. The wrapper calls `confirm` for you when the handler
accepts, so this is belt and braces — but the braces are the ones that hold: the
wrapper's `confirm` is a separate statement after the transaction, and a process
killed in between leaves a `CLAIMED` row that a redelivery will take over after
`CLAIM_TIMEOUT` and charge again.

`confirm` is idempotent (`update_all` to the same value), so calling it twice costs
one statement.

**The claim cannot go in the transaction.** `first_time?` has to commit on its own,
because a claim that rolls back with the handler's work is not a claim at all — two
consumers would both roll back, both see no row, and both charge. That is why the
store is not simply `ActiveRecord::Base.transaction { ... }` around everything.

## Purging

Nothing deletes a row on the handling path — deliberately, because a delete on the
hot path is contention on the one table every message touches. So it is scheduled:

```ruby
# lib/tasks/acemq_idempotency.rake — hourly
namespace :acemq do
  desc "Remove idempotency keys past their retention"
  task purge_idempotency: :environment do
    puts "removed #{ActiveRecordIdempotencyStore.new.purge_expired} expired keys"
  end
end
```

An unpurged table grows by one row per message for ever, and the index on
`expires_at` exists so that this task is cheap rather than a table scan.

## In development and in tests

`AceMQ::AMQP::Patterns::InMemoryIdempotencyStore` is the library's own, with a
sliding window and no database:

```ruby
store = AceMQ::AMQP::Patterns::InMemoryIdempotencyStore.new(window: 6 * 3600)
```

Correct for one process and wrong for two, which makes it right for a spec and
wrong for production — two consumer processes each with their own memory is exactly
the case the pattern exists for.

A consumer spec does not need a store at all when what is being tested is the
handler:

```ruby
RSpec.describe PaymentsConsumer do
  let(:store) { AceMQ::AMQP::Patterns::InMemoryIdempotencyStore.new }
  let(:message) do
    AceMQ::AMQP::Message.new(
      payload: { "order_id" => "A-1", "amount_cents" => 1299 },
      envelope: AceMQ::AMQP::Envelope.new(id: "m-1", type: "payment.due.v1")
    )
  end

  it "charges once however many times the broker delivers it" do
    consumer = described_class.new
    stub_const("#{described_class}::STORE", store)

    3.times { expect(consumer.call(message)).to be_accept }

    expect(Payments).to have_received(:charge!).once
  end
end
```

Three deliveries, three accepts, one charge. That assertion is the whole pattern,
and it needs no broker — see [testing.md](testing.md).

## Operating it

| | |
|---|---|
| `HandledMessage.where(state: "CLAIMED").where(recorded_at: ...5.minutes.ago)` | Claims that never finished. A handful is a deploy; a growing number is a handler that dies |
| `HandledMessage.count` | Should track message volume over the retention window, and should stop growing once purging runs |

The counter worth graphing is not in the table: it is how often `first_time?`
answered false. A rate that is normally near zero and spikes is a redelivery storm,
which usually means a consumer is being killed before it acknowledges — a
`shutdown_timeout` shorter than the handlers, most often. [lifecycle.md](lifecycle.md).

## See also

- [Outbox](outbox.md) — the other half; at-least-once is why this page exists
- [Consumers](consumers.md) — `accept`, `retry_later`, `reject`, `park`
- [Why this is not an ActiveJob adapter](not-activejob.md)
- [The library's patterns page](https://acemq.org/acemq-ruby-amqp/patterns.html)
