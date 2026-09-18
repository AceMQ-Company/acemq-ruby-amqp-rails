# Eager loading and reloading

Rails' autoloader and a long-lived consumer interact badly. This page says how,
what is done about it, and what is simply true and has to be lived with.

## What a reload does to a running consumer

A consumer is a class in `app/consumers`, autoloaded like anything else. In
development, saving that file makes Zeitwerk remove the constant and evaluate the
file again, producing a **new class object** under the same name.

A running consumer is not a class. It is a subscription holding the *instance* the
old class produced. So after a reload:

- `OrdersConsumer` the constant points at the new class.
- The subscription still calls the old instance's `#call`.
- Nothing raises, nothing logs, and the consumer goes on running yesterday's code.

There is no fix for this that is worth having. Swapping the instance underneath a
running subscription would mean a message half-handled by one object and settled
by another; tearing the subscription down and rebuilding it on every reload would
mean a deploy-shaped event every time somebody saves a file, with a drain each
time. **Restarting the consumer process is the only thing that has ever picked up
a change**, and it is what this gem tells you to do.

The registry does handle its half honestly: it is keyed by class *name* rather
than holding a set of class objects, so a reload replaces rather than adds.
Without that, an afternoon's editing would leave four `OrdersConsumer`s
registered and the next start would subscribe to the same queue four times.

## The part that is not merely cosmetic

With reloading enabled, Rails installs the autoloader's **load interlock** into
the executor. Every `#call` runs inside `Rails.application.executor.wrap`, so
every handler thread takes a *shared* load lock for the length of the handler.

The moment one of those threads touches a constant that has not been loaded yet,
it needs the **exclusive** lock — which cannot be had while another handler is
still holding its shared one. Neither thread can proceed.

Nothing raises. The two threads wait on each other, the deliveries they are
holding stay unacknowledged, and the consumer looks alive and reads nothing.
Whether it happens at all depends on which constants happen to be warm, so it
appears on a cold start and goes away when the same thing is run again — which is
the worst kind of failure there is.

It was reproduced while this gem was being written, on a freshly generated Rails
8.1 application with `concurrency 2`: of three messages published to a warm
broker, one was handled and two were held by threads that never returned. With
`concurrency 1` the same setup consumed all three. The symptom is not a deadlock
message; it is a queue that stops draining.

## What is done about it

**`bundle exec acemq-consumer` turns reloading off before the application
initializes**, and turns eager loading on.

```ruby
Rails.application.config.enable_reloading = false
Rails.application.config.eager_load = true
Rails.application.initialize!
```

It can do that because it boots `config/application` itself and calls
`initialize!` by hand — the window between the two is exactly what it needs. With
reloading off, Rails installs no interlock at all, so handler threads never
contend; with eager loading on, there is no autoload left for an interlock to
have guarded.

Nothing is lost by it. A reload could not reach a running consumer anyway.

`--reload` puts it back for anybody who wants to experiment, with the same
warning.

## `rake acemq:consume`

The rake task cannot do this. By the time a task body runs, `:environment` has
already booted the application with whatever `config/environments/development.rb`
said, and in development that is reloading on.

So the task runs the same runner, and the runner **warns**:

```
acemq: this process has the development autoloader enabled. Two handler threads
can deadlock on the load interlock, which looks like a consumer that is running
and reading nothing. Use `bundle exec acemq-consumer`, which turns reloading off,
or set concurrency to 1. A reload cannot reach a running consumer in any case.
```

Loud, because the failure is quiet. In production `eager_load` is true and
`enable_reloading` false, so the task is perfectly safe there and the warning
never appears — which is precisely why it would go unnoticed if it were not said
in development.

## Eager loading, and why the runner insists on it

In development nothing is loaded until something references it, and a consumer
process has no requests to do the referencing. Without eager loading the registry
is empty, the runner finds no consumers, and it says so rather than sitting there:

```
acemq: no consumers to run. A consumer is a subclass of AceMQ::Rails::Consumer
with a queue, in app/consumers. If you have some, this process did not load them
— check config.acemq.consumer_paths and that eager loading reaches them.
```

Both entry points call `Rails.application.eager_load!` before reading the
registry. The executable has already had it done by `eager_load = true`; the call
stays for `--reload`, where nothing else would do it.

## `app/consumers` needs no configuration

Rails autoloads every direct subdirectory of `app/`. The Railtie adds nothing for
`app/consumers` and only touches the autoload paths when
`config.acemq.consumer_paths` names somewhere else.

That initializer is declared `before: :set_autoload_paths`, which is load-bearing
rather than tidy: `set_autoload_paths` freezes `config.autoload_paths` on the way
out, and an initializer without the `before:` raises `FrozenError: can't modify
frozen Array` during boot. It is exactly the kind of thing only a real application
catches, which is why the test suite generates one and boots it.
