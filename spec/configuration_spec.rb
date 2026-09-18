# frozen_string_literal: true

RSpec.describe AceMQ::Rails::Configuration do
  subject(:config) { described_class.new }

  describe "defaults" do
    it "points at a local broker" do
      expect(config.url).to eq("amqp://guest:guest@localhost:5672")
    end

    it "does not connect while the web server boots" do
      expect(config.connect_on_boot).to be(false)
    end

    it "declares the topology when the consumer process starts" do
      expect(config.declare_topology_on_boot).to be(true)
    end

    it "leaves a shutdown deadline shorter than a default grace period" do
      # Kubernetes gives thirty seconds by default and Docker ten. Twenty leaves
      # room for the rest of the process to exit inside the former, and a
      # container run under the latter is expected to say so.
      expect(config.shutdown_timeout).to be < 30
    end
  end

  describe "#assign" do
    it "takes the string keys a YAML file gives" do
      config.assign("url" => "amqp://broker:5672", "client_name" => "checkout")

      expect(config.url).to eq("amqp://broker:5672")
      expect(config.client_name).to eq("checkout")
    end

    it "takes the dashed spelling the Spring starter uses" do
      config.assign("max-outstanding-publishes" => 500, "connect-timeout" => 3)

      expect(config.max_outstanding_publishes).to eq(500)
      expect(config.connect_timeout).to eq(3)
    end

    it "refuses a key it does not know" do
      expect { config.assign("publisher_confirm" => false) }
        .to raise_error(AceMQ::AMQP::ConfigurationError, /publisher_confirm is not a setting/)
    end

    it "refuses a consumer key it does not know" do
      expect { config.assign("consumer" => { "prefech" => 5 }) }
        .to raise_error(AceMQ::AMQP::ConfigurationError, /consumer\.prefech/)
    end

    it "reads the consumer defaults" do
      config.assign("consumer" => { "prefetch" => 50, "concurrency" => 4,
                                    "max_attempts" => 5, "initial_delay" => 1,
                                    "max_delay" => 60 })

      expect(config.consumer.prefetch).to eq(50)
      expect(config.consumer.concurrency).to eq(4)
      expect(config.consumer.retry_policy.max_attempts).to eq(5)
    end

    it "keeps the topology section as it was given" do
      config.assign("topology" => { "queues" => [{ "name" => "orders.new" }] })

      expect(config.topology["queues"].first["name"]).to eq("orders.new")
    end
  end

  describe "#resolved_credentials" do
    it "is nil when the URL is left to speak for itself" do
      expect(config.resolved_credentials).to be_nil
    end

    it "keeps a password out of the URL" do
      config.username = "checkout"
      config.password = "s3cret"

      credentials = config.resolved_credentials
      expect(credentials.username).to eq("checkout")
      # The whole point of putting it here: it is never in a string that gets
      # logged.
      expect(credentials.to_s).not_to include("s3cret")
    end

    it "takes a token instead" do
      config.token = "ya29.a0"

      expect(config.resolved_credentials).to be_token
    end
  end

  describe "#resolved_url" do
    it "leaves the URL alone when no virtual host is named" do
      config.url = "amqp://broker:5672/tenant-a"

      expect(config.resolved_url).to eq("amqp://broker:5672/tenant-a")
    end

    it "replaces the path, because that is where a vhost lives in an AMQP URL" do
      config.url = "amqp://broker:5672"
      config.virtual_host = "tenant-a"

      expect(config.resolved_url).to eq("amqp://broker:5672/tenant-a")
    end

    it "escapes the default vhost rather than writing a bare slash" do
      # "/" unescaped would be read as the separator and leave the vhost empty,
      # which is a different vhost and one most brokers do not have.
      config.url = "amqp://broker:5672"
      config.virtual_host = "/"

      expect(config.resolved_url).to eq("amqp://broker:5672/%2F")
    end
  end

  describe "#connection_arguments" do
    it "passes the codec, origin and consumer defaults" do
      config.client_name = "checkout@pod-1"
      config.format = "string"
      config.consumer.prefetch = 33

      _url, options = config.connection_arguments

      expect(options[:origin]).to eq("checkout@pod-1")
      expect(options[:codec]).to be_a(AceMQ::AMQP::StringCodec)
      expect(options[:prefetch]).to eq(33)
    end

    it "passes max_outstanding_publishes only when it was asked for" do
      _url, options = config.connection_arguments
      expect(options).not_to have_key(:max_outstanding_publishes)

      config.max_outstanding_publishes = 250
      _url, options = config.connection_arguments
      expect(options[:max_outstanding_publishes]).to eq(250)
    end

    it "prefers a codec object over a format name" do
      config.format = "json"
      config.codec = AceMQ::AMQP::BytesCodec.new

      _url, options = config.connection_arguments
      expect(options[:codec]).to be_a(AceMQ::AMQP::BytesCodec)
    end

    it "merges transport_options last, so an escape hatch is one" do
      config.transport_options = { connection_timeout: 45 }

      _url, options = config.connection_arguments
      expect(options[:connection_timeout]).to eq(45)
    end
  end

  describe AceMQ::Rails::Configuration::ConsumerDefaults do
    it "is RetryPolicy.none until somebody asks for attempts" do
      expect(described_class.new.retry_policy.max_attempts).to eq(1)
    end

    it "builds the ladder it was described" do
      policy = described_class.new
                              .assign(max_attempts: 4, initial_delay: 2, max_delay: 30)
                              .retry_policy

      expect(policy.max_attempts).to eq(4)
      expect(policy.initial_delay).to eq(2.0)
      expect(policy.max_delay).to eq(30.0)
    end

    it "defaults broker_wait_threshold to the library's, so the rungs match" do
      # A consumer whose threshold differs from the topology's is a consumer
      # looking for rung queues nobody declared.
      expect(described_class.new.broker_wait_threshold)
        .to eq(AceMQ::AMQP::RetryLadder::DEFAULT_THRESHOLD)
    end
  end
end
