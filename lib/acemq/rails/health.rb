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
    # The report is the library's, entire: {AceMQ::AMQP::Health.of} declares a
    # queue and deletes it again — the cheapest thing AMQP offers that actually
    # proves a round trip — reports a stopped consumer as +:degraded+ rather
    # than +:down+, and reports a connection the broker has blocked as +:up+
    # with the broker's own reason written onto it.
    #
    # What this module adds is one Rails-shaped thing and nothing else: the
    # connection defaults to the process connection, and {check} resolves it
    # when the check runs rather than when it is built, so a readiness endpoint
    # assembled at boot does not open a socket on the way up.
    #
    # == Why this used to be longer
    #
    # Until +acemq-amqp+ 0.7.0 the library had no notion of a blocked
    # connection, so this module synthesised one: it read
    # +connection.transport.session.blocked?+ — bunny's own flag — and merged a
    # fixed reason of its own into the library's report. That reached through
    # the transport seam into the driver, which is a thing an integration may do
    # and a portable contract may not, and it bought less than it looked like it
    # did. The reason was a constant, so an operator was told *that* the broker
    # had blocked the connection and never *why*; and the library's probe still
    # ran first, where a +queue.declare+ on a blocked connection does not fail
    # but waits for bunny's continuation timeout, so the report arrived seconds
    # late and +:down+ for a broker that was up and talking.
    #
    # 0.7.0 put +blocked_reason+ on the transport seam, made {Connection#blocked?}
    # forward it, skipped the round trip while the connection is blocked, and
    # reports the broker's actual reason after the same fixed wording. All three
    # halves of the workaround became the library's, which is where a rule every
    # AceMQ library states in the same words belongs. See docs/health.md.
    module Health
      # The report for a connection, the process one by default.
      #
      # Costs a round trip, so it belongs on a readiness probe with an interval,
      # not in a request. (Not even that while the connection is blocked: the
      # library skips the probe and answers from what the broker already said.)
      #
      # @param connection [AceMQ::AMQP::Connection] the process connection by
      #   default
      # @return [AceMQ::AMQP::Health::Report]
      def self.of(connection = AceMQ::Rails.connection)
        AceMQ::AMQP::Health.of(connection)
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
      # The library has a +Check+ of its own; this one exists because it takes
      # the connection *late*. +AceMQ::AMQP::Health::Check.new("acemq",
      # AceMQ::Rails.connection)+ opens the connection on the line that builds
      # the check, which in an initializer is a broker dialled during boot —
      # exactly what lazy connecting is for.
      #
      # @return [#name, #check]
      def self.check(name = "acemq", connection = nil)
        Check.new(name, connection)
      end

      # @api private
      Check = Struct.new(:name, :connection) do
        def check = Health.of(connection || AceMQ::Rails.connection)
      end
    end
  end
end
