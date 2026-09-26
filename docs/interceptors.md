# Interceptors

Something that runs around every publish or every handler, without appearing in
either. A tenant stamped on every message, a trace propagated, a handler timed, a
message refused before it reaches any code that would act on it.

```ruby
# config/application.rb, or an environment file
config.acemq.interceptors = [TenantStamp.new, HandlerTiming.new]
```

## Why this is a setting and not an initializer

An interceptor lives on a connection — `intercept_publish` and `intercept_consume`
are instance methods on `AceMQ::AMQP::Connection`. So the obvious way to register
one is:

```ruby
# config/initializers/acemq.rb — don't
AceMQ::Rails.connection.intercept_publish(TenantStamp.new)
```

and that line **opens the socket during boot**. `connect_on_boot` is false by
default precisely so that a broker which is down does not stop an application
serving the pages that never touch it, and an initializer reaching for the
connection undoes that quietly: the application dials the broker on the way up and
nothing in the configuration says why.

`config.acemq.interceptors` is applied on the way out of `Connection.open` instead,
so an interceptor costs nothing until something publishes or consumes.

[publishing.md](publishing.md) used to show only the initializer form, and it does
work. The cost was simply invisible, which is the worst combination.

### One list, both sides

Each entry is offered to **both** the publish side and the consume side. The library
works out which hooks an object answers to once, at registration, so an object with
only `before_publish` is a publish interceptor and being offered to the consume side
costs nothing. It is how the library's own
`AceMQ::AMQP::Telemetry::OpenTelemetry#install` registers itself, and it is why this
is one setting rather than two that have to be kept apart.

A bare object is accepted as well as an array.

A connection handed in with `AceMQ::Rails.connection=` — which is a test's own — is
left exactly as it was given. Nothing is applied to it.

## The hooks

An interceptor is any object. Implement the hooks you want and leave out the rest.

**Publishing**

| | |
|---|---|
| `before_publish(context)` | Mutate and return the context. Raising **stops the publish** and the exception reaches the caller |
| `after_confirm(context)` | The broker has it. Raising here is caught, warned to stderr, and ignored |
| `on_error(context, failure)` | The publish failed. Same: caught and ignored |

**Consuming**

| | |
|---|---|
| `before_handle(context)` | Mutate and return the context. Raising is **treated as a failed handler** — retried, then dead-lettered |
| `after_handle(context, ack)` | What the handler decided. Caught and ignored if it raises |
| `on_error(context, failure)` | The handler failed. Caught and ignored |

**Ordering**

`order`, a method returning an Integer. Lower runs first on the way in and last on
the way out; ties are broken by registration order, which is the order of the array.
Without the method, nought.

The asymmetry in what raising means is the part to read twice. `before_*` raising
changes the outcome — that is what it is for. Everything on the way out is reported
and stepped over, because a message that has already been handled cannot be
unhandled by an interceptor objecting after the fact.

## What a context holds

`PublishContext` is writable where it makes sense: `exchange`, `routing_key`,
`envelope`, `payload`, `reply_to`, `mandatory`.

`ConsumeContext` is mostly read-only — `queue`, `payload`, `body`, `content_type`,
`redelivered?` — with `envelope` and `settlement` writable.

Both answer `set_header(name, value)`, which is the one to use rather than reaching
into the envelope's headers hash. It **refuses any name beginning `x-acemq-`** with
an `ArgumentError`: those are the library's own — the id, the type, the attempt
count, the origin — and an interceptor rewriting one is an interceptor breaking the
contract the other four AceMQ libraries read.

## A tenant on every message

The example that justifies the mechanism, because the alternative is a keyword on
every publish in the application and one place that forgets it:

```ruby
# app/models/tenant_stamp.rb
class TenantStamp
  # First, so that an interceptor logging the context sees the tenant.
  def order = -100

  def before_publish(context)
    context.set_header("tenant", Current.tenant_id) if Current.tenant_id
    context
  end
end
```

```ruby
# config/application.rb
config.acemq.interceptors = [TenantStamp.new]
```

`Current` is a `CurrentAttributes`, which is per-thread and reset between requests —
and, in the consumer process, reset between messages by the executor the runner wraps
every handler in. So a message published *from inside a handler* carries the tenant
the handler set, and a message published from a request carries the request's. That is
the behaviour you want and it is the executor that provides it, not this interceptor.

The matching consume side refuses what is not ours:

```ruby
# app/models/tenant_guard.rb
class TenantGuard
  def before_handle(context)
    tenant = context.envelope.headers["tenant"]

    # FatalError rather than an ordinary exception: retrying a message addressed to
    # another tenant will fail identically for ever, so the ladder is skipped and it
    # goes straight to {queue}.dlq with the reason attached.
    unless Tenant.exists?(id: tenant)
      raise AceMQ::AMQP::FatalError, "message #{context.envelope.id} is for tenant #{tenant.inspect}"
    end

    Current.tenant_id = tenant
    context
  end
end
```

`FatalError` is the distinction worth knowing: an ordinary exception out of
`before_handle` is a failed handler and goes round the retry ladder, and a
`FatalError` short-circuits it. A message that is wrong rather than unlucky should not
be retried five times first.

## Instrumentation

The Rails-shaped use, and the one that composes with everything an application
already has. `ActiveSupport::Notifications` is the framework's own bus, and
`log_subscriber`, `rails-observability` gems, Datadog, Scout and the rest are all
already listening to it:

```ruby
# app/models/acemq_instrumentation.rb
#
# Publishes `publish.acemq` and `handle.acemq` on ActiveSupport::Notifications, so
# whatever the application already uses to watch ActiveRecord and ActionController
# watches messaging too, with no second reporter to configure.
class AceMQInstrumentation
  def before_publish(context)
    Thread.current[:acemq_publish_started] = clock
    context
  end

  def after_confirm(context)
    finish("publish.acemq", :acemq_publish_started,
           exchange: context.exchange, routing_key: context.routing_key,
           type: context.envelope.type, outcome: "confirmed")
    context
  end

  def before_handle(context)
    Thread.current[:acemq_handle_started] = clock
    context
  end

  def after_handle(context, ack)
    finish("handle.acemq", :acemq_handle_started,
           queue: context.queue, type: context.envelope.type,
           attempt: context.envelope.attempt, outcome: outcome_of(ack))
    context
  end

  def on_error(context, failure)
    key = context.respond_to?(:queue) ? :acemq_handle_started : :acemq_publish_started
    name = key == :acemq_handle_started ? "handle.acemq" : "publish.acemq"
    finish(name, key, outcome: "failed", error: failure.class.name)
    context
  end

  private

  def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # A thread local rather than an instance variable: one interceptor object serves
  # every thread on the connection, and `concurrency 4` is four handlers at once.
  def finish(name, key, **payload)
    started = Thread.current[key]
    Thread.current[key] = nil
    ActiveSupport::Notifications.instrument(name, duration: started && clock - started,
                                                 **payload) { nil }
  end

  def outcome_of(ack)
    return "unknown" unless ack.is_a?(AceMQ::AMQP::Ack)

    %i[accept retry reject park].find { |name| ack.public_send(:"#{name}?") }.to_s
  end
end
```

```ruby
# config/initializers/acemq_logging.rb
ActiveSupport::Notifications.subscribe("handle.acemq") do |_name, _start, _finish, _id, payload|
  Rails.logger.info(
    "acemq handled #{payload[:queue]} #{payload[:type]} " \
    "attempt=#{payload[:attempt]} outcome=#{payload[:outcome]} " \
    "in #{(payload[:duration] * 1000).round(1)}ms"
  )
end
```

The thread local is the detail that is easy to get wrong. **One interceptor object
serves every thread on the connection**, so an `@started` instance variable is four
handlers overwriting each other's start time under `concurrency 4`. The same is true
of any state an interceptor keeps.

`instrument` with a block that returns nil, rather than wrapping the work, because an
interceptor is two separate calls on either side of work it does not own. If you want
a real wrapping span, that is a [pipeline](patterns.md#pipelines) around the handler
instead, and the block form of `instrument` fits it properly.

## Blocks, for the short ones

An interceptor may be a block, and a block is a `before_*` hook and nothing else:

```ruby
AceMQ::Rails.connection.intercept_publish { |context| context.set_header("build", BUILD_SHA) }
```

There is no configuration key that takes a block — `config.acemq.interceptors`
expects objects — so a block means reaching for the connection, with the boot-time
cost the top of this page describes. For something this small, a four-line class is
the better trade.

## Tracing

`AceMQ::AMQP::Telemetry::OpenTelemetry` is an interceptor, and installs itself on both
sides:

```ruby
# Gemfile
gem "opentelemetry-api"
```

```ruby
# config/initializers/acemq_tracing.rb
require "acemq/amqp/telemetry/open_telemetry"

Rails.application.config.acemq.interceptors = [AceMQ::AMQP::Telemetry::OpenTelemetry.new]
```

Assigning it to `interceptors` rather than calling `install(connection)` is the same
argument as everywhere else on this page: `install` needs a connection and therefore
opens one. The object answers the hooks either way, so the list is enough.

It propagates W3C `traceparent` and `tracestate` — the standard names, deliberately
not `x-acemq-` prefixed, so a trace crosses into a service that has never heard of
AceMQ. The instrumentation name is `org.acemq.amqp`.

`opentelemetry-api` is required lazily and its absence raises
`AceMQ::AMQP::DependencyMissing` naming the gem. If the application already has the
`opentelemetry-instrumentation-rails` stack, this joins its traces rather than
starting its own — the point of using the standard header names.

[observability.md](observability.md) covers the metrics half.

## What interceptors do not reach

**The outbox relay.** It publishes to the transport directly, because an outbox record
already holds encoded bytes and rendered headers, so `before_publish` never runs for
an outbox message. Stamp the header when the record is built instead —
[outbox.md](outbox.md#what-the-outbox-does-not-do).

**`AceMQ::AMQP::Health`.** The probe declares and deletes a queue; it publishes
nothing.

**The scheduler's rung hops.** The control consumer republishes on the raw transport
for the same reason the relay does.

## Testing one

An interceptor is an object with methods that take a context, so the direct test needs
nothing at all:

```ruby
RSpec.describe TenantStamp do
  it "stamps the current tenant" do
    context = AceMQ::AMQP::PublishContext.new(
      exchange: "shop-events", routing_key: "order.placed",
      envelope: AceMQ::AMQP::Envelope.new, payload: {}
    )
    Current.tenant_id = "acme"

    expect(described_class.new.before_publish(context).envelope.headers["tenant"]).to eq("acme")
  end
end
```

And the wiring — that `config.acemq.interceptors` actually reaches the connection — is
worth one test through the whole stack, because it is the part that silently does
nothing when it is wrong:

```ruby
it "applies the configured interceptors" do
  AceMQ::Rails.config.interceptors = [TenantStamp.new]
  Current.tenant_id = "acme"
  # Not `AceMQ::Rails.connection =`, which is left as it is given. Let the gem open
  # one, with Connection.open stubbed to return a connection over a fake transport.
  allow(AceMQ::AMQP::Connection).to receive(:open)
    .and_return(AceMQ::AMQP::Connection.new(transport: FakeTransport.new))

  AceMQ::Rails.publish({ "order_id" => "A-1" }, to: "order.placed")

  expect(AceMQ::Rails.connection.transport.published.first.headers["tenant"]).to eq("acme")
end
```

## See also

- [Configuration](configuration.md) — `interceptors`, and `telemetry`
- [Observability](observability.md) — metrics, health and what is worth graphing
- [Publishing](publishing.md) — the connection, and confirms
- [The library's interceptors page](https://acemq.org/acemq-ruby-amqp/interceptors.html)
