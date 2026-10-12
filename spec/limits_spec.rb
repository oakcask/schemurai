# frozen_string_literal: true

require "spec_helper"

# rubocop:disable RSpec/ExampleLength -- Boundary and interruption checks share setup across backends.

RSpec.describe "configurable validation limits" do
  [:ruby, :vm].each do |backend|
    context "with #{backend}" do
      let(:validator) { Schemurai.compile({"items" => false}, backend: backend, limits: {max_errors: 1}) }

      it "stops before constructing an error beyond the count limit", :aggregate_failures do
        messages = Schemurai.const_get(:Internal).const_get(:ErrorMessage)
        allow(messages).to receive(:false_schema).and_call_original
        expect { validator.validate([1, 2]) }.to raise_error(Schemurai::LimitExceeded) { |error|
          expect([error.limit, error.maximum, error.attempted]).to eq([:max_errors, 1, 2])
        }
        expect(messages).to have_received(:false_schema).once
      end

      it "permits the exact count and resets state after an interrupted call", :aggregate_failures do
        expect { validator.validate([1, 2]) }.to raise_error(Schemurai::LimitExceeded)
        expect(validator.validate([1]).errors.length).to eq(1)
        expect(validator.validate([]).valid?).to be(true)
        expect(validator.valid?([1, 2])).to be(false)
      end

      it "supports per-call overrides and an explicitly unlimited call", :aggregate_failures do
        expect(validator.validate([1, 2], limits: {max_errors: 2}).errors.length).to eq(2)
        expect(validator.validate([1, 2], limits: nil).errors.length).to eq(2)
        expect { validator.validate([1], limits: {max_errors: 0}) }.to raise_error(Schemurai::LimitExceeded)
        expect(validator.validate([], limits: {max_errors: 0}).valid?).to be(true)
      end

      it "counts compact JSON bytes including escaping and array punctuation", :aggregate_failures do
        schema = {"additionalProperties" => false}
        value = {"日本語\"\\\n\u0001/~" => 1, "second" => 2}
        compiled = Schemurai.compile(schema, backend: backend)
        expected = compiled.validate(value).errors
        bytes = JSON.generate(expected.map(&:to_h)).bytesize
        expect(compiled.validate(value, limits: {max_output_bytes: bytes}).errors).to eq(expected)
        expect { compiled.validate(value, limits: {max_output_bytes: bytes - 1}) }.to raise_error(Schemurai::LimitExceeded) { |error|
          expect(error.limit).to eq(:max_output_bytes)
        }
      end

      it "accounts for the empty error array and ignores diagnostic caps in valid?", :aggregate_failures do
        expect(validator.validate([], limits: {max_output_bytes: 2}).valid?).to be(true)
        expect { validator.validate([], limits: {max_output_bytes: 1}) }.to raise_error(Schemurai::LimitExceeded)
        expect(validator.valid?([], limits: {max_output_bytes: 0, max_errors: 0})).to be(true)
      end

      it "bounds successful shared-reference expansion in both operations", :aggregate_failures do
        definitions = {"n0" => true}
        1.upto(24) { |i| definitions["n#{i}"] = {"allOf" => Array.new(2) { {"$ref" => "#/$defs/n#{i - 1}"} }} }
        compiled = Schemurai.compile({"$defs" => definitions, "$ref" => "#/$defs/n24"}, backend: backend, limits: {max_evaluations: 200})
        [:validate, :valid?].each do |method|
          expect { compiled.public_send(method, nil) }.to raise_error(Schemurai::LimitExceeded) { |error|
            expect(error.limit).to eq(:max_evaluations)
          }
        end
      end

      it "charges wide required scans and scalar bytes before processing them", :aggregate_failures do
        schema = {"required" => Array.new(1000) { |i| "p#{i}" }}
        expect { Schemurai.validate(schema, {}, backend: backend, limits: {max_evaluations: 10}) }.to raise_error(Schemurai::LimitExceeded)
        expect { Schemurai.valid?({"type" => "string"}, "x" * 1000, backend: backend, limits: {max_evaluations: 10}) }.to raise_error(Schemurai::LimitExceeded)
      end

      it "charges structural fingerprints instead of counting only schema visits", :aggregate_failures do
        shared = 1
        20.times { shared = [shared, shared] }
        value = Array.new(17) { |i| [shared, i] }
        compiled = Schemurai.compile({"uniqueItems" => true}, backend: backend, limits: {max_evaluations: 100})
        expect { compiled.valid?(value) }.to raise_error(Schemurai::LimitExceeded)
        expect { compiled.validate(value) }.to raise_error(Schemurai::LimitExceeded)
      end

      it "does not treat discarded branch diagnostics as emitted errors", :aggregate_failures do
        schema = {"anyOf" => [false, true]}
        expect(Schemurai.validate(schema, nil, backend: backend, limits: {max_errors: 0}).valid?).to be(true)
      end

      it "preserves independent limits in a shareable registry", :aggregate_failures do
        registry = Schemurai::SchemaRegistry.new(schemas: {"urn:limited" => {"items" => false}}, backend: backend).make_shareable
        limits = Schemurai::Limits.new(max_errors: 1)
        ractor = Ractor.new(registry, limits) do |shared, caps|
          shared.validator_for("urn:limited", limits: caps).validate([1, 2])
        rescue Schemurai::LimitExceeded => error
          error.limit
        end
        result = ractor.respond_to?(:value) ? ractor.value : ractor.take
        expect(result).to eq(:max_errors)
      end
    end
  end

  it "rejects invalid limits and unknown options", :aggregate_failures do
    [-1, 1.5, "1", false].each do |value|
      expect { Schemurai::Limits.new(max_errors: value) }.to raise_error(ArgumentError)
      expect { Schemurai::Limits.new(max_output_bytes: value) }.to raise_error(ArgumentError)
      expect { Schemurai::Limits.new(max_evaluations: value) }.to raise_error(ArgumentError)
    end
    expect { Schemurai.compile(true, limits: {unknown: 1}) }.to raise_error(ArgumentError)
    expect { Schemurai.compile(true, limits: 1) }.to raise_error(ArgumentError)
    expect(Schemurai::Limits.new.frozen?).to be(true)
  end

  it "applies limits to explicit meta-schema validation", :aggregate_failures do
    expect { Schemurai.validate_schema({"type" => "integer"}, limits: {max_evaluations: 0}) }.to raise_error(Schemurai::LimitExceeded)
    expect { Schemurai.valid_schema?({"type" => "integer"}, limits: {max_evaluations: 0}) }.to raise_error(Schemurai::LimitExceeded)
    expect(Schemurai.valid_schema?({"type" => "unknown"}, limits: {max_errors: 0, max_output_bytes: 0})).to be(false)
    expect(Schemurai.valid_schema?({"type" => "integer"}, limits: {max_errors: 0, max_output_bytes: 0})).to be(true)
  end
end

# rubocop:enable RSpec/ExampleLength
