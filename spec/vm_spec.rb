# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "the VM backend" do
  it "unions overlapping annotations and clears them between validations", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    schemas_and_instances = [
      [
        {"anyOf" => [
          {"properties" => {"a" => true}},
          {"properties" => {"a" => true, "b" => true}},
          {"properties" => {"extra" => true}, "required" => ["missing"]}
        ], "unevaluatedProperties" => false},
        {"a" => 1, "b" => 2}, {"extra" => 3}
      ],
      [
        {"allOf" => [
          {"prefixItems" => [true]},
          {"contains" => {"type" => "integer"}}
        ], "unevaluatedItems" => false},
        [1, 2, 3], [1, "extra"]
      ]
    ]
    schemas_and_instances.each do |schema, valid, invalid|
      schema = schema.merge("$schema" => "https://json-schema.org/draft/2020-12/schema")
      vm = Schemurai.compile(schema, backend: :vm)
      ruby = Schemurai.compile(schema, backend: :ruby)
      [valid, invalid, valid, invalid].each do |instance|
        expect(vm.valid?(instance)).to eq(ruby.valid?(instance))
        expect(vm.validate(instance).errors.map(&:to_h)).to eq(ruby.validate(instance).errors.map(&:to_h))
      end
    end
  end

  it "restores error paths after nested speculative branches", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    schema = {"properties" => {"a/b" => {
      "if" => {"anyOf" => [{"contains" => {"type" => "integer"}}, false]},
      "then" => {"items" => {"oneOf" => [{"type" => "integer"}, {"type" => "boolean"}]}},
      "else" => {"not" => true}
    }, "~key" => false}}
    vm = Schemurai.compile(schema, backend: :vm)
    ruby = Schemurai.compile(schema, backend: :ruby)

    [{"a/b" => [1, "bad"], "~key" => nil}, {"a/b" => ["bad"]}].each do |instance|
      expect(vm.validate(instance).errors.map(&:to_h)).to eq(ruby.validate(instance).errors.map(&:to_h))
      expect(vm.valid?(instance)).to be(false)
    end
  end

  it "compiles schema nodes into frozen instruction streams", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    validator = Schemurai.compile(
      {"type" => "object", "properties" => {"name" => {"type" => "string"}}},
      backend: :vm
    )
    evaluator = validator.instance_variable_get(:@evaluator)
    program = evaluator.instance_variable_get(:@root)
    object_rules = program.code.fetch(2)

    expect(program.code.fetch(1)).to eq(:typed_object)
    expect(program.code).to be_frozen
    expect(program.code).to all(be_frozen)
    expect(object_rules.properties.fetch("name").code.values_at(1, 2)).to eq([:type_string, nil])
  end

  it "executes the compiled program after the source schema changes", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    schema = {"type" => "integer"}
    validator = Schemurai.compile(schema, backend: :vm)
    schema.clear

    expect(validator.valid?(1)).to be(true)
    expect(validator.valid?(1.5)).to be(false)
    expect(validator.validate(1.5).errors.map(&:keyword)).to eq(["type"])
  end

  it "preserves detailed errors for fused type and constraint instructions" do
    validator = Schemurai.compile({"type" => "integer", "minimum" => 0}, backend: :vm)

    expect(validator.validate(-1.5).errors.map(&:keyword)).to eq(%w[type minimum])
  end

  it "restores detailed paths after annotation-only validity checks", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    schema = {
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "properties" => {"known" => true},
      "unevaluatedProperties" => false
    }
    validator = Schemurai.compile(schema, backend: :vm)
    instance = {"known" => 1, "extra" => 2}

    expect(validator.valid?(instance)).to be(false)
    expect(validator.validate(instance).errors.map { |error| [error.instance_path, error.schema_path] })
      .to eq([["/extra", "/unevaluatedProperties"]])
  end

  it "snapshots nested mutable operands without freezing the source schema", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    schema = {
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "type" => ["object"],
      "required" => [+"kind", +"value"],
      "properties" => {
        "kind" => {"enum" => [{"tag" => ["fixed"]}]},
        "value" => {"const" => {"tag" => ["fixed"]}},
        "name" => {"type" => "string", "pattern" => +"^fixed$"}
      },
      "dependentRequired" => {"kind" => ["name"]}
    }
    enum_value = schema.dig("properties", "kind", "enum", 0, "tag")
    const_value = schema.dig("properties", "value", "const", "tag")
    pattern = schema.dig("properties", "name", "pattern")
    required_kind = schema.fetch("required").first
    validator = Schemurai.compile(schema, backend: :vm)

    valid = {"kind" => {"tag" => ["fixed"]}, "value" => {"tag" => ["fixed"]}, "name" => "fixed"}
    invalid = [
      [],
      {},
      valid.merge("kind" => {"tag" => ["changed"]}),
      valid.merge("value" => {"tag" => ["changed"]}),
      valid.merge("name" => "changed"),
      valid.except("kind"),
      valid.except("name")
    ]
    expect(validator.valid?(valid)).to be(true)
    expect(invalid.map { |instance| validator.valid?(instance) }).to all(be(false))

    schema.fetch("type") << "array"
    required_kind.replace("value")
    enum_value.replace(["changed"])
    const_value.replace(["changed"])
    pattern.replace(".*")
    schema.dig("dependentRequired", "kind").clear

    expect(validator.valid?(valid)).to be(true)
    expect(invalid.map { |instance| validator.valid?(instance) }).to all(be(false))
    expect(schema.fetch("type")).not_to be_frozen
  end

  it "keeps a resolved external program stable after its source changes", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    external = {"type" => ["integer"]}
    registry = Schemurai::SchemaRegistry.new(schemas: {"urn:external" => external}, backend: :vm)
    validator = registry.compile({"$ref" => "urn:external"})

    expect(validator.valid?(1)).to be(true)
    expect(validator.valid?("text")).to be(false)

    external.fetch("type") << "string"

    expect(validator.valid?(1)).to be(true)
    expect(validator.valid?("text")).to be(false)
  end

  it "compiles and shares one program graph for all validators", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    registry = Schemurai::SchemaRegistry.new(
      schemas: {
        "urn:wrapper" => {"$ref" => "urn:value"},
        "urn:value" => {"type" => "integer"}
      },
      backend: :vm
    )

    registry.make_shareable
    first = registry.validator_for("urn:wrapper")
    second = registry.validator_for("urn:wrapper")
    compiler = registry.instance_variable_get(:@compiler)
    first_evaluator = first.instance_variable_get(:@evaluator)
    second_evaluator = second.instance_variable_get(:@evaluator)

    expect(compiler).to be_frozen
    expect(Ractor.shareable?(compiler)).to be(true)
    expect(first_evaluator.instance_variable_get(:@compiler)).to equal(compiler)
    expect(second_evaluator.instance_variable_get(:@compiler)).to equal(compiler)
    expect(first_evaluator.instance_variable_get(:@root)).to equal(second_evaluator.instance_variable_get(:@root))
    expect(first.valid?(1)).to be(true)
    expect(second.valid?("bad")).to be(false)
  end
end
