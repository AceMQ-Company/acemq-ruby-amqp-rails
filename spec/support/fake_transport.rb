# frozen_string_literal: true

# A broker that is a Hash, cut down to what this gem's own tests need.
#
# The library has a fuller one of these for testing its retry arithmetic. What
# is exercised here is different: which options a consumer class turns into, how
# a drain behaves when a handler will not return, and what a health report says
# about a blocked connection. None of those needs a message to survive a wire,
# and all of them would be slow and flaky if they had to.
class FakeTransport
  Published = Struct.new(:exchange, :routing_key, :body, :content_type, :message_id,
                         :headers, :reply_to, :mandatory, keyword_init: true)

  # What Connection#consume was called with, recorded per subscription. This is
  # the assertion most of the runner specs actually make.
  Subscribed = Struct.new(:queue, :options, :subscription, keyword_init: true)

  attr_reader :published, :declared_queues, :declared_exchanges, :bindings, :subscribed

  def initialize(blocked: false)
    @published = []
    @declared_queues = []
    @declared_exchanges = []
    @bindings = []
    @subscribed = []
    @closed = false
    @session = FakeSession.new(blocked)
  end

  # The bunny session the real transport exposes. Present because
  # AceMQ::Rails::Health reaches for it, and a fake that lacks it would make
  # that reach look safe when it is the part worth pinning.
  attr_reader :session

  def publish(exchange:, routing_key:, body:, content_type: nil, message_id: nil,
              headers: {}, reply_to: nil, mandatory: false,
              persistent: true) # rubocop:disable Lint/UnusedMethodArgument
    @published << Published.new(exchange: exchange, routing_key: routing_key, body: body,
                                content_type: content_type, message_id: message_id,
                                headers: headers, reply_to: reply_to, mandatory: mandatory)
    message_id
  end

  def publish_all(messages) = messages.map { |message| publish(**message) }

  def declare_queue(name, **options) = @declared_queues << [name, options]
  def declare_exchange(name, **options) = @declared_exchanges << [name, options]
  def bind(queue:, exchange:, routing_key: "") = @bindings << [queue, exchange, routing_key]

  def subscribe(queue, **options, &)
    subscription = Subscription.new
    @subscribed << Subscribed.new(queue: queue, options: options, subscription: subscription)
    subscription
  end

  def message_count(_queue) = 0
  def queue_exists?(_name) = true
  def delete_queue(_name) = nil
  def open? = !@closed
  def close = @closed = true

  def options_for(queue)
    @subscribed.find { |it| it.queue == queue }&.options
  end

  class Subscription
    def initialize = @open = true
    def open? = @open
    def stop = @open = false
    def close = @open = false
    def cancel = @open = false
  end

  # Only the one method Health reaches for.
  FakeSession = Struct.new(:blocked) do
    def blocked? = !!blocked
  end
end
