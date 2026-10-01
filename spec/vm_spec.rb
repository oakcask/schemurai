# frozen_string_literal: true

require_relative "spec_helper"
require "objspace"
require "timeout"

RSpec.describe "the VM backend" do
  it "keeps native instruction data behind the evaluator boundary", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    validator = Schemurai.compile(
      {"type" => "object", "properties" => {"name" => {"type" => "string"}}},
      backend: :vm
    )
    evaluator = validator.instance_variable_get(:@evaluator)
    vm = Schemurai.const_get(:VM)

    expect(vm.constants(false)).to contain_exactly(:Compiler, :Evaluator)
    expect(vm::Compiler.public_instance_methods(false)).to contain_exactly(:compile_all, :evaluator)
    expect(evaluator.instance_variables).to be_empty
    expect(vm::Evaluator.instance_method(:valid?).source_location).to be_nil
    expect(vm::Evaluator.instance_method(:validate).source_location).to be_nil
  end

  it "executes the compiled program after the source schema changes", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    schema = {"type" => "integer"}
    validator = Schemurai.compile(schema, backend: :vm)
    schema.clear

    expect(validator.valid?(1)).to be(true)
    expect(validator.valid?(1.5)).to be(false)
    expect(validator.validate(1.5).errors.map(&:keyword)).to eq(["type"])
  end

  it "does not publish a partially compiled program after compilation raises" do # rubocop:disable RSpec/ExampleLength
    registry = Schemurai::SchemaRegistry.new(backend: :vm)

    cases = [
      [{"type" => 1}, TypeError],
      [{"type" => "unknown"}, KeyError],
      [{"type" => ["string", "unknown"]}, KeyError],
      [{"$ref" => 1}, TypeError],
      [{"enum" => 1}, TypeError],
      [{"allOf" => 1}, TypeError],
      [{"properties" => 1}, TypeError],
      [{"patternProperties" => 1}, TypeError],
      [{"dependencies" => 1}, TypeError],
      [{"required" => 1}, TypeError],
      [{"$schema" => "https://json-schema.org/draft/2020-12/schema", "dependentRequired" => 1}, TypeError],
      [{"$schema" => "https://json-schema.org/draft/2020-12/schema", "dependentRequired" => {"x" => 1}}, TypeError],
      [{"$schema" => "https://json-schema.org/draft/2020-12/schema", "dependentSchemas" => 1}, TypeError]
    ]
    cases.each do |schema, error_class|
      2.times do
        expect { registry.compile(schema) }.to raise_error(error_class)
      end
    end
  end

  it "preserves Ruby string semantics for references containing null bytes", :aggregate_failures do
    schema = {"$ref" => "urn:missing\0#fragment"}
    validators = %i[ruby vm].map { |backend| Schemurai.compile(schema, backend: backend) }

    expect(validators.map { |validator| validator.valid?(nil) }).to eq([false, false])
    expect(validators.map { |validator| validator.validate(nil).errors.map(&:keyword) }).to eq([["$ref"], ["$ref"]])
  end

  it "preserves detailed errors for fused type and constraint instructions" do
    validator = Schemurai.compile({"type" => "integer", "minimum" => 0}, backend: :vm)

    expect(validator.validate(-1.5).errors.map(&:keyword)).to eq(%w[type minimum])
  end

  it "does not retain decimal conversions between validations" do # rubocop:disable RSpec/ExampleLength
    validator = Schemurai.compile({"multipleOf" => 0.1}, backend: :vm)
    GC.start
    before = ObjectSpace.each_object(Rational).count

    250.times { |index| validator.valid?(index + 0.12345) }
    GC.start

    expect(ObjectSpace.each_object(Rational).count - before).to be <= 1
  end

  it "checks unique scalar items in linear time", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    validator = Schemurai.compile({"uniqueItems" => true}, backend: :vm)
    values = Array.new(50_000) { |index| index }

    expect { Timeout.timeout(3) { validator.valid?(values) } }.not_to raise_error
    expect(validator.valid?([1, 1.0])).to be(false)
    expect(validator.valid?([-0.0, 0])).to be(false)
    expect(validator.valid?([false, 0])).to be(true)
    expect(validator.valid?([[1], [1.0]])).to be(false)
    expect(validator.valid?([{"value" => 1}, {"value" => 1.0}])).to be(false)
  end

  it "checks unique structured items in linear time", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    validator = Schemurai.compile({"uniqueItems" => true}, backend: :vm)
    values = Array.new(30_000) { |index| [{"value" => index.to_f}] }

    expect { Timeout.timeout(3) { validator.valid?(values) } }.not_to raise_error
    expect(validator.valid?([[{"value" => 1}], [{"value" => 1.0}]])).to be(false)
  end

  it "tracks large evaluated location sets in linear time" do # rubocop:disable RSpec/ExampleLength
    object_validator = Schemurai.compile(
      {
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "additionalProperties" => true,
        "unevaluatedProperties" => false
      },
      backend: :vm
    )
    array_validator = Schemurai.compile(
      {
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "items" => true,
        "unevaluatedItems" => false
      },
      backend: :vm
    )
    object = Array.new(30_000) { |index| ["key-#{index}", index] }.to_h
    array = Array.new(30_000, true)

    expect do
      Timeout.timeout(3) do
        raise "object annotation regression" unless object_validator.valid?(object)
        raise "array annotation regression" unless array_validator.valid?(array)
      end
    end.not_to raise_error
  end

  it "tracks recursive references in linear time without retained native buffers", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    schema = {
      "$id" => "urn:recursive-node",
      "type" => "object",
      "properties" => {"next" => {"$ref" => "urn:recursive-node"}}
    }
    validator = Schemurai.compile(schema, backend: :vm)
    evaluator = validator.instance_variable_get(:@evaluator)
    native_size = ObjectSpace.memsize_of(evaluator)
    instance = {}
    depth = Gem.win_platform? ? 20 : 500
    repetitions = Gem.win_platform? ? 5 : 200
    depth.times { instance = {"next" => instance} }

    expect { Timeout.timeout(3) { repetitions.times { raise "invalid recursive value" unless validator.valid?(instance) } } }
      .not_to raise_error
    expect(validator.validate(instance)).to be_valid

    GC.start
    GC.compact

    expect(ObjectSpace.memsize_of(evaluator)).to eq(native_size)
    retained_hash_sizes = ObjectSpace.reachable_objects_from(evaluator)
      .select { |object| object.instance_of?(Hash) && !object.empty? }
      .map(&:size)
    expect(retained_hash_sizes).to eq([1])
    retained_arrays = ObjectSpace.reachable_objects_from(evaluator).select { |object| object.instance_of?(Array) }
    expect(retained_arrays.length).to eq(1)
    expect(validator.valid?(instance)).to be(true)
  end

  it "keeps every native rule layout valid across GC compaction" do # rubocop:disable RSpec/ExampleLength
    schema = {
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "type" => "object",
      "allOf" => [{"required" => ["number", "text", "items"]}],
      "if" => {"properties" => {"enabled" => {"const" => true}}},
      "then" => {"dependentRequired" => {"enabled" => ["number"]}},
      "properties" => {
        "number" => {"type" => "number", "minimum" => 0, "multipleOf" => 0.25},
        "text" => {"type" => "string", "minLength" => 1, "pattern" => "^x"},
        "items" => {"type" => "array", "prefixItems" => [{"type" => "integer"}], "contains" => true}
      }
    }
    validator = Schemurai.compile(schema, backend: :vm)

    GC.verify_compaction_references(double_heap: true, toward: :empty)

    expect(validator.valid?({"enabled" => true, "number" => 1.25, "text" => "x", "items" => [1]})).to be(true)
  end

  it "retains young rule operands while compiling under minor GC stress" do # rubocop:disable RSpec/ExampleLength
    schema = {
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "type" => "object",
      "allOf" => [{"required" => ["items"]}],
      "if" => {"properties" => {"enabled" => {"const" => true}}},
      "then" => {"dependentRequired" => {"enabled" => ["items"]}},
      "properties" => {
        "items" => {
          "type" => "array",
          "prefixItems" => [{"type" => "integer"}],
          "items" => {"type" => "string"},
          "contains" => true
        },
        "text" => {"type" => "string", "pattern" => "^x"}
      },
      "patternProperties" => {"^number" => {"type" => "number"}},
      "dependentSchemas" => {"items" => {"required" => ["text"]}},
      "unevaluatedProperties" => false
    }
    previous_stress = GC.stress

    begin
      GC.stress = 1
      validator = Schemurai.compile(schema, backend: :vm)
    ensure
      GC.stress = previous_stress
    end

    expect(validator.valid?({"items" => [1, "tail"], "text" => "x"})).to be(true)
  end

  it "retains evaluator options while compiling under GC stress" do # rubocop:disable RSpec/ExampleLength
    previous_stress = GC.stress

    begin
      GC.stress = 1
      validator = Schemurai.compile(
        {"type" => "string", "format" => "date", "contentEncoding" => "base64"},
        backend: :vm,
        content: true,
        format: true
      )
    ensure
      GC.stress = previous_stress
    end

    expect(validator.valid?("not a date or base64")).to be(false)
  end

  it "preserves regexp encoding errors across validity and detailed evaluation" do # rubocop:disable RSpec/ExampleLength
    invalid_value = +"\xFF"
    invalid_value.force_encoding(Encoding::UTF_8)
    invalid_pattern = invalid_value.dup
    binary_name = "\xFF".b
    cases = [
      [{"pattern" => "."}, invalid_value],
      [{"pattern" => invalid_pattern}, "value"],
      [{"patternProperties" => {"." => false}}, {invalid_value => 1}],
      [{"patternProperties" => {"é" => false}}, {binary_name => 1}]
    ]
    normalize = lambda do |result|
      next result unless result.is_a?(Schemurai::Result)

      result.errors.map { |error| [error.keyword, error.instance_path, error.schema_path, error.message.class] }
    end

    cases.each do |schema, instance|
      ruby_validator = Schemurai.compile(schema, backend: :ruby)
      native_validator = Schemurai.compile(schema, backend: :vm)

      %i[valid? validate].each do |operation|
        expected = begin
          normalize.call(ruby_validator.public_send(operation, instance))
        rescue => error
          [error.class, error.message]
        end
        actual = begin
          normalize.call(native_validator.public_send(operation, instance))
        rescue => error
          [error.class, error.message]
        end

        expect(actual).to eq(expected)
      end
    end
  end

  it "releases recursive evaluation state when regexp matching raises", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    schema = {
      "$id" => "urn:exception-node",
      "type" => "object",
      "properties" => {
        "next" => {"$ref" => "urn:exception-node"},
        "value" => {"pattern" => "."}
      }
    }

    %i[valid? validate].each do |operation|
      validator = Schemurai.compile(schema, backend: :vm)
      evaluator = validator.instance_variable_get(:@evaluator)
      instance = {"value" => +"\xFF"}
      instance.fetch("value").force_encoding(Encoding::UTF_8)
      100.times { instance = {"next" => instance} }

      expect { validator.public_send(operation, instance) }.to raise_error(ArgumentError, /invalid byte sequence/)
      GC.start
      GC.compact

      retained = ObjectSpace.reachable_objects_from(evaluator)
      expect(retained.grep(Array)).to all(be_empty)
      expect(retained.grep(Hash).any? { |hash| hash.values.any?(Hash) }).to be(false)
      expect(validator.valid?({"value" => "ok"})).to be(true)
    end
  end

  it "propagates unexpected format exceptions and remains reusable", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    schema = {
      "$id" => "urn:format-callback",
      "type" => "object",
      "properties" => {
        "next" => {"$ref" => "urn:format-callback"},
        "value" => {"format" => "date"}
      }
    }
    instance = {"value" => "2026-09-04"}
    50.times { instance = {"next" => instance} }
    validators = %i[ruby vm].map { |backend| Schemurai.compile(schema, backend: backend, format: true) }
    formats = Schemurai.const_get(:Internal).const_get(:Formats)
    format_class = formats.resolve("date").class
    original_call = format_class.instance_method(:call)

    begin
      format_class.define_method(:call) do |_value|
        GC.start
        GC.compact
        raise "format callback failed"
      end
      validators.each do |validator|
        expect { validator.valid?(instance) }.to raise_error(RuntimeError, "format callback failed")
        expect { validator.validate(instance) }.to raise_error(RuntimeError, "format callback failed")
      end
    ensure
      format_class.define_method(:call, original_call)
    end

    expect(validators.map { |validator| validator.valid?(instance) }).to eq([true, true])
  end

  it "falls back for unsupported nested instance values reached by a program", :aggregate_failures do
    value = +"x"
    value.define_singleton_method(:length) { 2 }
    validator = Schemurai.compile({"properties" => {"value" => {"minLength" => 2}}}, backend: :vm)

    expect(validator.valid?({"value" => value})).to be(true)
    expect(validator.validate({"value" => value})).to be_valid
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

  it "collects applicator annotations only when unevaluated keywords need them" do # rubocop:disable RSpec/ExampleLength
    schema = {
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "anyOf" => [
        {"properties" => {"first" => true}},
        {"properties" => {"second" => true}}
      ],
      "unevaluatedProperties" => false
    }

    expect(Schemurai.valid?(schema, {"first" => 1, "second" => 2}, backend: :vm)).to be(true)
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
    GC.start
    GC.compact

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

    expect(compiler).to be_frozen
    expect(Ractor.shareable?(compiler)).to be(true)
    expect(compiler.instance_variables).to be_empty
    expect(first.valid?(1)).to be(true)
    expect(second.valid?("bad")).to be(false)
  end

  it "evaluates shared dynamic programs concurrently in independent Ractors" do # rubocop:disable RSpec/ExampleLength
    skip "Ruby #21537 can deadlock during Ractor GC on Windows" if Gem.win_platform? && RUBY_VERSION.start_with?("4.")

    schema = {
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$id" => "urn:node",
      "$dynamicAnchor" => "node",
      "type" => "object",
      "properties" => {"child" => {"$dynamicRef" => "#node"}}
    }
    registry = Schemurai::SchemaRegistry.new(schemas: {"urn:node" => schema}, backend: :vm)
    registry.make_shareable
    ractor_depth = Gem.win_platform? ? 1 : 100
    ractor_repetitions = 20
    ractor_count = Gem.win_platform? ? 1 : 4

    GC.start
    GC.compact

    ractors = ractor_count.times.map do
      Ractor.new(registry, ractor_depth, ractor_repetitions) do |shared, depth, repetitions|
        validator = shared.validator_for("urn:node")
        instance = {}
        depth.times { instance = {"child" => instance} }
        repetitions.times.all? { validator.valid?(instance) }
      end
    end

    expect(ractors.map { |ractor| ractor.respond_to?(:value) ? ractor.value : ractor.take }).to all(be(true))
  end
end
