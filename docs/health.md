# Health

```ruby
report = AceMQ::Rails.health
report.up?        # or down?, degraded?
report.detail     # what to do about it
report.to_h       # the shape every AceMQ library renders
```

```bash
bin/rails acemq:health
```

## Composed, not imposed

This gem adds no endpoint. An application that already has a readiness probe
should not grow a second one, so what is offered is a check that goes into the
one it has:

```ruby
class HealthController < ApplicationController
  def show
    report = AceMQ::AMQP::Health.aggregate(
      AceMQ::Rails::Health.check,
      DatabaseCheck.new,
      RedisCheck.new
    )
    render json: report.to_h, status: report.down? ? 503 : 200
  end
end
```

`aggregate` runs the checks on threads rather than in turn, so a slow one does
not add its latency to the others, and the combined status is the worst of them.
A check that raises becomes a `down` part rather than an exception out of the
probe — a probe that raises tells an orchestrator nothing at all.

It costs a round trip to the broker: the library declares a queue named for that
moment and deletes it again, which is the cheapest thing AMQP offers that
actually proves the round trip. That belongs on a probe with an interval, not in
a request.

## The three statuses

**`up`** — the broker answered and every consumer on this connection is running.

**`degraded`** — the broker answered and a consumer has stopped. The process can
still publish and its other consumers still work, so failing the probe would take
out something doing most of its job; but a queue with nothing reading it is a
real fault and has to be visible. That is what `degraded` is for: alert on it,
do not restart on it.

**`down`** — the connection is closed, or the broker did not answer. The detail
says which.

## A blocked connection is healthy, with a reason

This is the rule this gem adds, and it matches the Java starter and the Go
library.

RabbitMQ **blocks** a connection when it is low on memory or disk. Every publish
on that connection stops. The temptation is to fail the readiness probe, and
failing it is exactly wrong: a blocked connection is the broker applying back
pressure to a producer that is doing nothing wrong. Restarting the producer into
the same pressured broker helps nobody, and doing it to every replica at once
turns a broker under memory pressure into an outage with a crash-loop on top.

So it is reported as a detail on a report whose status is unchanged:

```json
{
  "status": "up",
  "detail": "the broker has blocked this connection; publishing is paused",
  "parts": { "consumers": 2, "consumers_running": 2, "blocked": true }
}
```

Visible on a dashboard, matchable by an alert rule — the wording is fixed for
exactly that reason — and not a reason for anything to be taken out of rotation.
A report that was already `degraded` stays `degraded` and says both things.

**Where it is checked, and why here.** The Ruby library's own `Health` has no
notion of a blocked connection: the flag lives on bunny's session
(`Bunny::Session#blocked?`, set from `connection.blocked` and cleared from
`connection.unblocked`), and the library's health check is written against a
transport seam that a hand-written double also satisfies. Reaching through two
layers to a driver is a thing an integration may do and a portable contract may
not. It is tolerant about it: a transport that cannot be asked simply says
nothing, because a health check that raised inside a readiness probe would be
worse than one that under-reports.

## Liveness is not readiness

Use this for **readiness**. For **liveness**, use something that does not touch
the broker at all — a static 200 is the honest answer. A liveness probe that
fails when a dependency is unavailable restarts a process that was working, which
is how a broker having a bad ten minutes becomes a fleet-wide restart storm.
