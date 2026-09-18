# frozen_string_literal: true

RSpec.describe AceMQ::Rails::Consumer do
  describe "the class-level declaration" do
    it "records the queue" do
      klass = Class.new(described_class) { queue "orders.new" }

      expect(klass.queue).to eq("orders.new")
    end

    it "is not runnable without one" do
      # The ApplicationConsumer shape: a base class holding shared behaviour
      # must not produce a subscription to a queue called nil.
      expect(Class.new(described_class)).not_to be_runnable
    end

    it "defaults the tag to the class name, so a broker's subscription list reads" do
      stub_const("OrdersConsumer", Class.new(described_class) { queue "orders.new" })

      expect(OrdersConsumer.tag).to eq("OrdersConsumer")
    end

    it "takes a tag when one is given" do
      klass = Class.new(described_class) { tag "orders-reader" }

      expect(klass.tag).to eq("orders-reader")
    end

    it "builds a retry policy from the settings" do
      klass = Class.new(described_class) do
        retries max_attempts: 5, initial_delay: 1, max_delay: 60
      end

      expect(klass.retries.max_attempts).to eq(5)
      expect(klass.retries.max_delay).to eq(60.0)
    end

    it "takes a RetryPolicy object instead" do
      policy = AceMQ::AMQP::RetryPolicy.exponential(3, 2, 20)
      klass = Class.new(described_class) { retries policy }

      expect(klass.retries).to be(policy)
    end

    it "takes broker_wait_threshold out of the retries settings" do
      klass = Class.new(described_class) do
        retries max_attempts: 5, initial_delay: 1, broker_wait_threshold: 10
      end

      expect(klass.broker_wait_threshold).to eq(10)
      expect(klass.retries.max_attempts).to eq(5)
    end
  end

  describe "inheritance" do
    it "inherits settings a parent declared" do
      parent = Class.new(described_class) do
        prefetch 50
        concurrency 4
      end
      child = Class.new(parent) { queue "orders.new" }

      expect(child.prefetch).to eq(50)
      expect(child.concurrency).to eq(4)
    end

    it "lets a child override one of them" do
      parent = Class.new(described_class) { prefetch 50 }
      child = Class.new(parent) do
        queue "orders.new"
        prefetch 1
      end

      expect(child.prefetch).to eq(1)
      expect(parent.prefetch).to eq(50)
    end

    it "does not inherit the queue" do
      # Two consumers sharing an inherited queue name is a competing-consumers
      # setup written by accident, and it would be silent.
      parent = Class.new(described_class) { queue "orders.new" }
      child = Class.new(parent)

      expect(child.queue).to be_nil
      expect(child).not_to be_runnable
    end
  end

  describe "#call" do
    it "says what a subclass forgot" do
      klass = Class.new(described_class) { queue "orders.new" }

      expect { klass.new.call(nil) }
        .to raise_error(NotImplementedError, /must define #call\(message\)/)
    end

    it "can be called with a message and no broker in the room" do
      klass = Class.new(described_class) do
        queue "orders.new"
        def call(message) = message.payload["ok"] ? accept : reject("no")
      end

      message = AceMQ::AMQP::Message.new(payload: { "ok" => true },
                                         envelope: AceMQ::AMQP::Envelope.new)
      expect(klass.new.call(message)).to be_accept
    end

    it "offers the four settlements without reaching into the library" do
      klass = Class.new(described_class) do
        queue "q"
        def settlements = [accept, retry_later("a"), reject("b"), park("c")]
      end

      accept, retried, rejected, parked = klass.new.settlements
      expect(accept).to be_accept
      expect(retried).to be_retry
      expect(rejected).to be_reject
      expect(parked).to be_park
    end
  end
end
