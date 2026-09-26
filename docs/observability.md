# Observability

Four separate things, and it is worth naming them apart because they are configured
in four places:

| | |
|---|---|
| **Metrics** | `config.acemq.telemetry` — a reporter the library counts into |
| **Tracing** | `config.acemq.interceptors` — the OpenTelemetry interceptor |
| **Rails instrumentation** | An interceptor of your own, on `ActiveSupport::Notifications` |
| **Health** | `AceMQ::Rails::Health`, on a readiness endpoint |

Health has [a page of its own](health.md). The rest is here.

## Metrics

`config.acemq.telemetry` takes anything answering three methods:

```ruby
# @param metric [String] one of the AceMQ::AMQP::Telemetry constants
# @param labels [Hash] exchange:, queue:, outcome: and the like
def count(metric, delta = 1, **labels)
def observe(metric, value, **labels)      # a duration in seconds
def gauge(metric, value, **labels)
```

Nil — the default — is the library's own no-op, which costs nothing. That is worth
knowing before assuming messaging is instrumented: **out of the box it is not.**

### What is counted

| Metric | | Labels |
|---|---|---|
| `acemq.publish.total` | Every publish | `exchange`, `outcome` |
| `acemq.consume.total` | Every handler call | `queue`, `outcome` |
| `acemq.consume.duration` | Handler seconds | `queue`, `outcome` |
| `acemq.consume.attempts` | The attempt a delivery is on | `queue` |
| `acemq.consume.in.flight` | A gauge, per queue | `queue` |
| `acemq.messages.retried.total` | Sent round the ladder | |
| `acemq.messages.dead.lettered.total` | Reached `{queue}.dlq` | |
| `acemq.retry.rung.missing` | **See below** | |
| `acemq.messages.set.aside.failed` | A message that could not even be parked | |
| `acemq.request.total`, `acemq.request.duration` | Request/reply | |
| `acemq.pipeline.run.total`, `acemq.pipeline.run.duration` | Pipelines | |

Outcomes are `confirmed`, `unroutable`, `failed`, `acked`, `retried`,
`dead_lettered`, `rejected`, `parked`, `answered`, `timed_out`, `published`,
`completed`, `ended_early` — the constants are under
`AceMQ::AMQP::Telemetry::Outcome`.

**`acemq.retry.rung.missing` is the one to alert on first**, and it is the one most
likely to be above nought in a new deployment. It counts a consumer that wanted a
rung queue and did not find one, which means the consumer's `retries` and the
topology's `retries:` disagree. The retry still happens — in this process, holding a
prefetch slot and making the next deploy's drain sit through the wait — so nothing
looks broken and deploys get slower. [topology.md](topology.md#retry-rungs).

### The built-in registry

The library ships one, and it can hand out Prometheus text, which makes a metrics
endpoint three lines:

```ruby
# config/initializers/acemq.rb
ACEMQ_METRICS = AceMQ::AMQP::Telemetry::Registry.new
Rails.application.config.acemq.telemetry = ACEMQ_METRICS
```

```ruby
# config/routes.rb
get "/metrics", to: "metrics#show"
```

```ruby
# app/controllers/metrics_controller.rb
class MetricsController < ApplicationController
  def show
    render plain: ACEMQ_METRICS.to_prometheus, content_type: "text/plain; version=0.0.4"
  end
end
```

`ACEMQ_METRICS[AceMQ::AMQP::Telemetry::PUBLISH_TOTAL, exchange: "shop-events",
outcome: "confirmed"]` reads one counter; `counts`, `gauges` and `timings` are the
whole lot, and `timings` gives count, sum, min, max and mean per metric.

**The registry is per process, and that is the thing to understand about this
endpoint.** Every Puma worker has its own, so `/metrics` reports whichever worker
answered the scrape — which is fine for a counter you are going to sum across
targets and misleading for anything you read as an absolute. And the numbers that
matter most are in the *consumer* process, which serves no HTTP at all.

So one of two shapes:

**Scrape the consumer process too.** A tiny Rack app on a port, or `rack`'s
`Rackup` in the consumer process, which is a web server in the process that exists
not to be one. Rarely worth it.

**Push to whatever the application already uses.** A reporter of four lines, and this
is the shape nearly every Rails application wants, because it already has somewhere
for metrics to go:

```ruby
# app/models/acemq_statsd_reporter.rb
class AceMQStatsdReporter
  def initialize(client) = @client = client

  # The metric names are dotted already, which is what StatsD wants. Labels become
  # tags; a client without tags can fold them into the name instead.
  def count(metric, delta = 1, **labels) = @client.count(metric, delta, tags: tags(labels))
  def observe(metric, value, **labels) = @client.histogram(metric, value, tags: tags(labels))
  def gauge(metric, value, **labels) = @client.gauge(metric, value, tags: tags(labels))

  private

  def tags(labels) = labels.map { |name, value| "#{name}:#{value}" }
end
```

```ruby
# config/environments/production.rb
config.acemq.telemetry = AceMQStatsdReporter.new(STATSD)
```

A reporter is called on the publishing thread and on every handler thread, so it has
to be thread-safe and it has to be fast. Anything that does I/O synchronously here —
an HTTP POST per metric — is a publish that waits for a metrics backend. Every StatsD
client buffers; most HTTP ones do not.

## Rails instrumentation

The library's telemetry is portable across the five AceMQ languages, which is exactly
why it is not `ActiveSupport::Notifications`: a Ruby library that reached for
ActiveSupport would be a Ruby library with a Rails dependency.

Bridging the two is an interceptor, and
[interceptors.md](interceptors.md#instrumentation) has the full one. What it buys is
that everything already listening to `ActiveSupport::Notifications` — a
`LogSubscriber`, the APM gem the application uses for ActiveRecord, a development
console — starts seeing messaging without a second thing to configure.

The short version, for logging only:

```ruby
# app/models/acemq_notifications.rb
class AceMQNotifications
  def after_handle(context, ack)
    ActiveSupport::Notifications.instrument(
      "handle.acemq", queue: context.queue, type: context.envelope.type,
                      attempt: context.envelope.attempt, ack: ack.action
    ) { nil }
    context
  end
end
```

```ruby
config.acemq.interceptors = [AceMQNotifications.new]
```

An interceptor object serves every thread on the connection, so keep no per-message
state in instance variables. `concurrency 4` is four handlers at once.

## Tracing

```ruby
# Gemfile
gem "opentelemetry-api"
```

```ruby
# config/initializers/acemq_tracing.rb
require "acemq/amqp/telemetry/open_telemetry"

Rails.application.config.acemq.interceptors = [AceMQ::AMQP::Telemetry::OpenTelemetry.new]
```

W3C `traceparent` and `tracestate`, the standard names rather than `x-acemq-`
prefixed, so a trace crosses into a service that has never heard of AceMQ. The
instrumentation name is `org.acemq.amqp`.

`interceptors` rather than `install(connection)`, because `install` needs a
connection and therefore opens one during boot —
[interceptors.md](interceptors.md#why-this-is-a-setting-and-not-an-initializer).

With `opentelemetry-instrumentation-rails` in the application, a request that
publishes and a handler that consumes end up on one trace: the controller's span is
the parent of the publish, and the publish's context travels on the message to
become the parent of the handler's. That is the single most useful thing on this
page, and it is four lines.

## What the consumer process says on its own

Before any of the above, `acemq-consumer` writes to stdout — unbuffered, so a
container's log driver sees the lines as they happen rather than at exit:

```
2026-09-26T09:14:02Z acemq: applying topology — 2 exchanges, 3 queues, 3 bindings
2026-09-26T09:14:02Z acemq: OrdersConsumer -> shop.orders (concurrency 4, prefetch 20)
2026-09-26T09:14:02Z acemq: 1 consumer(s) running; waiting for a signal
...
2026-09-26T09:14:51Z acemq: draining 1 consumer(s), 20s at most
2026-09-26T09:14:52Z acemq: drained in 0.41s
```

Broadcast rather than replacing `Rails.logger`, so an application with a JSON
formatter or a log drain keeps it and gets these lines too. `--quiet` turns the
mirror off, as does `RAILS_LOG_TO_STDOUT`.

Four lines worth alerting on:

| | |
|---|---|
| `acemq: no consumers to run` | The process aborted. Eager loading did not reach `app/consumers` |
| `acemq: this process has the development autoloader enabled` | A latent deadlock. [reloading.md](reloading.md) |
| `the drain did not finish within Ns` | Names each queue and how many deliveries were left. Either `shutdown_timeout` is too short or a handler is stuck |
| `acemq: closing the connection failed` | The web process's `at_exit`. Usually harmless, and never silent |

The exit code says the same thing more usefully: `0` for a drain that finished and
`75` — `EX_TEMPFAIL` — for one that ran out of time. Kubernetes ignores it; a systemd
unit with `Restart=on-failure` does not, and a CI job certainly does.

## Back-pressure and a blocked broker

Two mechanisms, and they are the parts of an outage most likely to be misread as
something else.

### The publish ceiling

`max_outstanding_publishes` — a thousand by default — is how many publishes may be
waiting for a confirm at once. Reach it and **the publish raises immediately**:

```
AceMQ::AMQP::PublishError: 1000 publishes are already waiting for a confirm and
none of them completed. The broker is not keeping up; publish more slowly rather
than buffering more.
```

It raises rather than waiting, deliberately: the transport publishes under the
channel's own mutex and blocking there would deadlock. So this is the one error on
this page that an application has to decide about rather than merely watch — in a
controller it is a 503, and in a handler it is a `retry_later`.

A permit comes back when the broker answers, not when the publish returns, so this
ceiling is a statement about the broker rather than about this process. Raising it
buys more memory held in this process and nothing else; the fix is upstream.

### A blocked connection

RabbitMQ blocks a publishing connection when it is low on memory or disk. Publishes
stop; consuming continues.

```ruby
AceMQ::Rails.connection.blocked?          # => true
AceMQ::Rails.connection.blocked_reason    # => "low on watermark memory"
```

Both are free — no round trip. The reason is the broker's own words, since
`acemq-amqp` 0.7.0.

**A blocked connection is reported `:up` by the health check**, with the reason
written into the report. That is deliberate and [health.md](health.md) argues it at
length: the broker is up and talking, the connection is fine, and restarting this
process would not free a byte of the broker's memory. A readiness probe that returned
503 here would take the whole deployment out of the load balancer for a condition
none of its instances caused.

What to do instead is alert on it, and the report is where to read it from:

```ruby
report = AceMQ::Rails.health
report.parts["blocked"]         # => true
report.parts["blocked_reason"]  # => "low on watermark memory"
```

## What is not measured, and cannot be from here

Worth writing down, because the absence looks like a gap until the reason is clear.

**Queue depth.** The broker knows; a client asking is `queue.declare` with
`passive`, which the library exposes as `message_count` but does nothing with on a
schedule. Queue depth is what a consumer Deployment should scale on, and the place to
read it is RabbitMQ's own Prometheus plugin — one exporter for the estate rather than
every application reporting on queues it happens to consume.

**Consumer lag on a stream.** RabbitMQ knows the committed offset and this library
does not ask for it. What an application can do is record the offset of the last
message it handled; [streams.md](streams.md#health-and-what-is-not-measured).

**Whether a message was ever consumed.** A publisher gets a confirm, which means the
broker has it. `mandatory: true` adds "and it was routed to at least one queue". That
is the end of what publishing can know, and the reason a workflow whose completion
matters is a workflow with a reply or a state machine in it rather than a hope.

## See also

- [Health](health.md) — the report, the probe, and why blocked is up
- [Interceptors](interceptors.md) — the full instrumentation bridge, and tracing
- [Configuration](configuration.md) — `telemetry`, `interceptors`, `max_outstanding_publishes`
- [Shutdown and the drain](lifecycle.md) — what the drain lines mean
- [The library's observability page](https://acemq.org/acemq-ruby-amqp/observability.html)
