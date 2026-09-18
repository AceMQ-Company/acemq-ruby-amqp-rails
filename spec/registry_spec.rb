# frozen_string_literal: true

RSpec.describe AceMQ::Rails::Registry do
  it "records a consumer when it is defined" do
    klass = Class.new(AceMQ::Rails::Consumer) { queue "orders.new" }

    expect(described_class.classes).to include(klass)
  end

  it "lists only the ones with a queue as runnable" do
    Class.new(AceMQ::Rails::Consumer)
    runnable = Class.new(AceMQ::Rails::Consumer) { queue "orders.new" }

    expect(described_class.runnable).to eq([runnable])
    expect(described_class.queues).to eq(["orders.new"])
  end

  it "replaces a class rather than adding a second one when it is reloaded" do
    # This is the whole reason the registry is keyed by name. Zeitwerk removes
    # the constant and evaluates the file again on every reload, which produces
    # a *new* class object under the same name; a set of classes would grow a
    # second OrdersConsumer every time somebody saved the file, and the consumer
    # process would end up subscribed to the same queue four times after an
    # afternoon's work.
    #
    # `class X < Y` rather than `Class.new(Y)` on purpose: Ruby assigns the
    # constant before it calls `inherited`, so the real reload path is the one
    # where the registry has a name to key on. An anonymous class is a different
    # case and is covered below.
    namespace = Module.new
    stub_const("Reloaded", namespace)

    2.times do
      namespace.send(:remove_const, :OrdersConsumer) if
        namespace.const_defined?(:OrdersConsumer, false)
      namespace.module_eval(<<~RUBY, __FILE__, __LINE__ + 1)
        class OrdersConsumer < AceMQ::Rails::Consumer
          queue "orders.new"
        end
      RUBY
    end

    named = described_class.classes.select { |it| it.name == "Reloaded::OrdersConsumer" }
    expect(named.size).to eq(1)
    expect(named.first).to be(namespace.const_get(:OrdersConsumer))
  end

  it "keeps anonymous classes apart, so specs do not collide" do
    one = Class.new(AceMQ::Rails::Consumer) { queue "a" }
    two = Class.new(AceMQ::Rails::Consumer) { queue "b" }

    expect(described_class.runnable).to contain_exactly(one, two)
  end

  it "forgets everything on clear" do
    Class.new(AceMQ::Rails::Consumer) { queue "orders.new" }
    described_class.clear

    expect(described_class.classes).to be_empty
  end
end
