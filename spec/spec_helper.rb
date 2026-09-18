# frozen_string_literal: true

require "securerandom"
require "acemq/rails"

# The integration specs want a broker and the rest do not. Tagging is how one
# `rspec` on a laptop with no Docker still runs everything it can, and how CI
# runs the broker job once rather than once per Ruby.
BROKER_URL = ENV.fetch("ACEMQ_TEST_BROKER", nil)

Dir[File.expand_path("support/**/*.rb", __dir__)].each { |file| require file }

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :defined

  config.filter_run_excluding(:integration) unless BROKER_URL

  # Every spec starts with an empty registry and a fresh configuration. The
  # registry is process-global by design — Rails has one application — so a spec
  # that defines a consumer class would otherwise leak it into the next one, and
  # the runner specs would find consumers they never asked for.
  config.before do
    AceMQ::Rails::Registry.clear
    AceMQ::Rails.config = AceMQ::Rails::Configuration.new
    AceMQ::Rails.connection = nil
    AceMQ::Rails.logger = nil
  end
end
