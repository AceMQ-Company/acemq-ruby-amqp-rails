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

  attr_reader :consumes, :applied, :closed, :drain_timeouts

  def initialize
    @consumes = []
    @applied = []
    @closed = false
    @drain_timeouts = []
  end

  def consume(queue, **options, &block)
    consumer = StubConsumer.new(queue)
    @consumes << Consume.new(queue: queue, options: options, block: block, consumer: consumer)
    consumer
  end

  def apply(topology) = @applied << topology
  def closed? = @closed
  def consumers = @consumes.map(&:consumer)

  # The drain, modelled rather than stubbed, because the runner no longer has
  # one of its own: since acemq-amqp 0.7.0 `Connection#close` stops every
  # consumer inside one deadline and raises `DrainTimeout` naming what was left
  # unsettled, and the runner's whole remaining job is to turn that into a
  # boolean and a log line.
  def close(timeout: AceMQ::AMQP::Connection::DRAIN_TIMEOUT)
    @closed = true
    @drain_timeouts << timeout
    stranded = Hash.new(0)
    consumers.each do |consumer|
      consumer.cancel(timeout: timeout)
      stranded[consumer.queue] += consumer.in_flight if consumer.in_flight.positive?
    end
    raise AceMQ::AMQP::DrainTimeout.new(stranded, timeout) unless stranded.empty?

    nil
  end

  def for(queue) = @consumes.find { |it| it.queue == queue }
  def options_for(queue) = self.for(queue)&.options
  def deliver(queue, message) = self.for(queue).block.call(message)

  # Only what a drain touches. `in_flight` is writable so a spec can say "this
  # handler never returned" without a sleep in it: what is still in flight
  # after the cancel is exactly what the deadline did not wait for.
  class StubConsumer
    attr_reader :queue, :cancelled
    attr_accessor :in_flight

    def initialize(queue, in_flight: 0)
      @queue = queue
      @cancelled = false
      @in_flight = in_flight
    end

    def running? = !@cancelled

    def cancel(timeout: AceMQ::AMQP::Connection::DRAIN_TIMEOUT) # rubocop:disable Lint/UnusedMethodArgument
      @cancelled = true
    end
  end
end
