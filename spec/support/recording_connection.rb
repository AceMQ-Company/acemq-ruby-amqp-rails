# frozen_string_literal: true

# A connection that records what the runner asked of it.
#
# The runner's job is a translation: consumer classes in, +Connection#consume+
# calls out, with the right options and the right block around the handler.
# Asserting on that translation wants the call recorded, not a broker — and the
# block matters as much as the options, because the block is where the Rails
# executor and the error reporter are wrapped on.
class RecordingConnection
  Consume = Struct.new(:queue, :options, :block, :consumer, keyword_init: true)

  attr_reader :consumes, :applied, :closed

  def initialize
    @consumes = []
    @applied = []
    @closed = false
  end

  def consume(queue, **options, &block)
    consumer = StubConsumer.new(queue)
    @consumes << Consume.new(queue: queue, options: options, block: block, consumer: consumer)
    consumer
  end

  def apply(topology) = @applied << topology
  def close = @closed = true
  def closed? = @closed

  def for(queue) = @consumes.find { |it| it.queue == queue }
  def options_for(queue) = self.for(queue)&.options
  def deliver(queue, message) = self.for(queue).block.call(message)

  # Only what the runner's drain touches.
  class StubConsumer
    attr_reader :queue, :cancelled

    def initialize(queue)
      @queue = queue
      @cancelled = false
    end

    def running? = !@cancelled
    def in_flight = 0

    def cancel(timeout: 30) # rubocop:disable Lint/UnusedMethodArgument
      @cancelled = true
    end
  end
end
