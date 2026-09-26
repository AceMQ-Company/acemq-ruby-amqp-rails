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

Verified against `acemq-amqp` 0.7.1, which the declared `~> 0.7.0` already admits.
No constraint change, so this is not a release of the dependency.

### Added

- **`config.acemq.interceptors`**, applied to the process connection as it is
  opened. A bare object is accepted as well as an array, and each entry is offered
  to both the publish and the consume side — the library works out which hooks an
  object answers to once, at registration, so an object with only `before_publish`
  is a publish interceptor and nothing else. It is how the library's own
  `Telemetry::OpenTelemetry#install` registers itself, which is why this is one
  setting rather than two that have to be kept apart.

  It exists because the alternative was worse rather than merely longer.
  `intercept_publish` and `intercept_consume` are instance methods on
  `AceMQ::AMQP::Connection`, so registering one from an initializer means reaching
  for `AceMQ::Rails.connection` — and that **opens the socket during boot**, which
  is the one thing `connect_on_boot: false` exists to avoid. The old advice did
  that, it worked, and the cost was invisible.

  A connection handed in with `AceMQ::Rails.connection=` is a test's own and is
  left exactly as it was given.

- **Documentation for the patterns the library ships, from Rails.** Eleven pages:
  [patterns](docs/patterns.md) (the require, where each one runs, and the executor
  that every hand-subscribed handler needs),
  [outbox](docs/outbox.md), [idempotency](docs/idempotency.md),
  [saga](docs/saga.md), [request/reply](docs/request-reply.md),
  [scheduling](docs/scheduling.md), [streams](docs/streams.md),
  [serialization](docs/serialization.md), [security](docs/security.md),
  [interceptors](docs/interceptors.md) and [observability](docs/observability.md).

  Two of them document a Rails-specific trap the library cannot know about. The
  SQL-backed stores (`SQLOutboxStore`, `SQLIdempotencyStore`, `SQLSchemaRegistry`)
  **do not work against `ActiveRecord::Base.connection.raw_connection` on
  SQLite**: ActiveRecord sets `results_as_hash = true` on its sqlite3 connection
  and the library's wrapper expects arrays, so inserts work and every `SELECT`
  silently returns nothing — a relay that publishes nothing and says nothing. The
  outbox and idempotency pages carry ActiveRecord-backed stores instead, with the
  library's own column names and the migrations for them, which work on whatever
  database the application uses.

  And a stream consumer written as a class inherits
  `config.acemq.consumer.max_attempts`, which on a stream means a retry
  **appends a second copy** rather than redelivering the first.
  `Patterns.read_stream` forces `RetryPolicy.none`; a consumer class has to say so.

### Changed

- **`publisher_confirms = false` now raises instead of being ignored.** It never
  did anything: the library opens its publishing channel with `confirm_select` and
  has no keyword for a publish without confirms. A line in a configuration file
  that reads as though durability had been traded for speed, and changed nothing at
  all, is worse than no line — the same argument an unknown key has always raised
  on. `true` is still accepted, and is still the default.

### Fixed

- **`format` no longer claims names that do not exist.** The documented list
  included `msgpack`, `cbor`, `avro` and `protobuf`; `AceMQ::AMQP::Codecs.build`
  knows `bytes`, `json`, `string`, `toml`, `xml` and `yaml`, and raises for
  anything else. Protobuf and Avro are deliberately not names — each needs a
  generated class, a schema or a registry, which a string cannot carry — so each is
  built and handed over in `codec`. Documentation and the YARD comment both.

## [0.1.0] - 2026-09-20

First release. Rails integration for `acemq-amqp` `~> 0.7.0`, published to
AceMQ's own gem feed at <https://acemq.org/gems>.

**Read "A reload in development deadlocks a concurrent consumer" under
[Known limits](#known-limits) before you run a consumer locally.** It is the one
failure here that is silent, and knowing about it is the difference between a
puzzling afternoon and a one-line explanation. `bundle exec acemq-consumer`
already avoids it; `rake acemq:consume` cannot, and says so.

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

- **A drain with one deadline, and it is the library's.**
  `AceMQ::Rails::Runner#drain` passes `shutdown_timeout` to
  `AceMQ::AMQP::Connection#close(timeout:)` and keeps no arithmetic of its own —
  the library spends one budget across cancelling every consumer and closing the
  socket, so `shutdown_timeout` means what it says however many consumers there
  are. Two answers to "how long may a shutdown take" is one too many, and eight
  consumers each asking for its own grace period inside a thirty-second one is
  the worst outcome available: `SIGKILL`ed at thirty with nothing completed and
  nothing settled.

  A drain that runs out of time is `AceMQ::AMQP::DrainTimeout`, and its message
  names every queue that still had deliveries in flight and how many —
  `orders.new (2)`. It is logged rather than raised out of a signal handler, and
  `acemq-consumer` exits `75`.

  `#drain` closes the connection the runner ran on rather than always the process
  connection. In the consumer process those are the same object; for a runner
  handed a connection of its own they are not, and cancelling one connection's
  consumers while closing another's socket was never two halves of the same
  shutdown.

- **`AceMQ::Rails.disconnect!`**, taking `timeout:` for the same deadline.
  Omitted, it leaves the library's default, which is what the Railtie's `at_exit`
  wants. That `at_exit` rescues: a `DrainTimeout` out of it would print a
  backtrace after a web process's last log line and change an exit code that was
  fine.

- **Health**, composing into whatever the application already exposes rather than
  adding an endpoint. `AceMQ::Rails::Health.check` goes into
  `AceMQ::AMQP::Health.aggregate` beside the checks that are already there, and
  resolves its connection late so a check registered at boot does not open one.

  **A blocked connection is reported healthy, with a reason** — the same rule as
  the Spring Boot starter and the Go library. RabbitMQ blocks a connection when
  it is low on memory or disk; failing the probe would restart a producer into
  the same pressured broker, and doing it to every replica at once turns a broker
  having a bad ten minutes into an outage with a crash-loop on top.

  ```json
  {
    "status": "up",
    "detail": "the broker has blocked this connection; publishing is paused: low on memory",
    "parts": { "consumers": 0, "consumers_running": 0, "queues": [], "blocked": true, "blocked_reason": "low on memory" }
  }
  ```

  The wording up to the colon is fixed and is the contract, so an alert rule can
  match it — but `parts.blocked` is the better thing to match, and
  `parts.blocked_reason` carries the broker's reason on its own for a dashboard
  that would rather not split a sentence. The string constant is the library's,
  `AceMQ::AMQP::Health::BLOCKED`, so every AceMQ library states the rule in the
  same words in one place.

  Answered in **0.0 seconds**, from what the broker already said over the socket,
  rather than by a `queue.declare` that a blocked broker has stopped reading and
  that therefore waits for bunny's continuation timeout. Nothing is timed while
  the connection is blocked, so `round_trip_ms` is absent from `parts` rather
  than invented.

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

- **A reload in development deadlocks a concurrent consumer, silently.** Every
  handler runs inside `Rails.application.executor.wrap`, which in development
  takes the load interlock's *shared* lock. Two handler threads each hold one;
  the moment either touches an unloaded constant it needs the *exclusive* lock,
  which cannot be had while the other's shared lock is outstanding. Neither
  proceeds and nothing raises. The consumer process looks alive, reads nothing,
  acknowledges nothing, and whether it happens at all depends on which constants
  happened to be warm — so it appears on a cold start and goes away on a retry,
  which is the worst way to meet a bug.

  **This is why `acemq-consumer` boots with reloading disabled** and eager
  loading on, set *before* the application initializes, which removes the
  interlock entirely. Use it. `rake acemq:consume` cannot do the same —
  `:environment` has already booted by the time a task body runs — so the runner
  warns loudly there instead.

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

- **A publish from a thread the consumer process does not know about is not
  covered by the drain.** The library's `publish` is synchronous, so a publish is
  either finished or is a thread still inside the call, and the drain closes the
  connection once the consumers are done.

- Not an ActiveJob adapter, and not an Engine. Both deliberate; see the README.

### Requirements

- Ruby 3.1 or later, which is `acemq-amqp`'s floor.
- Rails 7.1 or later, below 9.0 — 7.1, 7.2 and 8.x. Not 7.0, which left security
  support in October 2025; not 7.2 as the floor, because that would raise the
  Ruby floor to no purpose. Only `railties` is depended on, so this works in an
  application with no ActiveRecord, no ActiveJob and no ActionPack. Rails 8
  requires Ruby 3.2, which is Rails' constraint rather than one this gem adds.
- **`acemq-amqp` `~> 0.7.0`**, from <https://acemq.org/gems>. Three components
  rather than two, and the third is the point: `~> 0.7` is pessimistic on the
  *major* — it expands to `>= 0.7, < 1.0` and would quietly admit 0.8.0, a
  release that may move the API this gem is written against while the library is
  still 0.x. `~> 0.7.0` expands to `>= 0.7.0, < 0.8.0`: patch fixes arrive on
  their own and the next minor gets looked at before it ships here.

  The floor is load-bearing too. `Connection#blocked?`, `#blocked_reason` and
  `#close(timeout:)` are all 0.7.0, and the health check and the drain call all
  three.
- `bunny`, named by the application rather than depended on here, because the
  library deliberately declares no runtime dependencies at all — reading an
  AceMQ envelope should not drag a broker client into a process that will never
  open a socket.

[Unreleased]: https://github.com/AceMQ-Company/acemq-ruby-amqp-rails/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/AceMQ-Company/acemq-ruby-amqp-rails/releases/tag/v0.1.0
