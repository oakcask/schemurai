# frozen_string_literal: true

require "spec_helper"
require_relative "../oracle/lib/runner"
require_relative "../oracle/lib/comparator"
require_relative "../spec/support/backend_regressions"

backend = ENV.fetch("SCHEMURAI_DIFFERENTIAL_BACKEND").to_sym

RSpec.describe "the #{backend} evaluator" do
  it_behaves_like "backend regressions", backend

  it "does not instantiate or copy the Ruby evaluator" do
    ruby_evaluator = Schemurai.const_get(:Internal).const_get(:Evaluator)
    allow(ruby_evaluator).to receive(:new).and_raise("Ruby evaluator fallback")
    allow(ruby_evaluator).to receive(:dup).and_raise("Ruby evaluator copy")

    validator = Schemurai.compile({"type" => "integer"}, backend: backend)
    expect(validator.valid?(4)).to be(true)
    expect(validator.valid?(4.5)).to be(false)
  end

  it "matches the Ruby result stream for the complete catalog" do
    inputs = SchemuraiOracle::CaseCatalog.new.each_case
      .select { |record| record.classification == "selected" }
      .flat_map do |record|
        %w[valid validate].map { |operation| {"catalog_case" => record.id, "operation" => operation} }
      end
    ruby_runner = SchemuraiOracle::Runner.new(backend: :ruby)
    backend_runner = SchemuraiOracle::Runner.new(backend: backend)
    ruby_records = inputs.map { |input| ruby_runner.run(input) }
    backend_records = inputs.map { |input| backend_runner.run(input) }
    comparison = SchemuraiOracle::Comparator.new(actual_backend: backend.to_s)
      .compare(ruby_records, backend_records)

    expect(comparison).to be_empty
  end

  it "runs with validators owned by independent Ractors", :aggregate_failures do
    schema = {"type" => "array", "items" => {"$ref" => "#/$defs/item"}, "uniqueItems" => true, "$defs" => {"item" => {"type" => "integer"}}}
    registry = Schemurai::SchemaRegistry.new(schemas: {"urn:backend" => schema}, backend: backend)
    registry.make_shareable
    ractor = Ractor.new(registry) do |shared|
      validator = shared.validator_for("urn:backend")
      [validator.backend, validator.valid?([1]), validator.valid?(["bad"]), validator.valid?([1, 1])]
    end
    result = ractor.respond_to?(:value) ? ractor.value : ractor.take

    expect(result).to eq([backend, true, false, false])
  end

  it "preserves complete catalog results with generous invocation limits" do # rubocop:disable RSpec/ExampleLength
    catalog = SchemuraiOracle::CaseCatalog.new
    caps = [Schemurai::Limits.new(max_duration: 10),
      Schemurai::Limits.new(max_errors: 100_000, max_output_bytes: 10_000_000, max_evaluations: 100_000_000, max_duration: 10)]
    catalog.each_case.select { |record| record.classification == "selected" }.each do |record|
      validator = Schemurai.compile(record.schema, schemas: catalog.remotes, backend: backend, **record.options.transform_keys(&:to_sym))
      expected = validator.validate(record.instance)
      caps.each do |limits|
        expect(validator.validate(record.instance, limits: limits).errors).to eq(expected.errors), record.id
        expect(validator.valid?(record.instance, limits: limits)).to eq(expected.valid?), record.id
      end
    end
  end
end
