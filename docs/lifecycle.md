# Shutdown and the drain

What `SIGTERM` finishes, what it abandons, and how long each takes.

The Go library's [lifecycle guide](https://acemq.org/acemq-go-amqp/lifecycle.html)
is where this argument was first written down, with measurements. Ruby's answers
are mostly the same and differ in two places that matter, both because
`acemq-amqp` is blocking rather than async. The differences are measured here
rather than assumed.

## The shape

```
SIGTERM
  └─ every consumer is cancelled, each given whatever is left of
     one shared deadline (config.acemq.shutdown_timeout)
       ├─ the broker stops sending
       ├─ handlers already running are waited for
       └─ the channel is closed
  └─ the connection is closed
  └─ exit 0, or 75 if the deadline expired
```

The signal handler does one thing: push to a queue. A trap runs on the main
thread between other work and may not safely take a lock or write to a logger;
the draining happens back on the thread that called `run`.

## What the drain finishes

### The handler in flight

**It finishes.** Not "is given a chance to finish" — the drain blocks on it. A
handler sleeping for 300 milliseconds when the signal arrives makes the drain
take 300 milliseconds, and its message is acknowledged rather than abandoned for
the broker to give to somebody else.

Measured here: a handler holding a message for 1.5 seconds makes a drain with a
ten-second deadline take about 1.5 seconds and finish, with the handler's own
completion observed before the drain returns. That is `spec/integration_spec.rb`,
"finishes the handler it is already running before it closes".

That guarantee is also the whole reason a shutdown needs a deadline: the library
will wait for a handler that never returns until it is told not to.

### The retry waiting out a backoff

A short wait is spent **in this process**, on the handler's own thread, holding
the delivery and one prefetch slot. A long one is spent **on a rung queue in the
broker**, holding nothing. Which is which is `broker_wait_threshold`, thirty
seconds by default.

A wait held in this process is in flight, so the drain waits it out in full. A
consumer two seconds into a two-second backoff makes the drain take the rest of
it; one that fell back to waiting here because its rung queue was missing, on a
five-minute schedule, makes the drain *fail*, because nothing grants a pod five
minutes.

So the rung queues are a shutdown concern and not only a reliability one.
Declaring them is what keeps a wait off this process:

```yaml
queues:
  - name: shop.orders
    dead_letter: true
    retries:
      max_attempts: 5
      initial_delay: 10
      max_delay: 300
      broker_wait_threshold: 10
```

The library counts `acemq.retry.rung.missing` every time a consumer cannot find
its rung and waits here instead. That counter is worth an alert on its own
merits; it is also the early warning that the next deployment's drain is going to
be slow.

### The publish waiting for a confirm

Ruby's `publish` is **synchronous**: it writes the message and waits for the
broker's confirm before it returns. That is the first place this differs from Go,
and it simplifies matters — there is no set of unconfirmed publishes to reconcile
at shutdown, because a publish is either finished or is a thread still inside the
call.

The consequence is about *where* the publish is. A publish from a handler is
covered by the handler's own guarantee above. A publish from an application
thread the consumer process knows nothing about is not: the drain closes the
connection when the consumers are done, and a publish still in flight on another
thread meets a closed channel. A process that publishes from somewhere other than
a handler has to stop that itself before the drain, exactly as it would have to
stop a web server before closing a database pool.

## What it abandons

### The delivery that never reached a handler

The broker sends up to `prefetch` messages ahead. Those that are sitting in the
channel's buffer when the subscription is cancelled were never given to a handler,
are never acknowledged, and **go back to the broker**. They are redelivered after
the restart, with `redelivered?` true and the same attempt number — the attempt
count rides on the message's own headers, so nothing is lost by the round trip.

### Everything, if the deadline expires

The drain reports `false` and the process exits `75`. What that costs is worth
being exact about, because "the drain timed out" sounds worse than it is:

- Messages whose handlers had not finished are **not acknowledged**, so the
  broker redelivers them. The work may be done twice. That is the ordinary
  at-least-once case handlers should already be idempotent against.
- A message that needed dead-lettering in that window went to the broker's own
  dead-letter exchange without the reason attached, or nowhere.
- The consumer's channel may be closed under a handler that is still running, in
  which case bunny logs `ChannelAlreadyClosed` from its own consumer thread. It
  is noisy and it is not a failure of anything: the delivery that handler was
  holding is unsettled, which is the thing already described.

Nothing is silently dropped. What is lost is the *reasons*.

## One deadline for the whole drain

`shutdown_timeout` is the budget for *all* the consumers together, not for each
of them. Eight consumers each given twenty seconds is not a bound on anything:
it is two and a half minutes, and two and a half minutes into a shutdown
Kubernetes has long since sent `SIGKILL` — killing every handler mid-flight and
leaving everything they held unsettled, which is the exact outcome draining
exists to avoid.

The arithmetic is `AceMQ::AMQP::Connection#close(timeout:)`, and the runner
passes `shutdown_timeout` to it and keeps none of its own. Each consumer is
given whatever is left of the deadline, in the order they were started; one
reached with nothing left is stopped without being waited for.

When the deadline expires with handlers still running, the library raises
`AceMQ::AMQP::DrainTimeout` — after stopping every consumer and closing the
socket, because a shutdown that reports a problem having left the socket open is
a process that will not exit. The runner logs it and exits `75` rather than
re-raising; its message names each queue that still had deliveries in flight and
how many, which is what tells you whether to lengthen the grace period or go and
find the handler that will not return.

> Until `acemq-amqp` 0.7.0 `Connection#close` gave each consumer a fresh
> thirty-second timeout of its own, and this gem worked around it with a drain
> that cancelled consumers on threads against one shared deadline. 0.7.0 made the
> shared deadline the library's, so the workaround went: two answers to "how long
> may a shutdown take" is one too many, and the library's is the one every AceMQ
> language now gives.

## Choosing the deadline

It has to be comfortably shorter than whatever will kill the process.

| | |
|---|---|
| Kubernetes | `terminationGracePeriodSeconds`, thirty by default |
| systemd | `TimeoutStopSec` |
| Docker | `docker stop -t`, ten by default |

The default here is twenty, which sits inside a thirty-second grace period with
ten to spare for the process to actually exit. Setting the two equal means the
orchestrator wins the race sometimes, and a shutdown that is correct on most
deployments is one nobody debugs until it is not.

A container run under `docker stop`'s ten-second default wants
`shutdown_timeout: 6`, or a longer `-t`.

## The web process

The Railtie registers an `at_exit` that closes the connection. In a web process
that only ever published, that is a socket and a heartbeat thread going away
tidily rather than the broker logging an abrupt disconnection. It does nothing
when nothing was opened, which is the common case for a page that never published.

The consumer process never reaches it: the runner has already drained and
disconnected, and disconnecting twice is a no-op.
