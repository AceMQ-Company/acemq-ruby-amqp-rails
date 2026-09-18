# frozen_string_literal: true

require "bundler"
require "fileutils"
require "open3"
require "net/http"
require "tmpdir"

# Generates, boots and drives a real Rails application.
#
# A Railtie that has never booted inside Rails is not tested. Every other spec
# in this suite exercises a class; this one exercises the framework's own
# initializer ordering, its autoloader, its executor, its rake tasks, and the
# gem's executable — none of which can be proved by calling a method.
#
# The application is generated once per run into a temporary directory, with
# this repository as a path dependency, and thrown away afterwards.
class RailsApplication
  GEM_ROOT = File.expand_path("../..", __dir__)

  attr_reader :root, :broker_url

  def initialize(broker_url)
    @broker_url = broker_url
    @root = File.join(Dir.mktmpdir("acemq-rails-"), "shop")
  end

  # Everything `rails new` can be told not to make. What is left is a router, a
  # controller, ActiveRecord over SQLite and Puma — which is the smallest thing
  # that can still prove the claims on this page, and fast to resolve.
  #
  # --skip-bundle because the install is done below, under this repository's
  # control: `rails new` would run it with whatever BUNDLE_* the parent process
  # has, and the parent process here is a bundle of a different application.
  GENERATE = %w[
    --api --skip-git --skip-keeps --skip-test --skip-system-test --skip-action-mailer
    --skip-action-mailbox --skip-action-text --skip-active-storage --skip-action-cable
    --skip-jbuilder --skip-bootsnap --skip-javascript --skip-hotwire --skip-brakeman
    --skip-rubocop --skip-ci --skip-docker --skip-dev-gems --skip-thruster --skip-solid
    --skip-kamal --skip-bundle
  ].freeze

  # rails new, plus the files that make it an AceMQ application.
  def generate
    run!(File.dirname(@root), "bundle", "exec", "rails", "new", "shop", *GENERATE,
         env: { "BUNDLE_GEMFILE" => File.join(GEM_ROOT, "Gemfile"),
                "BUNDLE_PATH" => File.join(GEM_ROOT, "vendor", "bundle") })

    write_gemfile
    write_configuration
    write_consumer
    write_controller
    bundle!
    self
  end

  # Boots the application in a server and returns once it answers.
  def start_server(port)
    @server = spawn_in_app("bin/rails", "server", "-p", port.to_s, "-b", "127.0.0.1",
                           log: "log/server.log")
    wait_for_http(port, 60) or raise "the Rails server did not answer on #{port}"
    port
  end

  def stop_server
    return unless @server

    terminate(@server)
    @server = nil
  end

  # Starts the consumer process — the gem's own executable, not a rake task.
  def start_consumer(log: "log/consumer.log")
    @consumer = spawn_in_app("bundle", "exec", "acemq-consumer", log: log)
  end

  # Sends TERM and waits, which is what an orchestrator does.
  #
  # @return [Process::Status]
  def stop_consumer(within: 30)
    return nil unless @consumer

    pid = @consumer
    @consumer = nil
    Process.kill("TERM", pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + within
    loop do
      done, status = Process.waitpid2(pid, Process::WNOHANG)
      return status if done
      raise "the consumer did not exit within #{within}s" if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.1
    end
  end

  def get(port, path)
    Net::HTTP.get_response(URI("http://127.0.0.1:#{port}#{path}"))
  end

  # Form-encoded rather than a JSON body, and not because JSON would be less
  # realistic. Rails 8.1's JSON parameter parsing raises `wrong number of
  # arguments (given 2, expected 1)` on the json gem's 3.x line, which is what
  # Ruby 4.0 ships — an incompatibility between two things neither of which is
  # AceMQ. What this spec is about is a controller publishing a message, so it
  # takes the route that does not run through the broken parser.
  def post(port, path, params)
    Net::HTTP.post_form(URI("http://127.0.0.1:#{port}#{path}"), params)
  end

  # `rails runner`, for the things a controller is the wrong place for.
  def runner(code)
    out, status = unbundled do
      Open3.capture2e(clean_env.merge("RAILS_ENV" => "development"),
                      "bin/rails", "runner", code, chdir: @root)
    end
    raise "rails runner failed:\n#{out}" unless status.success?

    out
  end

  def rake(task)
    unbundled do
      Open3.capture2e(clean_env.merge("RAILS_ENV" => "development"),
                      "bin/rails", task, chdir: @root)
    end
  end

  def read(path) = File.read(File.join(@root, path))
  def exist?(path) = File.exist?(File.join(@root, path))
  def log(path) = exist?(path) ? read(path) : ""

  def destroy
    stop_server
    begin
      stop_consumer(within: 10)
    rescue StandardError
      nil
    end
    FileUtils.rm_rf(File.dirname(@root))
  end

  # What the consumer wrote down, one JSON object per message.
  def consumed
    return [] unless exist?("tmp/consumed.log")

    read("tmp/consumed.log").lines.map { |line| JSON.parse(line) }
  end

  def wait_for_consumed(count, within: 30)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + within
    sleep 0.2 until consumed.size >= count ||
                    Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    consumed
  end

  private

  def write_gemfile
    File.open(File.join(@root, "Gemfile"), "a") do |file|
      file.puts <<~RUBY

        # AceMQ. The library comes from AceMQ's own static feed rather than
        # rubygems.org; the integration is this repository, under test.
        source "https://acemq.org/gems" do
          gem "acemq-amqp", "~> 0.6"
        end
        gem "acemq-amqp-rails", path: #{GEM_ROOT.inspect}
        gem "bunny", "~> 2.23"
      RUBY
    end
  end

  def write_configuration
    File.write(File.join(@root, "config", "acemq.yml"), <<~YAML)
      shared:
        client_name: shop
        consumer:
          prefetch: 10
          concurrency: 1
          max_attempts: 3
          initial_delay: 1
          max_delay: 10
        topology:
          exchanges:
            - name: shop-events
              type: topic
          queues:
            - name: shop.orders
              dead_letter: true
          bindings:
            - queue: shop.orders
              exchange: shop-events
              routing_key: order.#

      development:
        url: #{@broker_url}
        shutdown_timeout: 10

      test:
        url: #{@broker_url}

      production:
        url: <%= ENV["ACEMQ_URL"] %>
    YAML
  end

  def write_consumer
    FileUtils.mkdir_p(File.join(@root, "app", "consumers"))
    File.write(File.join(@root, "app", "consumers", "orders_consumer.rb"), <<~RUBY)
      class OrdersConsumer < AceMQ::Rails::Consumer
        queue "shop.orders"
        concurrency 2

        def call(message)
          record = {
            payload: message.payload, type: message.envelope.type,
            origin: message.envelope.origin, attempt: message.attempt,
            # Proof that the Rails executor is around the call. A connection
            # checked out here has to be checked back in, and without the
            # executor wrapping the handler it never is: `with_connection` is
            # also what Rails 8 wants instead of the deprecated `connection`,
            # which a modern application has configured to refuse.
            # A real query rather than `connection.active?`, which the SQLite3
            # adapter answers with nil in Rails 8.1 and which would pass whether
            # or not the executor were doing its job.
            connected: ActiveRecord::Base.with_connection { |c| c.select_value("SELECT 1") },
            thread: Thread.current.object_id.to_s
          }
          # Locked, because `concurrency 2` means two handler threads may be in
          # here at once and a half-written line would make this file unreadable.
          File.open(Rails.root.join("tmp/consumed.log"), "a") do |file|
            file.flock(File::LOCK_EX)
            file.puts(record.to_json)
            file.flush
          end
          accept
        end
      end
    RUBY
  end

  def write_controller
    FileUtils.mkdir_p(File.join(@root, "app", "controllers"))
    File.write(File.join(@root, "app", "controllers", "orders_controller.rb"), <<~RUBY)
      class OrdersController < ApplicationController
        # Publishing from application code, the Rails way: no connection is
        # built here and none is closed. The one the Railtie set up is reached
        # by name.
        def create
          envelope = AceMQ::Rails.publish(
            { "order_id" => params.fetch(:order_id, "A-1") },
            to: "order.placed", exchange: "shop-events", type: "order.placed.v2"
          )
          render json: { id: envelope.id, origin: envelope.origin }
        end

        def health
          report = AceMQ::Rails.health
          render json: report.to_h, status: report.down? ? 503 : 200
        end
      end
    RUBY

    routes = File.join(@root, "config", "routes.rb")
    File.write(routes, File.read(routes).sub("Rails.application.routes.draw do", <<~RUBY.chomp))
      Rails.application.routes.draw do
        post "/orders", to: "orders#create"
        get "/acemq-health", to: "orders#health"
    RUBY
  end

  # The generated application gets a bundle of its own, inside itself.
  #
  # Not the system gem directory: this suite must run without write access to
  # it, which is the normal state of a Homebrew Ruby and of a CI runner, and
  # bundler's failure when it cannot write there is a permissions backtrace that
  # mentions rdoc rather than anything to do with this.
  def bundle!
    run!(@root, "bundle", "config", "set", "--local", "path", "vendor/bundle")
    run!(@root, "bundle", "install")
  end

  def run!(dir, *command, env: {})
    out, status = unbundled { Open3.capture2e(clean_env.merge(env), *command, chdir: dir) }
    raise "#{command.join(" ")} failed:\n#{out}" unless status.success?

    out
  end

  def spawn_in_app(*command, log:)
    FileUtils.mkdir_p(File.join(@root, File.dirname(log)))
    path = File.join(@root, log)
    unbundled do
      Process.spawn(clean_env.merge("RAILS_ENV" => "development"), *command,
                    chdir: @root, out: path, err: [path, "a"], pgroup: true)
    end
  end

  def terminate(pid)
    Process.kill("TERM", pid)
    Process.waitpid(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  # The generated application has a bundle of its own, and nothing of this
  # repository's may leak into it.
  #
  # `with_unbundled_env` is the half that matters and the half that is easy to
  # miss: running under `bundle exec` puts `-rbundler/setup` in RUBYOPT, so a
  # subprocess loads *this* gem's Gemfile before its own first line runs — and
  # the failure is "Could not find gem 'puma'", which mentions neither bundler
  # nor the wrong Gemfile. Unsetting BUNDLE_GEMFILE by hand is not enough,
  # because RUBYOPT, BUNDLER_SETUP, GEM_HOME and half a dozen others carry the
  # same information.
  def unbundled(&) = Bundler.with_unbundled_env(&)

  def clean_env
    { "BUNDLE_GEMFILE" => File.join(@root, "Gemfile"),
      "BUNDLE_PATH" => nil, "BUNDLE_APP_CONFIG" => nil }
  end

  def wait_for_http(port, seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      begin
        Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/acemq-health"))
        return true
      rescue StandardError
        sleep 0.4
      end
    end
    false
  end
end
