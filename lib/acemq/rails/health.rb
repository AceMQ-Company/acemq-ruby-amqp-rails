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
    # What this process can say about its broker.
    #
    # The library's own {AceMQ::AMQP::Health.of} does the expensive half: it
    # declares a queue and deletes it again, which is the cheapest thing AMQP
    # offers that actually proves a round trip, and it reports a stopped consumer
    # as +:degraded+ rather than +:down+.
    #
    # This adds the one thing the Ruby library does not model and the Go and Java
    # ones do: **a blocked connection is healthy, with a reason.**
    #
    # RabbitMQ blocks a connection when it is low on memory or disk. Every
    # publish on it stops, so the temptation is to fail the probe — and failing
    # it is exactly wrong. A blocked connection is the broker applying back
    # pressure to a producer that is doing nothing wrong; restarting the producer
    # into the same pressured broker helps nobody, and doing it to every replica
    # at once turns a broker under memory pressure into an outage with a
    # crash-loop on top. The state has to be *visible* — so it is reported as a
    # detail on an +:up+ report, which shows in a dashboard and can be alerted on
    # without anything being taken out of rotation.
    #
    # It is checked here rather than in the library because bunny is where the
    # flag lives — +Bunny::Session#blocked?+, set from +connection.blocked+ and
    # cleared from +connection.unblocked+ — and the library's Health is written
    # against a transport seam that a test double also satisfies. Reaching
    # through two layers to a driver is a thing an integration may do and a
    # portable contract may not.
    module Health
      # The reason string an operator will read. Fixed wording, because it is
      # what an alert rule will match on.
      BLOCKED = "the broker has blocked this connection; publishing is paused"

      # Checks the connection, its consumers, and whether the broker has blocked
      # it.
      #
      # Costs a round trip, so it belongs on a readiness probe with an interval,
      # not in a request.
      #
      # @param connection [AceMQ::AMQP::Connection, nil] the process connection
      #   by default
      # @return [AceMQ::AMQP::Health::Report]
      def self.of(connection = AceMQ::Rails.connection)
        report = AceMQ::AMQP::Health.of(connection)
        reason = blocked_reason(connection)
        return report unless reason

        # The detail is added and the status is not touched. A report that was
        # already +:degraded+ because a consumer stopped stays +:degraded+ and
        # says both things; one that was +:up+ stays +:up+ and says why it is
        # worth looking at.
        AceMQ::AMQP::Health::Report.new(
          status: report.status,
          detail: [report.detail, reason].compact.reject(&:empty?).join("; "),
          checked_at: report.checked_at,
          parts: report.parts.merge("blocked" => true)
        )
      end

      # A check for {AceMQ::AMQP::Health.aggregate}, so this composes into
      # whatever readiness endpoint the application already has rather than
      # insisting on one of its own.
      #
      #   AceMQ::AMQP::Health.aggregate(
      #     AceMQ::Rails::Health.check,
      #     DatabaseCheck.new
      #   )
      #
      # @return [#name, #check]
      def self.check(name = "acemq", connection = nil)
        Check.new(name, connection)
      end

      # @api private
      Check = Struct.new(:name, :connection) do
        def check = Health.of(connection || AceMQ::Rails.connection)
      end

      # Whether the broker has blocked this connection, or nil when it has not
      # and nil when nothing in the stack can say.
      #
      # Deliberately tolerant: a fake transport in a test has no bunny session,
      # and a health check that raises inside a readiness probe tells an
      # orchestrator nothing at all.
      #
      # @api private
      def self.blocked_reason(connection)
        transport = connection.respond_to?(:transport) ? connection.transport : connection
        return nil unless transport.respond_to?(:session)

        session = transport.session
        return nil unless session.respond_to?(:blocked?)

        session.blocked? ? BLOCKED : nil
      rescue StandardError
        nil
      end
    end
  end
end
