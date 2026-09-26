# Getting started

From an empty Rails application to a message published in a request and consumed
in a process of its own.

## Install

Neither gem is on rubygems.org before 1.0. Both come from AceMQ's own static
feed, which is a directory tree over HTTPS and needs no account and no
credential.

```ruby
# Gemfile
source "https://acemq.org/gems" do
  gem "acemq-amqp", "~> 0.7.0"
  gem "acemq-amqp-rails", "~> 0.1"
end

# The transport. `acemq-amqp` declares no runtime dependencies at all — reading
# an AceMQ envelope should not drag a broker client into a process that will
# never open a socket — so the application that does open sockets names it.
gem "bunny", "~> 2.23"
```

```bash
bundle install
```

`~> 0.7.0` on the library is three components on purpose. `~> 0.7` would be
pessimistic on the *major* — `>= 0.7, < 1.0` — and would quietly admit a 0.8 that
changed something this gem is written against; `~> 0.7.0` is `>= 0.7.0, < 0.8.0`, so
patch releases arrive on their own and the next minor is looked at before it ships
here. `bundle install` resolves the newest 0.7.x the feed carries.

Ruby 3.1 and later; Rails 7.1, 7.2 and 8.x. Rails 8 needs Ruby 3.2, which is Rails'
constraint rather than one this gem adds.

## Configure

```yaml
# config/acemq.yml
shared:
  client_name: shop
  consumer:
    prefetch: 20
    concurrency: 4
    max_attempts: 5
    initial_delay: 1
    max_delay: 60
  topology:
    exchanges:
      - { name: shop-events, type: topic }
    queues:
      - { name: shop.orders, dead_letter: true, retries: { max_attempts: 5, initial_delay: 1, max_delay: 60 } }
    bindings:
      - { queue: shop.orders, exchange: shop-events, routing_key: "order.#" }

development:
  url: amqp://guest:guest@localhost:5672

test:
  url: amqp://guest:guest@localhost:5672

production:
  url: <%= ENV["ACEMQ_URL"] %>
  shutdown_timeout: 20
```

This is Rails' own `config_for`, so `shared:`, per-environment sections and ERB
all work exactly as they do in `database.yml`. Anything that cannot be written in
YAML — a codec object, an interceptor, a telemetry reporter, an
`AceMQ::AMQP::Security` — goes in `config.acemq.*` in an environment file, which is
applied *over* the file. See [configuration.md](configuration.md).

For production that usually means a TLS URL and credentials out of the environment;
[security.md](security.md) is the page.

## Declare the broker's shape

```bash
bin/rails acemq:topology
```

Prints the plan and applies it. Idempotent, so it belongs in a deploy step beside
`db:migrate`. The consumer process does it on boot as well, which covers a
development machine; `declare_topology_on_boot: false` turns that off for an
estate where a deployment tool owns the broker.

## Publish

```ruby
class OrdersController < ApplicationController
  def create
    order = Order.create!(order_params)
    AceMQ::Rails.publish(order.as_json, to: "order.placed",
                         exchange: "shop-events", type: "order.placed.v2")
    head :created
  end
end
```

No connection is built here and none is closed. The one the Railtie set up is
reached by name, and it is opened on first use — so a broker that is down does
not stop the pages that never touch it from serving. See
[publishing.md](publishing.md).

## Consume

```ruby
# app/consumers/orders_consumer.rb
class OrdersConsumer < AceMQ::Rails::Consumer
  queue "shop.orders"
  concurrency 4

  def call(message)
    Fulfilment.begin!(message.payload)
    accept
  rescue Warehouse::Unavailable => e
    retry_later(e.message)
  end
end
```

`app/consumers` needs no configuration: Rails autoloads every direct
subdirectory of `app/`.

## Run the consumers

```bash
bundle exec acemq-consumer
```

Or `bin/rails acemq:consume`. **Not inside Puma** — [consumers.md](consumers.md)
says why, and the executable is the one that turns the development autoloader off,
which [reloading.md](reloading.md) explains is not optional.

In a Procfile:

```
web: bin/rails server
mq:  bundle exec acemq-consumer
```

In Kubernetes, a second Deployment with the same image and a different command,
scaled by queue depth rather than by request rate — which is half the point of
keeping them apart.

## Check it is working

```bash
bin/rails acemq:health      # what a readiness probe would see
bin/rails acemq:consumers   # every consumer and the queue it reads
```

And in the application, composed into whatever endpoint already exists:

```ruby
report = AceMQ::AMQP::Health.aggregate(AceMQ::Rails::Health.check, DatabaseCheck.new)
render json: report.to_h, status: report.down? ? 503 : 200
```

[health.md](health.md) has the rest, including why a blocked connection is
reported healthy.

## Then

Nothing above is instrumented, encrypted or idempotent, and that is where most
applications go next:

| | |
|---|---|
| A TLS broker, credentials, encrypted payloads | [security.md](security.md) |
| Metrics, tracing and what is worth alerting on | [observability.md](observability.md) |
| An event that must not be published without its row | [outbox.md](outbox.md) |
| A handler that will be called twice | [idempotency.md](idempotency.md) |
| Everything else the library ships | [patterns.md](patterns.md) |
