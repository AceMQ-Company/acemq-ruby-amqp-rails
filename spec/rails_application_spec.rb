# frozen_string_literal: true

require "json"

# A real Rails application, generated, booted, published from, consumed in, and
# shut down.
#
# This is the spec the rest of the suite cannot replace. Everything else here
# calls a method on a class; this one is the only place the framework's own
# initializer ordering, its autoloader, its executor, the rake tasks and the
# gem's executable are exercised at all. A Railtie that has never booted inside
# Rails is not tested.
#
# Slow on purpose, and tagged with the broker for that reason: it generates an
# application, resolves its bundle, boots a server and runs a second process.
RSpec.describe "a real Rails application", :integration, :slow do
  PORT = 39_723

  before(:context) do
    @app = RailsApplication.new(BROKER_URL).generate
    @app.start_server(PORT)
  end

  after(:context) do
    @app&.destroy
  end

  it "boots with the Railtie loaded and the configuration read from config/acemq.yml" do
    settings = JSON.parse(@app.runner(<<~RUBY))
      puts({ url: AceMQ::Rails.config.url,
             client_name: AceMQ::Rails.config.client_name,
             prefetch: AceMQ::Rails.config.consumer.prefetch,
             attempts: AceMQ::Rails.config.consumer.retry_policy.max_attempts,
             shutdown: AceMQ::Rails.config.shutdown_timeout,
             queues: AceMQ::Rails.topology.queues.map(&:name) }.to_json)
    RUBY

    # `shared:` and the per-environment section, both, which is what config_for
    # gives and what a hand-rolled YAML read would have had to reimplement.
    expect(settings["client_name"]).to eq("shop")
    expect(settings["url"]).to eq(BROKER_URL)
    expect(settings["shutdown"]).to eq(10)
    expect(settings["prefetch"]).to eq(10)
    expect(settings["attempts"]).to eq(3)
    expect(settings["queues"]).to include("shop.orders", "shop.orders.dlq")
  end

  it "lets an environment file override the file, because code beats data" do
    @app.runner(<<~RUBY)
      raise "expected the file's value" unless AceMQ::Rails.config.client_name == "shop"
    RUBY

    File.write(File.join(@app.root, "config", "environments", "development.rb"),
               File.read(File.join(@app.root, "config", "environments", "development.rb"))
                   .sub("Rails.application.configure do",
                        "Rails.application.configure do\n  " \
                        "config.acemq.client_name = \"shop-web\""))

    expect(@app.runner("puts AceMQ::Rails.config.client_name")).to include("shop-web")
  ensure
    File.write(File.join(@app.root, "config", "environments", "development.rb"),
               File.read(File.join(@app.root, "config", "environments", "development.rb"))
                   .sub("  config.acemq.client_name = \"shop-web\"\n", ""))
  end

  it "does not open a connection while the web server boots" do
    # The default, and a decision: a broker that is down should not stop an
    # application from serving the pages that never touch it.
    expect(@app.runner("puts AceMQ::Rails.connected?")).to include("false")
  end

  it "starts no consumers in the web process" do
    # The design point, enforced rather than recommended. Nothing in the Railtie
    # subscribes to anything, so a consumer cannot end up inside Puma by
    # accident.
    running = @app.runner("puts AceMQ::Rails.connection.consumers.size")

    expect(running.lines.map(&:strip)).to include("0")
  end

  it "declares the topology from a rake task" do
    out, status = @app.rake("acemq:topology")

    expect(status).to be_success
    expect(out).to include("shop.orders")
  end

  it "publishes from a controller, inside Puma" do
    response = @app.post(PORT, "/orders", "order_id" => "A-7")

    expect(response.code).to eq("200")
    body = JSON.parse(response.body)
    expect(body["id"]).to match(/\A[0-9a-f-]{36}\z/)
    expect(body["origin"]).to eq("shop")
  end

  it "answers a health endpoint the application composed itself" do
    response = @app.get(PORT, "/acemq-health")

    expect(response.code).to eq("200")
    report = JSON.parse(response.body)
    expect(report["status"]).to eq("up")
    expect(report["parts"]).to have_key("round_trip_ms")
  end

  describe "the consumer process" do
    before(:context) do
      @app.start_consumer
      # It has to eager-load the application and apply the topology before it
      # can read anything, which on a cold bundle takes a moment.
      sleep 6
    end

    it "consumes what the controller published, in a process of its own" do
      3.times { |i| @app.post(PORT, "/orders", "order_id" => "B-#{i}") }

      # Four: the three above and the A-7 published by the controller spec, which
      # was sitting on the queue before this process started and is consumed on
      # the way past. That it arrives at all is worth having in the count — a
      # queue holds messages published before anything was reading.
      consumed = @app.wait_for_consumed(4, within: 30)

      expect(consumed.map { |it| it["payload"]["order_id"] })
        .to include("A-7", "B-0", "B-1", "B-2")
      expect(consumed.first["type"]).to eq("order.placed.v2")
      expect(consumed.first["origin"]).to eq("shop")
      expect(consumed.first["attempt"]).to eq(1)
    end

    it "runs the handler inside the Rails executor, so ActiveRecord is usable" do
      # Without the executor the consumer checks a connection out of the pool on
      # first use and never checks it back in; a pool of five is exhausted after
      # five messages and the sixth waits for ever. This asserts the cheap half
      # — that a connection is reachable at all — and the message count above
      # asserts the expensive half, because six messages through a pool of five
      # is what an unwrapped handler cannot do.
      expect(@app.consumed).to all(include("connected" => 1))
    end

    it "logs the consumer it started and the queue it reads" do
      expect(@app.log("log/consumer.log")).to include("OrdersConsumer", "shop.orders")
    end

    it "drains on SIGTERM and exits cleanly" do
      status = @app.stop_consumer(within: 30)

      expect(status.exitstatus).to eq(0)
      expect(@app.log("log/consumer.log")).to match(/drained in \d/)
    end
  end
end
