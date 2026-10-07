# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "uniqueItems" do
  [:ruby, :vm].each do |backend|
    context "with the #{backend} backend" do
      let(:validator) { Schemurai.compile({"uniqueItems" => true}, backend: backend) }
      let(:padding) { Array.new(20) { |index| "padding-#{index}" } }

      [
        ["integer and float", [1, 1.0]],
        ["signed zero", [0, -0.0]],
        ["fractional numbers", [1.5, 1.5]],
        ["large integral float", [2**100, (2**100).to_f]],
        ["nested numbers and reordered keys", [{"a" => [1, {"b" => 2}], "c" => nil}, {"c" => nil, "a" => [1.0, {"b" => 2.0}]}]]
      ].each do |name, pair|
        it "rejects duplicate #{name} in both array sizes", :aggregate_failures do
          [pair, padding + pair].each do |instance|
            expect(validator.valid?(instance)).to be(false)
            expect(validator.validate(instance).errors.map(&:keyword)).to eq(["uniqueItems"])
          end
        end
      end

      it "keeps types, array order, and large integer precision distinct", :aggregate_failures do
        instance = padding + [true, 1, "1", nil, false, [1, 2], [2, 1], 2**53, 2**53 + 1, 10**400, 10**400 + 1]
        expect(validator.valid?(instance)).to be(true)
        expect(validator.validate(instance)).to be_valid
      end

      it "resolves fingerprint collisions with JSON equality", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
        evaluator = validator.instance_variable_get(:@evaluator)
        allow(evaluator).to receive(:json_fingerprint).and_return(0)

        expect(validator.valid?(padding + [1, 2])).to be(true)
        expect(validator.validate(padding + [1, 2])).to be_valid
        expect(validator.valid?(padding + [1, 1.0])).to be(false)
        expect(validator.validate(padding + [1, 1.0]).errors.map(&:keyword)).to eq(["uniqueItems"])
      end

      it "rebuilds the index after instances change", :aggregate_failures do
        instance = padding + [{"id" => 1}, {"id" => 2}]
        expect(validator.valid?(instance)).to be(true)
        instance.last["id"] = 1.0
        expect(validator.validate(instance)).not_to be_valid
        expect(validator.valid?(instance)).to be(false)
      end

      it "preserves detailed error paths" do
        nested = Schemurai.compile({"properties" => {"items" => {"uniqueItems" => true}}}, backend: backend)
        error = nested.validate({"items" => padding + [1, 1.0]}).errors.first
        expect([error.keyword, error.instance_path, error.schema_path]).to eq(["uniqueItems", "/items", "/properties/items/uniqueItems"])
      end
    end
  end
end
