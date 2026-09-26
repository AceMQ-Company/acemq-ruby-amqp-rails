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

require_relative "rails/version"
require_relative "rails/configuration"
require_relative "rails/registry"
require_relative "rails/consumer"
require_relative "rails/topology_builder"
require_relative "rails/health"
require_relative "rails/runner"

module AceMQ
  # Rails integration for AceMQ.
  #
  # One connection for the process, reachable from anywhere in the application;
  # consumers written as classes and run in a process of their own; a health
  # check that composes into whatever the application already exposes.
  #
  # == A note on the name
  #
  # This module is called +Rails+ and sits inside +AceMQ+, which means that
  # inside any file lexically nested in +module AceMQ; module Rails+, a bare
  # +Rails+ resolves to *this* module and not to the framework. Every reference
  # to the framework in this gem is therefore written +::Rails+, and that is not
  # a style choice — leaving one off gives a +NoMethodError+ on
  # +AceMQ::Rails.application+ that reads like a bug in the application.
  module Rails
    # Guards the one connection. Named here rather than inside the singleton
    # class, where a constant would belong to the singleton and not to the
    # module — which compiles, and then cannot be reached by the name it was
    # given.
    LOCK = Mutex.new

    class << self
      # The configuration. Set from +config/acemq.yml+ and +config.acemq.*+ when
      # a Railtie is loaded, and directly when there is no Rails — a rake task in
      # a plain Ruby process, or a spec.
      #
      # @return [Configuration]
      def config
        @config ||= Configuration.new
      end

      attr_writer :config, :logger

      # Where this gem logs. +Rails.logger+ when there is one.
      #
      # @return [#info, #warn, #error, nil]
      def logger
        return @logger if defined?(@logger) && @logger

        defined?(::Rails) && ::Rails.respond_to?(:logger) ? ::Rails.logger : nil
      end

      # The connection this process publishes and consumes on.
      #
      # One per process, opened on first use and memoised. A connection is a
      # socket and a heartbeat; opening one per request would be the single most
      # expensive mistake available here, and is the reason this exists rather
      # than every caller writing +Connection.open+.
      #
      # Opened lazily by default, which is a decision rather than laziness: a
      # broker that is down should not stop an application from serving the
      # pages that never touch it. +config.acemq.connect_on_boot = true+ moves
      # it to boot for an application that would rather fail fast.
      #
      # @return [AceMQ::AMQP::Connection]
      def connection
        # Double-checked, and the outer check is not an optimisation: this is on
        # the path of every publish in every request, and taking a process-wide
        # mutex there would serialise a Puma worker's threads behind each other
        # for the whole life of the process.
        return @connection if @connection

        LOCK.synchronize do
          @connection ||= begin
            url, options = config.connection_arguments
            intercept(AceMQ::AMQP::Connection.open(url, **options))
          end
        end
      end

      # Registers +config.acemq.interceptors+ on a freshly opened connection.
      #
      # Here rather than in an initializer, because an interceptor lives on a
      # connection and an initializer that reaches for one opens the socket
      # during boot — see {Configuration#interceptors}. Each is offered to both
      # sides; the library keeps only the hooks the object answers to.
      #
      # @api private
      def intercept(connection)
        Array(config.interceptors).each do |interceptor|
          connection.intercept_publish(interceptor)
          connection.intercept_consume(interceptor)
        end
        connection
      end

      # Whether a connection has been opened. Does not open one.
      def connected? = !@connection.nil?

      # Replaces the connection, for a test that wants a fake transport.
      #
      # @param connection [AceMQ::AMQP::Connection, nil]
      def connection=(connection)
        LOCK.synchronize { @connection = connection }
      end

      # Publishes a message.
      #
      #   AceMQ::Rails.publish(order.as_json, to: "order.placed",
      #                        exchange: "orders-events", type: "order.placed.v2")
      #
      # A thin delegation, and thin on purpose. The library's +publish+ is
      # already the right shape, and a wrapper that renamed its keywords would be
      # a second API to document, a second one to keep in step, and the place
      # where an integration starts making decisions the library deliberately
      # left to the caller.
      #
      # @return [AceMQ::AMQP::Envelope] what actually went on the wire
      def publish(payload, **options) = connection.publish(payload, **options)

      # Publishes a batch in one round trip. Added to the library in 0.6.0.
      #
      # @return [Array<AceMQ::AMQP::Envelope>] in the order the payloads were
      #   given, whatever order the broker confirmed them in
      def publish_all(payloads, **options) = connection.publish_all(payloads, **options)

      # What this process can say about its broker, blocked connections
      # included. See {Health}.
      #
      # @return [AceMQ::AMQP::Health::Report]
      def health = Health.of(connection)

      # The topology the configuration declares.
      #
      # @return [AceMQ::AMQP::Topology]
      def topology = TopologyBuilder.build(config.topology)

      # Declares the topology. What +rake acemq:topology+ runs, and what the
      # consumer process does on boot.
      def apply_topology
        return nil unless TopologyBuilder.declared?(config.topology)

        connection.apply(topology)
      end

      # The registered consumer classes.
      #
      # @return [Array<Class>]
      def consumers = Registry.runnable

      # Closes the connection, draining any consumers on it first.
      #
      # Safe to call when nothing was ever opened, which is what makes it usable
      # from an +at_exit+ in a web process that may never have published.
      #
      # The connection is let go of before it is closed, and not after: a close
      # that raises — which since +acemq-amqp+ 0.7.0 it does when the drain ran
      # out of time — must still leave this process without a connection it
      # thinks it has.
      #
      # @param timeout [Numeric, nil] seconds for the whole drain, every
      #   consumer together. The library's own default when nil, which is what
      #   an +at_exit+ wants; the consumer process passes +shutdown_timeout+
      # @raise [AceMQ::AMQP::DrainTimeout] when handlers were still running when
      #   the deadline expired. The socket is shut either way
      def disconnect!(timeout: nil)
        connection = LOCK.synchronize do
          taken = @connection
          @connection = nil
          taken
        end
        timeout ? connection&.close(timeout: timeout) : connection&.close
        nil
      end
    end
  end
end

# `::Rails`, not `Rails`. This line is outside the module, so a bare `Rails`
# would resolve to the framework here and to AceMQ::Rails three lines up — the
# ambiguity the module comment warns about, in the one place it would be
# invisible. Rubocop calls the `::` redundant; it is not.
require_relative "rails/railtie" if defined?(::Rails::Railtie) # rubocop:disable Style/RedundantConstantBase
