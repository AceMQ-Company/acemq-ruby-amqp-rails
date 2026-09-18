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
    # A handler for one queue, written as a class.
    #
    #   class OrdersConsumer < AceMQ::Rails::Consumer
    #     queue "orders.new"
    #     concurrency 4
    #     retries max_attempts: 5, initial_delay: 1, max_delay: 60
    #
    #     def call(message)
    #       Order.place!(message.payload)
    #       accept
    #     end
    #   end
    #
    # A class rather than a block in an initializer, for three reasons that come
    # from Rails rather than from taste. It can be unit-tested by calling
    # +new.call(message)+ with no broker anywhere. It lives in +app/consumers+,
    # where the autoloader finds it and a reload replaces it. And it has a name,
    # which is what a metric label, a log line and a stack trace want.
    #
    # Subclassing registers it. Nothing runs until the consumer *process* starts
    # it: the registry holds classes, and the code that turns a class into a
    # subscription lives in {Runner}, which the web server never loads.
    class Consumer
      # What {#call} must return. Re-exported so a consumer never has to reach
      # into the library's namespace for the one constant it uses every time.
      Ack = AceMQ::AMQP::Ack

      class << self
        # The queue this consumer reads. Required, and not inherited.
        def queue(name = nil)
          return @queue if name.nil?

          @queue = name.to_s
        end

        # Messages worked on at once by one instance of this consumer.
        #
        # One, unless the application's +consumer.concurrency+ says otherwise.
        # Raising it gives up the order the broker offers messages in — which is
        # the point of raising it, and worth saying out loud because
        # +concurrency 8+ reads like free throughput and is not.
        def concurrency(count = nil)
          return setting(:concurrency) if count.nil?

          @concurrency = Integer(count)
        end

        # Unacknowledged messages this consumer holds at once.
        def prefetch(count = nil)
          return setting(:prefetch) if count.nil?

          @prefetch = Integer(count)
        end

        # The codec for this queue, when it is not the application's.
        def codec(instance = nil)
          return setting(:codec) if instance.nil?

          @codec = AceMQ::AMQP::Codec.check!(instance)
        end

        # The retry ladder for this queue.
        #
        #   retries max_attempts: 5, initial_delay: 1, max_delay: 60
        #   retries AceMQ::AMQP::RetryPolicy.exponential(5, 1, 60)
        #
        # +broker_wait_threshold:+ decides where a wait is spent: shorter than
        # it, in this process holding a prefetch slot and holding up a drain;
        # longer, on a rung queue in the broker, where a restart does not have to
        # survive it. It is a shutdown setting as much as a reliability one — see
        # docs/lifecycle.md.
        def retries(policy = nil, **settings)
          return @retry_policy = policy if policy
          return setting(:retry_policy) if settings.empty?

          @broker_wait_threshold = settings.delete(:broker_wait_threshold) ||
                                   @broker_wait_threshold
          @retry_policy = Configuration::ConsumerDefaults.new.assign(settings).retry_policy
        end

        # Where a retry of this consumer's messages waits. See {retries}.
        def broker_wait_threshold(seconds = nil)
          return setting(:broker_wait_threshold) if seconds.nil?

          @broker_wait_threshold = seconds
        end

        # Arguments passed to +basic.consume+, for a stream's +x-stream-offset+
        # and the like.
        def arguments(table = nil)
          return setting(:arguments) || {} if table.nil?

          @arguments = table
        end

        # The consumer tag, which is what the broker's management interface shows
        # beside the subscription. The class name by default, because
        # +OrdersConsumer+ in a list of subscriptions is worth more than a UUID.
        def tag(value = nil)
          return @tag || name if value.nil?

          @tag = value.to_s
        end

        # Whether this class is one the runner should subscribe.
        #
        # A class with no queue is an abstract intermediate — the
        # +ApplicationConsumer+ holding shared behaviour is the normal Rails
        # shape, and it must not produce a subscription to a queue called nil.
        def runnable? = !queue.nil? && !queue.empty?

        # @api private
        def inherited(subclass)
          super
          Registry.register(subclass)
        end

        private

        # Walks up the superclass chain for a value a parent declared.
        def setting(name)
          klass = self
          while klass.respond_to?(:runnable?)
            value = klass.instance_variable_get(:"@#{name}")
            return value unless value.nil?

            klass = klass.superclass
          end
          nil
        end
      end

      # Handles one message.
      #
      # Must return an {AceMQ::AMQP::Ack}: {#accept}, {#retry_later}, {#reject}
      # or {#park}. Raising is the other way to reject — the retry ladder decides
      # what happens next, and an exception that reaches here is reported to
      # +Rails.error+ before it is settled, so an error tracker sees it.
      #
      # @param message [AceMQ::AMQP::Message]
      # @return [AceMQ::AMQP::Ack]
      def call(message)
        raise NotImplementedError,
              "#{self.class.name} must define #call(message) and return an Ack"
      end

      private

      # Done with it. The broker may forget it.
      def accept = Ack.accept

      # Try again later, on the ladder this consumer declared.
      def retry_later(reason = nil) = Ack.retry(reason)

      # It will never work. Send it to +{queue}.dlq+ with the reason attached.
      def reject(reason = nil) = Ack.reject(reason)

      # It broke the consumer rather than failed in it. +{queue}.parked+, for a
      # person to look at.
      def park(reason = nil) = Ack.park(reason)
    end
  end
end
