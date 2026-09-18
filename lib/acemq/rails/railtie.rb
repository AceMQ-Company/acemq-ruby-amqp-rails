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

require "rails/railtie"

module AceMQ
  module Rails
    # Wires AceMQ into a Rails application.
    #
    # A Railtie rather than an Engine, because this contributes no routes, no
    # views, no models and no migrations. An Engine would add a mount point
    # nobody mounts and an +app/+ tree nobody fills.
    #
    # It does four things, in this order:
    #
    # 1. Reads +config/acemq.yml+ through Rails' own +config_for+, and puts what
    #    it finds under +config.acemq+ so that an environment file can override
    #    any of it.
    # 2. Builds {Configuration} from the result, once, after every initializer
    #    has had its say.
    # 3. Adds +app/consumers+ to the autoload paths.
    # 4. Registers the rake tasks and an +at_exit+ that closes the connection.
    #
    # It starts no consumers. That is the whole design and it is enforced here
    # rather than merely recommended: nothing in this file subscribes to
    # anything, so a consumer cannot accidentally end up inside Puma.
    class Railtie < ::Rails::Railtie
      config.acemq = ::ActiveSupport::OrderedOptions.new

      # The YAML is read before any initializer runs, so what an initializer or
      # an environment file sets is applied over it rather than under it. A file
      # checked in for every environment is the general statement; a line in
      # +config/environments/test.rb+ is the specific one.
      #
      # +config_for+ gives per-environment sections, a +shared:+ block and ERB
      # for free, and reports a missing file as a missing file rather than as
      # nil. Written this way so an application without the file works: the
      # configuration has usable defaults and a URL is the only thing most
      # people set.
      # +before: :set_autoload_paths+ rather than merely early, because the
      # initializer below needs what this reads and that one cannot run any
      # later than it does.
      initializer "acemq.config_for", before: :set_autoload_paths do |app|
        next unless app.root.join("config", "acemq.yml").exist?

        app.config_for(:acemq).each do |key, value|
          # Only what the file said, and only where nothing has spoken already.
          # Assigning the whole hash would overwrite what an earlier Railtie or
          # a generated initializer had set.
          app.config.acemq[key] = value unless app.config.acemq.key?(key)
        end
      end

      # Consumers in a directory of the application's own choosing.
      #
      # +app/consumers+ needs nothing: Rails autoloads every direct subdirectory
      # of +app/+ already, so a consumer put there is found without this. What
      # this is for is +config.acemq.consumer_paths = ["lib/consumers"]+ and the
      # like.
      #
      # **+before: :set_autoload_paths+ is load-bearing.** That initializer is
      # in Rails' bootstrap and it freezes +config.autoload_paths+ on the way
      # out; an initializer without the +before:+ runs afterwards and raises
      # +FrozenError: can't modify frozen Array+ during boot. It is the kind of
      # thing only a real application catches, which is why one is generated and
      # booted in the specs.
      initializer "acemq.autoload_paths", before: :set_autoload_paths do |app|
        Array(app.config.acemq.consumer_paths).each do |path|
          directory = app.root.join(path)
          app.config.autoload_paths << directory.to_s if directory.exist?
        end
      end

      # After every initializer, so an initializer that builds a codec or an
      # interceptor has already run.
      config.after_initialize do |app|
        AceMQ::Rails.config = Configuration.new.assign(app.config.acemq.to_h)
        AceMQ::Rails.logger = ::Rails.logger

        if AceMQ::Rails.config.connect_on_boot
          # Deliberately not rescued. An application that asked to connect on
          # boot asked to fail fast, and swallowing the failure here would give
          # it the lazy behaviour it turned off.
          AceMQ::Rails.connection
        end
      end

      # A web process that published something holds a socket and a heartbeat
      # thread. Closing it on the way out is what makes a `docker stop` of the
      # web container quiet rather than a broker log full of abrupt
      # disconnections — and, in a process that had consumers, it is the drain.
      #
      # The consumer process never reaches this: its runner has already drained
      # and disconnected, and {AceMQ::Rails.disconnect!} does nothing twice.
      config.after_initialize do
        at_exit { AceMQ::Rails.disconnect! }
      end

      rake_tasks do
        load File.expand_path("tasks.rake", __dir__)
      end

      # +rails runner+ and the console both want the connection to go away
      # cleanly, and both of them are also the two places somebody will publish
      # one message by hand. Nothing to do beyond the at_exit above; this is
      # here as the place the next person will look.
      console do
        AceMQ::Rails.logger = ::Rails.logger
      end
    end
  end
end
