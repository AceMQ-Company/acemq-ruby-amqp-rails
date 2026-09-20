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
  "detail": "the broker has blocked this connection; publishing is paused: low on memory",
  "parts": {
    "consumers": 2,
    "consumers_running": 2,
    "blocked": true,
    "blocked_reason": "low on memory"
  }
}
```

Visible on a dashboard, matchable by an alert rule — the wording up to the colon
is fixed for exactly that reason — and not a reason for anything to be taken out
of rotation. A report that was already `degraded` stays `degraded` and says both
things.

**The reason after the colon is the broker's own**, as it arrived on
`connection.blocked`: `low on memory`, `low on disk`, or whatever a future
RabbitMQ says. It is the difference between paging someone and telling them which
alarm to go and clear. `parts.blocked_reason` has it on its own for a dashboard
that would rather not parse a sentence.

**No round trip is spent while the connection is blocked.** The check is built on
a `queue.declare`, and a blocked connection is one the broker has stopped
reading — so the declare does not fail, it *hangs*, until bunny's continuation
timeout gives up seconds later. The report is answered from what the broker
already said over the same socket, which is livelier proof than a declare;
`round_trip_ms` is absent from the parts, because nothing was timed.

**Where it is checked.** In `acemq-amqp` itself, since 0.7.0 — `blocked_reason`
is on the transport seam, `AceMQ::AMQP::Connection#blocked?` and
`#blocked_reason` forward it, and `AceMQ::AMQP::Health.of` writes it onto the
report. It is tolerant: a transport that has never heard of the method simply
says nothing, because a health check that raised inside a readiness probe would
be worse than one that under-reports.

Until 0.7.0 the library had no notion of a blocked connection and this gem
supplied one, reading `connection.transport.session.blocked?` — bunny's own flag
— and merging a reason of its own into the report. That is history now, and it is
worth saying what it cost while it lasted: the reason was a constant, so an
operator learned *that* the broker had blocked the connection and never *why*;
and the library's probe still ran first, so against a genuinely blocked broker
the report arrived seconds late and said `down`. Both halves are fixed by the
library having the rule rather than an integration bolting it on.

## Liveness is not readiness

Use this for **readiness**. For **liveness**, use something that does not touch
the broker at all — a static 200 is the honest answer. A liveness probe that
fails when a dependency is unavailable restarts a process that was working, which
is how a broker having a bad ten minutes becomes a fleet-wide restart storm.
