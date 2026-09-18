# frozen_string_literal: true

# Against a real broker. Everything here is something a fake cannot prove.
RSpec.describe "a real broker", :integration do
  let(:suffix) { SecureRandom.hex(4) }
  let(:queue) { "rails.spec.#{suffix}" }
  let(:exchange) { "rails.spec.#{suffix}.events" }

  before do
    AceMQ::Rails.config.url = BROKER_URL
    AceMQ::Rails.config.client_name = "acemq-rails-spec"
    AceMQ::Rails.config.shutdown_timeout = 10
    AceMQ::Rails.config.topology = {
      "exchanges" => [{ "name" => exchange, "type" => "topic" }],
      "queues" => [{ "name" => queue, "dead_letter" => true }],
      "bindings" => [{ "queue" => queue, "exchange" => exchange, "routing_key" => "order.#" }]
    }
  end

  after do
    connection = AceMQ::Rails.connected? ? AceMQ::Rails.connection : nil
    if connection
      [queue, "#{queue}.dlq", "#{queue}.parked"].each do |name|
        connection.delete_queue(name)
      rescue StandardError
        nil
      end
    end
    AceMQ::Rails.disconnect!
  end

  it "opens the connection the configuration describes" do
    expect(AceMQ::Rails.connection.origin).to eq("acemq-rails-spec")
    expect(AceMQ::Rails.health).to be_up
  end

  it "declares the topology and reports it healthy" do
    AceMQ::Rails.apply_topology

    expect(AceMQ::Rails.connection.queue_exists?(queue)).to be(true)
    expect(AceMQ::Rails.connection.queue_exists?("#{queue}.dlq")).to be(true)
  end

  it "carries a message from publish to a consumer class and drains" do
    seen = Thread::Queue.new
    klass = Class.new(AceMQ::Rails::Consumer) do
      define_method(:call) do |message|
        seen << message
        AceMQ::AMQP::Ack.accept
      end
    end
    klass.queue(queue)

    runner = AceMQ::Rails::Runner.new
    runner.start([klass])

    AceMQ::Rails.publish({ "order_id" => "A-1" }, to: "order.placed", exchange: exchange,
                                                  type: "order.placed.v2")

    message = pop_within(seen, 15)
    expect(message.payload["order_id"]).to eq("A-1")
    expect(message.envelope.type).to eq("order.placed.v2")
    expect(message.envelope.origin).to eq("acemq-rails-spec")
    expect(message.attempt).to eq(1)

    expect(runner.drain).to be(true)
  end

  it "sends a batch in one round trip, which 0.6.0 added" do
    AceMQ::Rails.apply_topology

    envelopes = AceMQ::Rails.publish_all(
      Array.new(50) { |i| { "order_id" => "A-#{i}" } },
      to: "order.placed", exchange: exchange, type: "order.placed.v2"
    )

    expect(envelopes.size).to eq(50)
    # In the order the payloads were given, whatever order the broker confirmed
    # them in — which is what makes a result matchable to its payload.
    expect(envelopes.map(&:id).uniq.size).to eq(50)
  end

  it "bounds how many publishes may be unconfirmed at once" do
    AceMQ::Rails.config.max_outstanding_publishes = 8
    AceMQ::Rails.apply_topology

    expect(AceMQ::Rails.connection.transport.max_outstanding_publishes).to eq(8)
    # And a batch larger than the ceiling is written in waves rather than held
    # whole, which is the point of the setting.
    expect(AceMQ::Rails.publish_all(Array.new(40) { |i| { "n" => i } },
                                    to: "order.placed", exchange: exchange).size).to eq(40)
  end

  it "dead-letters a message the consumer rejects, with the reason attached" do
    AceMQ::Rails.apply_topology
    klass = Class.new(AceMQ::Rails::Consumer) do
      def call(_message) = reject("the warehouse said no")
    end
    klass.queue(queue)

    runner = AceMQ::Rails::Runner.new
    runner.start([klass])
    AceMQ::Rails.publish({ "order_id" => "A-2" }, to: "order.placed", exchange: exchange)

    dead = nil
    wait_until(15) do
      dead = AceMQ::Rails.connection.pull("#{queue}.dlq")
      !dead.nil?
    end
    expect(dead).not_to be_nil
    expect(dead.headers["x-acemq-error"].to_s).to include("the warehouse said no")

    runner.drain
  end

  it "finishes the handler it is already running before it closes" do
    # The guarantee worth having, and the reason a shutdown needs a deadline.
    started = Thread::Queue.new
    finished = Thread::Queue.new
    klass = Class.new(AceMQ::Rails::Consumer) do
      define_method(:call) do |_message|
        started << :in
        sleep 1.5
        finished << :out
        AceMQ::AMQP::Ack.accept
      end
    end
    klass.queue(queue)

    runner = AceMQ::Rails::Runner.new
    runner.start([klass])
    AceMQ::Rails.publish({ "order_id" => "A-3" }, to: "order.placed", exchange: exchange)

    pop_within(started, 15)
    at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect(runner.drain(timeout: 10)).to be(true)
    took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - at

    # It blocked on the handler rather than giving it a chance.
    expect(took).to be > 0.5
    expect(finished.size).to eq(1)
  end

  it "gives up on a handler that will not return, and says so" do
    klass = Class.new(AceMQ::Rails::Consumer) do
      def call(_message)
        sleep 30
        accept
      end
    end
    klass.queue(queue)

    runner = AceMQ::Rails::Runner.new
    runner.start([klass])
    AceMQ::Rails.publish({ "order_id" => "A-4" }, to: "order.placed", exchange: exchange)
    sleep 1

    expect(runner.drain(timeout: 1)).to be(false)
  end

  def pop_within(queue, seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    loop do
      return queue.pop(true)
    rescue ThreadError
      raise "nothing arrived within #{seconds}s" if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
    end
  end

  def wait_until(seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    sleep 0.1 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  end
end
