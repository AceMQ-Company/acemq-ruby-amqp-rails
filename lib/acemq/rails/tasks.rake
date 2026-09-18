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

namespace :acemq do
  desc "Run the AceMQ consumers until interrupted"
  task consume: :environment do
    # Every consumer class has to exist before the registry is read, and in
    # development nothing is loaded until something references it. Eager loading
    # is how a process that has no requests to trigger autoloading finds them.
    Rails.application.eager_load!

    ok = AceMQ::Rails::Runner.new.run
    # A drain that did not finish is a fact the next thing in the pipeline
    # should be able to see. Kubernetes ignores it; a systemd unit with
    # Restart=on-failure does not, and a CI job certainly does.
    exit(ok ? 0 : 75)
  end

  desc "Declare the exchanges, queues and bindings in config.acemq.topology"
  task topology: :environment do
    unless AceMQ::Rails::TopologyBuilder.declared?(AceMQ::Rails.config.topology)
      warn "acemq: nothing declared under config.acemq.topology"
      exit 0
    end

    topology = AceMQ::Rails.topology
    puts topology.plan
    AceMQ::Rails.connection.apply(topology)
    AceMQ::Rails.disconnect!
    puts "acemq: applied"
  end

  desc "Report on the broker: the health check a readiness probe would run"
  task health: :environment do
    report = AceMQ::Rails.health
    puts JSON.pretty_generate(report.to_h)
    AceMQ::Rails.disconnect!
    exit(report.down? ? 1 : 0)
  end

  desc "List the consumers this application would run"
  task consumers: :environment do
    Rails.application.eager_load!
    AceMQ::Rails.consumers.each do |klass|
      puts format("%-40s %-28s concurrency %-3s prefetch %s",
                  klass.name, klass.queue,
                  klass.concurrency || AceMQ::Rails.config.consumer.concurrency,
                  klass.prefetch || AceMQ::Rails.config.consumer.prefetch)
    end
  end
end
