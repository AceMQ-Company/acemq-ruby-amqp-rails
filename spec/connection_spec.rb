# frozen_string_literal: true

RSpec.describe AceMQ::Rails do
  describe ".connection" do
    # A real library connection over a fake transport: `intercept_publish` and
    # `intercept_consume` are the library's own, so what this proves is that the
    # configured interceptors reach a connection this gem opened — not that a
    # double was called.
    let(:transport) { FakeTransport.new }

    # An interceptor that only stamps a header on the way out, which is the
    # shape nearly every real one has.
    let(:stamping) do
      Class.new do
        def before_publish(context)
          context.set_header("tenant", "acme")
          context
        end
      end
    end

    before do
      allow(AceMQ::AMQP::Connection).to receive(:open)
        .and_return(AceMQ::AMQP::Connection.new(transport: transport))
    end

    it "registers config.acemq.interceptors on the connection it opens" do
      described_class.config.interceptors = [stamping.new]

      described_class.publish({ "order_id" => "A-1" }, to: "order.placed")

      expect(transport.published.first.headers["tenant"]).to eq("acme")
    end

    it "takes a bare object as well as a list" do
      described_class.config.interceptors = stamping.new

      described_class.publish({ "order_id" => "A-1" }, to: "order.placed")

      expect(transport.published.first.headers["tenant"]).to eq("acme")
    end

    it "offers an interceptor to both sides and keeps only the hooks it has" do
      # The library works out an interceptor's hooks once, at registration, so an
      # object answering only `before_handle` is a consume interceptor and
      # offering it to the publish side costs nothing. That is what lets one
      # setting serve both sides instead of two that have to be kept apart.
      seen = []
      watching = Class.new do
        define_method(:before_handle) do |context|
          seen << context.queue
          context
        end
      end
      described_class.config.interceptors = [watching.new]

      described_class.publish({ "order_id" => "A-1" }, to: "order.placed")

      expect(seen).to be_empty
    end

    it "leaves a connection handed in by a test exactly as it was given" do
      described_class.config.interceptors = [stamping.new]
      described_class.connection = AceMQ::AMQP::Connection.new(transport: transport)

      described_class.publish({ "order_id" => "A-1" }, to: "order.placed")

      expect(transport.published.first.headers).not_to have_key("tenant")
    end
  end
end
