# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "backend selection" do
  it "gets the backend from the evaluator implementation" do
    evaluator_class = Class.new do
      def backend = :unused
    end
    evaluator = instance_double(evaluator_class, backend: :custom)

    expect(Schemurai::Validator.new(evaluator).backend).to eq(:custom)
  end

  it "makes selection and actual identity observable", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    registry = Schemurai::SchemaRegistry.new(backend: :ruby)
    validator = registry.compile(true)
    requested = ENV.fetch("SCHEMURAI_BACKEND", "ruby").to_sym
    selected = (requested == :default) ? :ruby : requested

    expect(Schemurai.backend).to eq(selected)
    expect(registry.backend).to eq(:ruby)
    expect(validator.backend).to eq(:ruby)
  end

  it "selects the VM backend explicitly", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    registry = Schemurai::SchemaRegistry.new(backend: :vm)
    validator = registry.compile({"type" => "integer"})

    expect(registry.backend).to eq(:vm)
    expect(validator.backend).to eq(:vm)
    expect(validator.valid?(1)).to be(true)
    expect(validator.valid?(1.5)).to be(false)
  end

  it "rejects removed and unknown backends", :aggregate_failures do
    %i[bytecode unknown].each do |backend|
      expect { Schemurai.compile(true, backend: backend) }
        .to raise_error(Schemurai::Error, /unknown Schemurai backend/)
    end
  end
end
