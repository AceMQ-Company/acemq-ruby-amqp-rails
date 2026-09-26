# The transactional outbox

`AceMQ::Rails.publish` goes out when it is called. An `ActiveRecord` transaction
commits later, or does not. Between those two facts sits the bug this pattern
exists for:

```ruby
# Wrong, and wrong in a way that only shows up under load.
Order.transaction do
  order = Order.create!(order_params)
  AceMQ::Rails.publish(order.as_json, to: "order.placed", exchange: "shop-events")
  Inventory.reserve!(order)     # raises
end
```

The message is on the broker. The row is not. Somewhere a warehouse is picking
stock for an order that does not exist, and there is nothing in this application's
logs that looks wrong.

## `after_commit` narrows it, and does not close it

The first thing everybody reaches for is right as far as it goes:

```ruby
class Order < ApplicationRecord
  after_commit :announce, on: :create

  private

  def announce
    AceMQ::Rails.publish(as_json, to: "order.placed", exchange: "shop-events")
  end
end
```

**Use `after_commit` and not `after_save` or `after_create`** for anything that
leaves the process. `after_save` runs inside the transaction, so it is the broken
example above with the publish moved into the model. `after_commit` runs after the
database has committed, so a rollback publishes nothing. That is a real
improvement and most applications should stop here.

What it cannot fix is the other order of the same problem. The transaction commits;
this process is killed, or the broker is unreachable, or the publish raises
`PublishError` — and now the row exists and the message does not. `after_commit`
moved the window, from "message without a row" to "row without a message", and the
second is quieter: nothing raises anywhere, and the only symptom is a fulfilment
that never started.

Two further things about `after_commit` worth knowing before relying on it:

- **It is not in the transaction, so it cannot be retried by the transaction.** An
  exception raised in an `after_commit` callback does not roll anything back. It
  propagates out of the `save!` to the caller, which by then is a controller with a
  committed row and a 500.
- **It does not run at all if the process dies first.** There is no queue of
  pending callbacks anywhere.

Whether that window matters is a judgement about the message. "A user changed their
avatar" — `after_commit` is fine. "An order was placed" — it is not, and the rest
of this page is what to do instead.

## What the outbox does

Write the message into the same transaction as the work, as a row. Commit both or
neither. A separate process reads the rows and publishes them.

```
transaction:  INSERT INTO orders ...      ┐
              INSERT INTO acemq_outbox ...┘  both, or neither

relay:        SELECT ... WHERE published_at IS NULL
              publish, wait for the confirm
              UPDATE ... SET published_at = now
```

The guarantee is **at-least-once**, and deliberately. A record is marked published
only after the broker has confirmed it, so a crash in that gap publishes it again.
The alternative — mark first, publish second — loses messages, and a duplicate can
be recognised where an absence cannot. So every consumer of anything sent this way
has to be idempotent, which is why [idempotency.md](idempotency.md) is the page
after this one.

## The store

The library ships `AceMQ::AMQP::Patterns::SQLOutboxStore`, which drives a raw
`SQLite3::Database` or `PG::Connection`. In a Rails application the transaction is
`ActiveRecord::Base.transaction`, and the store contract is three methods, so the
store belongs in the application where ActiveRecord can see it.

> **`SQLOutboxStore` does not work against `ActiveRecord::Base.connection.raw_connection`
> on SQLite.** ActiveRecord sets `results_as_hash = true` on its sqlite3
> connection; the library's wrapper calls `execute` and expects arrays, so every
> `SELECT` comes back as hashes and reads silently return nothing. Inserts work.
> The relay publishes nothing and says nothing. On PostgreSQL the raw connection is
> an untouched `PG::Connection` and the wrapper uses `exec_params(...).values`, so
> that combination is unaffected — but a store written against ActiveRecord works
> on both, and on whatever the next application uses.

### The migration

The column names are the library's, and they are worth keeping even though nothing
here enforces them: the same table exists in the Java, Go, .NET and Python
libraries, so an operator's "what is stuck in the outbox" query is one query for
the estate rather than one per service.

```ruby
# db/migrate/20260926000000_create_acemq_outbox.rb
class CreateAcemqOutbox < ActiveRecord::Migration[7.1]
  def change
    create_table :acemq_outbox, id: :string, limit: 64 do |t|
      t.string   :exchange_name, null: false, limit: 255
      t.string   :routing_key,   null: false, limit: 255
      t.text     :body,          null: false
      t.string   :body_encoding, null: false, limit: 16
      t.string   :content_type,  null: false, limit: 255
      t.text     :headers,       null: false
      t.datetime :created_at,    null: false
      t.datetime :published_at
      t.integer  :attempts,      null: false, default: 0
      t.string   :last_error,    limit: 1000
      t.string   :locked_by,     limit: 64
      t.datetime :locked_until
    end

    add_index :acemq_outbox, %i[published_at created_at], name: "acemq_outbox_pending"
  end
end
```

`id: :string` because the primary key is the message id — the same id the message
carries in `x-acemq-id` on the wire. That is what makes "adding the same record
twice" harmless when a transaction is retried, and it is what lets somebody match a
row to a message in a broker trace.

The index is on `(published_at, created_at)` because that is the relay's query, and
an outbox without it gets slower every day it runs.

**`body` is text, not binary.** A table somebody may have to read during an
incident is worth more than a few bytes. A body that is *not* text — anything a
binary codec, a claim check or `EncryptedCodec` produced — is stored base64 with
`body_encoding` saying so, because PostgreSQL refuses invalid UTF-8 in a text
column and losing the message to a driver error would be the worse trade.

### The model and the store

```ruby
# app/models/outbox_message.rb
class OutboxMessage < ApplicationRecord
  self.table_name = "acemq_outbox"
end
```

```ruby
# app/models/active_record_outbox_store.rb
#
# The three methods AceMQ::AMQP::Patterns::OutboxRelay calls — add, pending,
# mark_published — plus mark_failed, which the relay calls only if the store has
# it. Nothing here is Rails-specific except that all of it goes through
# ActiveRecord, which is the point: the insert joins whatever transaction the
# caller is already in, on whatever database the application uses.
class ActiveRecordOutboxStore
  # Seconds a relay holds a record it has claimed. Longer than the slowest
  # publish, shorter than anybody's patience: a relay killed mid-batch leaves
  # records locked until this expires.
  LEASE = 60

  # Failures before a record is left alone. Without a ceiling, one record nothing
  # can publish is claimed on every sweep for ever and the ones behind it wait.
  MAX_ATTEMPTS = 10

  def add(record)
    body, encoding = encode(record.body)
    OutboxMessage.create!(
      id: record.id, exchange_name: record.exchange.to_s,
      routing_key: record.routing_key.to_s, body: body, body_encoding: encoding,
      content_type: record.content_type.to_s,
      headers: JSON.generate(record.headers || {}),
      created_at: record.created_at || Time.now.utc, attempts: 0
    )
    nil
  rescue ActiveRecord::RecordNotUnique
    # The caller is retrying its own transaction. One message, not two.
    nil
  end

  # Claimed under a lease rather than merely read. Two relays that both read the
  # same batch both publish it, and that duplicate is the one a relay can avoid
  # without any help from the consumer.
  def pending(limit = 0)
    token = SecureRandom.uuid
    now = Time.now.utc
    limit = limit.to_i.positive? ? [limit.to_i, 1_000].min : 1_000

    claimable = free(now).order(:created_at, :id).limit(limit)
    # The claim is conditional on the row still being free, so whichever relay
    # gets there second updates nothing and reads nothing back.
    free(now).where(id: claimable.pluck(:id))
             .update_all(locked_by: token, locked_until: now + LEASE)

    OutboxMessage.where(locked_by: token, published_at: nil)
                 .order(:created_at, :id).map { |row| to_record(row) }
  end

  def mark_published(id)
    OutboxMessage.where(id: id)
                 .update_all(published_at: Time.now.utc, locked_by: nil, locked_until: nil)
    nil
  end

  # Counting the attempt is what eventually stops an unpublishable record being
  # claimed for ever; giving the lease up is what lets the next sweep try it
  # rather than waiting a minute for nothing.
  def mark_failed(id, reason)
    OutboxMessage.update_counters(id, attempts: 1)
    OutboxMessage.where(id: id).update_all(last_error: reason.to_s[0, 1_000],
                                           locked_by: nil, locked_until: nil)
    nil
  rescue StandardError
    # Already the failure path. A relay that died here would leave the record
    # locked rather than free, which is worse than letting the lease expire.
    nil
  end

  def pending_count = OutboxMessage.where(published_at: nil).count

  # Nothing removes published rows otherwise, and a table that only grows makes
  # the relay's own query slow. How long to keep them is an auditing decision.
  def purge_published(older_than)
    OutboxMessage.where.not(published_at: nil)
                 .where(published_at: ...(Time.now.utc - older_than)).delete_all
  end

  private

  def free(now)
    OutboxMessage.where(published_at: nil)
                 .where(attempts: ...MAX_ATTEMPTS)
                 .where("locked_until IS NULL OR locked_until < ?", now)
  end

  def to_record(row)
    AceMQ::AMQP::Patterns::OutboxRecord.new(
      id: row.id, exchange: row.exchange_name, routing_key: row.routing_key,
      body: decode(row.body, row.body_encoding), content_type: row.content_type,
      headers: JSON.parse(row.headers), created_at: row.created_at
    )
  end

  def encode(body)
    text = body.to_s.dup.force_encoding(Encoding::UTF_8)
    text.valid_encoding? ? [text, "utf-8"] : [[body.to_s].pack("m0"), "base64"]
  end

  def decode(body, encoding) = encoding == "base64" ? body.to_s.unpack1("m0") : body.to_s
end
```

## Writing a message

`AceMQ::AMQP::Patterns.record` builds the row's contents from the connection's own
codec and origin, so a message that went through the outbox is **indistinguishable
on the wire** from one that did not. That is the point of it: the outbox is a
delivery mechanism, not a second kind of message.

```ruby
# app/models/order.rb
class Order < ApplicationRecord
  def self.place!(params, outbox: ActiveRecordOutboxStore.new)
    transaction do
      order = create!(params)
      Inventory.reserve!(order)

      outbox.add(
        AceMQ::AMQP::Patterns.record(
          AceMQ::Rails.connection, order.as_json,
          to: "order.placed", exchange: "shop-events", type: "order.placed.v2"
        )
      )
      order
    end
  end
end
```

No `after_commit`, and none wanted: the insert *is* inside the transaction, which
is the whole mechanism. A rollback takes the outbox row with it.

`require "acemq/amqp/patterns"` has to have happened — `AceMQ::AMQP::Patterns` is
not loaded by `require "acemq/amqp"`. An initializer is the place for it; see
[patterns.md](patterns.md).

> **`Patterns.record` reads `AceMQ::Rails.connection`**, which opens the socket on
> first use. That is not a publish and does not wait for the broker, but it does
> mean the first order placed after a deploy dials the broker inside a database
> transaction. If that bothers you — and on a slow broker it should —
> `connect_on_boot: true` moves it to boot, where a transaction is not open.

## The relay

A thread that publishes for ever, which makes it a process. Not Puma, for every
reason [consumers.md](consumers.md) gives about consumers and one more: a relay in
each of four web workers is four relays competing for the same rows, and the lease
is all that stops them publishing the same message four times.

The consumer process is already the right process, so put it there:

```ruby
# config/initializers/acemq_outbox.rb
require "acemq/amqp/patterns"

# Only in the process that runs consumers. `acemq-consumer` sets no flag of its
# own, so this is the question that distinguishes it from Puma and from a rake
# task: it is the process whose program is the executable.
if $PROGRAM_NAME.end_with?("acemq-consumer")
  Rails.application.config.after_initialize do
    relay = AceMQ::AMQP::Patterns::OutboxRelay.new(
      AceMQ::Rails.connection, ActiveRecordOutboxStore.new,
      interval: 1, batch: 100,
      on_error: lambda { |error, exchange:, routing_key:|
        Rails.error.report(error, context: { outbox: exchange, routing_key: routing_key })
      }
    ).start

    at_exit { relay.close }
  end
end
```

Three details in there are load-bearing.

**`on_error` with keywords gets the destination.** The library inspects the
callable: a one-argument callback is handed the exception, and one declaring
`exchange:`/`routing_key:` is handed those too. "The outbox cannot reach
`shop-events`" is actionable in a way that "a sweep failed" is not.

**`at_exit { relay.close }`** stops the thread and waits for the sweep in progress.
It runs before the Railtie's own `at_exit` closes the connection, because `at_exit`
handlers run in reverse order of registration and this one is registered later —
which is the order you want, since a relay publishing on a closed connection would
raise on the way out.

**A failed sweep is not fatal**, and that is the point of an outbox. The records
are still there and the next tick tries again. Nothing is lost by the relay being
down, only delayed — which is the sentence to put in the runbook.

### Flushing on demand

`sweep` publishes one batch and returns how many went out, so a request can flush
its own message instead of waiting up to an interval:

```ruby
order = Order.place!(order_params)
RELAY.sweep      # the message is on the broker before the response is rendered
```

It raises whatever the broker or the store raised, unlike the background thread
which reports. In a controller that means a 500 for a message that is safely in the
table and will go out on the next tick anyway, so this is usually the wrong trade —
worth it in a test, where waiting a second for a tick is the difference between a
suite that is fast and one that is flaky.

### Its own process instead

A relay in the consumer process shares that process's fate: scaling consumers
scales relays, and the lease is doing real work. A relay of its own is a rake task
and a third Deployment:

```ruby
# lib/tasks/acemq_relay.rake
namespace :acemq do
  desc "Publish what the outbox holds, until interrupted"
  task relay: :environment do
    require "acemq/amqp/patterns"

    relay = AceMQ::AMQP::Patterns::OutboxRelay.new(
      AceMQ::Rails.connection, ActiveRecordOutboxStore.new, interval: 1
    ).start

    stopping = Thread::Queue.new
    %w[INT TERM].each { |signal| Signal.trap(signal) { stopping << signal } }
    stopping.pop

    relay.close
    AceMQ::Rails.disconnect!
  end
end
```

One replica is enough and two are safe. The lease means the second one finds
nothing to claim rather than publishing everything twice, so this is the one place
in this repository where `replicas: 2` is for availability rather than throughput.

## What the outbox does not do

**It is not ordered across records.** A failing record stops the batch rather than
being stepped over — the records were written in an order somebody meant, and
skipping one invents a reordering — but nothing guarantees that two transactions
committing at the same moment produce rows the relay reads in the order they
committed. If order matters, it matters per key, and that is
[`Patterns.ordered`](patterns.md#ordering) and a partitioned routing key.

**It does not apply publish interceptors.** The relay writes to the transport
directly, because a record already holds encoded bytes and rendered headers. So an
interceptor that stamps `tenant` on every publish does not reach an outbox message
— the headers were fixed when `Patterns.record` ran. Stamp it there, or in the
envelope:

```ruby
AceMQ::AMQP::Patterns.record(AceMQ::Rails.connection, order.as_json,
                             to: "order.placed", exchange: "shop-events",
                             type: "order.placed.v2",
                             headers: { "tenant" => Current.tenant })
```

**It does not make anything exactly-once.** See the first section: at-least-once,
on purpose. [idempotency.md](idempotency.md).

## Operating it

The two questions worth a dashboard:

```ruby
ActiveRecordOutboxStore.new.pending_count                      # the backlog
OutboxMessage.where(published_at: nil).where(attempts: 10..)   # the stuck ones
```

A pending count that goes up and stays up is a relay that is down or a broker that
is refusing. A row with `attempts` at the ceiling has a `last_error` saying why,
and it will never be tried again — which is deliberate, and means somebody has to
look.

And purging, which nothing does for you:

```ruby
# lib/tasks/acemq_outbox.rake — daily, from cron or whatever schedules things here
task purge_outbox: :environment do
  puts "removed #{ActiveRecordOutboxStore.new.purge_published(7 * 24 * 3600)} published rows"
end
```

## Testing it

The whole pattern is testable with no broker at all, because the relay takes a
connection and a connection takes a transport:

```ruby
RSpec.describe Order do
  let(:outbox) { ActiveRecordOutboxStore.new }

  before { AceMQ::Rails.connection = AceMQ::AMQP::Connection.new(transport: FakeTransport.new) }
  after  { AceMQ::Rails.connection = nil }

  it "writes the event in the same transaction as the order" do
    expect { described_class.place!(valid_params, outbox: outbox) }
      .to change(outbox, :pending_count).by(1)
  end

  it "writes nothing when the transaction rolls back" do
    allow(Inventory).to receive(:reserve!).and_raise(Inventory::Unavailable)

    expect { described_class.place!(valid_params, outbox: outbox) rescue nil }
      .not_to change(outbox, :pending_count)
  end

  it "publishes what the outbox holds" do
    described_class.place!(valid_params, outbox: outbox)

    AceMQ::AMQP::Patterns::OutboxRelay.new(AceMQ::Rails.connection, outbox).sweep

    expect(AceMQ::Rails.connection.transport.published.map(&:routing_key))
      .to eq(["order.placed"])
    expect(outbox.pending_count).to eq(0)
  end
end
```

`sweep` rather than `start`, so there is no thread and no sleep. See
[testing.md](testing.md) for the transport contract a fake has to answer.

## See also

- [Idempotency](idempotency.md) — the other half, and not optional
- [Patterns](patterns.md) — the require, and where each pattern runs
- [Publishing](publishing.md) — confirms, and what "published" means
- [The library's patterns page](https://acemq.org/acemq-ruby-amqp/patterns.html#outbox)
