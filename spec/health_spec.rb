# frozen_string_literal: true

RSpec.describe AceMQ::Rails::Health do
  def connection_on(transport)
    AceMQ::AMQP::Connection.new(transport: transport)
  end

  it "is up when the broker answers" do
    report = described_class.of(connection_on(FakeTransport.new))

    expect(report).to be_up
  end

  it "is down when the connection has been closed" do
    transport = FakeTransport.new
    transport.close

    expect(described_class.of(connection_on(transport))).to be_down
  end

  context "when the broker has blocked the connection" do
    let(:connection) { connection_on(FakeTransport.new(blocked: true)) }

    it "stays up" do
      # The rule this gem exists to add. RabbitMQ blocks a connection when it is
      # low on memory or disk; publishing stops, and the temptation is to fail
      # the probe. Failing it is exactly wrong: restarting a producer into the
      # same pressured broker helps nobody, and doing it to every replica at
      # once turns a broker under memory pressure into an outage with a
      # crash-loop on top.
      expect(described_class.of(connection)).to be_up
    end

    it "says why, in wording an alert rule can match on" do
      expect(described_class.of(connection).detail).to include(described_class::BLOCKED)
    end

    it "puts it in the parts, where a dashboard reads it" do
      expect(described_class.of(connection).to_h["parts"]["blocked"]).to be(true)
    end

    it "does not overwrite a detail the library already had" do
      transport = FakeTransport.new(blocked: true)
      connection = connection_on(transport)
      connection.consume("orders.new") { AceMQ::AMQP::Ack.accept }
      # A stopped consumer is degraded; being blocked as well must not hide it.
      connection.consumers.first.cancel

      report = described_class.of(connection)
      expect(report).to be_degraded
      expect(report.detail).to include("consumers", described_class::BLOCKED)
    end
  end

  it "says nothing about blocking when the transport cannot be asked" do
    # A hand-written double has no bunny session, and a health check that raised
    # inside a readiness probe would tell an orchestrator nothing at all.
    transport = Class.new(FakeTransport) { undef_method :session }.new

    expect(described_class.of(connection_on(transport)).to_h["parts"])
      .not_to have_key("blocked")
  end

  describe ".check" do
    it "composes into the library's aggregate, so an app keeps one endpoint" do
      AceMQ::Rails.connection = connection_on(FakeTransport.new)
      always_down = Struct.new(:name) do
        def check
          AceMQ::AMQP::Health::Report.new(status: AceMQ::AMQP::Health::DOWN,
                                          detail: "the database", checked_at: Time.now,
                                          parts: {})
        end
      end

      report = AceMQ::AMQP::Health.aggregate(described_class.check, always_down.new("db"))

      expect(report).to be_down
      expect(report.parts.keys).to contain_exactly("acemq", "db")
      expect(report.parts["acemq"]).to be_up
    end
  end
end
