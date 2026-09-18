# frozen_string_literal: true

require_relative "lib/acemq/rails/version"

Gem::Specification.new do |spec|
  spec.name = "acemq-amqp-rails"
  spec.version = AceMQ::Rails::VERSION
  spec.authors = ["AceMQ"]

  spec.summary = "Rails integration for AceMQ over AMQP: a Railtie, a shared " \
                 "connection, and consumers that run outside the web server"
  spec.description = "Wires acemq-amqp into a Rails application. One connection for " \
                     "the process, configured from config/acemq.yml and config.acemq.*; " \
                     "consumers written as classes in app/consumers and run by a process " \
                     "of their own rather than inside Puma; a health check that composes " \
                     "into whatever readiness endpoint the application already has."
  spec.homepage = "https://acemq.org"
  spec.license = "Apache-2.0"

  # The library's floor. Nothing here needs more, and raising it would strand a
  # Rails 7.1 application on a Ruby that still gets security fixes.
  spec.required_ruby_version = ">= 3.1"

  spec.metadata = {
    "source_code_uri" => "https://github.com/AceMQ-Company/acemq-ruby-amqp-rails",
    "bug_tracker_uri" => "https://github.com/AceMQ-Company/acemq-ruby-amqp-rails/issues",
    "changelog_uri" => "https://github.com/AceMQ-Company/acemq-ruby-amqp-rails/" \
                       "blob/main/CHANGELOG.md",
    "documentation_uri" => "https://acemq.org/acemq-ruby-amqp-rails/",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb", "lib/**/*.rake", "exe/*", "LICENSE", "README.md",
                   "CHANGELOG.md"]
  spec.require_paths = ["lib"]
  spec.bindir = "exe"
  spec.executables = ["acemq-consumer"]

  # The published gem, from AceMQ's own feed. A Gemfile needs
  #
  #   source "https://acemq.org/gems" do
  #     gem "acemq-amqp-rails"
  #   end
  #
  # because a gemspec cannot name a source for its own dependencies and neither
  # of these is on rubygems.org before 1.0.
  #
  # Pessimistic on the minor rather than the patch: 0.6 is where publish_all and
  # max_outstanding_publishes arrived, both of which this configures, and while
  # the library is 0.x a minor release may change the API this is written
  # against.
  spec.add_dependency "acemq-amqp", "~> 0.6"

  # Railtie, config_for, the executor and the error reporter. 7.1 rather than
  # 7.0 because 7.0 stopped getting security fixes in October 2025, and rather
  # than 7.2 because 7.2 needs Ruby 3.1 as its own floor and this gem's floor is
  # the library's — which leaves 7.1, 7.2 and 8.x all supported on one line of
  # code. Rails 8 needs Ruby 3.2; that is Rails' constraint and not one this gem
  # adds.
  spec.add_dependency "railties", ">= 7.1", "< 9.0"

  # Not a dependency, and the omission is deliberate in both directions:
  #
  # * bunny is what acemq-amqp opens a socket with, and acemq-amqp does not
  #   depend on it either — it requires it lazily and names it when it is
  #   missing, so that reading an AceMQ envelope never drags a broker client
  #   into a process that will never connect. An application using this gem does
  #   open sockets, so its Gemfile needs `gem "bunny"`. Adding it here would
  #   quietly reverse a decision the library made on purpose.
  # * activerecord, activejob and actionpack are not needed. This works in an
  #   application that has none of them.
end
