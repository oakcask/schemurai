# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Schemurai do
  def format_assertion_schema(required, format:)
    meta_schema_uri = "https://example.test/format-assertion/#{required}"
    meta_schema = {
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$id" => meta_schema_uri,
      "$vocabulary" => {
        "https://json-schema.org/draft/2020-12/vocab/core" => true,
        "https://json-schema.org/draft/2020-12/vocab/format-assertion" => required
      }
    }
    [{"$schema" => meta_schema_uri, "format" => format}, {meta_schema_uri => meta_schema}]
  end

  def expect_unsupported_format_to_be_rejected(required)
    schema, schemas = format_assertion_schema(required, format: "unknown")
    expect { described_class.compile(schema, schemas: schemas) }.to raise_error(
      Schemurai::UnsupportedFormatError,
      /unsupported format "unknown" required by Format-Assertion vocabulary/
    )
  end

  def nested_path_schema
    {
      "properties" => {
        "a/b" => {
          "allOf" => [
            {"properties" => {"~key" => {"type" => "integer", "minimum" => 2}}}
          ]
        }
      }
    }
  end

  def reference_path_schema
    {
      "properties" => {"x" => {"$ref" => "#/$defs/value"}},
      "$defs" => {"value" => {"type" => "integer"}}
    }
  end

  def expect_error(result, keyword:, instance_path:, schema_path:, message: nil)
    error = result.errors.fetch(0)
    expect(error).to have_attributes(keyword: keyword, instance_path: instance_path, schema_path: schema_path)
    expect(error.message).to eq(message) if message
  end

  def expect_nested_path_error(result)
    expect_error(
      result,
      keyword: "minimum",
      instance_path: "/a~1b/~0key",
      schema_path: "/properties/a~1b/allOf/0/properties/~0key/minimum"
    )
  end

  def expect_combiner_error(result)
    expect_error(
      result,
      keyword: "anyOf",
      instance_path: "",
      schema_path: "/anyOf",
      message: "value must match at least one subschema"
    )
  end

  def expect_reference_path_error(result)
    expect_error(result, keyword: "type", instance_path: "/x", schema_path: "/properties/x/$ref/type")
  end

  it "keeps implementation constants private" do
    expected = %i[
      Error InvalidSchemaError LimitExceeded ResolutionError Result SchemaRegistry UnsupportedFormatError VERSION ValidationError Validator
    ]
    expect(described_class.constants(false)).to match_array(expected)
  end

  it "exposes validator exceptions under one base error" do # rubocop:disable RSpec/ExampleLength
    error_classes = [
      described_class::Error,
      described_class::InvalidSchemaError,
      described_class::ResolutionError,
      described_class::UnsupportedFormatError
    ]
    expect(error_classes.map(&:superclass))
      .to eq([StandardError, described_class::Error, described_class::Error, described_class::Error])
  end

  it "offers boolean and detailed validation APIs", :aggregate_failures do
    schema = {"type" => "integer", "minimum" => 2}

    expect(described_class.valid?(schema, 3)).to be(true)
    result = described_class.validate(schema, 1)
    expect(result).not_to be_valid
    expect(result.errors.first).to be_a(described_class::ValidationError).and have_attributes(keyword: "minimum", instance_path: "")
  end

  it "reports escaped instance and schema paths for nested errors" do
    result = described_class.validate(nested_path_schema, {"a/b" => {"~key" => 1}})
    expect_nested_path_error(result)
  end

  it "only reports the committed error from failed alternatives" do
    schema = {"anyOf" => [{"type" => "integer"}, {"type" => "string", "minLength" => 5}]}
    result = described_class.validate(schema, "x")
    expect_combiner_error(result)
  end

  it "keeps the evaluation path when an error occurs through a reference" do
    result = described_class.validate(reference_path_schema, {"x" => "bad"})
    expect_reference_path_error(result)
  end

  it "resolves registered external schemas", :aggregate_failures do
    schema = {"$ref" => "https://example.test/integer"}
    schemas = {"https://example.test/integer" => {"type" => "integer"}}

    expect(described_class.valid?(schema, 1, schemas: schemas)).to be(true)
    expect(described_class.valid?(schema, "1", schemas: schemas)).to be(false)
  end

  it "validates repeatedly with a compiled schema", :aggregate_failures do
    validator = described_class.compile({"type" => "integer"})

    expect(validator.valid?(1)).to be(true)
    expect(validator.valid?("1")).to be(false)
    expect(validator.validate("1")).not_to be_valid
  end

  it "validates schemas against their declared meta-schema", :aggregate_failures do
    schema = {"$schema" => "https://json-schema.org/draft/2020-12/schema", "type" => "invalid"}

    result = described_class.validate_schema(schema)
    expect(result).not_to be_valid
    expect(result.errors.first).to have_attributes(instance_path: "/type", keyword: "anyOf")
    expect(described_class.valid_schema?(schema)).to be(false)
  end

  it "validates nested schemas and modern keyword values", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    schemas = [
      {
        "$schema" => "https://json-schema.org/draft/2019-09/schema",
        "properties" => {"value" => {"type" => "invalid"}}
      },
      {
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "required" => "value"
      }
    ]

    results = [:ruby, :vm].to_h do |backend|
      [backend, schemas.map { |schema| described_class.valid_schema?(schema, backend: backend) }]
    end
    expect(results).to eq(ruby: [false, false], vm: [false, false])
  end

  it "uses Draft 7 to validate schemas without a dialect declaration", :aggregate_failures do
    expect(described_class.valid_schema?({"type" => "integer"})).to be(true)
    expect(described_class.valid_schema?({"type" => "invalid"})).to be(false)
  end

  it "keeps schema validation opt-in during compilation", :aggregate_failures do
    schema = {"type" => "invalid"}

    expect { described_class.compile(schema) }.not_to raise_error
    expect { described_class.compile(schema, validate_schema: true) }
      .to raise_error(described_class::InvalidSchemaError) { |error| expect(error.result).not_to be_valid }
  end

  it "applies the registry schema-validation option to every compiled schema", :aggregate_failures do
    registry = described_class::SchemaRegistry.new(validate_schema: true)

    expect(registry).to be_validate_schema
    expect { registry.compile({"type" => "integer"}) }.not_to raise_error
    expect { registry.compile({"type" => "invalid"}) }.to raise_error(described_class::InvalidSchemaError)
  end

  it "validates every registered external schema when creating a registry", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    valid_schemas = {"urn:valid" => {"type" => "integer"}}
    invalid_schemas = {"urn:invalid" => {"type" => "invalid"}}

    registry = described_class::SchemaRegistry.new(schemas: valid_schemas, validate_schema: true)
    expect { registry.make_shareable }.not_to raise_error
    expect do
      described_class::SchemaRegistry.new(schemas: invalid_schemas, validate_schema: true)
    end.to raise_error(described_class::InvalidSchemaError)
  end

  it "passes schema validation through the convenience validation APIs", :aggregate_failures do
    schema = {"type" => "invalid"}

    expect { described_class.validate(schema, 1, validate_schema: true) }
      .to raise_error(described_class::InvalidSchemaError)
    expect { described_class.valid?(schema, 1, validate_schema: true) }
      .to raise_error(described_class::InvalidSchemaError)
  end

  it "uses registered custom meta-schemas", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    meta_schema_uri = "https://example.test/meta"
    meta_schema = {
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$id" => meta_schema_uri,
      "properties" => {"custom" => {"type" => "string"}}
    }
    schema = {"$schema" => meta_schema_uri, "custom" => 1}

    result = described_class.validate_schema(schema, schemas: {meta_schema_uri => meta_schema})
    expect(result).not_to be_valid
    expect(result.errors.first).to have_attributes(instance_path: "/custom", keyword: "type")
  end

  it "rejects an unavailable declared meta-schema consistently across backends", :aggregate_failures do
    schema = {"$schema" => "https://example.test/unavailable-meta-schema"}

    [:ruby, :vm].each do |backend|
      expect { described_class.validate_schema(schema, backend: backend) }
        .to raise_error(described_class::ResolutionError, /unresolvable reference/)
    end
  end

  it "reuses a validator after an instance method raises", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    numeric_class = Class.new(Numeric) do
      def finite? = raise("finite failed")
    end
    validator = described_class.compile({"type" => "integer"})

    expect { validator.valid?(numeric_class.new) }.to raise_error(RuntimeError, "finite failed")
    expect(validator.valid?(1)).to be(true)
    expect(validator.validate("bad")).not_to be_valid
  end

  it "uses independent validators concurrently" do # rubocop:disable RSpec/ExampleLength
    registry = described_class::SchemaRegistry.new
    validators = 4.times.map { registry.compile({"type" => "integer", "minimum" => 1}) }
    threads = validators.map do |validator|
      Thread.new { 100.times.map { |index| validator.valid?(index) }.count(true) }
    end

    expect(threads.map(&:value)).to eq([99, 99, 99, 99])
  end

  it "configures validators separately from the positional schema", :aggregate_failures do
    schema = {"type" => "string", "format" => "date"}
    annotation_validator = described_class.compile(schema)
    assertion_validator = described_class.compile(schema, format: true)

    expect(annotation_validator.valid?("not a date")).to be(true)
    expect(assertion_validator.valid?("not a date")).to be(false)
  end

  it "rejects schema keyword shorthand" do
    expect { described_class.compile(type: "string") }.to raise_error(ArgumentError)
  end

  it "shares registered schemas between compiled schemas" do
    registry = described_class::SchemaRegistry.new(schemas: {"urn:integer" => {"type" => "integer"}})
    validators = 2.times.map { registry.compile({"$ref" => "urn:integer"}) }
    results = [validators.first.valid?(1), validators.last.valid?("1")]
    expect(results).to eq([true, false])
  end

  it "reuses a compiled root for validators with different options", :aggregate_failures do
    registry = described_class::SchemaRegistry.new
    schema = {"format" => "date"}
    validators = [registry.compile(schema), registry.compile(schema, format: true)]

    expect(validators.first.valid?("not a date")).to be(true)
    expect(validators.last.valid?("not a date")).to be(false)
  end

  describe "shareable schema registries" do
    def validate_in_ractor(registry)
      Ractor.new(registry) do |shared_registry|
        validator = shared_registry.validator_for("urn:wrapper")
        [validator.valid?(1), validator.valid?(0)]
      end
    end

    let(:registry) do
      described_class::SchemaRegistry.new(
        schemas: {
          "urn:positive" => {"type" => "integer", "minimum" => 1},
          "urn:wrapper" => {"$ref" => "urn:positive"}
        }
      )
    end

    it "resolves registered schemas before becoming shareable", :aggregate_failures do
      expect(registry.make_shareable).to equal(registry)

      expect(registry).to be_shareable
      expect(Ractor.shareable?(registry)).to be(true)
      expect(registry.validator_for("urn:wrapper").valid?(1)).to be(true)
      expect(registry.validator_for("urn:wrapper").valid?(0)).to be(false)
    end

    it "can create separate validators in different Ractors" do
      registry.make_shareable
      ractors = 2.times.map { validate_in_ractor(registry) }
      results = ractors.map { |ractor| ractor.respond_to?(:value) ? ractor.value : ractor.take }

      expect(results).to eq([[true, false], [true, false]])
    end

    it "rejects mutation and unknown URIs after becoming shareable", :aggregate_failures do
      registry.make_shareable

      expect { registry.compile(true) }
        .to raise_error(Schemurai::Error, /cannot compile schemas/)
      expect { registry.validator_for("urn:missing") }
        .to raise_error(Schemurai::ResolutionError, /unregistered schema URI/)
    end

    it "requires sharing before retrieving validators by URI" do
      expect { registry.validator_for("urn:wrapper") }
        .to raise_error(Schemurai::Error, /make_shareable must be called/)
    end

    it "reports unresolved references while becoming shareable" do
      registry = described_class::SchemaRegistry.new(
        schemas: {"urn:wrapper" => {"$ref" => "urn:missing"}}
      )

      expect { registry.make_shareable }
        .to raise_error(Schemurai::ResolutionError, /unresolvable reference/)
    end

    it "freezes retained caller-owned schemas in place" do
      schema = {"$id" => "urn:value", "type" => "integer"}
      registry = described_class::SchemaRegistry.new(schemas: {"urn:value" => schema})

      registry.make_shareable

      expect(schema).to be_frozen
    end

    it "never reports shareable after an unexpected failed transition", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
      registry = described_class::SchemaRegistry.new(schemas: {"urn:value" => true})
      calls = 0
      original = Ractor.method(:make_shareable)
      allow(Ractor).to receive(:make_shareable) do |object|
        calls += 1
        raise TypeError, "injected shareability failure" if calls == 2

        original.call(object)
      end

      expect { registry.make_shareable }.to raise_error(TypeError, "injected shareability failure")
      expect(registry.shareable?).to eq(Ractor.shareable?(registry)).and be(false)
    end
  end

  it "keeps format as an annotation by default" do
    expect(described_class.valid?({"format" => "email"}, "not an email")).to be(true)
  end

  it "optionally asserts supported formats", :aggregate_failures do
    expect(described_class.valid?({"format" => "date"}, "2020-02-29", format: true)).to be(true)
    expect(described_class.valid?({"format" => "date"}, "2021-02-29", format: true)).to be(false)

    result = described_class.validate({"format" => "time"}, "24:00:00Z", format: true)
    expect(result).not_to be_valid
    expect(result.errors.first.to_h).to include(keyword: "format", schema_path: "/format")
  end

  it "supports format assertions with a reusable validator", :aggregate_failures do
    validator = described_class.compile({"format" => "date-time"}, format: true)

    expect(validator.valid?("1963-06-19T08:30:06Z")).to be(true)
    expect(validator.valid?("1963-06-19 08:30:06Z")).to be(false)
  end

  it "resolves the format when compiling a reusable validator", :aggregate_failures do
    schema = {"format" => "date"}
    validator = described_class.compile(schema, format: true)
    schema["format"] = "unknown"

    expect(validator.valid?("2020-02-29")).to be(true)
    expect(validator.valid?("2021-02-29")).to be(false)
  end

  it "ignores unknown formats in best-effort assertion mode" do
    expect(described_class.valid?({"format" => "unknown"}, "anything", format: true)).to be(true)
  end

  it "rejects unknown formats while compiling a Format-Assertion schema", :aggregate_failures do
    [true, false].each { |required| expect_unsupported_format_to_be_rejected(required) }
  end
end
