# Reporting a vulnerability

Email **security@acemq.com** with what you found and how to reproduce it. Please do
not open a public issue for anything exploitable.

You should get an acknowledgement within two working days, and an assessment of
whether it is a vulnerability, what is affected, and a rough timeline within a week.
If a fix is warranted, we will tell you when it is released and credit you unless you
would rather we did not.

## What is in scope

This repository is a Rails integration. Most of what is worth reporting about the
messaging itself is a vulnerability in the
[library](https://github.com/AceMQ-Company/acemq-ruby-amqp) that this happens to
configure — report it there, or here, and it will end up in the right place.

Things worth reporting here even if they feel minor:

- A credential from `config/acemq.yml` or `config.acemq.*` reaching a log, an
  exception message, a health report, or the output of any of the rake tasks.
  `username`/`password` exist precisely so a password need not be in the URL, and
  a URL that does carry one is redacted before it reaches an error — anything
  that defeats either is a defect.
- A way for the configuration to reach a broker without the certificate
  verification it asked for: a `tls:` `Security` that is dropped, an `amqps://`
  URL that ends up unverified, a `virtual_host` that changes the host rather than
  the vhost.
- Anything that causes a consumer to acknowledge a message whose handler failed.
  The gem re-raises out of `Rails.error.record` for exactly this reason; a path
  that swallows instead is a message-loss bug and is treated as a security issue,
  because "the payment was processed" and "the payment message was dropped" look
  the same afterwards.
- A message payload rendered into a log at any level by this gem. It does not
  log payloads, and should not start.
- A consumer process that keeps serving after the drain deadline has passed and
  the connection has been closed, settling messages it can no longer settle
  correctly.
- A way for `config/acemq.yml` to execute more than the ERB a Rails
  `config_for` already permits. The file is read by Rails' own reader and is as
  trusted as `database.yml`; anything beyond that is a finding.

## What is not

- **`config/acemq.yml` supporting ERB.** So does `database.yml`. The file is part
  of the application, and an attacker who can edit it can edit
  `config/application.rb`.
- **The defaults pointing at `amqp://guest:guest@localhost:5672`.** That is a
  local broker on loopback for a development machine, it is what `rails new`-era
  defaults look like everywhere, and a deployment that ships it has not
  configured the gem at all.
- **The gem not authenticating the health endpoint.** It does not serve one. The
  application composes `AceMQ::Rails::Health.check` into its own endpoint and
  decides what may reach it.
- **`connect_on_boot` raising on boot when the broker is down.** That is what it
  is for, and the documentation says so.
- **Vulnerabilities in Rails, bunny or RabbitMQ.** Report those upstream.
- Findings from a scanner with no demonstrated impact.

## Supported versions

Pre-1.0. The most recent release on the `0.x` line is what is supported, and a
fix ships as a new patch release.

## What this gem does not do for you

It configures a connection, holds it, and runs consumers. It does not manage
broker users or permissions, hold your keys, encrypt message bodies, or
authenticate anything that serves the health report. The library's
[security guide](https://acemq.org/acemq-ruby-amqp/security.html) says which of
those it can do for you and how.
