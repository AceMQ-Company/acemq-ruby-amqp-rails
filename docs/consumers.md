# Consumers

A consumer is a class in `app/consumers`. It is run by a process of its own, and
that second sentence is the design.

```ruby
class OrdersConsumer < AceMQ::Rails::Consumer
  queue "shop.orders"
  concurrency 4
  prefetch 20
  retries max_attempts: 5, initial_delay: 1, max_delay: 300

  def call(message)
    Fulfilment.begin!(message.payload)
    accept
  rescue Warehouse::Unavailable => e
    retry_later(e.message)
  rescue Order::Malformed => e
    reject(e.message)
  end
end
```

`#call` takes an `AceMQ::AMQP::Message` — `payload`, `envelope`, `routing_key`,
`body`, `attempt`, `redelivered?` — and must return an `Ack`. Four are available
without reaching into the library's namespace:

| | |
|---|---|
| `accept` | Done with it. The broker may forget it |
| `retry_later(reason)` | Try again on the ladder this consumer declared |
| `reject(reason)` | It will never work. `{queue}.dlq`, with the reason attached |
| `park(reason)` | It broke the consumer rather than failed in it. `{queue}.parked`, for a person |

Raising is the other way to reject, and it is the one that reaches an error
tracker: an exception out of `#call` is reported to `Rails.error` — with the
consumer, the queue, the message id and the attempt as context — and then
re-raised so that the library's retry ladder still decides what happens.

## Why not inside Puma

This is the question the design answers, so it is worth answering properly rather
than asserting.

**Puma owns its workers' lifetimes and a message handler is not a request.** A
consumer started from an initializer inherits every decision Puma makes for the
benefit of request-serving, and none of them are right for a long-lived
subscription:

- **`preload_app!` forks.** A bunny connection is a TCP socket and a heartbeat
  thread; neither survives `fork`. A consumer started before the fork is a broken
  consumer in every worker, and it fails in the way that is hardest to see — the
  socket is there, nothing is read, no error is raised.
- **`worker_timeout` kills.** It exists to catch a request that has hung, and it
  is set to a number of seconds a slow *page* should take. A handler that takes
  longer than that — a report, a batch, a third party having a bad afternoon — is
  a worker Puma kills, mid-message, without a drain.
- **Scaling is by the wrong number.** Web processes are scaled by request rate.
  Consumers are scaled by queue depth. Tying them together means adding web
  capacity to drain a backlog, or discovering that a quiet night has scaled the
  consumers to one.
- **Draining is on Puma's schedule.** Puma's shutdown is built around finishing
  in-flight *requests*; it has no notion of a handler that must finish, a
  delivery that must be settled, or a publish that must be confirmed. What
  [lifecycle.md](lifecycle.md) describes cannot be arranged from inside it.
- **A reload replaces the classes underneath it.** [reloading.md](reloading.md).

None of those is a bug that could be fixed from in here. They are consequences of
what a web server is for.

So this gem starts nothing. The Railtie contributes configuration, a connection
and rake tasks; **nothing in it subscribes to anything**, which makes "a consumer
inside Puma" not a mistake you can make by accident. The registry holds classes,
and the code that turns a class into a subscription lives in `Runner`, which the
web process never loads.

## Running them

```bash
bundle exec acemq-consumer
bundle exec acemq-consumer --queues shop.orders,shop.refunds
bin/rails acemq:consume
```

Both do the same thing. The executable is the one to use, for two reasons:

Rake is a layer between the signal and the drain. It installs handlers of its
own, a task's exit code goes out through rake's, and Ctrl-C prints a backtrace
from inside rake before anything of ours notices. For a process whose entire job
is to start, wait and drain correctly on a signal, one fewer layer is worth an
executable — and a Procfile line, a systemd `ExecStart` and a container `CMD` all
want a command rather than a task runner running a command.

And the executable boots the application itself, which lets it turn reloading off
*before* the application initializes. `rake acemq:consume` cannot, and
[reloading.md](reloading.md) explains why that matters more than it sounds.

What the process does, in order: boot the application with eager loading on and
reloading off; apply the topology; subscribe every registered consumer; wait for
a signal; drain.

The exit code is `0` for a drain that finished and `75` — `EX_TEMPFAIL` — for one
that ran out of time. The process did its job and ran out of time putting itself
away, which is a different thing from having failed, and a restart policy should
be able to tell them apart.

## Settings, and where they come from

Every setting falls back: the class, then its superclass, then
`config.acemq.consumer`, then the library's own default. An unset option is
**left out** of the call rather than passed as nil, so the library's defaults stay
the library's business rather than being frozen here at whatever they were.

```ruby
class ApplicationConsumer < AceMQ::Rails::Consumer
  prefetch 50
  concurrency 4
  # No queue: this is an abstract intermediate and the runner skips it.
end

class OrdersConsumer < ApplicationConsumer
  queue "shop.orders"   # inherited: prefetch 50, concurrency 4
end

class ReportsConsumer < ApplicationConsumer
  queue "shop.reports"
  concurrency 1         # one at a time, so the order the broker offers is kept
end
```

The **queue is not inherited**, on purpose. Two consumers sharing an inherited
queue name is a competing-consumers setup written by accident, and it would be
silent.

`concurrency` is the one worth thinking about. One keeps a queue's messages in
the order the broker offers them. Raising it trades that order for throughput —
which is the point of raising it, and worth saying out loud because
`concurrency 8` reads like free throughput and is not.

The **consumer tag** defaults to the class name, so RabbitMQ's management
interface shows `OrdersConsumer` beside the subscription rather than a UUID.

## One instance, many messages

The runner builds one instance of each consumer class and hands every message to
it. A consumer that memoises something expensive on the way up gets to keep it —
and, by the same token, a consumer holding mutable state shared across messages
is holding it across threads once `concurrency` is above one. Keep state in the
message or in the database.

## ActiveRecord, and the executor

Every `#call` runs inside `Rails.application.executor.wrap`. This is what makes
ActiveRecord usable from a handler at all: a consumer runs on a bunny thread,
which Rails has never seen, and without the executor it checks a connection out
of the pool on first use and never checks it back in — so a pool of five is
exhausted after five messages and the sixth waits for ever. The executor is also
what returns the query cache and any `CurrentAttributes` to a clean state between
messages.
