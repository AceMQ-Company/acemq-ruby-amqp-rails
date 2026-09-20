# acemq-ruby-amqp-rails

[![ci](https://github.com/AceMQ-Company/acemq-ruby-amqp-rails/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/AceMQ-Company/acemq-ruby-amqp-rails/actions/workflows/ci.yml)
[![authorship guard](https://github.com/AceMQ-Company/acemq-ruby-amqp-rails/actions/workflows/attribution-guard.yml/badge.svg?branch=main)](https://github.com/AceMQ-Company/acemq-ruby-amqp-rails/actions/workflows/attribution-guard.yml)
[![version](https://img.shields.io/badge/version-0.1.0-blue)](https://github.com/AceMQ-Company/acemq-ruby-amqp-rails/releases)
[![gems](https://img.shields.io/badge/gems-acemq.org%2Fgems-blue)](https://acemq.org/gems)
[![docs](https://img.shields.io/badge/docs-acemq.org-blue)](https://acemq.org/acemq-ruby-amqp-rails/)
[![license](https://img.shields.io/badge/license-Apache--2.0-green)](LICENSE)
[![Ruby](https://img.shields.io/badge/Ruby-3.1%2B-red)](#requirements)
[![Rails](https://img.shields.io/badge/Rails-7.1%20%E2%80%93%208.x-CC0000)](#requirements)

Rails integration for [acemq-amqp](https://github.com/AceMQ-Company/acemq-ruby-amqp):
one connection, configured from `config/acemq.yml`; consumers written as classes
and run in a process of their own; a health check that composes into whatever
readiness endpoint the application already has.

> **Status: `0.1.0`, prepared and not yet tagged.** 102 examples — unit specs
> against a fake transport, integration specs against RabbitMQ 4, and a spec that
> generates a real Rails application, boots it under Puma, publishes through an
> HTTP request, consumes in a second process and shuts it down with `SIGTERM`.
> Tagging publishes it to <https://acemq.org/gems>; see
> [RELEASING.md](RELEASING.md).

```yaml
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
AceMQ::Rails.publish(order.as_json, to: "order.placed",
                     exchange: "shop-events", type: "order.placed.v2")
```

```ruby
# app/consumers/orders_consumer.rb
class OrdersConsumer < AceMQ::Rails::Consumer
  queue "shop.orders"
  concurrency 4

  def call(message)
    Fulfilment.begin!(message.payload)
    accept
  end
end
```

```bash
bundle exec acemq-consumer
```

That is the whole surface for the common case: a module method to publish, a
class to consume, and a command to run the consumers.

## Installing

Neither gem is on rubygems.org before 1.0. Both come from AceMQ's own static
feed, which is a directory tree over HTTPS and needs no account and no
credential.

```ruby
source "https://acemq.org/gems" do
  gem "acemq-amqp", "~> 0.7.0"
  gem "acemq-amqp-rails", "~> 0.1"
end

# The transport. `acemq-amqp` declares no runtime dependencies at all — reading
# an AceMQ envelope should not drag a broker client into a process that will
# never open a socket — so the application that does open sockets names it.
gem "bunny", "~> 2.23"
```

## What it wires in

| | |
|---|---|
| `config.acemq.*` and `config/acemq.yml` | Read through Rails' own `config_for`: `shared:`, per-environment sections and ERB. The file is the general statement; a line in an environment file is the specific one, and wins |
| `AceMQ::Rails.connection` | One per process, opened on first use. Not on boot, so a broker that is down does not stop the pages that never touch it |
| `AceMQ::Rails.publish` / `.publish_all` | Delegations to the library, keywords and all |
| `AceMQ::Rails::Consumer` | A handler for one queue, in `app/consumers`, testable by calling `new.call(message)` |
| `AceMQ::Rails::Health.check` | Composes into `AceMQ::AMQP::Health.aggregate` beside the checks the application already has |
| `rake acemq:topology` / `:consume` / `:health` / `:consumers` | |
| `acemq-consumer` | The consumer process |
| an `at_exit` | Closes the connection tidily in a web process that published |

**Nothing subscribes to anything.** That is enforced rather than recommended: the
Railtie starts no consumers, so a consumer inside Puma is not a mistake that can
be made by accident.

## Three decisions worth knowing about

### Consumers run outside the web server

Not a preference. Puma owns its workers' lifetimes and a message handler is not a
request: `preload_app!` forks, and a bunny socket does not survive a fork;
`worker_timeout` kills a handler that takes longer than a slow page should; web
processes are scaled by request rate and consumers by queue depth; and Puma's
shutdown has no notion of a handler that must finish or a delivery that must be
settled. None of those could be fixed from inside a gem.

So the consumers run in a process of their own — `bundle exec acemq-consumer`, or
`rake acemq:consume`. [docs/consumers.md](docs/consumers.md) makes the case at
length.

### This is deliberately not an ActiveJob adapter

ActiveJob is background jobs; this is messaging. Conflating them is how people end
up using a broker as a job queue and being surprised by the semantics: delivery is
at-least-once and `perform` has no such contract; a message from a Java producer
carries no Ruby class name to `constantize`; `retry_on` counts attempts in one
place while the broker counts them in another; and `perform_later` cannot report
a publish the broker refused to confirm.

Use ActiveJob with a job backend for jobs, and this for messages. They coexist
happily, and a handler that does nothing but `perform_later` is often the right
seam. [docs/not-activejob.md](docs/not-activejob.md).

### A blocked connection is healthy, with a reason

RabbitMQ blocks a connection when it is low on memory or disk, and publishing
stops. The report says so in wording an alert can match, names the broker's own
reason after it, and the **status does not change** — restarting a producer into
the same pressured broker helps nobody, and doing it to every replica at once
turns a broker under memory pressure into an outage with a crash-loop on top.
Same rule as the Spring Boot starter and the Go library, and since `acemq-amqp`
0.7.0 it is the library's rather than something this gem bolts on.
[docs/health.md](docs/health.md).

## Honest limits

- **A development reload cannot reach a running consumer.** The subscription
  holds the instance the old class produced; a reload swaps the constant and
  leaves the consumer running yesterday's code. Restarting the process is the
  only thing that ever picked up a change, and there is no fix worth having.
- **Worse, the development autoloader can deadlock handler threads.** With
  reloading on, two handlers inside the Rails executor can wait on each other for
  the load interlock — nothing raises, the consumer looks alive and reads nothing.
  `acemq-consumer` turns reloading off before the application initializes;
  `rake acemq:consume` cannot, and warns instead.
  [docs/reloading.md](docs/reloading.md).
- **A publish from a thread the consumer process does not know about is not
  covered by the drain.** The library's `publish` is synchronous, so a publish is
  either finished or is a thread still inside the call; the drain closes the
  connection once the consumers are done. [docs/lifecycle.md](docs/lifecycle.md).
- **No Engine, no generators, no dashboard.** No routes, no views, no migrations.
  `rake acemq:consumers` and `rake acemq:health` are the whole of the operator
  surface.
- **The library's patterns are not wrapped.** Outbox, scheduler, request/reply,
  sagas, claim check, streams — all of them work, on
  `AceMQ::Rails.connection`, with the library's own documentation. Wrapping them
  would be a second API to keep in step with the first.
- **`acemq-amqp` is blocking, not async.** A consumer's concurrency is threads,
  and a handler that blocks holds one.

## Requirements

**Ruby 3.1 or later**, which is the library's floor. Nothing here needs more, and
raising it would strand a Rails 7.1 application on a Ruby that still gets security
fixes.

**Rails 7.1 or later**, and under 9.0. Not 7.0, which stopped getting security
fixes in October 2025. Not 7.2 as the floor, because 7.2 requires Ruby 3.1 as its
own floor and this gem's floor is the library's — so 7.1, 7.2 and 8.x are all
supported by one line of code. Rails 8 requires Ruby 3.2; that is Rails'
constraint, not one this gem adds.

Only `railties` is depended on. This works in an application with no
ActiveRecord, no ActiveJob and no ActionPack.

Docker for the integration tests.

## Documentation

Eleven pages, published at
**<https://acemq.org/acemq-ruby-amqp-rails/>**. They read as markdown in
[docs/](docs/) too, and render with `.github/scripts/build-docs-site.sh`.

| | |
|---|---|
| **Start here** | [docs/index.md](docs/index.md) · [Getting started](docs/getting-started.md) |
| **Reference** | [Configuration](docs/configuration.md) — every setting |
| **Usage** | [Publishing](docs/publishing.md) · [Consumers](docs/consumers.md) · [Topology](docs/topology.md) · [Testing](docs/testing.md) |
| **Operations** | [Shutdown and the drain](docs/lifecycle.md) · [Health](docs/health.md) · [Eager loading and reloading](docs/reloading.md) |
| **Design** | [Why this is not an ActiveJob adapter](docs/not-activejob.md) |
| **Support** | [Enterprise support](https://acemq.com) |

## A version line of its own

This gem tracks two release trains: AceMQ's and Rails'. A Rails release that
moves an autoloading hook is a release here and nothing at all in `acemq-amqp`,
and a library release that adds a publishing method is a dependency bump here
rather than a new number. Sharing a version with the library would mean one of
those two facts had to be lied about — which is the same reason
`acemq-java-amqp-spring-boot-starter` is a repository on its own version line.

## Building it

```bash
bundle install
bundle exec rspec                                     # unit specs, no broker
bundle exec rubocop

docker run -d --rm -p 5672:5672 rabbitmq:4-alpine
ACEMQ_TEST_BROKER=amqp://guest:guest@localhost:5672 bundle exec rspec
```

The second `rspec` adds the broker specs and the real-Rails-application spec,
which generates an application, resolves its bundle and boots it. It takes about
a minute.

### Releasing

`release.yml` runs on an annotated `v*` tag. It checks the tag is a `0.1.x`
version and that `AceMQ::Rails::VERSION` agrees with it, runs the specs and
RuboCop, builds the gem, checks the built gem carries what the gemspec's globs
were supposed to include, and installs it into a clean `GEM_HOME` with only its
declared dependencies — which is the one thing the specs cannot catch, since they
satisfy every `require` from this repository's own Gemfile, `rails` and `bunny`
included. It then runs the whole Ruby × Rails matrix and the broker and
real-Rails-application specs against the tag, and only afterwards publishes.
**The version comes from the working tree, not from the tag**: a tag whose
version `lib/acemq/rails/version.rb` does not declare fails the run before
anything is built, so the constant is bumped in the commit the tag points at.

The gem goes to the **AceMQ gem feed** — `AceMQ-Company/gems`, served as a static
index at <https://acemq.org/gems/> beside `acemq-amqp` itself — rather than to
rubygems.org, and not by trusted publishing. The job writes with
`GEMS_REPO_DEPLOY_KEY`, an SSH deploy key carrying write access to that one
repository and to nothing else in the organisation; it rebuilds the index over
everything already published rather than over this release alone, and then
installs the gem back out of the feed with `acemq-amqp` resolving beside it,
because a feed is only real if a client can resolve from it. That is about
reversibility: a version pushed to rubygems.org cannot really be withdrawn, where
a release here is corrected by deleting a file and re-indexing. Moving to
rubygems.org later changes nothing for consumers except the source line.

`publish` is gated on the ref rather than on the event, so a manual
`workflow_dispatch` against a branch runs every check and publishes nothing —
the workflow can be tried out without spending a version number. Dispatched
against a tag instead, it publishes: that is how a release whose publish step
failed is re-run without moving the tag.

[RELEASING.md](RELEASING.md) has the steps, the supported matrix, what the
release-line guard does and when to lift it, and how to check a release really
published.

## Licence

Apache-2.0. See [LICENSE](LICENSE), and [SECURITY.md](SECURITY.md) for reporting
a vulnerability.
