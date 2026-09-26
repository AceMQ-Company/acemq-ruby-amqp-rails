# Security

Four separate questions, and it is worth keeping them apart because they have
different answers: is the connection encrypted, is the broker who it claims to be,
who is this application logging in as, and can anybody who reaches the broker read
the messages.

The library owns all four. This page is how each of them is reached from a Rails
application, and where a configuration key exists for it rather than a line of
Ruby.

| | Reached by |
|---|---|
| Encryption in transit | `url` — the scheme decides |
| Broker identity | `url`, or `tls` for a private authority |
| Login | `username`/`password`, or `token` |
| Payload encryption | `codec` |

## The scheme decides, and that is the whole default

`Security.for_url` reads the URL and nothing else:

- **`amqps://`** — encrypted, and the broker's certificate is verified against the
  system trust store.
- **`amqp://`** — plaintext.

There is no scheme that encrypts without verifying. That combination exists —
`Security.without_verifying_the_broker` — and it cannot be reached by writing a
URL, which is deliberate: an unverified TLS connection looks exactly like a
verified one in a log line, and the only way to get one here is to ask for it by a
name that says what it is and to supply a reason.

```yaml
# config/acemq.yml
production:
  url: <%= ENV["ACEMQ_URL"] %>          # amqps://broker.example.com:5671
```

5671 is the TLS port and 5672 the plaintext one, by RabbitMQ convention rather
than by anything this library enforces.

> **No trailing slash.** bunny reads `amqps://host:5671/` as a request for the
> virtual host named by the empty string and the broker answers `NOT_ALLOWED -
> vhost  not found`. Use `virtual_host:` for a vhost — it is taken literally and
> escaped whole, so `/` really means the vhost called `/`.

## A private certificate authority

An internal broker is usually signed by an authority the system trust store has
never heard of. That is what `config.acemq.tls` is for, and it is Ruby rather than
YAML because a `Security` is an object with checks in it:

```ruby
# config/environments/production.rb
config.acemq.tls = AceMQ::AMQP::Security.verified(
  certificate_authority: Rails.root.join("config/certs/ca.pem").to_s
)
```

Naming an authority **narrows** trust to that authority — the system store is
then not consulted at all, so a broker signed by a public CA stops being
acceptable. That is the point of it.

Re-expressing any of this as YAML paths would mean re-implementing the checks
`Security` already performs: every path is read at construction and an unreadable
one is reported then rather than as a handshake failure later, a certificate and
key have to arrive as a pair, and TLS is pinned between 1.2 and 1.3
(`MINIMUM_TLS_VERSION`, `MAXIMUM_TLS_VERSION`) instead of taking whatever OpenSSL
would have negotiated.

### Mutual TLS

A client certificate is the same constructor:

```ruby
config.acemq.tls = AceMQ::AMQP::Security.verified(
  certificate_authority: Rails.root.join("config/certs/ca.pem").to_s,
  certificate: Rails.root.join("config/certs/client.crt").to_s,
  key: Rails.root.join("config/certs/client.key").to_s
)
```

One without the other raises `AceMQ::AMQP::ConfigurationError` at construction —
which, in an environment file, means during boot and not on the first publish.

With RabbitMQ's `EXTERNAL` mechanism the certificate *is* the login, so there is
no username to set. The broker has to be configured for it; a certificate the
broker does not map to a user is a successful handshake followed by a refused
login.

### Encrypting without verifying

```ruby
config.acemq.tls = AceMQ::AMQP::Security.without_verifying_the_broker(
  because: "the staging broker is behind the VPN and its certificate is self-signed"
)
```

`because:` is a required keyword and an empty one raises. The reason is not
decoration: it ends up in `Security#to_s`, so the next person to read a log line
or a console session finds out why verification was turned off without having to
find the commit.

## Credentials

Kept out of the URL, which is the only reason the setting exists at all. A URL is
what gets logged when a connection fails — the library redacts the password it
finds there, but the username stays, and a URL in a configuration file is a URL in
a stack trace, a `bundle exec rails runner` history and a `ps` listing.

```yaml
production:
  url: <%= ENV["ACEMQ_URL"] %>
  username: <%= ENV["ACEMQ_USERNAME"] %>
  password: <%= ENV["ACEMQ_PASSWORD"] %>
```

Either both or neither. A username with no password is a login attempt with an
empty password, which is not what anybody meant.

For a broker taking a bearer token — RabbitMQ with OAuth 2 — `token:` instead, and
it is mutually exclusive with `username`:

```yaml
production:
  token: <%= ENV["ACEMQ_TOKEN"] %>
```

`AceMQ::AMQP::Credentials` never prints its secret. `inspect`, `to_s` and `p` all
give `[REDACTED]`, so a credential cannot reach a log through a debugging line
somebody left in.

### Credentials from a file, and rotation

There is **no configuration key** for either. `Credentials.from_file` and the
callable form that `Credentials.resolve` accepts both take something YAML cannot
express, so they are hand-wired — through `transport_options`, which is merged
over everything this configuration names and reaches `Transport.open` as it is:

```ruby
# config/environments/production.rb
#
# A mounted secret rather than an environment variable, and re-read every time a
# connection opens rather than once at boot — which is what makes a rotated
# secret take effect on a reconnect instead of on a deploy.
config.acemq.transport_options = {
  credentials: -> { AceMQ::AMQP::Credentials.from_file("/run/secrets/mq") }
}
```

The file is `username:password` on one line, or just the password with
`username:` passed to `from_file`. A trailing newline is trimmed. An unreadable or
empty file raises `ConfigurationError` naming the path.

> **Do not set credentials twice.** `Security.for_connection` raises
> `ConfigurationError` when credentials arrive both on the connection and inside a
> `Security` object — "put them in one place so there is no question which login
> is used". So if you build a `Security` with `credentials:` in it, leave
> `username`, `password` and `token` out of `config/acemq.yml`.

## Development certificates

TLS on a laptop needs certificates, and certificates cannot be committed. The
library generates them, and marks every one it generates.

```ruby
# lib/tasks/acemq_certs.rake
namespace :acemq do
  desc "Write development TLS certificates into tmp/certs"
  task :certs do
    require "acemq/amqp"

    result = AceMQ::AMQP::DevelopmentCertificates.generate(
      directory: Rails.root.join("tmp/certs").to_s,
      broker_host: "localhost",
      days: 30
    )
    puts "wrote #{result.files.join(", ")}, valid until #{result.expiry}"
  end
end
```

It writes `ca.crt`, `ca.key`, `server.crt`, `server.key`, `client.crt`,
`client.key` and a `rabbitmq.conf` for the broker. Certificates get mode `0644`
and keys `0600`. They last thirty days.

`tmp/` is already in a generated Rails `.gitignore`, which is why the task writes
there. Anywhere else, add the paths — a private key in a repository is a private
key that has to be rotated everywhere it ever reached.

Every generated certificate carries `ACEMQ DEVELOPMENT ONLY - DO NOT TRUST` in its
organisation field, and the library **refuses it** unless the refusal is
explicitly waived:

```ruby
# config/environments/development.rb
config.acemq.tls = AceMQ::AMQP::Security
                   .verified(certificate_authority: Rails.root.join("tmp/certs/ca.crt").to_s)
                   .allowing_development_certificates
```

Without that call the configured certificate raises `ConfigurationError` before a
socket is opened:

> `the certificate authority tmp/certs/ca.crt carries "ACEMQ DEVELOPMENT ONLY - DO
> NOT TRUST". It was generated by the AceMQ development tooling and is refused
> here, because an authority anybody can regenerate is not one to verify a
> production broker against. If this really is a development broker, say so with
> Security#allowing_development_certificates.`

A marked certificate presented by the *broker* is refused during the handshake
instead, and that one reads worse: OpenSSL reports its own generic `certificate
verify failed` and the reason is written to stderr immediately above it. Worth
knowing before spending an afternoon on it.

The point of the marker is the accident it prevents: an environment variable
pointing at the wrong `ca.crt`, and a production service happily verifying against
an authority anybody on the team can regenerate. `allowing_development_certificates`
is a line nobody writes in `config/environments/production.rb` by mistake.

## Encrypting the payload

TLS protects the message between this process and the broker. It does not protect
the message *at* the broker, in a dead-letter queue, in a support engineer's
`rabbitmqadmin get`, or in a broker backup. For a payload where that matters the
library has `EncryptedCodec`, and because it is a codec it needs no new
configuration key:

```ruby
# config/initializers/acemq.rb
keyring = AceMQ::AMQP::Keyring.of(
  "orders-2026-09",
  AceMQ::AMQP::Keys.from_base64(Rails.application.credentials.acemq_message_key)
)

Rails.application.config.acemq.codec =
  AceMQ::AMQP::EncryptedCodec.wrapping(AceMQ::AMQP::JSONCodec.new, keyring)
```

An initializer rather than an environment file, because
`Rails.application.credentials` is where a key belongs and an initializer is where
that is reachable. `config.acemq.*` set in an initializer still wins over
`config/acemq.yml`: the Railtie reads the file before any initializer and builds
the configuration after all of them.

`config.acemq.codec` is checked with `AceMQ::AMQP::Codec.check!`, so an object
missing one of `content_type`, `encode`, `decode` and `can_decode?` is rejected on
boot rather than on the first message.

AES-GCM, 128/192/256 bits depending on the key length, a fresh nonce per message.
The key identifier travels in the frame as authenticated associated data, which is
what makes the next part work.

### Rotation

One key writes; every key in the ring reads. That asymmetry is the whole design:

```ruby
keyring.add(AceMQ::AMQP::EncryptionKey.new("orders-2026-12", new_secret))  # readers first
keyring.use("orders-2026-12")                                             # then writers
```

Deploy the `add` everywhere before the `use` anywhere. A consumer reads the
identifier out of the message and looks that key up, so messages written with the
old key keep decoding for as long as the old key is in the ring — which has to be
at least as long as the longest thing that can hold a message: a queue TTL, a
dead-letter queue nobody has drained, a replay somebody runs next quarter.

`AceMQ::AMQP::EncryptedCodec.key_id_of(body)` reads the identifier without any key
at all, which is what an operator staring at an undecryptable dead letter needs.

A key the ring does not hold raises `DecodeError`. So does a wrong key and so does
a tampered message, and they are deliberately indistinguishable — telling them
apart is an oracle.

### What it costs

Every consumer of the queue needs the key. That is not a library problem, it is
the reason to think before reaching for this: a payload only your own services
read can be encrypted, and a payload that is an integration contract with a team
in another language means distributing a key to them. The five AceMQ libraries
share the frame byte for byte, so it is possible; it is still a key-management
problem you have taken on.

## What reaches a log

| | |
|---|---|
| `AceMQ::AMQP::Transport.redact(url)` | The URL with its password removed. What a failed connection reports |
| `Credentials#inspect` / `#to_s` | `[REDACTED]`, always |
| `Security#to_s` | Mode, certificate *paths*, the `because:` reason. Never a secret |

`Security#inspect` deliberately does not call a credentials callable just because
something logged the object — it prints `credentials=(supplied at connection
time)` instead. A logger that resolved a secret in order to print that it was not
printing it would be its own bug.

## Consumer processes

Nothing here is different in the consumer process, and that is worth saying
because the deployment is different: a second Deployment with the same image needs
the same secrets mounted and the same certificate volume. A consumer that cannot
read `/run/secrets/mq` fails at `Runner#start` rather than serving pages without
messaging, so the failure is loud — but only if somebody looks at that Deployment.

`bin/rails acemq:health` from inside the container is the cheapest way to find out
whether the credentials and the trust chain are the ones you think they are.

## Reporting a vulnerability

[SECURITY.md](https://github.com/AceMQ-Company/acemq-ruby-amqp-rails/blob/main/SECURITY.md)
in the repository, which names the supported versions and where to send it.

## See also

- [Configuration](configuration.md) — every setting, including `tls` and `codec`
- [Serialization](serialization.md) — what a codec is, and composing one
- [The library's security page](https://acemq.org/acemq-ruby-amqp/security.html) —
  the same machinery without Rails around it
