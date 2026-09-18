# frozen_string_literal: true

RSpec.describe AceMQ::Rails::TopologyBuilder do
  # The shape a YAML file actually produces: string keys throughout.
  let(:settings) do
    {
      "exchanges" => [{ "name" => "orders-events", "type" => "topic" }],
      "queues" => [{ "name" => "orders.new", "dead_letter" => true }],
      "bindings" => [{ "queue" => "orders.new", "exchange" => "orders-events",
                       "routing_key" => "order.#" }]
    }
  end

  it "builds a topology that validates" do
    topology = described_class.build(settings)

    expect(topology.problems).to be_empty
  end

  it "declares the exchange with the kind it was given" do
    topology = described_class.build(settings)

    expect(topology.exchanges.map(&:name)).to include("orders-events")
  end

  it "wires up the dead-letter queue and its exchange" do
    topology = described_class.build(settings)

    expect(topology.queues.map(&:name)).to include("orders.new", "orders.new.dlq")
  end

  it "declares the retry rungs a ladder needs" do
    # A consumer that cannot find its rung falls back to waiting in this
    # process: slower, holds a prefetch slot, and makes the next deployment's
    # drain sit through the wait. The library counts acemq.retry.rung.missing
    # every time; declaring them here is how that counter stays at nought.
    settings["queues"].first["retries"] = { "max_attempts" => 5, "initial_delay" => 60,
                                            "max_delay" => 300 }

    topology = described_class.build(settings)

    expect(topology.queues.map(&:name).grep(/retry/)).not_to be_empty
  end

  it "takes symbol keys too, because config_for gives them" do
    topology = described_class.build(
      queues: [{ name: "orders.new" }],
      exchanges: [{ name: "orders-events", type: :topic }]
    )

    expect(topology.queues.map(&:name)).to eq(["orders.new"])
  end

  it "takes the dashed spelling" do
    topology = described_class.build(
      "queues" => [{ "name" => "orders.new", "dead-letter" => true }]
    )

    expect(topology.queues.map(&:name)).to include("orders.new.dlq")
  end

  it "declares a stream when asked for one" do
    topology = described_class.build("queues" => [{ "name" => "events", "type" => "stream" }])

    expect(topology.to_s).to include("stream")
  end

  it "says which entry is missing a name" do
    expect { described_class.build("queues" => [{ "durable" => true }]) }
      .to raise_error(AceMQ::AMQP::TopologyError, /topology\.queues needs a name/)
  end

  it "says which binding is incomplete" do
    expect { described_class.build("bindings" => [{ "queue" => "orders.new" }]) }
      .to raise_error(AceMQ::AMQP::TopologyError, /topology\.bindings needs a exchange/)
  end

  describe ".declared?" do
    it "is false for nothing at all, so an empty section applies nothing" do
      expect(described_class.declared?(nil)).to be(false)
      expect(described_class.declared?({})).to be(false)
      expect(described_class.declared?("queues" => [])).to be(false)
    end

    it "is true as soon as anything is declared" do
      expect(described_class.declared?(settings)).to be(true)
    end
  end
end
