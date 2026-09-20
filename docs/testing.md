# Testing

## Consumers, with no broker anywhere

A consumer is a class with one method. Call it.

```ruby
RSpec.describe OrdersConsumer do
  it "begins fulfilment" do
    message = AceMQ::AMQP::Message.new(
      payload: { "order_id" => "A-1" },
      envelope: AceMQ::AMQP::Envelope.new(type: "order.placed.v2")
    )

    expect { described_class.new.call(message) }
      .to change(Fulfilment, :count).by(1)
  end

  it "asks for a retry when the warehouse is down" do
    allow(Warehouse).to receive(:reserve).and_raise(Warehouse::Unavailable)

    ack = described_class.new.call(message)

    expect(ack).to be_retry
  end
end
```

That is the whole point of the class shape. No broker, no threads, no runner, and
the assertions are about what the handler decided rather than about what a double
was called with.

## Publishing, with no broker

The library's `Connection` takes a transport, so a fake one is all it takes to
assert on what was published. The library's [testing
guide](https://acemq.org/acemq-ruby-amqp/testing.html) has the full transport
contract; the short version is that it needs `publish`, `publish_all`,
`declare_queue`, `declare_exchange`, `bind`, `subscribe`, `pull`,
`message_count`, `queue_exists?`, `delete_queue`, `open?` and `close`.

```ruby
RSpec.configure do |config|
  config.before do
    AceMQ::Rails.connection = AceMQ::AMQP::Connection.new(transport: FakeTransport.new)
  end

  config.after { AceMQ::Rails.connection = nil }
end
```

`AceMQ::Rails.connection=` exists for this. Nothing in the request path notices,
because everything reaches the connection by name.

### A blocked broker, with no broker

A fake is a blocked connection by answering one more method:

```ruby
class FakeTransport
  # Why the broker has blocked this connection, or nil. `AceMQ::AMQP::Health`
  # asks the transport seam for this; a transport that has never heard of it is
  # simply not asked.
  attr_reader :blocked_reason
end

report = AceMQ::Rails::Health.of(connection_on(FakeTransport.new(blocked_reason: "low on memory")))
report.up?                          # => true
report.detail                       # => "...publishing is paused: low on memory"
report.parts["blocked_reason"]      # => "low on memory"
```

> Before `acemq-amqp` 0.7.0 this needed a stand-in `Bunny::Session` answering
> `blocked?`, because the reach was into the driver rather than at the seam. A
> fake that still has only `session` will now report nothing about blocking —
> which is the tolerant behaviour, and therefore silent. Rename it.

```ruby
it "publishes an event when an order is placed" do
  post orders_path, params: { order_id: "A-1" }

  published = AceMQ::Rails.connection.transport.published
  expect(published.size).to eq(1)
  expect(published.first.routing_key).to eq("order.placed")
end
```

## Against a real broker

For the things a fake cannot prove — that a message survives the wire, that a
rejected message reaches `{queue}.dlq` with the reason attached, that a drain
finishes.

```ruby
RSpec.describe "orders", :integration do
  before do
    AceMQ::Rails.config.url = ENV.fetch("ACEMQ_TEST_BROKER")
    AceMQ::Rails.config.topology = { "queues" => [{ "name" => queue }] }
  end

  after { AceMQ::Rails.disconnect! }

  it "is consumed" do
    runner = AceMQ::Rails::Runner.new
    runner.start([OrdersConsumer])

    AceMQ::Rails.publish({ "order_id" => "A-1" }, to: "order.placed",
                         exchange: "shop-events")
    # ... wait for the handler to record what it saw ...

    expect(runner.drain).to be(true)
  end
end
```

`Runner#start` subscribes without waiting for a signal, and `#drain` stops
everything — which is what makes a runner usable in a test at all. Give each
example a queue named with a random suffix and delete it afterwards; two specs
sharing a queue is a flake waiting for a busy CI runner.

A broker in Docker is enough:

```bash
docker run -d --rm -p 5672:5672 rabbitmq:4-alpine
```

## This gem's own suite

Ninety-odd examples, in three groups.

**Unit**, against a fake transport and a recording connection: what a consumer
class turns into, what the registry does on a reload, what the topology builder
makes of a YAML section, what a drain finishes. No Docker; they run in under a
second.

**Against a real broker**, tagged `:integration`: publish and consume, a batch in
one round trip, the `max_outstanding_publishes` ceiling, a rejected message
arriving in the dead-letter queue with its reason, a drain that blocks on a
handler, and a drain that runs out of time.

**Against a real Rails application**, the same tag. It generates an application
in a temporary directory with `rails new`, adds this gem as a path dependency and
the library from the published feed, writes a `config/acemq.yml`, a consumer and
a controller, resolves its bundle, boots it under Puma, publishes through an HTTP
request, runs `bundle exec acemq-consumer` as a second process, watches the
messages arrive, sends it `SIGTERM` and checks that it drained and exited zero.

That last group is the one the others cannot replace. A Railtie that has never
booted inside Rails is not tested, and the initializer-ordering bug it caught —
`config.autoload_paths` being frozen by the time an initializer without a
`before:` runs — is invisible to every other kind of test.
