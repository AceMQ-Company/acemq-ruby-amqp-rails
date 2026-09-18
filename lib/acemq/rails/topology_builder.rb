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
    # Turns the +topology+ section of the configuration into a library
    # {AceMQ::AMQP::Topology}.
    #
    #   topology:
    #     exchanges:
    #       - name: orders-events
    #         type: topic
    #     queues:
    #       - name: orders.new
    #         dead_letter: true
    #         retries: { max_attempts: 5, initial_delay: 1, max_delay: 60 }
    #     bindings:
    #       - queue: orders.new
    #         exchange: orders-events
    #         routing_key: order.#
    #
    # Declared rather than inferred. A queue that appears because some consumer
    # class mentioned it is a queue whose durability, type and dead-lettering
    # nobody decided, and those three are part of a queue's identity to the
    # broker: get them wrong once and the second service to declare it is refused
    # with PRECONDITION_FAILED and cannot consume at all.
    module TopologyBuilder
      # @param settings [Hash] the +topology+ section
      # @return [AceMQ::AMQP::Topology]
      # @raise [AceMQ::AMQP::TopologyError] when the declaration cannot stand up
      def self.build(settings)
        settings = normalise(settings)
        topology = AceMQ::AMQP::Topology.new(
          **{ dead_letter_exchange: settings[:dead_letter_exchange] }.compact
        )

        Array(settings[:exchanges]).each { |it| exchange(topology, normalise(it)) }
        Array(settings[:queues]).each { |it| queue(topology, normalise(it)) }
        Array(settings[:bindings]).each { |it| binding(topology, normalise(it)) }

        topology
      end

      # Whether anything at all was declared. An empty section applies nothing,
      # silently and on purpose: an application whose queues are made by a
      # migration tool should not have to configure this away.
      def self.declared?(settings)
        settings = normalise(settings)
        %i[exchanges queues bindings].any? { |key| !Array(settings[key]).empty? }
      end

      # @api private
      def self.exchange(topology, spec)
        name = require_key(spec, :name, "topology.exchanges")
        kind = spec[:type] || spec[:kind] || "topic"
        topology.exchange(name, kind.to_sym,
                          durable: fetch(spec, :durable, true),
                          auto_delete: fetch(spec, :auto_delete, false),
                          arguments: spec[:arguments] || {})
      end

      # @api private
      def self.queue(topology, spec)
        name = require_key(spec, :name, "topology.queues")
        topology.queue(name,
                       durable: fetch(spec, :durable, true),
                       auto_delete: fetch(spec, :auto_delete, false),
                       exclusive: fetch(spec, :exclusive, false),
                       arguments: spec[:arguments] || {},
                       **queue_kind(spec),
                       **dead_letter(spec))
        retries(topology, name, spec)
      end

      # @api private
      def self.binding(topology, spec)
        queue = require_key(spec, :queue, "topology.bindings")
        exchange = require_key(spec, :exchange, "topology.bindings")
        topology.binding(queue, exchange, (spec[:routing_key] || "").to_s)
      end

      # @api private
      #
      # The rungs of a retry ladder are queues, and they have to exist before a
      # consumer needs them — a consumer that cannot find its rung falls back to
      # waiting in this process, which is slower, holds a prefetch slot, and
      # makes the next deployment's drain sit through the wait. The library
      # counts +acemq.retry.rung.missing+ every time; declaring them here is how
      # that counter stays at nought.
      def self.retries(topology, name, spec)
        settings = spec[:retries] || spec[:retry]
        return unless settings

        settings = normalise(settings)
        threshold = settings.delete(:broker_wait_threshold)
        policy = Configuration::ConsumerDefaults.new.assign(settings).retry_policy
        topology.retry_ladder(name, policy,
                              **{ threshold: threshold }.compact)
      end

      # @api private
      def self.queue_kind(spec)
        kind = spec[:type] || spec[:queue_type]
        kind.nil? ? {} : { queue_type: kind.to_sym }
      end

      # @api private
      #
      # +dead_letter: true+ wires up the conventional +{queue}.dlq+ and the
      # exchange that reaches it. There is deliberately no way to name a
      # different queue: the name is +Naming.dead_letter_queue+ in all five
      # libraries, and a Ruby service that renamed its own would be draining a
      # queue the Java service beside it has never heard of.
      def self.dead_letter(spec)
        spec[:dead_letter] ? { dead_letter: true } : {}
      end

      # @api private
      def self.require_key(spec, key, where)
        value = spec[key]
        if value.nil? || value.to_s.empty?
          raise AceMQ::AMQP::TopologyError,
                "acemq: every entry in #{where} needs a #{key}; got #{spec.inspect}"
        end

        value.to_s
      end

      # @api private
      def self.fetch(spec, key, fallback)
        spec.key?(key) ? spec[key] : fallback
      end

      # @api private
      #
      # YAML gives string keys and a Rails +config_for+ gives a
      # +ActiveSupport::OrderedOptions+ with symbol ones. Both arrive here.
      def self.normalise(value)
        return {} if value.nil?

        value.to_h { |key, inner| [key.to_s.tr("-", "_").to_sym, inner] }
      end
    end
  end
end
