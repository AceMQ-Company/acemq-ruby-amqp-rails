# frozen_string_literal: true

RSpec.describe AceMQ::Rails::Runner do
  let(:connection) { RecordingConnection.new }
  let(:runner) { described_class.new(connection: connection) }
  let(:message) do
    AceMQ::AMQP::Message.new(payload: { "order_id" => "A-1" },
                             envelope: AceMQ::AMQP::Envelope.new)
  end

  def consumer_class(queue_name, &body)
    Class.new(AceMQ::Rails::Consumer) do
      queue queue_name
      define_method(:call) { |_message| AceMQ::AMQP::Ack.accept }
      class_eval(&body) if body
    end
  end

  describe "#start" do
    it "subscribes every runnable consumer and nothing else" do
      consumer_class("orders.new")
      consumer_class("orders.cancelled")
      Class.new(AceMQ::Rails::Consumer) # the ApplicationConsumer shape

      runner.start

      expect(connection.consumes.map(&:queue))
        .to contain_exactly("orders.new", "orders.cancelled")
    end

    it "passes each consumer's own settings through" do
      consumer_class("orders.new") do
        concurrency 4
        prefetch 50
        arguments("x-stream-offset" => "next")
        retries max_attempts: 5, initial_delay: 1, broker_wait_threshold: 15
      end

      runner.start

      options = connection.options_for("orders.new")
      expect(options[:concurrency]).to eq(4)
      expect(options[:prefetch]).to eq(50)
      expect(options[:arguments]).to eq("x-stream-offset" => "next")
      expect(options[:retry_policy].max_attempts).to eq(5)
      expect(options[:retry_threshold]).to eq(15)
    end

    it "names the subscription after the class, so a broker's list reads" do
      stub_const("OrdersConsumer", consumer_class("orders.new"))

      runner.start

      expect(connection.options_for("orders.new")[:tag]).to eq("OrdersConsumer")
    end

    it "falls back to the application's concurrency" do
      AceMQ::Rails.config.consumer.concurrency = 3
      consumer_class("orders.new")

      runner.start

      expect(connection.options_for("orders.new")[:concurrency]).to eq(3)
    end

    it "leaves an unset option out rather than passing nil" do
      # The library has its own defaults and they are its business. Passing nil
      # would freeze whatever they were on the day this was written.
      consumer_class("orders.new")

      runner.start

      expect(connection.options_for("orders.new")).not_to have_key(:prefetch)
      expect(connection.options_for("orders.new")).not_to have_key(:codec)
    end

    it "applies the topology first, so a consumer never waits on a missing queue" do
      AceMQ::Rails.config.topology = {
        "exchanges" => [{ "name" => "orders-events", "type" => "topic" }],
        "queues" => [{ "name" => "orders.new" }]
      }
      consumer_class("orders.new")

      runner.start

      expect(connection.applied.first.queues.map(&:name)).to include("orders.new")
    end

    it "declares nothing when nothing was declared" do
      consumer_class("orders.new")

      runner.start

      expect(connection.applied).to be_empty
    end

    it "leaves the topology alone when asked to" do
      AceMQ::Rails.config.declare_topology_on_boot = false
      AceMQ::Rails.config.topology = { "queues" => [{ "name" => "orders.new" }] }
      consumer_class("orders.new")

      runner.start

      expect(connection.applied).to be_empty
    end

    it "refuses to start with nothing to run, and says where to look" do
      expect { runner.start }
        .to raise_error(AceMQ::AMQP::ConfigurationError, /no consumers to run/)
    end

    it "warns when the development autoloader is still on" do
      # The failure it warns about is two handler threads deadlocked on the load
      # interlock, which looks like a consumer that is running and reading
      # nothing. Nothing raises, so the warning is the only signal there is.
      lines = []
      logger = Class.new do
        def initialize(lines) = (@lines = lines)
        def info(line) = @lines << line
        def warn(line) = @lines << line
      end
      # Only the three things the check reaches for: Rails.application, its
      # config, and config.enable_reloading.
      reloading = Struct.new(:config) do
        def application = self
      end
      stub_const("Rails", reloading.new(Struct.new(:enable_reloading).new(true)))

      consumer_class("orders.new")
      described_class.new(connection: connection, logger: logger.new(lines)).start

      expect(lines.join("\n")).to include("development autoloader", "acemq-consumer")
    end
  end

  describe "the handler wrapper" do
    it "calls one instance of the class per subscription" do
      # One instance, not one per message: a consumer that memoises something
      # expensive on the way up should get to keep it.
      seen = []
      klass = Class.new(AceMQ::Rails::Consumer) do
        queue "orders.new"
        define_method(:call) do |_message|
          seen << object_id
          AceMQ::AMQP::Ack.accept
        end
      end
      runner.start([klass])

      2.times { connection.deliver("orders.new", message) }

      expect(seen.uniq.size).to eq(1)
    end

    it "hands the message straight to #call and returns its Ack" do
      klass = Class.new(AceMQ::Rails::Consumer) do
        queue "orders.new"
        def call(message) = message.payload["order_id"] == "A-1" ? accept : reject
      end
      runner.start([klass])

      expect(connection.deliver("orders.new", message)).to be_accept
    end

    it "lets an exception out, so the retry ladder still decides" do
      # ActiveSupport::ErrorReporter#handle would report and *swallow*, which
      # would leave the handler returning nil instead of an Ack and a failed
      # message settled as though it had worked. #record is what this uses, and
      # #record re-raises.
      klass = Class.new(AceMQ::Rails::Consumer) do
        queue "orders.new"
        def call(_message) = raise("the warehouse said no")
      end
      runner.start([klass])

      expect { connection.deliver("orders.new", message) }
        .to raise_error(RuntimeError, "the warehouse said no")
    end

    it "wraps the call in the executor and the reporter when Rails is there" do
      executor = Class.new do
        def self.calls = @calls ||= 0
        def self.wrap = (@calls = calls + 1) && yield
      end
      reporter = Class.new do
        def self.contexts = @contexts ||= []

        def self.record(_klass = StandardError, **options)
          contexts << options[:context]
          yield
        end
      end
      runner.instance_variable_set(:@executor, executor)
      runner.instance_variable_set(:@reporter, reporter)

      stub_const("OrdersConsumer", consumer_class("orders.new"))
      runner.start([OrdersConsumer])
      connection.deliver("orders.new", message)

      expect(executor.calls).to eq(1)
      expect(reporter.contexts.first)
        .to include(consumer: "OrdersConsumer", queue: "orders.new",
                    message_id: message.envelope.id)
    end
  end

  describe "#drain" do
    it "cancels every consumer and closes the connection" do
      consumer_class("orders.new")
      consumer_class("orders.cancelled")
      runner.start
      AceMQ::Rails.connection = connection

      expect(runner.drain).to be(true)
      expect(runner.consumers.map(&:running?)).to all(be(false))
      expect(connection).to be_closed
    end

    it "spends one deadline on the whole drain, not one on each consumer" do
      # The arithmetic is the library's since acemq-amqp 0.7.0 — this asserts
      # that shutdown_timeout is what reaches it, because a drain given a fresh
      # deadline per consumer is not a bound on anything: eight consumers each
      # given thirty seconds is four minutes, and four minutes into a shutdown
      # Kubernetes has long since sent SIGKILL.
      consumer_class("orders.new")
      consumer_class("orders.cancelled")
      runner.start
      AceMQ::Rails.connection = connection

      runner.drain(timeout: 7)

      expect(connection.drain_timeouts).to eq([7])
    end

    it "reports a drain that ran out of time rather than pretending" do
      # DrainTimeout out of the library, a boolean out of here: acemq-consumer
      # turns it into exit 75, and a backtrace out of a signal handler is not an
      # exit status.
      consumer_class("orders.new")
      runner.start
      AceMQ::Rails.connection = connection
      connection.for("orders.new").consumer.in_flight = 2

      expect(runner.drain(timeout: 0.2)).to be(false)
    end

    it "names the queue and the count when it gives up, so a grace period can be fixed" do
      lines = []
      logger = Class.new do
        def initialize(lines) = (@lines = lines)
        def info(line) = @lines << line
        def warn(line) = @lines << line
      end
      consumer_class("orders.new")
      runner = described_class.new(connection: connection, logger: logger.new(lines))
      runner.start
      AceMQ::Rails.connection = connection
      connection.for("orders.new").consumer.in_flight = 2

      runner.drain(timeout: 0.2)

      expect(lines.join("\n")).to include("orders.new (2)", "redelivered")
    end

    it "is safe when nothing was ever started" do
      expect(runner.drain).to be(true)
    end
  end

  describe "#run" do
    it "comes back when it is told to stop, and drains on the way" do
      consumer_class("orders.new")
      Thread.new do
        sleep 0.05
        runner.stop
      end

      expect(runner.run).to be(true)
      expect(runner.consumers.map(&:running?)).to all(be(false))
    end
  end
end
