# Changelog

All notable changes to this project are documented in this file. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

While the version is `0.x` the public API may change in any release.

This gem has a version line of its own, separate from `acemq-amqp`, because it
tracks two release trains rather than one. A Rails release that moves an
autoloading hook is a release here and nothing at all in the library; a library
release that adds a publishing method is a dependency bump here rather than a new
number. Sharing a version would mean one of those two facts had to be lied about.

## [Unreleased]

## [0.1.0] - 2026-09-18

First release. Rails integration for `acemq-amqp` 0.6.0.

### Added

- **A Railtie**, giving configuration under `config.acemq.*` and in
  `config/acemq.yml`. The file is read through Rails' own `config_for`, so
  `shared:`, per-environment sections and ERB all work as they do in
  `database.yml`; `config.acemq.*` in an environment file is applied over it,
  because a file checked in for every environment is the general statement and a
  line in `config/environments/test.rb` is the specific one.

  The settings mirror the Spring Boot starter's `acemq.*` properties: URL,
  credentials, virtual host, client name, timeouts, publisher confirms,
  `max_outstanding_publishes`, format, TLS, topology, and consumer defaults with
  a retry ladder. Dashes are accepted alongside underscores, because
  `max-outstanding-publishes` is how the same setting is spelled in
  `application.yaml` and somebody will copy it across. A key neither half
  recognises raises on boot rather than being ignored: a typo silently dropped is
  how a production broker ends up with the default retry policy and nobody knows
  why.

- **One connection for the process**, `AceMQ::Rails.connection`, opened on first
  use and reachable by name. Opening one per request is the single most expensive
  mistake available here, and this exists so that no caller has to build one.

  Lazily by default, and that is a decision rather than laziness: a broker that
  is down should not stop an application from serving the pages that never touch
  it. `connect_on_boot: true` moves it to boot for a service that would rather
  fail fast, and is deliberately not rescued.

- **`AceMQ::Rails.publish` and `.publish_all`**, thin delegations to the
  library's own. Every keyword is the library's. A wrapper that renamed them
  would be a second API to document, a second to keep in step, and the place
  where an integration starts making decisions the library left to the caller.

- **Consumers as classes**, `AceMQ::Rails::Consumer`, in `app/consumers`.
  `queue`, `concurrency`, `prefetch`, `codec`, `retries` and `tag`, each
  inherited from a parent class that declares it — except the queue, because two
  consumers sharing an inherited queue name is a competing-consumers setup
  written by accident. `accept`, `retry_later`, `reject` and `park` are available
  without reaching into the library's namespace. A consumer is unit-testable by
  calling `new.call(message)` with no broker in the room.

- **A consumer process**, `bundle exec acemq-consumer`, and `rake acemq:consume`
  beside it. It eager-loads the application, applies the topology, subscribes
  every registered consumer, waits for a signal and drains. Exit `0` for a drain
  that finished, `75` (`EX_TEMPFAIL`) for one that ran out of time, so a restart
  policy can tell "it failed" from "it ran out of time putting itself away".

  `--queues` runs a subset; `--quiet` stops this gem's lines being mirrored to
  stdout, which they are by default because a container's log driver reads
  nothing else.

- **A drain that cancels consumers in parallel against one shared deadline.** The
  library's own `Connection#close` cancels them in turn, each with its own
  thirty-second timeout, so eight consumers can ask for four minutes inside a
  thirty-second grace period and be `SIGKILL`ed at thirty — the worst outcome
  there is, because nothing completes and nothing is settled. `shutdown_timeout`
  here means what it says however many consumers there are.

- **Health**, composing into whatever the application already exposes rather than
  adding an endpoint. `AceMQ::Rails::Health.check` goes into
  `AceMQ::AMQP::Health.aggregate` beside the checks that are already there.

  **A blocked connection is reported healthy, with a reason** — the same rule as
  the Spring Boot starter and the Go library. RabbitMQ blocks a connection when
  it is low on memory or disk; failing the probe would restart a producer into
  the same pressured broker, and doing it to every replica at once turns a broker
  having a bad ten minutes into an outage with a crash-loop on top. The reason is
  fixed wording so an alert rule can match it, and it appears in `parts` as
  `blocked`.

  Checked here rather than in the library because the flag lives on bunny's
  session and the library's health check is written against a transport seam a
  hand-written double also satisfies. Reaching through two layers to a driver is
  a thing an integration may do and a portable contract may not.

- **Topology from configuration**, applied by `rake acemq:topology` and on the
  consumer process's boot. Exchanges, queues, bindings, dead-letter queues and
  the rung queues a retry ladder needs. Declared rather than inferred from
  consumer classes: a queue that appears because some class mentioned it is a
  queue whose durability, type and dead-lettering nobody decided, and all three
  are part of its identity to the broker.

- **The Rails executor around every handler.** A consumer runs on a bunny thread,
  which Rails has never seen; without this it checks an ActiveRecord connection
  out of the pool on first use and never checks it back in, so a pool of five is
  exhausted after five messages and the sixth waits for ever.

  An exception out of a handler is reported to `Rails.error` with the consumer,
  the queue, the message id and the attempt as context, and then **re-raised** so
  the library's retry ladder still decides. `ErrorReporter#record`, not
  `#handle`: `handle` reports and swallows, which would leave the handler
  returning nil instead of an `Ack` and a failed message settled as though it had
  worked.

- **`rake acemq:health` and `rake acemq:consumers`**, for looking at a deployment
  without writing a script.

### Known limits

- **A development reload cannot reach a running consumer.** The subscription
  holds the instance the old class produced; Zeitwerk swaps the constant and the
  consumer goes on running yesterday's code, silently. There is no fix worth
  having — swapping the instance mid-subscription would mean a message half
  handled by one object and settled by another — so restarting the process is
  what is documented.

  The registry does handle its half: it is keyed by class name rather than
  holding class objects, so a reload replaces rather than adds. Without that, an
  afternoon's editing would leave four `OrdersConsumer`s registered and the next
  start would subscribe to the same queue four times.

- **With reloading on, two handler threads can deadlock on the load interlock.**
  Every handler runs inside the Rails executor, which in development holds a
  shared load lock; the moment one thread touches an unloaded constant it needs
  the exclusive one, which cannot be had while another handler holds its shared
  one. Nothing raises. The consumer looks alive and reads nothing, and whether it
  happens depends on which constants are warm — so it appears on a cold start and
  goes away on a retry.

  `acemq-consumer` turns reloading off and eager loading on *before* the
  application initializes, which removes the interlock entirely. `rake
  acemq:consume` cannot — `:environment` has already booted by the time a task
  body runs — so the runner warns loudly instead.

- **A publish from a thread the consumer process does not know about is not
  covered by the drain.** The library's `publish` is synchronous, so a publish is
  either finished or is a thread still inside the call, and the drain closes the
  connection once the consumers are done.

- Not an ActiveJob adapter, and not an Engine. Both deliberate; see the README.

### Requirements

- Ruby 3.1 or later, which is `acemq-amqp`'s floor.
- Rails 7.1 or later, below 9.0. Not 7.0, which left security support in October
  2025; not 7.2 as the floor, because that would raise the Ruby floor to no
  purpose. Only `railties` is depended on.
- `acemq-amqp` `~> 0.6`, from <https://acemq.org/gems>. Pessimistic on the minor
  rather than the patch: 0.6 is where `publish_all` and
  `max_outstanding_publishes` arrived, both of which this configures, and while
  the library is 0.x a minor release may change the API this is written against.
- `bunny`, named by the application rather than depended on here, because the
  library deliberately declares no runtime dependencies at all.

[Unreleased]: https://github.com/AceMQ-Company/acemq-ruby-amqp-rails/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/AceMQ-Company/acemq-ruby-amqp-rails/releases/tag/v0.1.0
