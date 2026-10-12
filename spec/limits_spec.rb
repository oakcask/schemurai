# frozen_string_literal: true

require "spec_helper"

# rubocop:disable RSpec/ExampleLength -- Boundary and interruption checks share setup across backends.

RSpec.describe "configurable validation limits" do
  [:ruby, :vm].each do |backend|
    context "with #{backend}" do
      let(:validator) { Schemurai.compile({"items" => false}, backend: backend, max_errors: 1) }

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
        expect(validator.validate([1, 2], max_errors: 2).errors.length).to eq(2)
        expect(validator.validate([1, 2], max_errors: nil, timeout: nil).errors.length).to eq(2)
        expect { validator.validate([1], max_errors: 0) }.to raise_error(Schemurai::LimitExceeded)
        expect(validator.validate([], max_errors: 0).valid?).to be(true)
      end

      it "overrides each kwarg independently", :aggregate_failures do
        compiled = Schemurai.compile({"items" => false}, backend: backend, max_errors: 1, timeout: 0)
        expect { compiled.validate([1, 2], max_errors: nil) }.to raise_error(Schemurai::LimitExceeded) { |error|
          expect(error.limit).to eq(:timeout)
        }
        expect { compiled.validate([1, 2], timeout: nil) }.to raise_error(Schemurai::LimitExceeded) { |error|
          expect(error.limit).to eq(:max_errors)
        }
        expect(compiled.validate([1, 2], max_errors: nil, timeout: nil).errors.length).to eq(2)
        expect(compiled.valid?([1, 2], timeout: nil)).to be(false)
      end

      it "applies a duration deadline to both operations and permits overrides", :aggregate_failures do
        compiled = Schemurai.compile(true, backend: backend, timeout: 0)
        [:validate, :valid?].each do |method|
          expect { compiled.public_send(method, nil) }.to raise_error(Schemurai::LimitExceeded) { |error|
            expect(error.limit).to eq(:timeout)
            expect(error.maximum).to eq(0)
            expect(error.attempted).to be >= 0
          }
          result = compiled.public_send(method, nil, timeout: 10)
          expect((method == :valid?) ? result : result.valid?).to be(true)
          result = compiled.public_send(method, nil, max_errors: nil, timeout: nil)
          expect((method == :valid?) ? result : result.valid?).to be(true)
        end
      end

      it "polls required scans even when no child schema or error is evaluated", :aggregate_failures do
        schema = {"required" => Array.new(1000) { |i| "p#{i}" }}
        value = schema.fetch("required").to_h { |name| [name, 1] }
        compiled = Schemurai.compile(schema, backend: backend)
        allow(Process).to receive(:clock_gettime).and_call_original
        [:validate, :valid?].each do |method|
          allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(0.0)
          visits = 0
          allow(value).to receive(:key?).and_wrap_original do |original, *args|
            visits += 1
            allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(0.2)
            original.call(*args)
          end
          expect { compiled.public_send(method, value, timeout: 0.1) }.to raise_error(Schemurai::LimitExceeded) { |error|
            expect(error.limit).to eq(:timeout)
          }
          expect(visits).to be_between(1, 256)
        end
      end

      it "checks the deadline before returning a short completed call", :aggregate_failures do
        compiled = Schemurai.compile(true, backend: backend)
        allow(Process).to receive(:clock_gettime).and_call_original
        [:validate, :valid?].each do |method|
          allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(0.0, 0.0, 0.2)
          expect { compiled.public_send(method, nil, timeout: 0.1) }.to raise_error(Schemurai::LimitExceeded) { |error|
            expect(error.limit).to eq(:timeout)
          }
        end
      end

      it "does not treat discarded branch diagnostics as emitted errors", :aggregate_failures do
        schema = {"anyOf" => [false, true]}
        expect(Schemurai.validate(schema, nil, backend: backend, max_errors: 0).valid?).to be(true)
      end

      it "preserves independent limits in a shareable registry", :aggregate_failures do
        registry = Schemurai::SchemaRegistry.new(schemas: {"urn:limited" => {"items" => false}}, backend: backend)
        registry.compile({"items" => false}).validate([1])
        registry.compile(true).validate(nil)
        registry.make_shareable
        ractor = Ractor.new(registry) do |shared|
          shared.validator_for("urn:limited", max_errors: 1, timeout: 10).validate([1, 2])
        rescue Schemurai::LimitExceeded => error
          error.limit
        end
        result = ractor.respond_to?(:value) ? ractor.value : ractor.take
        expect(result).to eq(:max_errors)
      end
    end
  end

  it "rejects invalid kwargs and unknown options", :aggregate_failures do
    validator = Schemurai.compile(true)
    [-1, 1.5, "1", false].each do |value|
      expect { Schemurai.compile(true, max_errors: value) }.to raise_error(ArgumentError)
      expect { validator.validate(nil, max_errors: value) }.to raise_error(ArgumentError)
      expect { validator.valid?(nil, max_errors: value) }.to raise_error(ArgumentError)
    end
    [-1, Float::NAN, Float::INFINITY, -Float::INFINITY, "1", false, 10**1000].each do |value|
      expect { Schemurai.compile(true, timeout: value) }.to raise_error(ArgumentError)
      expect { validator.validate(nil, timeout: value) }.to raise_error(ArgumentError)
    end
    expect { Schemurai.compile(true, unknown: 1) }.to raise_error(ArgumentError)
    expect { Schemurai.compile(true, limits: {}) }.to raise_error(ArgumentError)
  end

  it "applies kwargs to explicit meta-schema validation", :aggregate_failures do
    expect { Schemurai.validate_schema({"type" => "integer"}, timeout: 0) }.to raise_error(Schemurai::LimitExceeded)
    expect { Schemurai.valid_schema?({"type" => "integer"}, timeout: 0) }.to raise_error(Schemurai::LimitExceeded)
    expect(Schemurai.valid_schema?({"type" => "unknown"}, max_errors: 0)).to be(false)
    expect(Schemurai.valid_schema?({"type" => "integer"}, max_errors: 0)).to be(true)
  end
end

# rubocop:enable RSpec/ExampleLength
