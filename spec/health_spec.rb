# frozen_string_literal: true

RSpec.describe AceMQ::Rails::Health do
  # The wording an alert rule matches on. The library's since 0.7.0; this gem
  # had a constant of its own with the identical string until then, and naming
  # the library's here is what stops the two drifting apart unnoticed.
  def blocked = AceMQ::AMQP::Health::BLOCKED

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
    let(:connection) { connection_on(FakeTransport.new(blocked_reason: "low on memory")) }

    it "stays up" do
      # RabbitMQ blocks a connection when it is low on memory or disk;
      # publishing stops, and the temptation is to fail the probe. Failing it is
      # exactly wrong: restarting a producer into the same pressured broker
      # helps nobody, and doing it to every replica at once turns a broker under
      # memory pressure into an outage with a crash-loop on top.
      expect(described_class.of(connection)).to be_up
    end

    it "says why, in wording an alert rule can match on, and then says the broker's reason" do
      expect(described_class.of(connection).detail).to eq("#{blocked}: low on memory")
    end

    it "puts the reason in the parts, where a dashboard reads it" do
      parts = described_class.of(connection).to_h["parts"]

      expect(parts["blocked"]).to be(true)
      expect(parts["blocked_reason"]).to eq("low on memory")
    end

    it "does not spend a round trip the broker has stopped reading" do
      # A declare on a blocked connection does not fail — it waits for bunny's
      # continuation timeout and then looks like a broker that did not answer.
      # Skipping it is why the report arrives at once and says `up`.
      expect(described_class.of(connection).to_h["parts"]).not_to have_key("round_trip_ms")
    end

    it "does not overwrite a detail the library already had" do
      transport = FakeTransport.new(blocked_reason: "low on disk")
      connection = connection_on(transport)
      connection.consume("orders.new") { AceMQ::AMQP::Ack.accept }
      # A stopped consumer is degraded; being blocked as well must not hide it.
      connection.consumers.first.cancel

      report = described_class.of(connection)
      expect(report).to be_degraded
      expect(report.detail).to include("consumers", blocked, "low on disk")
    end
  end

  it "says nothing about blocking when the transport cannot be asked" do
    # A hand-written double need not have heard of the method, and a health
    # check that raised inside a readiness probe would tell an orchestrator
    # nothing at all.
    transport = Class.new(FakeTransport) { undef_method :blocked_reason }.new

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

    it "takes the connection when the check runs, not when it is built" do
      # The reason this exists rather than AceMQ::AMQP::Health::Check. Building
      # the check in an initializer must not dial the broker on the way up.
      AceMQ::Rails.connection = nil
      check = described_class.check

      expect(AceMQ::Rails).not_to be_connected

      AceMQ::Rails.connection = connection_on(FakeTransport.new)
      expect(check.check).to be_up
    end

    it "names a blocked part in the aggregate's top line, not only in its parts" do
      # An aggregate that summarised by status alone would answer `up` with an
      # empty detail, throwing away — at the level an operator reads first — the
      # one fact the check went to the trouble of finding.
      AceMQ::Rails.connection =
        connection_on(FakeTransport.new(blocked_reason: "low on memory"))

      report = AceMQ::AMQP::Health.aggregate(described_class.check)

      expect(report).to be_up
      expect(report.detail).to eq("acemq")
      expect(report.parts["acemq"].detail).to eq("#{blocked}: low on memory")
    end
  end
end
