# Configuration

Two ways in, and they are not alternatives.

**`config/acemq.yml`**, read through Rails' own `config_for`. That is where a
URL, a virtual host, a topology and the consumer defaults belong: they differ per
environment and they are data. `shared:`, per-environment sections and ERB all
work as they do in `database.yml`, because it is the same reader.

**`config.acemq.*`** in `config/application.rb` or an environment file, for the
things that are decisions rather than data — a codec object, a telemetry
reporter, an `AceMQ::AMQP::Security`. None of those can be written in YAML
without inventing a second configuration language.

The file is read first and the Ruby is applied over it. A file checked in for
every environment is the general statement; a line in
`config/environments/test.rb` is the specific one, and the specific one wins.

A key neither half recognises raises on boot rather than being ignored. A typo in
a configuration file that is silently dropped is how a production broker ends up
with the default retry policy and nobody knows why. Dashes are accepted alongside
underscores, because `max-outstanding-publishes` is how the same setting is
spelled in the Spring Boot starter's `application.yaml` and somebody will copy it
across.

## Connection

| Setting | Default | |
|---|---|---|
| `url` | `amqp://guest:guest@localhost:5672` | `amqps://` is verified against the system trust store on its own |
| `username`, `password` | — | Kept out of the URL, so they stay out of the log line that reports a failed connection |
| `token` | — | Instead of a username and password, for a broker taking one |
| `virtual_host` | — | The name, taken literally and escaped whole: `/` becomes `/%2F`, which is the vhost really called `/` |
| `client_name` | the process default | Stamped on every published message as `x-acemq-origin`. The difference between a dead-lettered message you can trace to a pod and one you cannot |
| `connect_timeout` | `10` | Seconds for the AMQP handshake |
| `heartbeat` | `:server` | Or a number of seconds. Taking the broker's suggestion is right almost always |
| `connect_on_boot` | `false` | See below |
| `transport_options` | `{}` | Passed to `Bunny.new`, for the handful of things this does not name |

**`connect_on_boot` is false by default and that is a decision.** A broker that
is down should not stop an application from serving the pages that never touch
it. The connection is opened on first use instead. Set it to true for a service
that would rather fail fast — a consumer-only deployment, say — and note that it
is deliberately not rescued: an application that asked to connect on boot asked
to fail, and swallowing the failure would give it the lazy behaviour it turned
off.

## Publishing

| Setting | Default | |
|---|---|---|
| `format` | `json` | A name `AceMQ::AMQP::Codecs.build` knows: `bytes`, `json`, `string`, `toml`, `xml`, `yaml`. Anything else raises and names the list |
| `codec` | — | A codec *object*, for anything that cannot be named — a composite, protobuf, Avro, an encrypted one, a claim-check wrapper. Wins over `format` |
| `max_outstanding_publishes` | the library's | How many publishes may be waiting for a confirm at once. Added to the library in 0.6.0 |
| `publisher_confirms` | `true` | Cannot be turned off; `false` raises. See below |

**Protobuf and Avro are not names**, and that is not an omission: each needs
something a string cannot carry — a generated message class, a schema, a registry —
so each is built and handed over in `codec`. [serialization.md](serialization.md) is
the whole of this.

`max_outstanding_publishes` is the back pressure that stops a runaway loop from
holding a million messages in this process's memory, and it is what bounds a
`publish_all` larger than the ceiling: such a batch is written in waves rather
than held whole. Reaching it raises `PublishError` rather than waiting —
[observability.md](observability.md#the-publish-ceiling) says why, and what to do
about it.

**`publisher_confirms` cannot be turned off, and setting it to false raises.** The
library opens its publishing channel with `confirm_select` and has no keyword for a
publish without confirms, so there is nothing for `false` to do. It refuses rather
than being ignored, for the same reason an unknown key does: a line in a
configuration file that reads as though durability had been traded for speed, and
changed nothing at all, is worse than no line.

## Interceptors and telemetry

Neither can be written in YAML, because both are objects.

| Setting | Default | |
|---|---|---|
| `interceptors` | `[]` | Applied to the process connection as it is opened. A bare object is accepted as well as an array |
| `telemetry` | — | A reporter answering `count`, `observe` and `gauge`. Nil is the library's own no-op, which costs nothing |

```ruby
# config/application.rb
config.acemq.interceptors = [TenantStamp.new, AceMQ::AMQP::Telemetry::OpenTelemetry.new]
config.acemq.telemetry = AceMQStatsdReporter.new(STATSD)
```

**`interceptors` exists so that registering one does not open the broker
connection.** `intercept_publish` and `intercept_consume` are instance methods, so an
initializer that reaches for `AceMQ::Rails.connection` to call one dials the broker
during boot — the one thing `connect_on_boot: false` is for, and it happens quietly.
This list is applied on the way out of `Connection.open` instead.

Each entry is offered to both sides; the library keeps only the hooks the object
answers to, which is how one setting serves publishing and consuming both. A
connection handed in with `AceMQ::Rails.connection=` — a test's own — is left exactly
as it was given.

[interceptors.md](interceptors.md) and
[observability.md](observability.md) are the pages.

## TLS

```ruby
config.acemq.tls = AceMQ::AMQP::Security.verified(
  certificate_authority: Rails.root.join("config/certs/ca.pem").to_s
)
```

A `Security` object rather than a set of YAML paths, because the library's
`Security` is where the checks live — a development certificate refused unless
asked for, a minimum TLS version, a client certificate that has to be a pair —
and re-expressing them here would be re-implementing them. `amqps://` on its own
needs none of this: it verifies against the system trust store.

Mutual TLS, credentials from a mounted file, a rotating secret, development
certificates and payload encryption are all [security.md](security.md).

> Do not set credentials twice. A `Security` built with `credentials:` in it, plus
> `username`/`password` here, raises `ConfigurationError` — "put them in one place so
> there is no question which login is used".

## Consumer defaults

Under `consumer:`, and every one of them overridable per consumer class.

| Setting | Default | |
|---|---|---|
| `prefetch` | `20` | Unacknowledged messages one consumer holds |
| `concurrency` | `1` | Messages worked on at once. One keeps a queue's messages in the order the broker offers them |
| `max_attempts` | `1` | One means no retries |
| `initial_delay`, `multiplier`, `max_delay` | `0`, `2.0`, `0` | The ladder |
| `jitter` | — | A factor, to stop a fleet retrying in lockstep |
| `give_up_after` | — | Seconds of message age past which it is dead-lettered whatever the attempt count |
| `broker_wait_threshold` | `30` | Where a retry waits |

**`broker_wait_threshold` is a shutdown setting as much as a reliability one.** A
delay shorter than it is waited out in this process, holding a prefetch slot and
holding up a drain; a delay at or above it is waited out on a rung queue in the
broker, where a restart does not have to survive it and a drain does not have to
sit through it. [lifecycle.md](lifecycle.md) has the arithmetic.

## Topology

| Setting | Default | |
|---|---|---|
| `topology` | `{}` | The exchanges, queues and bindings. Empty applies nothing, silently and on purpose |
| `declare_topology_on_boot` | `true` | Whether the consumer process applies it as it starts |

`declare_topology_on_boot` is true because a consumer that starts before its queue
exists reads nothing and says nothing about why. Turn it off for an estate where a
deployment tool owns the broker — `bin/rails acemq:topology` is then the only thing
that declares anything.

See [topology.md](topology.md), and [streams.md](streams.md) for `type: stream`.

## Shutdown

| Setting | Default | |
|---|---|---|
| `shutdown_timeout` | `20` | Seconds the consumer process spends draining before it gives up |

Twenty is chosen to sit inside Kubernetes' thirty-second default
`terminationGracePeriodSeconds` with room for the process to exit. It must be
comfortably shorter than whatever will kill the process — `TimeoutStopSec` under
systemd, `docker stop -t` under Docker, ten seconds by default there.

## Consumers

| Setting | Default | |
|---|---|---|
| `consumer_paths` | `[]` | Extra directories to autoload consumers from |

Empty, and that is not an omission: Rails autoloads every direct subdirectory of
`app/`, so `app/consumers` needs nothing. This is for `lib/consumers` and the
like.

## The whole thing, once

```yaml
shared:
  client_name: shop
  format: json
  max_outstanding_publishes: 1000
  shutdown_timeout: 20
  consumer:
    prefetch: 20
    concurrency: 4
    max_attempts: 5
    initial_delay: 1
    max_delay: 300
    broker_wait_threshold: 10
  topology:
    exchanges:
      - { name: shop-events, type: topic }
    queues:
      - name: shop.orders
        dead_letter: true
        retries: { max_attempts: 5, initial_delay: 1, max_delay: 300 }
    bindings:
      - { queue: shop.orders, exchange: shop-events, routing_key: "order.#" }

production:
  url: <%= ENV["ACEMQ_URL"] %>
  username: <%= ENV["ACEMQ_USERNAME"] %>
  password: <%= ENV["ACEMQ_PASSWORD"] %>
  virtual_host: shop
  connect_on_boot: true
```
