# AceMQ for Rails

Rails integration for [AceMQ over AMQP](https://acemq.org/acemq-ruby-amqp/): one
connection for the process, configured the Rails way; consumers written as classes
and run in a process of their own; a health check that composes into whatever
readiness endpoint the application already has.

It is a thin layer. The library underneath is where publishing, retries,
dead-lettering, codecs and the wire contract live, and none of that is rewritten
here. What this adds is the four things a Rails application needs and a library
cannot supply: a place for configuration, a place for the connection, a process
for the consumers, and the executor around a handler that makes ActiveRecord
usable from a thread Rails never made.

```ruby
# config/acemq.yml
shared:
  client_name: shop
  topology:
    exchanges:
      - { name: shop-events, type: topic }
    queues:
      - { name: shop.orders, dead_letter: true }
    bindings:
      - { queue: shop.orders, exchange: shop-events, routing_key: "order.#" }

production:
  url: <%= ENV["ACEMQ_URL"] %>
```

```ruby
# app/controllers/orders_controller.rb
def create
  order = Order.create!(order_params)
  AceMQ::Rails.publish(order.as_json, to: "order.placed",
                       exchange: "shop-events", type: "order.placed.v2")
  head :created
end
```

```ruby
# app/consumers/orders_consumer.rb
class OrdersConsumer < AceMQ::Rails::Consumer
  queue "shop.orders"

  def call(message)
    Fulfilment.begin!(message.payload)
    accept
  end
end
```

```
$ bundle exec acemq-consumer
```

That last line is the design, not an implementation detail. **Consumers do not
run inside Puma**, and [consumers.md](consumers.md) is the argument at length.

## Where to go next

| | |
|---|---|
| **Start here** | [Getting started](getting-started.md) |
| **Reference** | [Configuration](configuration.md) — every setting |
| **Usage** | [Publishing](publishing.md) · [Consumers](consumers.md) · [Topology](topology.md) · [Serialization](serialization.md) · [Testing](testing.md) |
| **Security** | [TLS, credentials, certificates, payload encryption](security.md) |
| **Patterns** | [From Rails](patterns.md) · [Outbox](outbox.md) · [Idempotency](idempotency.md) · [Saga](saga.md) · [Request/reply](request-reply.md) · [Scheduling](scheduling.md) · [Streams](streams.md) |
| **Operations** | [Shutdown and the drain](lifecycle.md) · [Health](health.md) · [Observability](observability.md) · [Interceptors](interceptors.md) · [Eager loading and reloading](reloading.md) |
| **Design** | [Why this is not an ActiveJob adapter](not-activejob.md) |
| **Support** | [Enterprise support](https://acemq.com) |

## Versions

| | |
|---|---|
| Ruby | 3.1 and later |
| Rails | 7.1, 7.2 and 8.x. Rails 8 needs Ruby 3.2, which is Rails' constraint rather than one this gem adds |
| `acemq-amqp` | `~> 0.7.0` — every 0.7.x, and the next minor is looked at before it ships here |
| Transport | `bunny ~> 2.23`, named by the application. The library declares no runtime dependencies at all |

The constraint on the library is three components on purpose: `~> 0.7` would be
pessimistic on the *major* and would quietly admit a 0.8 that changed something this
gem is written against. A weekly job checks that the constraint still admits the
newest release, because a constraint that has stopped doing so looks exactly like one
that still does until somebody looks.

## What it is not

- **Not an ActiveJob adapter**, deliberately. [not-activejob.md](not-activejob.md).
- **Not a replacement for the library.** `AceMQ::Rails.publish` is a delegation to
  `AceMQ::AMQP::Connection#publish`, and every keyword is the library's.
- **Not an Engine.** No routes, no views, no migrations, nothing to mount.
- **Not a scheduler, an outbox or a saga.** The library has all three and this gem
  wraps none of them. [patterns.md](patterns.md) is how each one is reached from
  Rails, and which of them needs a process rather than a setting.
