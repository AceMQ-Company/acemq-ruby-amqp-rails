# frozen_string_literal: true

# Copyright 2026 AceMQ.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require "acemq/amqp"

module AceMQ
  module Rails
    # Everything this integration can be told, in one object.
    #
    # Two ways in, and they are not alternatives:
    #
    # * +config/acemq.yml+, read through Rails' own +config_for+, which already
    #   understands per-environment sections, a +shared:+ block and ERB. That is
    #   where a URL, a virtual host and a topology belong: they differ per
    #   environment and they are data.
    # * +config.acemq.*+ in +config/application.rb+ or an environment file, for
    #   the things that are decisions rather than data — a codec object, an
    #   interceptor, a telemetry reporter. None of those can be written in YAML
    #   without inventing a second configuration language.
    #
    # The YAML is read first and the Ruby is applied over it. A file checked in
    # for every environment is the general statement; a line in
    # +config/environments/test.rb+ is the specific one, and the specific one
    # wins. This is the opposite order from +database.yml+, which has no Ruby
    # half to disagree with, and the same order as +config.active_job.queue_adapter+
    # overriding whatever an adapter's own defaults were.
    class Configuration
      # The AMQP URL. +amqps://+ is verified against the system trust store on
      # its own; a broker with a private certificate authority needs +tls+.
      attr_accessor :url

      # Broker login, kept out of the URL so it stays out of the log line that
      # reports a failed connection. Either both or neither.
      attr_accessor :username, :password

      # A token instead of a username and password, for brokers that take one
      # (RabbitMQ with OAuth 2). Mutually exclusive with +username+.
      attr_accessor :token

      # The AMQP virtual host. Nil leaves whatever is in the URL alone; a value
      # replaces the URL's path, which is how a vhost is expressed in AMQP.
      attr_accessor :virtual_host

      # What is stamped on every message this application publishes, in
      # +x-acemq-origin+. Defaults to the Rails application's name and the
      # hostname, which is what makes a dead-lettered message traceable to a pod.
      attr_accessor :client_name

      # Seconds to wait for the AMQP handshake.
      attr_accessor :connect_timeout

      # Heartbeat interval in seconds, or +:server+ to take the broker's
      # suggestion. Taking the broker's suggestion is right almost always.
      attr_accessor :heartbeat

      # How many publishes may be waiting for a confirm at once. This is the
      # back pressure that stops a runaway loop from holding a million messages
      # in this process's memory. 0.6.0 of the library added it; the default is
      # the library's.
      attr_accessor :max_outstanding_publishes

      # Whether a publish waits for the broker to confirm it. True, and the
      # writer refuses anything else.
      #
      # Confirms are not optional in the library and there is no keyword to ask
      # for a publish without them: the publishing channel calls
      # +confirm_select+ the moment it is opened, and +publish+ raises
      # {AceMQ::AMQP::PublishError} when nothing comes back. The setting stays
      # because it has been documented as one since 0.1.0, and it refuses rather
      # than being ignored — a line in a configuration file that reads as though
      # it turned durability off, and did nothing at all, is worse than no line.
      attr_reader :publisher_confirms

      # @raise [AceMQ::AMQP::ConfigurationError] for anything false
      def publisher_confirms=(value)
        unless value
          raise AceMQ::AMQP::ConfigurationError,
                "acemq: publisher_confirms cannot be turned off. The library opens its " \
                "publishing channel with confirm_select and raises PublishError when the " \
                "broker does not answer, so there is no unconfirmed publish to ask for. " \
                "Remove the setting."
        end

        @publisher_confirms = true
      end

      # The codec name, resolved through +AceMQ::AMQP::Codecs.build+: bytes,
      # json, string, toml, xml, yaml. +AceMQ::AMQP::Codecs.names+ is the list,
      # and a name that is not on it raises.
      #
      # Protobuf and Avro are deliberately *not* names. Each needs something a
      # string cannot carry — a generated message class, a schema, a registry —
      # so each is built and handed over as an object in +codec+ instead. See
      # docs/serialization.md.
      attr_accessor :format

      # A codec instance, for anything that cannot be named — a composite, an
      # encrypted one, a claim-check wrapper.
      attr_accessor :codec

      # An +AceMQ::AMQP::Security+, for a private certificate authority or a
      # client certificate. Nil means "whatever the URL scheme implies".
      attr_accessor :tls

      # A telemetry reporter: anything answering +count+, +observe+ and +gauge+.
      # Nil means the library's own no-op, which costs nothing.
      attr_accessor :telemetry

      # Interceptors applied to the process connection as it is opened.
      #
      # An interceptor lives on a connection — +intercept_publish+ and
      # +intercept_consume+ are instance methods on
      # {AceMQ::AMQP::Connection} — so registering one from an initializer means
      # reaching for {AceMQ::Rails.connection}, and that *opens the socket during
      # boot*. It is the one thing +connect_on_boot: false+ exists to avoid, and
      # it happens quietly: the application dials the broker on the way up and
      # nothing in the configuration says why. This list is applied on the way
      # out of +Connection.open+ instead, so an interceptor costs nothing until
      # something publishes or consumes.
      #
      # Each entry is registered on **both** sides. The library works out which
      # hooks an object actually answers to once, at registration, so an object
      # with only +before_publish+ is a publish interceptor and nothing else —
      # which is exactly how the library's own
      # +AceMQ::AMQP::Telemetry::OpenTelemetry#install+ registers itself. A bare
      # object is accepted as well as an array.
      #
      # Ruby rather than YAML, because an interceptor is an object. Applied only
      # by {AceMQ::Rails.connection}: a connection handed in with
      # +AceMQ::Rails.connection=+ is a test's own, and is left as it was given.
      attr_accessor :interceptors

      # Declared on boot of the consumer process, and by +rake acemq:topology+.
      # A hash of +exchanges+, +queues+ and +bindings+; see TopologyBuilder.
      attr_accessor :topology

      # Whether to apply +topology+ when the consumer process starts. True by
      # default: a consumer that starts before its queue exists reads nothing
      # and says nothing about why.
      attr_accessor :declare_topology_on_boot

      # Consumer defaults, overridable per consumer class.
      attr_accessor :consumer

      # Seconds the consumer process spends draining before it gives up. Must be
      # comfortably shorter than whatever will kill the process —
      # +terminationGracePeriodSeconds+, +TimeoutStopSec+, +docker stop -t+.
      attr_accessor :shutdown_timeout

      # Whether opening the connection is attempted while the web server boots.
      # False by default, and that default is a decision: a broker that is down
      # should not stop an application from serving the pages that do not need
      # it. The connection is opened on first use instead.
      attr_accessor :connect_on_boot

      # Extra keyword arguments handed to +Bunny.new+, for the handful of
      # things this configuration does not name.
      attr_accessor :transport_options

      # Extra directories to autoload consumers from.
      #
      # Empty by default and that is not an omission: Rails already autoloads
      # every direct subdirectory of +app/+, so a consumer in +app/consumers+
      # needs nothing here. This is for +lib/consumers+ and the like.
      attr_accessor :consumer_paths

      def initialize
        @url = "amqp://guest:guest@localhost:5672"
        @connect_timeout = 10
        @heartbeat = :server
        @publisher_confirms = true
        @format = "json"
        @declare_topology_on_boot = true
        @shutdown_timeout = 20
        @connect_on_boot = false
        @transport_options = {}
        @topology = {}
        @interceptors = []
        @consumer_paths = []
        @consumer = ConsumerDefaults.new
      end

      # Consumer settings that apply unless a consumer class says otherwise.
      class ConsumerDefaults
        # Unacknowledged messages a consumer holds at once.
        attr_accessor :prefetch

        # Messages worked on at once by one consumer. One keeps a queue's
        # messages in the order the broker offers them; raising it trades that
        # order for throughput.
        attr_accessor :concurrency

        # The retry ladder: how many attempts, the first delay, the ceiling, and
        # the point past which a wait is spent on a broker queue rather than in
        # this process. That last one is a shutdown setting as much as a
        # reliability one — a wait held here is a wait a drain has to sit
        # through. See docs/lifecycle.md.
        attr_accessor :max_attempts, :initial_delay, :max_delay, :multiplier,
                      :jitter, :give_up_after, :broker_wait_threshold

        def initialize
          @prefetch = AceMQ::AMQP::Connection::DEFAULT_PREFETCH
          @concurrency = 1
          @max_attempts = 1
          @initial_delay = 0.0
          @max_delay = 0.0
          @multiplier = 2.0
          @broker_wait_threshold = AceMQ::AMQP::RetryLadder::DEFAULT_THRESHOLD
        end

        # The library's RetryPolicy these settings describe.
        def retry_policy
          return AceMQ::AMQP::RetryPolicy.none if max_attempts.to_i <= 1

          policy = AceMQ::AMQP::RetryPolicy.new(
            max_attempts: max_attempts.to_i,
            initial_delay: initial_delay.to_f,
            multiplier: multiplier.to_f,
            max_delay: max_delay.to_f
          )
          policy = policy.give_up_after(give_up_after.to_f) if give_up_after
          policy = policy.with_jitter(jitter.to_f) if jitter
          policy
        end

        # @api private
        def assign(settings)
          settings.each { |key, value| writer(key, value) }
          self
        end

        private

        def writer(key, value)
          name = :"#{key}="
          unless respond_to?(name)
            raise AceMQ::AMQP::ConfigurationError,
                  "acemq: consumer.#{key} is not a setting; the settings are " \
                  "#{self.class.instance_methods(false).grep(/=$/).map { |m| m.to_s.chomp("=") }
                       .reject { |m| m == "assign" }.sort.join(", ")}"
          end

          public_send(name, value)
        end
      end

      # Applies a hash read out of +config/acemq.yml+.
      #
      # String keys, because that is what YAML gives, and dashes accepted
      # alongside underscores because +max-outstanding-publishes+ is how the
      # same setting is spelled in the Spring starter's +application.yaml+ and
      # somebody will copy it across.
      #
      # An unknown key raises rather than being ignored. A typo in a
      # configuration file that is silently dropped is how a production broker
      # ends up with the default retry policy and nobody knows why.
      #
      # @param settings [Hash]
      # @return [Configuration] self
      def assign(settings)
        return self if settings.nil?

        settings.each do |key, value|
          name = normalise(key)
          case name
          when "consumer" then @consumer.assign(symbolize(value))
          when "topology" then @topology = value
          when "transport_options" then @transport_options = symbolize(value)
          else assign_one(name, value)
          end
        end
        self
      end

      # The codec this configuration asks for.
      #
      # @return [#encode]
      def resolved_codec
        return AceMQ::AMQP::Codec.check!(codec) if codec

        AceMQ::AMQP::Codecs.build(format)
      end

      # The credentials this configuration asks for, or nil to leave the URL to
      # speak for itself.
      #
      # @return [AceMQ::AMQP::Credentials, nil]
      def resolved_credentials
        return AceMQ::AMQP::Credentials.token(token) if token

        return nil if username.nil? || username.to_s.empty?

        AceMQ::AMQP::Credentials.of(username: username, password: password.to_s)
      end

      # The URL with +virtual_host+ applied.
      #
      # A vhost is the path of an AMQP URL, and this is fiddlier than joining
      # two strings because "/" is a legal vhost name — it is RabbitMQ's default
      # — and also the separator. The value here is taken **literally**, as the
      # name of the vhost, and escaped whole: +/+ becomes +/%2F+ and
      # +tenant/a+ becomes +/tenant%2Fa+, which is the vhost really called
      # "tenant/a" rather than a path with two segments.
      #
      # +CGI.escape+ with its +++ put back, because +CGI.escape+ encodes a space
      # the way a form does and a URI path wants +%20+. A vhost with a space in
      # it is rare and is not a reason for this to be wrong.
      #
      # @return [String]
      def resolved_url
        return url.to_s if virtual_host.nil? || virtual_host.to_s.empty?

        require "uri"
        require "cgi"
        parsed = URI.parse(url.to_s)
        parsed.path = "/#{CGI.escape(virtual_host.to_s).gsub("+", "%20")}"
        parsed.to_s
      rescue URI::InvalidURIError => e
        raise AceMQ::AMQP::ConfigurationError,
              "acemq: the url #{AceMQ::AMQP::Transport.redact(url.to_s)} cannot be " \
              "parsed, so virtual_host cannot be applied to it: #{e.message}"
      end

      # What {AceMQ::AMQP::Connection.open} is called with.
      #
      # @return [Array(String, Hash)]
      def connection_arguments
        options = {
          codec: resolved_codec,
          origin: client_name,
          retry_policy: consumer.retry_policy,
          prefetch: consumer.prefetch,
          retry_threshold: consumer.broker_wait_threshold,
          telemetry: telemetry,
          heartbeat: heartbeat,
          connection_timeout: connect_timeout,
          security: tls,
          credentials: resolved_credentials
        }
        # Only when asked for. The library's default is its own business and
        # repeating it here would freeze it at whatever it was the day this was
        # written.
        if max_outstanding_publishes
          options[:max_outstanding_publishes] = max_outstanding_publishes.to_i
        end
        options.compact!
        [resolved_url, options.merge(transport_options)]
      end

      private

      def assign_one(name, value)
        writer = :"#{name}="
        unless respond_to?(writer)
          raise AceMQ::AMQP::ConfigurationError,
                "acemq: #{name} is not a setting. Check config/acemq.yml — a " \
                "misspelled key here is a default applied in production."
        end

        public_send(writer, value)
      end

      def normalise(key) = key.to_s.tr("-", "_")

      def symbolize(value)
        return {} if value.nil?

        value.to_h { |key, inner| [normalise(key).to_sym, inner] }
      end
    end
  end
end
