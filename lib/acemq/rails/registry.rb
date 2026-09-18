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

module AceMQ
  module Rails
    # Every {Consumer} subclass that has been loaded.
    #
    # Keyed by name rather than held as a set of classes, and that is the whole
    # reason this is not a one-line array. Zeitwerk unloads a constant and loads
    # a *new* class object under the same name on every reload; a set would grow
    # a second +OrdersConsumer+ every time somebody saved the file, and the
    # consumer process would subscribe to the same queue four times after an
    # afternoon's work. Keyed by name, a reload replaces.
    #
    # An anonymous class — one made in a spec with +Class.new(Consumer)+ — has no
    # name to key on and is kept under its object id instead, so tests do not
    # collide with each other and do not need to know this exists.
    module Registry
      LOCK = Mutex.new
      private_constant :LOCK

      @classes = {}

      class << self
        # @api private
        def register(klass)
          LOCK.synchronize { @classes[key_for(klass)] = klass }
          klass
        end

        # Every registered class, in the order it was first registered.
        #
        # @return [Array<Class>]
        def classes
          LOCK.synchronize { @classes.values.dup }
        end

        # The ones the runner will actually subscribe: those with a queue.
        #
        # @return [Array<Class>]
        def runnable
          classes.select { |klass| klass.respond_to?(:runnable?) && klass.runnable? }
        end

        # @return [Array<String>] every queue that will be subscribed
        def queues = runnable.map(&:queue)

        # Forgets everything. For specs, and for a reload that wants to start
        # from nothing rather than trust the keying above.
        def clear
          LOCK.synchronize { @classes = {} }
          nil
        end

        private

        # An anonymous class has no name until it is assigned to a constant, and
        # a spec's +Class.new(Consumer)+ is registered before that happens. Its
        # object id is unique and that is all this needs.
        def key_for(klass)
          name = klass.name
          name.nil? || name.empty? ? "##{klass.object_id}" : name
        end
      end
    end
  end
end
