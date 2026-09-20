# frozen_string_literal: true

# Copyright 2026 AceMQ.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require "acemq/amqp"

module AceMQ
  module Rails
    # The consumer process: what +rake acemq:consume+ and +acemq-consumer+ run.
    #
    # This is deliberately not a thing the web server does. See docs/consumers.md
    # for the argument at length; the short form is that Puma owns its workers'
    # lifetimes and a message handler is not a request. A consumer started inside
    # Puma is forked with the worker if +preload_app!+ is on (and a bunny socket
    # does not survive a fork), killed by +worker_timeout+ if a handler takes
    # longer than a slow request should, scaled by however many web processes the
    # traffic wants rather than by how deep the queue is, and drained on Puma's
    # schedule rather than on the broker's. None of those is a bug that can be
    # fixed from in here.
    #
    # What it does, in order: eager-load the application so consumer classes
    # exist, apply the topology, subscribe every runnable consumer, and then
    # sleep until a signal arrives — at which point it drains.
    class Runner
      # Signals that mean "stop": what Kubernetes, systemd, Docker and a
      # terminal all send.
      SIGNALS = %w[INT TERM].freeze

      # @param config [Configuration]
      # @param connection [AceMQ::AMQP::Connection, nil]
      # @param logger [#info, #warn, #error, nil]
      def initialize(config: AceMQ::Rails.config, connection: nil, logger: nil)
        @config = config
        @connection = connection
        @logger = logger || AceMQ::Rails.logger
        @consumers = []
        @stopping = Thread::Queue.new
        @lock = Mutex.new
      end

      attr_reader :config, :consumers

      # The connection. Opened on first use, so a runner can be built in a test
      # without one.
      def connection
        @lock.synchronize { @connection ||= AceMQ::Rails.connection }
      end

      # Boots, runs, and drains on a signal. Returns when the drain is over.
      #
      # @param classes [Array<Class>, nil] the consumers to run; every runnable
      #   registered class by default
      # @return [Boolean] whether the drain finished within the deadline
      def run(classes = nil)
        trap_signals
        start(classes)
        log_info "acemq: #{@consumers.size} consumer(s) running; waiting for a signal"
        @stopping.pop
        drain
      end

      # Applies the topology and subscribes every consumer, without waiting.
      #
      # Separated from {#run} so a test can start, publish, assert and stop
      # without a signal anywhere near it.
      #
      # @return [Array<AceMQ::AMQP::Consumer>]
      def start(classes = nil)
        classes = Array(classes || Registry.runnable)
        refuse_an_empty_run(classes)
        complain_about_reloading
        apply_topology

        @consumers = classes.map { |klass| subscribe(klass) }
      end

      # Asks {#run} to come back. For a test, and for anything embedding this.
      def stop = @stopping << :stop

      # Stops every consumer, waits for the handlers they are already running,
      # and closes the connection.
      #
      # **What this finishes and what it abandons** is set out with measurements
      # in docs/lifecycle.md. In brief:
      #
      # * A handler in flight finishes, and its message is acknowledged. The
      #   drain blocks on it.
      # * A delivery the broker had sent but no handler had picked up goes back
      #   to the broker unacknowledged and is redelivered.
      # * A retry waiting out a *short* backoff is waited out in full, because
      #   the library's backoff is a +sleep+ on the handler's own thread and is
      #   therefore in flight. A long one is waiting on a rung queue in the
      #   broker and costs this nothing. Which is which is
      #   +consumer.broker_wait_threshold+, thirty seconds by default, and it is
      #   the single setting that most affects how long a deploy takes.
      # * A publish waiting for a confirm is waited for: the library's +publish+
      #   is synchronous, so a publish in progress is a thread this has to join
      #   or abandon, and the transport close below happens after.
      #
      # The drain itself is the library's +Connection#close+, which since
      # +acemq-amqp+ 0.7.0 spends **one deadline across every consumer** rather
      # than a fresh one on each. Until then it did not, which is why this class
      # had a drain of its own: eight consumers each given thirty seconds is
      # four minutes, and four minutes into a shutdown Kubernetes has long since
      # sent +SIGKILL+ — killing every handler mid-flight and leaving everything
      # they held unsettled, the exact outcome draining exists to avoid. One
      # deadline is the library's answer now, so this passes +shutdown_timeout+
      # to it and keeps none of the arithmetic.
      #
      # What is left here is the shape a process wants rather than the shape a
      # library wants: a boolean and a log line, where the library raises
      # {AceMQ::AMQP::DrainTimeout}. +acemq-consumer+ turns that boolean into
      # exit +0+ or +75+, and an exception out of a signal handler's drain would
      # be a backtrace where an exit status belongs.
      #
      # @return [Boolean] whether every handler finished in time
      def drain(timeout: config.shutdown_timeout)
        started = monotonic
        log_info "acemq: draining #{@consumers.size} consumer(s), #{timeout}s at most"

        finished = close_connection(timeout)

        took = (monotonic - started).round(2)
        log_info "acemq: drained in #{took}s" if finished
        finished
      end

      private

      def subscribe(klass)
        handler = klass.new
        options = {
          codec: klass.codec,
          retry_policy: klass.retries,
          prefetch: klass.prefetch,
          concurrency: klass.concurrency,
          tag: klass.tag,
          arguments: klass.arguments,
          retry_threshold: klass.broker_wait_threshold
        }.compact
        options[:concurrency] ||= config.consumer.concurrency

        log_info "acemq: #{klass.name || klass} -> #{klass.queue} " \
                 "(concurrency #{options[:concurrency]}, prefetch " \
                 "#{options[:prefetch] || config.consumer.prefetch})"

        connection.consume(klass.queue, **options) do |message|
          invoke(klass, handler, message)
        end
      end

      # One handler call, with the two things Rails expects around it.
      #
      # +Rails.error.record+ — and emphatically not +handle+ — reports to
      # whatever error tracker the application has configured and then re-raises.
      # +handle+ reports and *swallows*, returning a fallback, and a swallowed
      # exception here would be the worst outcome on this page: the handler
      # returns nil instead of an Ack, the library has nothing to act on, and a
      # message that failed is settled as though it had worked. +record+ keeps
      # the exception travelling, so the retry ladder still decides.
      #
      # The executor wrapping is what makes ActiveRecord usable from a handler at
      # all. A consumer runs on a bunny thread, which Rails has never seen;
      # without this it checks a connection out of the pool on first use and
      # never checks it back in, so a pool of five is exhausted after five
      # messages and the sixth waits for ever. +Rails.application.executor.wrap+
      # is the framework's own answer for "code running on a thread the framework
      # did not make", and it is also what returns the query cache and any
      # +CurrentAttributes+ to a clean state between messages.
      def invoke(klass, handler, message)
        executor.wrap do
          reporter.record(StandardError, severity: :error,
                                         context: error_context(klass, message)) do
            handler.call(message)
          end
        end
      end

      def error_context(klass, message)
        { consumer: klass.name, queue: klass.queue,
          message_id: message.envelope.id, attempt: message.envelope.attempt }
      end

      # The Rails executor, or a stand-in that only yields. The stand-in is for
      # specs, which run this class without an application around it.
      def executor
        @executor ||= if defined?(::Rails) && ::Rails.respond_to?(:application) &&
                         ::Rails.application
                        ::Rails.application.executor
                      else
                        Passthrough
                      end
      end

      def reporter
        @reporter ||= if defined?(::Rails) && ::Rails.respond_to?(:error) && ::Rails.error
                        ::Rails.error
                      else
                        Passthrough
                      end
      end

      # Both seams, for a process with no Rails in it — a spec, most of all.
      # Each one only yields; there is nothing to check a connection out of and
      # nothing to report to, and an exception travels on either way.
      module Passthrough
        def self.wrap
          yield
        end

        def self.record(_error_class = StandardError, **_options)
          yield
        end
      end

      def apply_topology
        return unless config.declare_topology_on_boot
        return unless TopologyBuilder.declared?(config.topology)

        topology = TopologyBuilder.build(config.topology)
        log_info "acemq: applying topology — #{topology}"
        connection.apply(topology)
      end

      # Stops every consumer and closes the socket, inside +timeout+.
      #
      # {AceMQ::AMQP::DrainTimeout} is logged rather than raised, and its
      # message is worth the line: it names each queue that still had deliveries
      # in flight and how many, which is what an operator needs to decide
      # whether the grace period is too short or one handler is stuck. The old
      # warning here could only say that *something* had not finished.
      #
      # Any other failure is a drain that did not happen, which is a false
      # +true+ if it is swallowed: the consumers may still be subscribed and the
      # process is about to exit.
      #
      # The connection drained is the one this ran on. In the consumer process
      # that is the process connection, and going through
      # {AceMQ::Rails.disconnect!} is what makes +AceMQ::Rails.connection+ stop
      # handing out a closed socket by name — and what lets the Railtie's
      # +at_exit+ find nothing left to do. A runner handed a connection of its
      # own, which is a spec or something embedding this, drains that one:
      # cancelling one connection's consumers and closing another's socket was
      # never two halves of the same shutdown.
      def close_connection(timeout)
        own = @lock.synchronize { @connection }
        if own.nil? || (AceMQ::Rails.connected? && own.equal?(AceMQ::Rails.connection))
          AceMQ::Rails.disconnect!(timeout: timeout)
        else
          own.close(timeout: timeout)
        end
        true
      rescue AceMQ::AMQP::DrainTimeout => e
        log_warn "acemq: #{e.message}"
        false
      rescue StandardError => e
        log_warn "acemq: closing the connection failed: #{e.message}"
        false
      end

      # A consumer process with the development autoloader still on is a process
      # with a latent deadlock in it, and the warning is loud because the
      # failure is quiet.
      #
      # With reloading enabled Rails installs the autoloader's interlock into the
      # executor. Two handler threads inside +executor.wrap+ each hold a shared
      # load lock; the moment one of them touches a constant that has not been
      # loaded it needs the exclusive one, which cannot be had while the other is
      # still in a handler. Nothing raises. The two threads wait on each other,
      # the deliveries they hold stay unacknowledged, and the consumer looks
      # alive and reads nothing. Whether it happens depends on which constants
      # are warm, so it appears on a cold start and goes away on a retry.
      #
      # +acemq-consumer+ turns reloading off before the application initializes.
      # +rake acemq:consume+ cannot — +:environment+ has already booted by the
      # time a task body runs — so this is what it gets instead.
      def complain_about_reloading
        return unless reloading?
        return if @consumers_may_reload

        log_warn "acemq: this process has the development autoloader enabled. " \
                 "Two handler threads can deadlock on the load interlock, which " \
                 "looks like a consumer that is running and reading nothing. Use " \
                 "`bundle exec acemq-consumer`, which turns reloading off, or set " \
                 "concurrency to 1. A reload cannot reach a running consumer in " \
                 "any case — see docs/reloading.md."
      end

      def reloading?
        return false unless defined?(::Rails) && ::Rails.respond_to?(:application) &&
                            ::Rails.application

        config = ::Rails.application.config
        config.respond_to?(:enable_reloading) ? config.enable_reloading : false
      rescue StandardError
        false
      end

      def refuse_an_empty_run(classes)
        return unless classes.empty?

        raise AceMQ::AMQP::ConfigurationError,
              "acemq: no consumers to run. A consumer is a subclass of " \
              "AceMQ::Rails::Consumer with a queue, in app/consumers. If you have " \
              "some, this process did not load them — check config.acemq.consumer_paths " \
              "and that eager loading reaches them."
      end

      def trap_signals
        SIGNALS.each do |signal|
          # A trap handler runs on the main thread between other work and may
          # not take a lock or write to a logger safely. Pushing to a queue is
          # one of the few things that is safe in there, and the draining
          # happens back on the thread that called run.
          Signal.trap(signal) { @stopping << signal }
        rescue ArgumentError
          # A platform without it. Nothing to do and nothing worth saying.
          nil
        end
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def log_info(line) = @logger&.info(line)
      def log_warn(line) = @logger&.warn(line)
    end
  end
end
