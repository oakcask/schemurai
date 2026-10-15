# frozen_string_literal: true

require "spec_helper"
require "base64"
require "objspace"
require "open3"
require "rbconfig"
require_relative "../oracle/lib/case_catalog"

RSpec.describe "native VALUE execution" do
  it "stops native evaluation and diagnostics cooperatively without VM delegation" do # rubocop:disable RSpec/ExampleLength
    validator = Schemurai.compile({"items" => {"type" => "integer"}}, backend: :native)
    # Keep Ruby's clock fixed so the exhaustion assertion specifically tests Rust.
    allow(Process).to receive(:clock_gettime).and_call_original
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(0.0)
    budgets = []
    budget_class = Schemurai.const_get(:Internal).const_get(:LimitBudget)
    allow(budget_class).to receive(:new).and_wrap_original do |original, *args, **options|
      budget = original.call(*args, **options)
      allow(budget).to receive(:raise_native_limit).and_call_original
      budgets << budget
      budget
    end
    allow(Schemurai.const_get(:VM).const_get(:LimitedEvaluator)).to receive(:new).and_raise("VM execution fallback")
    [:valid?, :validate].each do |method|
      expect { validator.public_send(method, Array.new(2_000_000, 1), timeout: 0.001) }.to raise_error(Schemurai::LimitExceeded) { |error|
        expect(error.limit).to eq(:timeout)
      }
      expect(budgets.last).to have_received(:raise_native_limit).with(2, 0)
    end
    definitions = {"n0" => false}
    1.upto(24) { |i| definitions["n#{i}"] = {"allOf" => Array.new(2) { {"$ref" => "#/$defs/n#{i - 1}"} }} }
    diagnostic = Schemurai.compile({"$defs" => definitions, "$ref" => "#/$defs/n24"}, backend: :native)
    expect { diagnostic.validate(nil, timeout: 0.005) }.to raise_error(Schemurai::LimitExceeded) { |error|
      expect(error.limit).to eq(:timeout)
    }
    expect(budgets.last).to have_received(:raise_native_limit).with(2, 0)
    expect(validator.valid?([1], timeout: 10)).to be(true)
    expect(validator.validate([1], timeout: 10).valid?).to be(true)
  end

  it "applies independent kwargs defaults and exact error boundaries", :aggregate_failures do
    validator = Schemurai.compile({"items" => false}, backend: :native, max_errors: 1, timeout: 0)
    expect { validator.validate([1, 2], max_errors: nil) }.to raise_error(Schemurai::LimitExceeded) { |error|
      expect(error.limit).to eq(:timeout)
    }
    expect { validator.validate([1, 2], timeout: nil) }.to raise_error(Schemurai::LimitExceeded) { |error|
      expect([error.limit, error.maximum, error.attempted]).to eq([:max_errors, 1, 2])
    }
    expect(validator.validate([1], timeout: nil).errors.length).to eq(1)
    expect(validator.validate([1, 2], max_errors: nil, timeout: nil).errors.length).to eq(2)
    expect(validator.valid?([1, 2], timeout: nil)).to be(false)
    expect { validator.validate([1], max_errors: 0, timeout: nil) }.to raise_error(Schemurai::LimitExceeded)
    expect(validator.validate([], max_errors: 0, timeout: nil).valid?).to be(true)
  end

  it "retains the original duration deadline when native transfers to VM", :aggregate_failures do
    validator = Schemurai.compile({"type" => "array", "minItems" => 0, "items" => true}, backend: :native)
    value = Class.new(Array).new
    allow(Process).to receive(:clock_gettime).and_call_original
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(0.0)
    vm = Schemurai.const_get(:VM).const_get(:LimitedEvaluator)
    allow(vm).to receive(:new).and_wrap_original do |original, *args, **options|
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(0.2)
      original.call(*args, **options)
    end
    expect { validator.valid?(value, timeout: 0.1) }.to raise_error(Schemurai::LimitExceeded) { |error|
      expect(error.limit).to eq(:timeout)
      expect(error.attempted).to eq(0.2)
    }
    expect(vm).to have_received(:new).once
  end

  it "includes Ruby message rendering in the original duration budget", :aggregate_failures do
    validator = Schemurai.compile(false, backend: :native)
    renderer = Schemurai.const_get(:Native).const_get(:Diagnostics)
    allow(Process).to receive(:clock_gettime).and_call_original
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(0.0)
    allow(renderer).to receive(:error).and_wrap_original do |original, *args|
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(0.2)
      original.call(*args)
    end
    expect { validator.validate(nil, timeout: 0.1) }.to raise_error(Schemurai::LimitExceeded) { |error|
      expect(error.limit).to eq(:timeout)
    }
    expect(renderer).to have_received(:error).once
  end

  it "enforces native limits without routing bounded calls through the Ruby evaluator" do # rubocop:disable RSpec/ExampleLength
    ruby_limited = Schemurai.const_get(:Internal).const_get(:LimitedEvaluator)
    allow(ruby_limited).to receive(:new).and_raise("Ruby execution fallback")
    validator = Schemurai.compile({"items" => false}, backend: :native, max_errors: 1)
    allow(Schemurai.const_get(:VM).const_get(:LimitedEvaluator)).to receive(:new).and_raise("VM execution fallback")
    program = validator.instance_variable_get(:@evaluator).instance_variable_get(:@program)
    allow(program).to receive(:diagnostics).and_raise("unbounded diagnostics")
    expect { validator.validate([1, 2]) }.to raise_error(Schemurai::LimitExceeded) { |error|
      expect(error.limit).to eq(:max_errors)
    }
    expect(validator.validate([1]).errors.length).to eq(1)
    expect(validator.valid?([1])).to be(false)
    expect(validator.backend).to eq(:native)
  end

  it "interrupts exponentially expanding failing diagnostics during native collection" do # rubocop:disable RSpec/ExampleLength
    definitions = {"n0" => false}
    1.upto(32) { |i| definitions["n#{i}"] = {"allOf" => Array.new(2) { {"$ref" => "#/$defs/n#{i - 1}"} }} }
    validator = Schemurai.compile({"$defs" => definitions, "$ref" => "#/$defs/n32"}, backend: :native)
    [:max_errors].each do |cap|
      expect { validator.validate(nil, **{cap => 100}) }.to raise_error(Schemurai::LimitExceeded) { |error|
        expect(error.limit).to eq(cap)
      }
    end
  end

  it "keeps native type, numeric and scope masks compatible with the Ruby compiler", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    Schemurai.compile(true, backend: :native)
    native = Schemurai.const_get(:Native)::Protocol
    vm = Schemurai.const_get(:VM)
    %i[TYPE_NULL TYPE_BOOLEAN TYPE_OBJECT TYPE_ARRAY TYPE_NUMBER TYPE_INTEGER TYPE_STRING
      MAXIMUM MINIMUM EXCLUSIVE_MAXIMUM EXCLUSIVE_MINIMUM MULTIPLE_OF TRACKS_EVALUATION TRACKS_DYNAMIC_SCOPE].each do |name|
      expect(native.const_get(name)).to eq(vm.const_get(name)), name.to_s
    end
  end

  let(:vm_class) do
    Schemurai.const_get(:Backend).load_vm!
    Schemurai.const_get(:VM)::Evaluator
  end

  def capture_validation(validator, method, value, **options)
    result = validator.public_send(method, value, **options)
    [:result, (method == :validate) ? result.errors : result]
  rescue => error
    [:error, error.class, error.message]
  end

  def expect_native_policy_results(schemas, values, **options)
    cases = schemas.map do |schema|
      vm = Schemurai.compile(schema, backend: :vm, **options)
      [Schemurai.compile(schema, backend: :native, **options), values.map { |value| [vm.valid?(value), vm.validate(value).errors] }]
    end
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |native, expected|
      values.zip(expected).each do |value, (valid, errors)|
        expect(native.valid?(value)).to eq(valid), value.inspect
        expect(native.validate(value).errors).to eq(errors), value.inspect
      end
    end
  end

  it "evaluates input-independent schemas and boolean children without VM execution" do # rubocop:disable RSpec/ExampleLength
    special = Class.new do
      def is_a?(*) = raise("instance type queried")
      def class = raise("instance class queried")
      def hash = raise("instance hash queried")
      def ==(*) = raise("instance equality queried")
      def inspect = raise("instance inspected")
    end.new
    cycle = []
    cycle << cycle
    hash = {Object.new => special}
    hash["cycle"] = hash
    values = [BasicObject.new, special, Class.new(String).new("value"), Class.new(Array).new,
      Class.new(Hash).new, Rational(1, 2), Complex(1, 2), :value, cycle, hash, nil, 1]
    rules = [true, false, {}, {"not" => false}, {"not" => true}, {"allOf" => [true, false]},
      {"anyOf" => [false, true]}, {"oneOf" => [true, true]}, {"if" => false, "then" => false, "else" => true},
      {"$defs" => {"value" => false}, "$ref" => "#/$defs/value"}, {"$ref" => "#/missing"},
      {"$defs" => {"value" => {"$ref" => "#/$defs/value"}}, "$ref" => "#/$defs/value"},
      {"$schema" => "https://json-schema.org/draft/2020-12/schema", "$defs" => {"value" => {"$dynamicAnchor" => "value", "allOf" => [false]}},
       "$dynamicRef" => "#value"}]
    wrappers = [->(rule, value) { [rule, value] }, ->(rule, value) { [{"items" => rule}, [value]] },
      ->(rule, value) { [{"properties" => {"x" => rule}}, {"x" => value}] },
      ->(rule, value) { [{"patternProperties" => {"^x$" => rule}}, {"x" => value}] },
      ->(rule, value) { [{"contains" => rule}, [value]] }]
    combinations = values.product([:valid?, :validate], [{}, {timeout: 10}, {max_errors: 0}, {max_errors: 1}])
    cases = rules.product(wrappers).map do |rule, wrap|
      schema = wrap.call(rule, nil).first
      vm = Schemurai.compile(schema, backend: :vm)
      [Schemurai.compile(schema, backend: :native), combinations.map do |value, method, options|
        input = wrap.call(rule, value).last
        [input, method, options, capture_validation(vm, method, input, **options)]
      end]
    end
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    cases.each do |native, inputs|
      inputs.each do |input, method, options, expected|
        expect(capture_validation(native, method, input, **options)).to eq(expected)
      end
    end
  end

  it "classifies only reached instance-dependent branches" do # rubocop:disable RSpec/ExampleLength
    value = Class.new do
      def is_a?(*) = raise("reached type query")
    end.new
    typed = {"type" => "integer"}
    cases = [[{"anyOf" => [true, typed]}, true], [{"allOf" => [false, typed]}, false],
      [{"if" => true, "then" => false, "else" => typed}, false],
      [{"if" => false, "then" => typed, "else" => true}, true],
      [{"oneOf" => [true, true, typed]}, false], [{"allOf" => [true, typed]}, nil]].map do |schema, verdict|
      vm = Schemurai.compile(schema, backend: :vm)
      native = Schemurai.compile(schema, backend: :native)
      [native, verdict, [:valid?, :validate].map { |method| capture_validation(vm, method, value) }]
    end
    cases.each do |native, _verdict, expected|
      program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
      expect(capture_validation(program, :valid?, value)).to eq(expected.first)
      [:valid?, :validate].zip(expected).each do |method, result|
        expect(capture_validation(native, method, value)).to eq(result)
        expect(capture_validation(native, method, value, timeout: 10)).to eq(result)
      end
    end
  end

  it "guards every Hash key before sharing a record kind with sibling branches" do
    schema = {"anyOf" => [{"maxProperties" => 0, "properties" => {"x" => true}},
      {"required" => ["x"], "properties" => 9.times.to_h { |i| ["p#{i}", true] }}]}
    value = {"x" => 1, :foreign => 2}
    native = Schemurai.compile(schema, backend: :native)
    vm = Schemurai.compile(schema, backend: :vm)
    runner = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
    expect(runner.valid?(value)).to be_nil
    expect(native.valid?(value)).to eq(vm.valid?(value))
    expect(native.validate(value).errors).to eq(vm.validate(value).errors)
  end

  it "shares input-independent native programs between Ractor runners" do
    schema = {"$defs" => {"value" => false}, "allOf" => [{"$ref" => "#/$defs/value"}, {"not" => true}]}
    registry = Schemurai::SchemaRegistry.new(schemas: {"urn:boolean" => schema}, backend: :native).make_shareable
    workers = Array.new(2) do
      Ractor.new(registry) do |shared|
        validator = shared.validator_for("urn:boolean")
        runner = validator.instance_variable_get(:@evaluator).instance_variable_get(:@program)
        value = BasicObject.new
        GC.start
        [runner.valid?(value), runner.diagnostics(value).map(&:first)]
      end
    end
    workers.each { |worker| expect(worker.respond_to?(:value) ? worker.value : worker.take).to eq([false, %w[falseSchema not]]) }
  end

  it "checks special Ruby values with single and union type predicates without VM execution" do # rubocop:disable RSpec/ExampleLength
    names = %w[null boolean object array number integer string]
    types = names + (0...128).map { |mask| names.each_with_index.filter_map { |name, bit| name if (mask & (1 << bit)) != 0 } }
    fake = Object.new
    fake.define_singleton_method(:is_a?) { |klass| klass == String }
    numeric = Class.new(Numeric) do
      def finite? = true
      def to_i = 2
      def ==(other) = other == 2
    end.new
    private_query_class = Class.new do
      private def is_a?(*) = true
    end
    stub_const("NativePrivateTypeQuery", private_query_class)
    private_query = private_query_class.new
    null_like = Object.new
    null_like.define_singleton_method(:nil?) { 0 }
    boolean_like = Object.new
    boolean_like.define_singleton_method(:==) { |_other| [] }
    values = [BasicObject.new, Class.new.new, Object.new, :value, Rational(1, 2), Rational(2, 1), Complex(1, 2), numeric, fake,
      private_query, null_like, boolean_like,
      Class.new(String).new("value"), Class.new(Array).new([1]), Class.new(Hash)["x", 1], {Object.new => 1},
      nil, false, true, 1, 1.5, "value", [], {}]
    wrappers = [->(rule, value) { [rule, value] }, ->(rule, value) { [{"items" => rule}, [value]] },
      ->(rule, value) { [{"properties" => {"x" => rule}}, {"x" => value}] },
      ->(rule, value) { [{"contains" => rule}, [value]] }]
    combinations = values.product([:valid?, :validate], [{}, {timeout: 10}, {max_errors: 0}])
    cases = types.product(wrappers).map do |type, wrap|
      rule = {"type" => type}
      schema = wrap.call(rule, nil).first
      vm = Schemurai.compile(schema, backend: :vm)
      [Schemurai.compile(schema, backend: :native), combinations.map do |value, method, options|
        input = wrap.call(rule, value).last
        [input, method, options, capture_validation(vm, method, input, **options)]
      end]
    end
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    cases.each do |native, inputs|
      inputs.each do |input, method, options, expected|
        expect(capture_validation(native, method, input, **options)).to eq(expected)
      end
    end
  end

  it "preserves stateful type calls and messages across repeated branches and references" do # rubocop:disable RSpec/ExampleLength
    value_class = Class.new do
      attr_reader :trace

      def initialize
        @trace = []
        @calls = 0
      end

      def is_a?(type)
        @trace << ["is_a?", type.name]
        @calls += 1
        type == String && @calls.even?
      end

      def class
        @trace << ["class"]
        @calls += 1
        Object
      end
    end
    wrap = lambda do |shape, value|
      case shape
      when :object then {"x" => value}
      when :array then [value, value]
      else value
      end
    end
    single = {"type" => "string"}
    object = {"properties" => {"x" => single}}
    cases = [[{"allOf" => [single, single]}, :scalar], [{"anyOf" => [single, single]}, :scalar],
      [{"oneOf" => [single, single]}, :scalar], [{"allOf" => [single, {"type" => ["string"]}]}, :scalar],
      [{"$defs" => {"t" => single}, "allOf" => [{"$ref" => "#/$defs/t"}, {"$ref" => "#/$defs/t"}]}, :scalar],
      [{"anyOf" => [object, object]}, :object], [{"oneOf" => [object, object]}, :object],
      [{"items" => single}, :array], [{"contains" => single}, :array]].map do |schema, shape|
      vm = Schemurai.compile(schema, backend: :vm)
      native = Schemurai.compile(schema, backend: :native)
      combinations = [:valid?, :validate].product([{}, {timeout: 10}, {max_errors: 0}, {max_errors: 1}])
      inputs = combinations.map do |method, options|
        value = value_class.new
        input = wrap.call(shape, value)
        [method, options, capture_validation(vm, method, input, **options), value.trace]
      end
      [native, shape, inputs]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    cases.each do |native, shape, inputs|
      inputs.each do |method, options, expected, trace|
        value = value_class.new
        input = wrap.call(shape, value)
        expect(capture_validation(native, method, input, **options)).to eq(expected), [shape, method, options].inspect
        expect(value.trace).to eq(trace)
      end
    end
  end

  it "does not use dynamic type success as a native collection storage proof" do
    value = Object.new
    value.define_singleton_method(:is_a?) { |type| type == Array }
    value.define_singleton_method(:length) { raise "Ruby collection method reached" }
    schema = {"allOf" => [{"type" => "array"}, {"minItems" => 1}]}
    vm = Schemurai.compile(schema, backend: :vm)
    native = Schemurai.compile(schema, backend: :native)
    runner = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
    expect { runner.valid?(value) }.to raise_error("Ruby collection method reached")
    [:valid?, :validate].each do |method|
      expect(capture_validation(native, method, value)).to eq(capture_validation(vm, method, value))
    end
  end

  it "keeps type callbacks safe during compaction and method changes" do
    value_class = Class.new(String) do
      def is_a?(type)
        GC.verify_compaction_references(double_heap: true, toward: :empty)
        type == String
      end
    end
    value = value_class.new("value")
    schema = {"type" => ["integer", "string"]}
    native = Schemurai.compile(schema, backend: :native)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    expect(native.valid?(value)).to be(true)
    expect(native.validate(value).errors).to be_empty
    value_class.define_method(:is_a?) { |_type| false }
    expect(native.valid?(value)).to be(false)
    # The type message still uses Ruby's physical String case classification.
    expect(native.validate(value).errors.map(&:keyword)).to eq(["type"])
  end

  it "runs dynamic type predicates in independent Ractor runners" do
    registry = Schemurai::SchemaRegistry.new(schemas: {"urn:type" => {"type" => ["integer", "null"]}}, backend: :native).make_shareable
    workers = Array.new(2) do
      Ractor.new(registry) do |shared|
        validator = shared.validator_for("urn:type")
        runner = validator.instance_variable_get(:@evaluator).instance_variable_get(:@program)
        value = Rational(1, 2)
        GC.start
        [runner.valid?(value), runner.diagnostics(value).map(&:first)]
      end
    end
    workers.each { |worker| expect(worker.respond_to?(:value) ? worker.value : worker.take).to eq([false, ["type"]]) }
  end

  it "validates plain Object and Symbol scalar types without VM execution" do
    object = Object.new
    object.instance_variable_set(:@cycle, object)
    symbols = [:identity, :"native_identity_#{Process.pid}"]
    rules = [true, false, {"type" => %w[null boolean object array number integer string]},
      {"allOf" => [{"not" => {"type" => "number"}}, {"anyOf" => [{"type" => "string"}, true]}]}]
    rules += %w[null boolean object array number integer string].map { |type| {"type" => type} }
    schemas = rules + rules.map { |rule| {"items" => rule} } + rules.map { |rule| {"properties" => {"value" => rule}} }
    values = [object, Object.new, *symbols]
    expect_native_policy_results(schemas, values + values.map { |value| [value] } + values.map { |value| {"value" => value} })
  end

  it "checks scalar assertion adapters for plain Object and Symbol values" do
    scalars = [Object.new, :identity, :"native_identity_adapter_#{Process.pid}"]
    rules = [{"minimum" => 0, "maximum" => 1, "multipleOf" => 2}, {"minLength" => 1, "maxLength" => 2},
      {"pattern" => "^a$"}, {"format" => "date"}, {"contentMediaType" => "application/json"},
      {"contentEncoding" => "base64"}, {"required" => ["id"], "additionalProperties" => false}]
    schemas = rules.flat_map { |rule| [rule, {"items" => rule}, {"items" => rule.merge("type" => "string")}] }
    values = scalars + scalars.map { |value| [value, "bad"] } + scalars.map { |value| [value, "a"] }
    expect_native_policy_results(schemas, values, format: true, content: true)
  end

  it "compares identity scalars with JSON constants and structural uniqueness" do
    scalars = Array.new(24) { Object.new } + Array.new(24) { |i| :"native_identity_enum_#{Process.pid}_#{i}" }
    schemas = [{"const" => 0}, {"const" => "identity"}, {"const" => [0, 1]},
      {"enum" => (0...16).to_a}, {"enum" => (0...24).to_a},
      {"enum" => Array.new(24) { |value| {"value" => [value]} }}, {"uniqueItems" => true}]
    values = [scalars.first, scalars.last, Object.new, :other, scalars, scalars + [scalars.first],
      [scalars.first, scalars.last], {"value" => [scalars.last]}, [{"value" => scalars.first}, {"value" => scalars.first}]]
    expect_native_policy_results(schemas, values)
  end

  it "keeps identity scalars native under budgets, compaction and instance changes" do
    schema = {"items" => {"anyOf" => [{"type" => "number"}, {"not" => {"type" => "string"}}]}, "uniqueItems" => true}
    object = Object.new
    values = [object, :identity, Object.new]
    native = Schemurai.compile(schema, backend: :native)
    vm = Schemurai.compile(schema, backend: :vm)
    expected = [vm.valid?(values), vm.validate(values).errors]
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    expect(native.valid?(values, timeout: 10)).to eq(expected.first)
    expect(native.validate(values, max_errors: 1, timeout: 10).errors).to eq(expected.last)
    object.instance_variable_set(:@cycle, values)
    values << object
    expect(native.valid?(values, timeout: 10)).to be(false)
    expect(native.validate(values, timeout: 10).errors.map(&:keyword)).to eq(["uniqueItems"])
  end

  it "keeps identity scalar uniqueness native in independent Ractor runners" do
    registry = Schemurai::SchemaRegistry.new(schemas: {"urn:identity" => {"uniqueItems" => true}}, backend: :native).make_shareable
    workers = Array.new(2) do
      Ractor.new(registry) do |shared|
        validator = shared.validator_for("urn:identity")
        runner = validator.instance_variable_get(:@evaluator).instance_variable_get(:@program)
        object = Object.new
        values = [object, :identity, Object.new]
        GC.start
        first = runner.valid?(values)
        values << object
        [first, runner.valid?(values), runner.diagnostics(values).map(&:first)]
      end
    end
    workers.each { |worker| expect(worker.respond_to?(:value) ? worker.value : worker.take).to eq([true, false, ["uniqueItems"]]) }
  end

  it "preserves class-wide overrides on identity scalar methods" do # rubocop:disable RSpec/ExampleLength
    script = <<~RUBY
      require "schemurai"
      klass = Object.const_get(ARGV.fetch(0))
      method = ARGV.fetch(1)
      value = klass == Symbol ? :identity : Object.new
      schema = method == "is_a?" ? {"type" => "string"} : {"uniqueItems" => true}
      input = if method == "is_a?"
        value
      elsif method == "hash"
        [*(0...17), {"unused" => value}]
      else
        [value, value]
      end
      vm = Schemurai.compile(schema, backend: :vm)
      native = Schemurai.compile(schema, backend: :native)
      runner = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
      original_class = Object.instance_method(:class)
      klass.define_method(method) { |*| raise "class-wide override" }
      capture = lambda do |validator|
        validator.valid?(input).to_s
      rescue => error
        [original_class.bind_call(error).name, error.message]
      end
      expected = capture.call(vm)
      abort "native bypassed an overridden method" unless capture.call(runner) == expected
      abort "different override behavior" unless capture.call(native) == expected
      puts "ok"
    RUBY
    %w[Object Symbol].product(%w[== hash is_a? class instance_of?]).each do |klass, method|
      output, errors, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-Iext/schemurai_native", "-e", script, klass, method)
      expect(status.success?).to be(true), errors
      expect(output).to eq("ok\n")
    end
  end

  it "reuses guarded kinds across same-location applicators and rechecks mutations" do # rubocop:disable RSpec/ExampleLength
    dialect = {"$schema" => "https://json-schema.org/draft/2020-12/schema"}
    integer = {"type" => "integer", "minimum" => 1}
    object = {"properties" => {"x" => integer}, "required" => ["x"]}
    schemas = [{"anyOf" => [integer, object]}, {"oneOf" => [integer, object]},
      {"allOf" => [object, {"not" => integer}]}, {"if" => integer, "then" => false, "else" => object},
      {"$defs" => {"object" => object}, "$ref" => "#/$defs/object"}].map { |schema| dialect.merge(schema) }
    expect_native_policy_results(schemas, [{"x" => 1}, {"x" => 0}, {}, 1, "bad"])
    native = Schemurai.compile(schemas.first, backend: :native)
    runner = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
    value = {"x" => 1}
    expect(runner.valid?(value)).to be(true)
    value[:foreign] = 1
    expect(runner.valid?(value)).to be_nil
    expect(runner.diagnostics(value)).to be_nil
  end

  it "merges sparse property words across distant global IDs and overlapping branches" do # rubocop:disable RSpec/ExampleLength
    dialect = {"$schema" => "https://json-schema.org/draft/2020-12/schema"}
    padding = 4096.times.to_h { |i| ["unused#{i}", true] }
    item = {"anyOf" => [{"properties" => {"x" => true}}, {"properties" => {"x" => true, "y" => true}}],
            "unevaluatedProperties" => false}
    schema = dialect.merge("allOf" => [{"properties" => padding}, {"properties" => {"records" => {"items" => item}}}])
    words = dialect.merge("allOf" => [{"properties" => {"x" => true}}, {"properties" => padding},
      {"properties" => {"y" => true}}, {"properties" => {"x" => true}}], "unevaluatedProperties" => false)
    expect_native_policy_results([schema, words], [{"records" => [{"x" => 1}, {"x" => 1, "y" => 2}]},
      {"records" => [{"x" => 1, "extra" => 2}]}, {"records" => [{}]}, {"x" => 1, "y" => 2}, {}, {"extra" => 1}])
  end

  it "shares static reference successes without suppressing distinct failure paths or later fallback" do # rubocop:disable RSpec/ExampleLength
    dialect = {"$schema" => "https://json-schema.org/draft/2020-12/schema"}
    definitions = {"d0" => {"type" => "integer", "minimum" => 1}}
    1.upto(4) { |i| definitions["d#{i}"] = {"allOf" => Array.new(2) { {"$ref" => "#/$defs/d#{i - 1}"} }} }
    schema = dialect.merge("$defs" => definitions, "$ref" => "#/$defs/d4")
    leaf = {"anyOf" => [true, {"pattern" => "(?=x)"}]}
    fallback = dialect.merge("$defs" => {"leaf" => leaf}, "allOf" => Array.new(2) { {"$ref" => "#/$defs/leaf"} })
    vm = Schemurai.compile(fallback, backend: :vm)
    native = Schemurai.compile(fallback, backend: :native)
    runner = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
    expect(runner.valid?("x")).to be(true)
    expect(runner.diagnostics("x")).to eq([])
    expect(native.validate("x").errors).to eq(vm.validate("x").errors)
    expect_native_policy_results([schema], [1, 0, "bad"])
  end

  it "limits shared reference memoization to one invocation" do
    schema = {"$defs" => {"leaf" => {"properties" => {"x" => {"minimum" => 1}}}},
              "allOf" => Array.new(2) { {"$ref" => "#/$defs/leaf"} }}
    native = Schemurai.compile(schema, backend: :native)
    value = {"x" => 1}
    expect(native.valid?(value)).to be(true)
    expect(native.validate(value).errors).to be_empty
    value["x"] = 0
    expect(native.valid?(value)).to be(false)
    expect(native.validate(value).errors.size).to eq(2)
  end

  it "memoizes invariant dynamic reference graphs without changing source paths or annotations" do # rubocop:disable RSpec/ExampleLength
    schemas = [{"type" => "integer"}, {"properties" => {"x" => {"type" => "integer"}}}].map do |leaf|
      definitions = {"target" => leaf.merge("$dynamicAnchor" => "target"), "d0" => {"$dynamicRef" => "#target"}}
      1.upto(4) { |i| definitions["d#{i}"] = {"allOf" => Array.new(2) { {"$ref" => "#/$defs/d#{i - 1}"} }} }
      {"$schema" => "https://json-schema.org/draft/2020-12/schema", "$defs" => definitions,
       "$ref" => "#/$defs/d4", "unevaluatedProperties" => false}
    end
    expect_native_policy_results(schemas, [1, "bad", {"x" => 1}, {"x" => "bad"}, {"x" => 1, "extra" => 2}, {}])
  end

  it "separates shared dynamic reference results by effective single and multiple anchor bindings" do # rubocop:disable RSpec/ExampleLength
    dialect = {"$schema" => "https://json-schema.org/draft/2020-12/schema"}
    cases = [1, 2].flat_map do |names|
      definitions = names.times.to_h { |i| ["target#{i}", {"$dynamicAnchor" => "target#{i}", "type" => "integer", "minimum" => 2}] }
      definitions["d0"] = {"allOf" => names.times.map { |i| {"$dynamicRef" => "#target#{i}"} }}
      1.upto(4) { |i| definitions["d#{i}"] = {"allOf" => Array.new(2) { {"$ref" => "#/$defs/d#{i - 1}"} }} }
      body = dialect.merge("$id" => "urn:body", "$defs" => definitions, "$ref" => "#/$defs/d4")
      [false, true].flat_map do |annotations|
        resources = %w[a b].each_with_index.to_h do |name, branch|
          targets = names.times.to_h do |i|
            leaf = if annotations
              {"properties" => {"#{name}#{i}" => {"type" => "integer"}}}
            else
              {"type" => "integer", "minimum" => (i == names - 1) ? branch : 0}
            end
            ["target#{i}", leaf.merge("$dynamicAnchor" => "target#{i}")]
          end
          ["urn:#{name}", dialect.merge("$id" => "urn:#{name}", "$defs" => targets, "$ref" => "urn:body")]
        end.merge("urn:body" => body)
        values = annotations ? [{"a0" => 1}, {"a0" => 1, "b0" => 2},
          {"a0" => 1, "b0" => 2, "a1" => 3, "b1" => 4}, {"a0" => "bad"}, {"extra" => 1}, {}] : [0, 1, -1, "bad"]
        %w[allOf anyOf oneOf].map do |keyword|
          root = dialect.merge(keyword => [{"$ref" => "urn:a"}, {"$ref" => "urn:b"}])
          root["unevaluatedProperties"] = false if annotations
          vm = Schemurai.compile(root, schemas: resources, backend: :vm)
          [Schemurai.compile(root, schemas: resources, backend: :native),
            values.map { |value| [value, vm.valid?(value), vm.validate(value).errors] }]
        end
      end
    end
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |native, values|
      runner = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
      values.each do |value, valid, errors|
        expect(runner.valid?(value)).to eq(valid)
        expect(runner.diagnostics(value)).not_to be_nil
        expect(native.validate(value).errors).to eq(errors)
      end
    end
  end

  it "indexes new names appended to an existing resource during binding callbacks" do # rubocop:disable RSpec/ExampleLength
    dialect = {"$schema" => "https://json-schema.org/draft/2020-12/schema"}
    resources = {
      "urn:body" => dialect.merge("$id" => "urn:body", "$defs" => {
        "x" => {"$dynamicAnchor" => "x", "type" => "integer"}, "z" => {"$dynamicAnchor" => "z", "type" => "integer"}
      }, "allOf" => [{"$dynamicRef" => "#z"}, {"$dynamicRef" => "#x"}]),
      "urn:fallback" => dialect.merge("$id" => "urn:fallback", "$defs" => {"y" => {"$dynamicAnchor" => "y", "minimum" => 1}}),
      "urn:late" => dialect.merge("$id" => "urn:outer", "$defs" => {
        "y" => {"$dynamicAnchor" => "y", "minimum" => 5}, "z" => {"$dynamicAnchor" => "z", "minimum" => 7}
      })
    }
    schema = dialect.merge("$id" => "urn:outer", "$defs" => {
      "x" => {"$dynamicAnchor" => "x", "allOf" => [{"$ref" => "urn:late"}, {"$dynamicRef" => "urn:fallback#y"}]}
    }, "$ref" => "urn:body")
    vm = Schemurai.compile(schema, schemas: resources, backend: :vm)
    expect(vm.valid?(8)).to be(true) # Resolve late resources before comparing stable graph behavior.
    expected = [0, 4, 5, 8, "bad"].map { |value| [value, vm.valid?(value), vm.validate(value).errors] }
    compiler_class = Schemurai.const_get(:VM)::Compiler
    allow_any_instance_of(compiler_class).to receive(:compile).and_wrap_original do |original, *args| # rubocop:disable RSpec/AnyInstance
      GC.verify_compaction_references(double_heap: true, toward: :empty)
      original.call(*args)
    end
    native = Schemurai.compile(schema, schemas: resources, backend: :native)
    program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
    expected.each do |value, valid, errors|
      expect(program.valid?(value)).to eq(valid)
      expect(program.diagnostics(value)).not_to be_nil
      expect(native.validate(value).errors).to eq(errors)
    end
  end

  it "discovers new anchor names and resources while compiling dynamic overrides" do # rubocop:disable RSpec/ExampleLength
    dialect = {"$schema" => "https://json-schema.org/draft/2020-12/schema"}
    resources = {
      "urn:body" => dialect.merge("$id" => "urn:body", "$defs" => {"x" => {"$dynamicAnchor" => "x", "type" => "integer"}}, "$dynamicRef" => "#x"),
      "urn:late" => dialect.merge("$id" => "urn:late", "$defs" => {"y" => {"$dynamicAnchor" => "y", "type" => "integer", "minimum" => 3}})
    }
    targets = {"x" => {"$dynamicAnchor" => "x", "$dynamicRef" => "urn:late#y"}}
    cases = [targets, targets.merge("y" => {"$dynamicAnchor" => "y", "type" => "integer", "minimum" => 5})].map do |definitions|
      schema = dialect.merge("$id" => "urn:outer", "$defs" => definitions, "$ref" => "urn:body")
      vm = Schemurai.compile(schema, schemas: resources, backend: :vm)
      [Schemurai.compile(schema, schemas: resources, backend: :native),
        [2, 4, 5, "bad"].map { |value| [value, vm.valid?(value), vm.validate(value).errors] }]
    end
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |native, values|
      runner = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
      values.each do |value, valid, errors|
        expect(runner.valid?(value)).to eq(valid)
        expect(runner.diagnostics(value)).not_to be_nil
        expect(native.validate(value).errors).to eq(errors)
      end
    end
  end

  it "ignores unreachable dynamic names in shared graph keys including guarded annotation traversal" do # rubocop:disable RSpec/ExampleLength
    build = lambda do |depth, cyclic, tracked|
      base = {"$id" => "urn:base", "$dynamicAnchor" => "n", "properties" => {"v" => {"type" => "integer", "minimum" => 0}}}
      base["properties"]["next"] = {"$ref" => "urn:base"} if cyclic
      definitions = {"base" => base, "other" => {"$id" => "urn:other", "$dynamicAnchor" => "n", "minimum" => 0},
                     "d0" => {"$id" => "urn:d0", "$dynamicRef" => "urn:base#n"}}
      1.upto(depth) do |i|
        %w[a b].each do |branch|
          definitions["#{branch}#{i}"] = {"$id" => "urn:#{branch}#{i}", "$dynamicAnchor" => "x#{i}", "$ref" => "urn:d#{i - 1}"}
        end
        definitions["d#{i}"] = {"$id" => "urn:d#{i}", "allOf" => [{"$ref" => "urn:a#{i}"}, {"$ref" => "urn:b#{i}"}]}
      end
      refs = [{"$ref" => "urn:d#{depth}"}, {"$ref" => "urn:other"}] + (1..depth).map { |i| {"$dynamicRef" => "urn:a#{i}#x#{i}"} }
      schema = {"$schema" => "https://json-schema.org/draft/2020-12/schema", "$defs" => definitions, "allOf" => refs}
      schema["unevaluatedProperties"] = false if tracked
      schema
    end
    [false, true].product([false, true]).each do |cyclic, tracked|
      native = Schemurai.compile(build.call(24, cyclic, tracked), backend: :native)
      program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
      expect(program.valid?({"v" => 8})).to be(true)
      expect(program.diagnostics({"v" => 8})).to eq([])
      schema = build.call(3, cyclic, tracked)
      native = Schemurai.compile(schema, backend: :native)
      vm = Schemurai.compile(schema, backend: :vm)
      [{"v" => -1}, {"v" => 8}, {"v" => "bad"}, {"v" => 8, "extra" => 1}].each do |value|
        expect(native.valid?(value)).to eq(vm.valid?(value))
        expect(native.validate(value).errors).to eq(vm.validate(value).errors)
      end
    end
  end

  it "keeps shared reference annotations usable after invocation cache turnover" do # rubocop:disable RSpec/ExampleLength
    definitions = {"d0" => {"properties" => {"x" => {"type" => "integer"}}}}
    1.upto(8) { |i| definitions["d#{i}"] = {"allOf" => Array.new(2) { {"$ref" => "#/$defs/d#{i - 1}"} }} }
    schema = {"$schema" => "https://json-schema.org/draft/2020-12/schema", "$defs" => definitions,
              "items" => {"$ref" => "#/$defs/d8", "unevaluatedProperties" => false}}
    value = Array.new(1200) { |i| {"x" => i} }
    vm = Schemurai.compile(schema, backend: :vm)
    native = Schemurai.compile(schema, backend: :native)
    runner = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    expect(runner.valid?(value)).to eq(vm.valid?(value))
    expect(runner.diagnostics(value)).to eq([])
    expect(native.validate(value).errors).to eq(vm.validate(value).errors)
    value.last["extra"] = 1
    expect(runner.valid?(value)).to be(false)
    expect(runner.diagnostics(value)).not_to be_nil
    expect(native.validate(value).errors).to eq(vm.validate(value).errors)
    value.last.delete("extra")
    value.last["x"] = "bad"
    expect(runner.valid?(value)).to be(false)
    expect(runner.diagnostics(value)).not_to be_nil
    expect(native.validate(value).errors).to eq(vm.validate(value).errors)
  end

  it "reuses shared reference annotations without losing coverage or failure paths" do # rubocop:disable RSpec/ExampleLength
    dialect = {"$schema" => "https://json-schema.org/draft/2020-12/schema"}
    schemas = [{"properties" => {"x" => {"type" => "integer"}}},
      {"prefixItems" => [{"type" => "integer"}]}].map do |leaf|
      definitions = {"d0" => leaf}
      1.upto(4) { |i| definitions["d#{i}"] = {"allOf" => Array.new(2) { {"$ref" => "#/$defs/d#{i - 1}"} }} }
      dialect.merge("$defs" => definitions, "$ref" => "#/$defs/d4",
        (leaf.key?("properties") ? "unevaluatedProperties" : "unevaluatedItems") => false)
    end
    expect_native_policy_results(schemas, [{"x" => 1}, {"x" => "bad"}, {"x" => 1, "extra" => 2},
      {}, [1], ["bad"], [1, 2], []])
    native = Schemurai.compile(schemas.first, backend: :native)
    value = {"x" => 1}
    expect(native.validate(value).errors).to be_empty
    value["extra"] = 2
    expect(native.valid?(value)).to be(false)
    expect(native.validate(value).errors).not_to be_empty
  end

  it "keeps shared diagnostic annotation policies separate within one traversal" do # rubocop:disable RSpec/ExampleLength
    leaf = {"properties" => {"y" => true}}
    schema = {"$schema" => "https://json-schema.org/draft/2020-12/schema", "$defs" => {"leaf" => leaf},
              "allOf" => [{"properties" => {"x" => {"$ref" => "#/$defs/leaf"}}},
                {"properties" => {"x" => {"$ref" => "#/$defs/leaf", "unevaluatedProperties" => false}}}]}
    expect_native_policy_results([schema], [{"x" => {"y" => 1}}, {"x" => {"extra" => 1}},
      {"x" => {"y" => 1, "extra" => 2}}, {}])
  end

  it "compares full wide integer fingerprints in mixed arrays, nested values and enums" do # rubocop:disable RSpec/ExampleLength
    numbers = Array.new(40) { |i| 2**4096 + (i << 1100) + 1 }
    duplicate = 2**4096 + (20 << 1100) + 1
    values = [numbers + ["other"], ["other"] + numbers, numbers + [duplicate, "other"],
      numbers.map { |n| {"n" => n} }, numbers.map { |n| [n, -n] },
      numbers.map { |n| {"n" => n} } + [{"n" => duplicate}],
      [2**1023, (2**1023).to_f] + numbers, [-2**1023, (-2**1023).to_f] + numbers]
    choices = numbers + numbers.map { |n| {"n" => -n} }
    values += [numbers.last, duplicate, {"n" => -duplicate},
      numbers.last + (1 << 1500), {"n" => -(numbers.last + (1 << 1500))}, Float::INFINITY]
    expect_native_policy_results([{"uniqueItems" => true}, {"enum" => choices}], values)
  end

  it "applies every grouped pattern in schema order including overlapping and empty matches" do # rubocop:disable RSpec/ExampleLength
    dialect = {"$schema" => "https://json-schema.org/draft/2020-12/schema"}
    patterns = {"^a" => {"type" => "integer"}, "^a.*$" => {"minimum" => 2}, "^" => {"maximum" => 4},
                "^b|^é" => {"type" => "string"}}
    schema = dialect.merge("patternProperties" => patterns, "additionalProperties" => false)
    wide = dialect.merge("patternProperties" => 64.times.to_h { |i| ["^p#{i}$", {"const" => i}] },
      "additionalProperties" => false)
    expect_native_policy_results([schema, schema.merge("unevaluatedProperties" => false), wide],
      [{}, {"a" => 3}, {"a" => 1}, {"a" => "bad"}, {"b" => "ok", "é" => 8},
        {"p63" => 63}, {"p63" => 62}, {"extra" => 1}])
  end

  it "terminates supported contains validity while preserving counts, annotations and later fallback" do # rubocop:disable RSpec/ExampleLength
    dialect = {"$schema" => "https://json-schema.org/draft/2020-12/schema"}
    predicates = [true, false, {"const" => 1}, {"type" => "integer"}, {"minimum" => 1, "maximum" => 2}]
    schemas = predicates.flat_map do |predicate|
      [{"contains" => predicate}, {"contains" => predicate, "minContains" => 0},
        {"contains" => predicate, "minContains" => 2, "maxContains" => 3},
        {"contains" => predicate, "minContains" => 0, "maxContains" => 0},
        {"contains" => predicate, "minContains" => 2, "maxContains" => 1},
        {"contains" => predicate, "unevaluatedItems" => false}].map { |schema| dialect.merge(schema) }
    end
    native = Schemurai.compile(dialect.merge("contains" => {"const" => 1}), backend: :native)
    runner = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
    expect(runner.valid?([1, Object.new])).to be(true)
    expect(runner.diagnostics([1, Object.new])).to eq([])
    expect_native_policy_results(schemas, [[], [0], [1], [1, 0, 2], [1, 1, 1, 1], [1, 1.0], [1, 2**200]])
  end

  it "indexes required/property joins by name while retaining duplicates and ordered missing errors" do # rubocop:disable RSpec/ExampleLength
    properties = 128.times.to_h { |i| ["p#{i}", {"type" => "integer"}] }
    required = properties.keys.reverse.map(&:dup) + ["extra", "extra"]
    schema = {"properties" => properties, "required" => required}
    all = 128.times.to_h { |i| ["p#{i}", i] }.merge("extra" => 1)
    expect_native_policy_results([schema], [all, all.except("p0", "p127", "extra"), {}, all.merge("p64" => "bad")])
  end

  it "exports annotations from diagnostic applicators without retaining failed children" do # rubocop:disable RSpec/ExampleLength
    dialect = {"$schema" => "https://json-schema.org/draft/2020-12/schema"}
    leaf = {"properties" => {"id" => {"type" => "integer"}}, "required" => ["id"]}
    wrappers = [{"allOf" => [leaf]}, {"if" => {"required" => ["id"]}, "then" => leaf},
      {"$ref" => "#/$defs/leaf", "$defs" => {"leaf" => leaf}}, {"dependentSchemas" => {"id" => leaf}}]
    schemas = wrappers.flat_map do |wrapper|
      nested = {"allOf" => [wrapper]}
      3.times { nested = {"allOf" => [nested]} }
      [dialect.merge(wrapper).merge("unevaluatedProperties" => false),
        dialect.merge(nested).merge("unevaluatedProperties" => false)]
    end
    # References in nested schemas must resolve from the document root.
    schemas.each { |schema| schema["$defs"] = {"leaf" => leaf} }
    values = [{}, {"id" => 1}, {"id" => "bad"}, {"id" => 1, "extra" => nil}, {"id" => "bad", "extra" => nil}]
    expect_native_policy_results(schemas, values)
  end

  it "keeps attempted array locations separate from exported branch annotations" do # rubocop:disable RSpec/ExampleLength
    dialect = {"$schema" => "https://json-schema.org/draft/2020-12/schema"}
    leaf = {"prefixItems" => [{"type" => "integer"}], "contains" => {"type" => "string"}}
    schemas = [{"allOf" => [leaf]}, {"if" => {"minItems" => 1}, "then" => leaf},
      {"$ref" => "#/$defs/leaf", "$defs" => {"leaf" => leaf}},
      {"allOf" => [{"allOf" => [leaf]}, {"prefixItems" => [true, true]}]}].map do |wrapper|
      dialect.merge(wrapper).merge("unevaluatedItems" => false)
    end
    expect_native_policy_results(schemas, [[], [1], ["bad"], [1, "ok"], ["bad", "ok"], [1, "ok", false]])
  end

  it "shares sparse property lookup while preserving required fields and ordered errors" do # rubocop:disable RSpec/ExampleLength
    dialect = {"$schema" => "https://json-schema.org/draft/2020-12/schema"}
    properties = 130.times.to_h { |i| ["p#{i}", {"type" => "integer"}] }
    schema = dialect.merge("properties" => properties, "required" => %w[p1 p64])
    schemas = [schema, schema.merge("patternProperties" => {"^p" => {"minimum" => 1}}, "additionalProperties" => false),
      schema.merge("propertyNames" => {"pattern" => "^p[0-9]+$"}, "unevaluatedProperties" => false),
      dialect.merge("allOf" => [schema], "unevaluatedProperties" => false)]
    values = [{}, {"p1" => 1}, {"p64" => 2, "p1" => 1}, {"p64" => "bad", "p1" => false},
      {"extra" => nil, "p64" => 2, "p1" => 0}, 130.times.to_h { |i| ["p#{i}", i + 1] }]
    expect_native_policy_results(schemas, values)
  end

  it "retains schema-order fallback and identity lookups in sparse objects" do # rubocop:disable RSpec/ExampleLength
    properties = 64.times.to_h { |i| ["p#{i}", {"type" => "integer"}] }
    properties["p1"] = {"pattern" => "(?=x)"}
    native = Schemurai.compile({"properties" => properties}, backend: :native)
    program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
    expect(program.valid?({"p1" => "x", "p0" => "bad"})).to be(false)
    expect(program.valid?({"p2" => "bad", "p1" => "x"})).to be(false)
    expect(program.diagnostics({"p1" => "x", "p0" => "bad"})).not_to be_nil
    mutable = {"p0" => 1}
    expect(program.valid?(mutable)).to be(true)
    mutable["p0"] = "bad"
    expect(program.valid?(mutable)).to be(false)
    mutable.clear
    expect(program.valid?(mutable)).to be(true)
    schema = {"properties" => properties, "required" => ["p0"]}
    vm = Schemurai.compile(schema, backend: :vm)
    native = Schemurai.compile(schema, backend: :native)
    ordinary = {"p2" => 1, "p0" => 2}
    [ordinary, ordinary.dup.compare_by_identity, ordinary.dup.compare_by_identity.freeze].each do |value|
      expect(native.valid?(value)).to eq(vm.valid?(value))
      expect(native.validate(value).errors).to eq(vm.validate(value).errors)
    end
  end

  it "keeps conclusive validity separate from later diagnostic exceptions" do
    schema = {"anyOf" => [true, {"pattern" => "^x"}]}
    native = Schemurai.compile(schema, backend: :native)
    vm = Schemurai.compile(schema, backend: :vm)
    value = "x".encode(Encoding::UTF_16LE)
    program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
    expect(program.valid?(value)).to be(true)
    expect { program.diagnostics(value) }.to raise_error(Encoding::CompatibilityError)
    expect(native.valid?(value)).to eq(vm.valid?(value))
    [native, vm].each { |validator| expect { validator.validate(value) }.to raise_error(Encoding::CompatibilityError) }
  end

  it "compares arbitrary integer constants and mixed Float values without VM evaluation" do # rubocop:disable RSpec/ExampleLength
    random = Random.new(8417)
    integers = [2**62, -(2**63), 2**63 - 1, 2**100, -(2**127), 2**200 + 1, 2**1023, 2**4096 + 3]
    floats = [0.0, -0.0, 1.5, Float::INFINITY, -Float::INFINITY, Float::NAN, Float::MAX]
    100.times do
      float = [random.rand(2**64)].pack("Q").unpack1("d")
      next unless float.finite? && float.abs >= 2**62

      integers << float.to_i
      floats << float
    end
    cases = integers.map do |integer|
      values = [integer, integer + 1, -integer, *floats]
      vm = Schemurai.compile({"const" => integer}, backend: :vm)
      [Schemurai.compile({"const" => integer}, backend: :native), values.map { |value| [value, vm.valid?(value), vm.validate(value).errors] }]
    end
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |native, values|
      values.each do |value, valid, errors|
        expect(native.valid?(value)).to eq(valid), value.inspect
        expect(native.validate(value).errors).to eq(errors), value.inspect
      end
    end
  end

  it "indexes large integer uniqueness with exact collision checks and no Ruby allocation" do # rubocop:disable RSpec/ExampleLength
    native = Schemurai.compile({"uniqueItems" => true}, backend: :native)
    values = Array.new(40) { |i| 2**200 + i }
    collisions = [2**4096 + 2**1100, 2**4096 + 2**1200]
    low_word_collisions = Array.new(40) { |i| 2**200 + (i << 64) + 1 }
    long_chain = Array.new(40) { |i| 2**4096 + (i << 1100) }
    nested = Array.new(40) { |i| {"id" => 2**200 + i, "nested" => [-(2**200) - i]} }
    datasets = [values, values + [2**200 + 39], values + [(2**200).to_f], values + [(2**200 + 40).to_f],
      values + [-(2**200).to_f], values.drop(1) + [(2**200).to_f], values + collisions, values + collisions + [collisions.first + 0], nested,
      nested + [{"nested" => [-(2**200)], "id" => (2**200).to_f}],
      low_word_collisions, low_word_collisions + [2**200 + (39 << 64) + 1],
      long_chain, long_chain + [2**4096], long_chain + [2**4096 + (20 << 1100)],
      long_chain + [2**4096 + (39 << 1100)]]
    random = Random.new(9571)
    same_bucket = Array.new(40) { |i| 2**200 + ((i << 11) ^ i) }.shuffle(random: random)
    datasets.concat([same_bucket, same_bucket + [same_bucket[17]], same_bucket.map { |n| -n },
      same_bucket + [(2**200).to_f], same_bucket.reject { |n| n == 2**200 } + [(2**200).to_f]])
    scattered = Array.new(40) { 2**200 + random.rand(2**64) }
    datasets.concat([scattered, scattered + [scattered[17]], scattered.map { |n| -n },
      scattered.map { |n| -n } + [-scattered[17]]])
    (0..64).each do |shift|
      shifted = Array.new(40) { |i| 2**200 + (i << shift) }.shuffle(random: random)
      datasets.concat([shifted, shifted + [shifted[17]], shifted.map { |n| -n },
        shifted.map { |n| -n } + [-shifted[17]]])
    end
    vm = Schemurai.compile({"uniqueItems" => true}, backend: :vm)
    expected = datasets.map { |value| [vm.valid?(value), vm.validate(value).errors] }
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    datasets.zip(expected).each do |value, (valid, errors)|
      expect(native.valid?(value)).to eq(valid), value.inspect
      expect(native.validate(value).errors).to eq(errors), value.inspect
    end
    measure = lambda do
      before = GC.stat(:total_allocated_objects)
      100.times { native.valid?(values) }
      GC.stat(:total_allocated_objects) - before
    end
    measure.call
    expect(measure.call).to eq(0)
  end

  it "checks ordered large integers and reverts to exact indexing when order changes" do # rubocop:disable RSpec/ExampleLength
    random = Random.new(9571)
    datasets = [63, 200, 1024, 4096].flat_map do |bits|
      ascending = Array.new(40) { |i| 2**bits + (i << 64) + 1 }
      [ascending, ascending.reverse, ascending.map { |n| -n }, ascending.map { |n| -n }.reverse,
        ascending + [ascending.first], ascending + [ascending.last], ascending + [ascending[20]],
        ascending + [ascending.last + 1], ascending.reverse + [ascending.last + 1],
        ascending.shuffle(random: random), ascending.shuffle(random: random) + [ascending[20]],
        ascending + [0], ascending + ["item"], ascending + [nil], ascending + [ascending.first.to_f]]
    end
    datasets << Array.new(40) { |i| i.even? ? 2**200 + i : -(2**200) - i }
    [1, 2, 15, 16, 17].each do |size|
      prefix = Array.new(80) { |i| 2**200 + i }
      tail = Array.new(size) { |i| -(2**200) - i }.shuffle(random: random)
      datasets.concat([prefix + tail, prefix.reverse + tail, prefix + tail + [tail.first],
        prefix + tail + [prefix[40]], prefix + tail + [nil], prefix + tail + [tail.first.to_f]])
    end
    schema = {"uniqueItems" => true}
    vm = Schemurai.compile(schema, backend: :vm)
    expected = datasets.map { |value| [vm.valid?(value), vm.validate(value).errors] }
    native = Schemurai.compile(schema, backend: :native)
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    datasets.zip(expected).each do |value, (valid, errors)|
      expect(native.valid?(value)).to eq(valid), value.inspect
      expect(native.validate(value).errors).to eq(errors), value.inspect
    end
  end

  it "fingerprints signed immediate boundaries and exact mixed Float values" do # rubocop:disable RSpec/ExampleLength
    integers = [-(2**62), -(2**62) + 1, -(2**53) - 1, -(2**53), -1, 0, 1, 2**53, 2**53 + 1, 2**62 - 1, 2**62]
    padding = Array.new(17) { |i| "padding#{i}" }
    datasets = integers.flat_map do |integer|
      [[integer, *padding, integer.to_f], [{"n" => integer}, *padding, {"n" => integer.to_f}]]
    end
    datasets.concat([[*padding, *integers], [*padding, *integers, -1.0], [*padding, *integers, -0.0]])
    schema = {"uniqueItems" => true}
    vm = Schemurai.compile(schema, backend: :vm)
    expected = datasets.map { |value| [vm.valid?(value), vm.validate(value).errors] }
    native = Schemurai.compile(schema, backend: :native)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    datasets.zip(expected).each do |value, (valid, errors)|
      expect(native.valid?(value)).to eq(valid)
      expect(native.validate(value).errors).to eq(errors)
    end
  end

  it "checks integer fingerprint width boundaries and mixed hinted arrays without VM execution" do # rubocop:disable RSpec/ExampleLength
    powers = [63, 64, 127, 128, 200, 255, 256, 257, 511, 512, 1023, 1024, 4096]
    integers = powers.flat_map { |bits| [-1, 0, 1].flat_map { |offset| [2**bits + offset, -(2**bits + offset)] } }
    mixed = integers + [42, 0.5, nil, true, false, "item", {"id" => 1}, ["nested"]]
    datasets = [integers, mixed, mixed + [integers[6] + 0], mixed + [{"id" => 1}], mixed + [["nested"]]]
    powers.take(11).each do |bits|
      floating = (2**bits).to_f
      padding = Array.new(20) { |i| "padding#{i}" }
      datasets.concat([[2**bits, *padding, floating], [2**bits + 1, *padding, floating], [-(2**bits), *padding, -floating]])
    end
    datasets << [Float::MAX.to_i, *Array.new(20) { |i| i }, Float::MAX]
    vm = Schemurai.compile({"uniqueItems" => true}, backend: :vm)
    expected = datasets.map { |value| [vm.valid?(value), vm.validate(value).errors] }
    native = Schemurai.compile({"uniqueItems" => true}, backend: :native)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    datasets.zip(expected).each do |value, (valid, errors)|
      expect(native.valid?(value)).to eq(valid), value.inspect
      expect(native.validate(value).errors).to eq(errors), value.inspect
    end
  end

  it "indexes unordered Bignums and restarts for mixed values without VM execution" do # rubocop:disable RSpec/ExampleLength
    datasets = [64, 200, 256, 257, 1024, 4096].flat_map do |bits|
      values = Array.new(40) { |i| 2**bits + i }.shuffle(random: Random.new(9571))
      high_words = Array.new(40) { |i| 2**bits + (i << 1088) + 1 }.shuffle(random: Random.new(9571))
      [values, values + [2**bits + 17], values.map { |n| -n }, high_words, high_words + [high_words[17] + 0],
        high_words.map { |n| -n }, high_words.map { |n| -n } + [-high_words[17]],
        high_words + [2**bits, (2**bits).to_f]]
    end
    values = Array.new(40) { |i| 2**200 + i }.shuffle(random: Random.new(9571))
    [1, 17, 40].each do |at|
      datasets << values.dup.insert(at, (2**200).to_f)
      datasets << values.dup.insert(at, (2**200).to_f).reject { |n| n.is_a?(Integer) && n == 2**200 }
      datasets << values.dup.insert(at, {"id" => 1})
    end
    vm = Schemurai.compile({"uniqueItems" => true}, backend: :vm)
    expected = datasets.map { |value| [vm.valid?(value), vm.validate(value).errors] }
    native = Schemurai.compile({"uniqueItems" => true}, backend: :native)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    GC.start
    GC.compact if GC.respond_to?(:compact)
    datasets.zip(expected).each do |value, (valid, errors)|
      expect(native.valid?(value)).to eq(valid), value.inspect
      expect(native.validate(value).errors).to eq(errors), value.inspect
    end
  end

  it "resolves uniqueness probe collisions across table sizes without VM execution" do # rubocop:disable RSpec/ExampleLength
    datasets = [17, 31, 32, 33, 63, 64, 65, 127, 128, 129, 1023, 1024, 1025, 65_534, 65_535, 65_536].flat_map do |length|
      values = Array.new(length) { |i| i }.shuffle(random: Random.new(9571))
      cases = [values, values + [values[length / 2]]]
      cases << values.map { |i| {"id" => i} } if length <= 129
      cases
    end
    # These integers have identical sampled low words and magnitude size in
    # the canonical index. A noninteger first item selects that index.
    high_words = ["canonical"] + Array.new(65) { |i| 2**4096 + (i << 1088) + 1 }
    datasets.concat([high_words, high_words + [high_words[33] + 0]])
    nan_objects = Array.new(65) { {"number" => Float::NAN} }
    datasets.concat([nan_objects, nan_objects + [nan_objects.first]])
    vm = Schemurai.compile({"uniqueItems" => true}, backend: :vm)
    expected = datasets.map { |value| [vm.valid?(value), vm.validate(value).errors] }
    native = Schemurai.compile({"uniqueItems" => true}, backend: :native)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    datasets.zip(expected).each do |value, (valid, errors)|
      expect(native.valid?(value)).to eq(valid)
      expect(native.validate(value).errors).to eq(errors)
    end
  end

  it "evaluates container bounds and uniqueness without VM execution" do # rubocop:disable RSpec/ExampleLength
    fake_array = Object.new
    fake_array.define_singleton_method(:is_a?) { |type| type == Array }
    fake_array.define_singleton_method(:length) { 2 }
    fake_array.define_singleton_method(:[]) { |index| [1, 1][index] }
    fake_array.define_singleton_method(:each_with_index) { |&block| [1, 1].each_with_index(&block) }
    fake_hash = Object.new
    fake_hash.define_singleton_method(:is_a?) { |type| type == Hash }
    fake_hash.define_singleton_method(:length) { 2 }
    fake_hash.define_singleton_method(:key?) { |*| raise "unused key lookup" }
    key = Object.new
    keyed = {key => 1}
    key.define_singleton_method(:hash) { raise "unused key hash" }
    fractional = Class.new(Array).new([1, 2])
    fractional.define_singleton_method(:length) { Rational(3, 2) }
    values = [[1, 1], [], {"x" => 1}, {}, Class.new(Array).new([1, 1]), Class.new(Array).new([1, 2]), Class.new(Array).new,
      Class.new(Hash)["x", 1], Class.new(Hash).new, fake_array, fake_hash, fractional, keyed,
      keyed.dup.compare_by_identity, BasicObject.new, Rational(1, 2), Class.new(String).new("x")]
    rules = [{"minItems" => 0.5}, {"maxProperties" => -1}, {"minProperties" => 2**100}, {"maxItems" => 0}, {"minItems" => 3}, {"maxItems" => 0, "minItems" => 3, "uniqueItems" => true},
      {"uniqueItems" => true}, {"uniqueItems" => false}, {"uniqueItems" => 1}, {"items" => []},
      {"maxItems" => 0, "items" => []}, {"maxItems" => 1, "additionalItems" => false},
      {"maxProperties" => 0}, {"minProperties" => 3}, {"maxProperties" => 0, "minProperties" => 3, "required" => []},
      {"maxItems" => "bad"}, {"minProperties" => "bad"}, {"maxItems" => false}, {"minProperties" => false}]
    rules = rules.flat_map { |rule| [rule, rule.merge("type" => "array"), rule.merge("type" => "object")] }
    wrappers = [->(rule, value) { [rule, value] }, ->(rule, value) { [{"items" => rule}, [value, value]] },
      ->(rule, value) { [{"properties" => {"v~/s" => rule}}, {"v~/s" => value}] },
      ->(rule, value) { [{"contains" => rule}, [value]] },
      ->(rule, value) { [{"$defs" => {"v" => rule}, "allOf" => [{"$ref" => "#/$defs/v"}, {"$ref" => "#/$defs/v"}]}, value] }]
    cases = rules.product(wrappers).map do |rule, wrap|
      schema = wrap.call(rule, nil).first
      vm = Schemurai.compile(schema, backend: :vm)
      expected = values.product([:valid?, :validate], [{}, {timeout: 10}, {max_errors: 0}, {max_errors: 1}]).map do |value, method, options|
        input = wrap.call(rule, value).last
        [input, method, options, capture_validation(vm, method, input, **options)]
      end
      [Schemurai.compile(schema, backend: :native), schema, expected]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    cases.each do |native, schema, expected|
      expected.each_with_index do |(input, method, options, result), index|
        expect(capture_validation(native, method, input, **options)).to eq(result), [schema, method, options, index].inspect
      end
    end
  end

  it "checks required keys on special objects without VM execution" do # rubocop:disable RSpec/ExampleLength
    custom = Class.new(Hash) do
      def key?(name)
        return false if name == "x"

        super
      end
    end
    exploding = Class.new(Hash) do
      def key?(_name) = raise(ArgumentError, "required key callback")
    end
    mutating = Class.new(Hash) do
      def key?(name)
        name << "observed" if name.is_a?(Array) && !name.frozen?
        false
      end
    end
    fake = Object.new
    fake.define_singleton_method(:is_a?) { |type| type == Hash }
    fake.define_singleton_method(:length) { 1 }
    fake.define_singleton_method(:key?) { |name| name == "x" }
    fake.define_singleton_method(:each) { |&block| {"x" => 1}.each(&block) }
    values = [{}, {"x" => 1}, {"x" => 1, "y" => 2}, custom["x", 1, "y", 2], exploding["x", 1], mutating.new,
      {1 => 1, nil => 2, false => 3}, {"x" => 1}.compare_by_identity, fake, BasicObject.new, [1], 1]
    requirements = [["x", "y", "x"], [], [1, nil, false, ["x"], {"a" => 1}], nil, false, true, "x", 3, {"x" => 1, "y" => ["z"]}]
    wrappers = [->(rule, value) { [rule, value] }, ->(rule, value) { [{"items" => rule}, [value, value]] },
      ->(rule, value) { [{"properties" => {"v~/s" => rule}}, {"v~/s" => value}] },
      ->(rule, value) { [{"contains" => rule}, [value]] },
      ->(rule, value) { [{"anyOf" => [rule, false]}, value] },
      ->(rule, value) { [{"$defs" => {"v" => rule}, "allOf" => [{"$ref" => "#/$defs/v"}, {"$ref" => "#/$defs/v"}]}, value] }]
    rules = requirements.flat_map do |required|
      [{"required" => required}, {"type" => "object", "required" => required},
        {"maxProperties" => 0, "minProperties" => 2, "required" => required}]
    end
    cases = rules.product(wrappers).map do |rule, wrap|
      schema = wrap.call(rule, nil).first
      vm = Schemurai.compile(schema, backend: :vm)
      expected = values.product([:valid?, :validate], [{}, {timeout: 10}, {max_errors: 0}, {max_errors: 1}, {max_errors: 2}]).map do |value, method, options|
        input = wrap.call(rule, value).last
        [input, method, options, capture_validation(vm, method, input, **options)]
      end
      [Schemurai.compile(schema, backend: :native), schema, expected]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    cases.each do |native, schema, expected|
      expected.each_with_index do |(input, method, options, result), index|
        expect(capture_validation(native, method, input, **options)).to eq(result), [schema, method, options, index].inspect
      end
    end
  end

  it "checks dependency keys on special objects without VM execution" do # rubocop:disable RSpec/ExampleLength
    custom = Class.new(Hash) do
      def key?(name)
        return false if name == "end"

        super
      end
    end
    exploding = Class.new(Hash) do
      def key?(_name) = raise(RegexpError, "dependency key callback")
    end
    values = [{}, {"start" => 1}, {"start" => 1, "end" => 2}, custom["start", 1, "end", 2], exploding["start", 1],
      {"start" => 1}.compare_by_identity, {1 => 1}, Class.new(Hash)["start", 1], BasicObject.new, [1], nil]
    rules = [["end", "end", nil], [], [1, false, ["nested"]]].map { |names| {"dependencies" => {"start" => names, "absent" => ["other"]}} }
    rules.concat([["end", "end", nil], [], [1, false, ["nested"]], nil, false, true, "bad", 3, {"x" => 1}].map do |names|
      {"$schema" => "https://json-schema.org/draft/2020-12/schema", "dependentRequired" => {"start" => names, "absent" => ["other"]}}
    end)
    rules = rules.flat_map { |rule| [rule, rule.merge("type" => "object"), rule.merge("maxProperties" => 0, "required" => ["start", "start"])] }
    wrappers = [->(rule, value) { [rule, value] }, ->(rule, value) { [{"items" => rule}, [value, value]] },
      ->(rule, value) { [{"properties" => {"v~/s" => rule}}, {"v~/s" => value}] },
      ->(rule, value) { [{"contains" => rule}, [value]] }, ->(rule, value) { [{"anyOf" => [rule, false]}, value] },
      ->(rule, value) { [{"$defs" => {"v" => rule}, "allOf" => [{"$ref" => "#/$defs/v"}, {"$ref" => "#/$defs/v"}]}, value] }]
    cases = rules.product(wrappers).map do |rule, wrap|
      schema = wrap.call(rule, nil).first
      vm = Schemurai.compile(schema, backend: :vm)
      expected = values.product([:valid?, :validate], [{}, {timeout: 10}, {max_errors: 0}, {max_errors: 1}, {max_errors: 2}]).map do |value, method, options|
        input = wrap.call(rule, value).last
        [input, method, options, capture_validation(vm, method, input, **options)]
      end
      [Schemurai.compile(schema, backend: :native), schema, expected]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    cases.each do |native, schema, expected|
      expected.each_with_index do |(input, method, options, result), index|
        expect(capture_validation(native, method, input, **options)).to eq(result), [schema, method, options, index].inspect
      end
    end
  end

  it "runs scalar contains validity through native callbacks without VM execution" do # rubocop:disable RSpec/ExampleLength
    fake = Object.new
    fake.define_singleton_method(:is_a?) { |type| type == Array }
    fake.define_singleton_method(:length) { 1 }
    fake.define_singleton_method(:any?) { |&block| [1, "a"].any?(&block) }
    fake.define_singleton_method(:count) { |&block| [1, "a"].count(&block) }
    rescuing = Class.new(Array) do
      def any?(&block)
        super
      rescue ArgumentError, NoMethodError
        true
      end

      def count(&block)
        super
      rescue ArgumentError, NoMethodError
        Rational(3, 2)
      end
    end
    values = [Class.new(Array).new([1, "a", [1]]), Class.new(Array).new, rescuing.new([BasicObject.new, 1]),
      fake, BasicObject.new, [1, "a"], nil, {Object.new => 1},
      Class.new(Array).new([Class.new(Hash)["x", 1], {1 => 2}, Class.new(Array).new([1])])]
    children = [true, false, {"type" => "integer"}, {"type" => %w[number string]}, {"type" => "array"},
      {"type" => "null"}, {"type" => "boolean"}, {"type" => "number"}, {"type" => "string"}, {"type" => "object"},
      {"type" => "integer", "const" => 1}, {"type" => %w[integer string], "enum" => [1, "a"], "const" => "a"},
      {"type" => "string", "const" => "a", "minLength" => 2}, {"enum" => [1, "a"], "maximum" => 0},
      {"maximum" => 0}, {"type" => "number", "multipleOf" => 0.1},
      {"minLength" => 2, "pattern" => "^a", "format" => "ipv4"},
      {"contentEncoding" => "base64", "contentMediaType" => "application/json"}, {"const" => [1]}, {"enum" => [1, "a"]},
      {}, {"allOf" => []}, {"anyOf" => []}, {"oneOf" => []},
      {"allOf" => [{"type" => "integer"}, {"minimum" => 0}]},
      {"anyOf" => [{"type" => "integer"}, {"minLength" => 2}]},
      {"oneOf" => [{"const" => 1}, {"const" => "a"}, false]}, {"not" => {"type" => "integer"}},
      {"if" => {"type" => "number"}, "then" => {"minimum" => 2}, "else" => {"maxLength" => 0}},
      {"$id" => "urn:contains-child", "$defs" => {"leaf" => {"type" => "integer"}},
       "allOf" => [{"$ref" => "urn:contains-child#/$defs/leaf"}, {"$ref" => "urn:contains-child#/$defs/leaf"}]},
      {"maxItems" => 1, "uniqueItems" => true}, {"required" => ["x"], "dependencies" => {"x" => ["y"]}},
      {"contains" => {"type" => "integer"}}, {"contains" => {"anyOf" => [true, false]}}]
    rules = children.flat_map do |child|
      [{"contains" => child}, {"type" => "array", "contains" => child},
        {"maxItems" => 0, "contains" => child}, {"uniqueItems" => true, "contains" => child},
        {"$schema" => "https://json-schema.org/draft/2020-12/schema", "contains" => child, "minContains" => 0, "maxContains" => 1}]
    end
    wrappers = [->(rule, value) { [rule, value] },
      ->(rule, value) { [{"anyOf" => [rule, false]}, value] },
      ->(rule, value) { [{"oneOf" => [rule, false]}, value] },
      ->(rule, value) { [{"not" => rule}, value] },
      ->(rule, value) { [{"if" => rule, "then" => false, "else" => true}, value] },
      ->(rule, value) { [{"$defs" => {"v" => rule}, "allOf" => [{"$ref" => "#/$defs/v"}, {"$ref" => "#/$defs/v"}]}, value] }]
    cases = rules.product(wrappers).map do |rule, wrap|
      schema = wrap.call(rule, nil).first
      vm = Schemurai.compile(schema, backend: :vm, format: true, content: true)
      expected = values.product([{}, {timeout: 10}, {max_errors: 0}]).map do |value, options|
        input = wrap.call(rule, value).last
        [input, options, capture_validation(vm, :valid?, input, **options)]
      end
      [Schemurai.compile(schema, backend: :native, format: true, content: true), schema, expected]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    cases.each do |native, schema, expected|
      expected.each_with_index do |(input, options, outcome), index|
        expect(capture_validation(native, :valid?, input, **options)).to eq(outcome), [schema, options, index].inspect
      end
    end
  end

  it "preserves checkpoints and rescued exceptions between contains child instructions" do # rubocop:disable RSpec/ExampleLength
    array = Class.new(Array) do
      def initialize(state, value)
        super([value])
        @state = state
      end

      def any?
        @state[:active] = true
        yield first
      rescue ArgumentError => error
        @state[:calls] << [:rescue, error.message]
        true
      ensure
        @state[:active] = false
        @state[:calls] << :ensure
      end
    end
    string = Class.new(String) do
      def initialize(calls, text)
        super(text)
        @calls = calls
      end

      def is_a?(type)
        @calls << [:is_a?, type]
        super
      end

      def ==(other)
        @calls << [:equal, other]
        super
      end
    end
    state = nil
    budget_class = Schemurai.const_get(:Internal)::LimitBudget
    allow(budget_class).to receive(:new).and_wrap_original do |original, **options|
      budget = original.call(**options)
      allow(budget).to receive(:checkpoint).and_wrap_original do |checkpoint|
        if state[:active]
          state[:checks] += 1
          state[:calls] << :checkpoint
          raise ArgumentError, "checkpoint #{state[:checks]}" if state[:checks] == state[:fail_at]
        end
        checkpoint.call
      end
      budget
    end
    leaf = {"type" => "string", "enum" => ["a"], "const" => "a", "minLength" => 1}
    schemas = [leaf, {}, {"allOf" => [leaf, {"const" => "a"}]}, {"anyOf" => [{"const" => "b"}, leaf]},
      {"oneOf" => [leaf, false, leaf]}, {"not" => leaf}, {"if" => leaf, "then" => {"const" => "a"}, "else" => false},
      {"$id" => "urn:contains-child", "$defs" => {"leaf" => leaf},
       "allOf" => [{"$ref" => "urn:contains-child#/$defs/leaf"}, {"$ref" => "urn:contains-child#/$defs/leaf"}]}].map { |child| {"contains" => child} }
    run = lambda do |backend, schema, fail_at, options, text|
      state = {calls: [], checks: 0, fail_at: fail_at, active: false}
      value = array.new(state, string.new(state[:calls], text))
      outcome = capture_validation(Schemurai.compile(schema, backend: backend), :valid?, value, **options)
      [outcome, state[:calls]]
    end
    cases = schemas.product([nil] + (1..20).to_a, [{timeout: 10}, {max_errors: 0}], %w[a b]).map do |schema, fail_at, options, text|
      [schema, fail_at, options, text, run.call(:vm, schema, fail_at, options, text)]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    cases.each do |schema, fail_at, options, text, expected|
      expect(run.call(:native, schema, fail_at, options, text)).to eq(expected), [schema, fail_at, options, text].inspect
    end
  end

  it "declines contains callbacks before a later unsupported traversal can replay them" do # rubocop:disable RSpec/ExampleLength
    klass = Class.new(Array) do
      attr_reader :calls

      def initialize
        super([1])
        @calls = []
      end

      def any?(&block)
        @calls << :any?
        super
      end
    end
    rule = {"contains" => {"type" => "integer"}}
    cases = [
      [{"allOf" => [rule, {"items" => true}]}, ->(value) { value }],
      [{"items" => rule}, ->(value) { [value] }],
      [{"properties" => {"v" => rule}}, ->(value) { {"v" => value} }],
      [{"$defs" => {"loop" => {"$ref" => "#/$defs/loop"}}, "allOf" => [rule, {"$ref" => "#/$defs/loop"}]}, ->(value) { value }],
      [{"contains" => {"anyOf" => [true, {"items" => true}]}}, ->(value) { value }],
      [{"$schema" => "https://json-schema.org/draft/2020-12/schema", "contains" => {"unevaluatedProperties" => true}}, ->(value) { value }],
      [{"$defs" => {"loop" => {"$ref" => "#/$defs/loop"}}, "contains" => {"$ref" => "#/$defs/loop"}}, ->(value) { value }],
      [{"$schema" => "https://json-schema.org/draft/2020-12/schema", "$defs" => {"x" => {"$dynamicAnchor" => "x", "type" => "integer"}},
        "contains" => {"$dynamicRef" => "#x"}}, ->(value) { value }]
    ]
    cases.each do |schema, wrap|
      native = Schemurai.compile(schema, backend: :native)
      value = klass.new
      program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
      expect(program.valid?(wrap.call(value))).to be_nil, schema.inspect
      expect(value.calls).to be_empty
      expected_value = klass.new
      expected = capture_validation(Schemurai.compile(schema, backend: :vm), :valid?, wrap.call(expected_value))
      expect(capture_validation(native, :valid?, wrap.call(value))).to eq(expected)
      expect(value.calls).to eq(expected_value.calls)
    end
  end

  it "does not replay earlier type predicates after a contains callback changes its parent" do # rubocop:disable RSpec/ExampleLength
    schema = {"allOf" => [{"type" => "array"}, {"contains" => {"type" => "string"}}]}
    results = [:vm, :native].map do |backend|
      calls = []
      parent = []
      value = Object.new
      value.define_singleton_method(:is_a?) do |type|
        calls << type
        parent.define_singleton_method(:is_a?) { |_type| false }
        type == String
      end
      parent << value
      validator = Schemurai.compile(schema, backend: backend)
      outcomes = Array.new(2) { capture_validation(validator, :valid?, parent) }
      [outcomes, calls]
    end
    expect(results.last).to eq(results.first)
  end

  it "preserves contains block exceptions, ensure clauses and scalar call order" do # rubocop:disable RSpec/ExampleLength
    klass = Class.new(Array) do
      def initialize(calls, value)
        super([value, value])
        @calls = calls
      end

      def length
        @calls << :length
        super
      end

      def any?(&block)
        @calls << :any?
        super
      rescue ArgumentError, NoMethodError => error
        @calls << [:rescue, error.class]
        true
      ensure
        @calls << :ensure
      end

      def count(&block)
        @calls << :count
        super
      rescue ArgumentError, NoMethodError => error
        @calls << [:rescue, error.class]
        Rational(3, 2)
      ensure
        @calls << :ensure
      end
    end
    value_class = Class.new do
      def initialize(calls)
        @calls = calls
      end

      def is_a?(type)
        @calls << [:is_a?, type]
        raise ArgumentError, "numeric predicate callback" if type == Numeric

        super
      end
    end
    rules = [true, {"type" => "integer"}, {"maximum" => 0}, {"minLength" => 2}, {"const" => nil}].flat_map do |child|
      [{"contains" => child}, {"$schema" => "https://json-schema.org/draft/2020-12/schema", "contains" => child, "minContains" => 0, "maxContains" => 1}]
    end
    cases = rules.product([{}, {timeout: 10}, {max_errors: 0}]).map do |schema, options|
      calls = []
      input = klass.new(calls, value_class.new(calls))
      outcome = capture_validation(Schemurai.compile(schema, backend: :vm), :valid?, input, **options)
      [Schemurai.compile(schema, backend: :native), options, outcome, calls]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    cases.each do |native, options, outcome, expected_calls|
      calls = []
      expect(capture_validation(native, :valid?, klass.new(calls, value_class.new(calls)), **options)).to eq(outcome)
      expect(calls).to eq(expected_calls)
    end
  end

  it "keeps contains callbacks alive after their original validation and compaction" do # rubocop:disable RSpec/ExampleLength
    klass = Class.new(Array) do
      attr_reader :saved

      def any?(&block)
        @saved = block
        super
      end
    end
    leaf = {"type" => "number", "multipleOf" => 0.1}
    schemas = [{"contains" => leaf}, {"contains" => {"allOf" => [leaf, {"type" => "number"}]}},
      {"$defs" => {"leaf" => leaf}, "contains" => {"allOf" => [{"$ref" => "#/$defs/leaf"}, {"$ref" => "#/$defs/leaf"}]}}]
    cases = schemas.product([{}, {timeout: 10}]).map do |schema, options|
      vm = Schemurai.compile(schema, backend: :vm)
      input = klass.new([0.2])
      expected = capture_validation(vm, :valid?, input, **options)
      expected_later = [0.3, "bad", 0.25].map { |value| capture_validation(input.saved, :call, value) }
      [Schemurai.compile(schema, backend: :native), options, expected, expected_later]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    cases.each do |native, options, expected, expected_later|
      input = klass.new([0.2])
      expect(capture_validation(native, :valid?, input, **options)).to eq(expected)
      GC.verify_compaction_references(double_heap: true, toward: :empty) if GC.respond_to?(:verify_compaction_references)
      expect([0.3, "bad", 0.25].map { |value| capture_validation(input.saved, :call, value) }).to eq(expected_later)
      expect(native.valid?(klass.new([0.2]), **options)).to be(true)
      expect(capture_validation(input.saved, :call, 0.3)).to eq(expected_later.first)
    end
  end

  it "retains nested contains callbacks in their original scope through compaction" do # rubocop:disable RSpec/ExampleLength
    array = Class.new(Array) do
      attr_reader :saved

      def any?(&block)
        @saved = block
        super
      end
    end
    schema = {"contains" => {"allOf" => [{"contains" => {"type" => "integer"}}, {"minItems" => 1}]}}
    run = lambda do |backend, options|
      inner = array.new([1])
      outer = array.new([inner])
      validator = Schemurai.compile(schema, backend: backend)
      result = capture_validation(validator, :valid?, outer, **options)
      GC.verify_compaction_references(double_heap: true, toward: :empty) if GC.respond_to?(:verify_compaction_references)
      [result, capture_validation(inner.saved, :call, 2), capture_validation(inner.saved, :call, "bad"),
        capture_validation(outer.saved, :call, array.new([3])), capture_validation(inner.saved, :call, 4)]
    end
    cases = [{}, {timeout: 10}].map { |options| [options, run.call(:vm, options)] }
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    cases.each { |options, expected| expect(run.call(:native, options)).to eq(expected) }
  end

  it "keeps nested saved contains blocks active until the outer invocation returns" do # rubocop:disable RSpec/ExampleLength
    inner_class = Class.new(Array) do
      attr_reader :saved

      def any?(&block)
        @saved = block
        super
      end
    end
    outer_class = Class.new(Array) do
      def initialize(inner, calls)
        super([inner])
        @calls = calls
      end

      def any?
        result = yield first
        GC.verify_compaction_references(double_heap: true, toward: :empty) if GC.respond_to?(:verify_compaction_references)
        @calls << first.saved.call(2)
        result
      rescue NoMethodError => error
        @calls << error.class
        false
      end
    end
    schema = {"contains" => {"contains" => {"type" => "integer"}}}
    run = lambda do |backend, options|
      calls = []
      inner = inner_class.new([1])
      value = outer_class.new(inner, calls)
      result = capture_validation(Schemurai.compile(schema, backend: backend), :valid?, value, **options)
      [result, calls, capture_validation(inner.saved, :call, 3)]
    end
    cases = [{}, {timeout: 10}].map { |options| [options, run.call(:vm, options)] }
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    cases.each { |options, expected| expect(run.call(:native, options)).to eq(expected) }
  end

  it "shares contains scalar caches with the owning evaluator across invocations" do # rubocop:disable RSpec/ExampleLength
    numeric = Class.new(Numeric) do
      def initialize(calls)
        @calls = calls
      end

      def to_s
        @calls << :decimal
        GC.verify_compaction_references(double_heap: true, toward: :empty) if GC.respond_to?(:verify_compaction_references)
        "0.2"
      end
    end
    array = Class.new(Array)
    schema = {"$schema" => "https://json-schema.org/draft/2020-12/schema",
              "contains" => {"type" => "number", "multipleOf" => 0.1}, "minContains" => 0, "maxContains" => 2}
    cases = [{}, {timeout: 10}].map do |options|
      calls = []
      vm = Schemurai.compile(schema, backend: :vm)
      input = array.new([numeric.new(calls)] * 2)
      outcomes = Array.new(3) { capture_validation(vm, :valid?, input, **options) }
      [Schemurai.compile(schema, backend: :native), options, outcomes, calls]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    cases.each do |native, options, outcomes, expected_calls|
      calls = []
      input = array.new([numeric.new(calls)] * 2)
      expect(Array.new(3) { capture_validation(native, :valid?, input, **options) }).to eq(outcomes)
      expect(calls).to eq(expected_calls)
    end
  end

  it "shares contains scalar caches between validity and remaining diagnostic execution" do # rubocop:disable RSpec/ExampleLength
    numeric = Class.new(Numeric) do
      def initialize(calls)
        @calls = calls
      end

      def to_s
        @calls << :decimal
        "0.2"
      end
    end
    schema = {"contains" => {"type" => "number", "multipleOf" => 0.1}}
    results = [:vm, :native].map do |backend|
      calls = []
      validator = Schemurai.compile(schema, backend: backend)
      value = Class.new(Array).new([numeric.new(calls)])
      outcomes = [:valid?, :validate, :valid?, :validate].map { |method| capture_validation(validator, method, value) }
      [outcomes, calls]
    end
    expect(results.last).to eq(results.first)
  end

  it "retains contains scalar caches when late registration rebuilds the native runner" do # rubocop:disable RSpec/ExampleLength
    numeric = Class.new(Numeric) do
      def initialize(calls)
        @calls = calls
      end

      def to_s
        @calls << :decimal
        "0.2"
      end
    end
    schema = {"allOf" => [{"contains" => {"type" => "number", "multipleOf" => 0.1}},
      {"anyOf" => [true, {"$ref" => "urn:later-callback"}]}]}
    results = [:vm, :native].map do |backend|
      calls = []
      registry = Schemurai::SchemaRegistry.new(backend: backend)
      validator = registry.compile(schema)
      value = Class.new(Array).new([numeric.new(calls)])
      outcomes = [:valid?, :validate].map { |method| capture_validation(validator, method, value) }
      registry.compile({"$id" => "urn:later-callback", "type" => "array"})
      outcomes.concat([:valid?, :validate].map { |method| capture_validation(validator, method, value) })
      [outcomes, calls]
    end
    expect(results.last).to eq(results.first)
  end

  it "keeps contains child exceptions at the VM deadline boundaries" do # rubocop:disable RSpec/ExampleLength
    allow(Process).to receive(:clock_gettime).and_call_original
    advance = -> { allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(0.2) }
    klass = Class.new(Array) do
      def initialize(advance, calls, value)
        super([value])
        @advance, @calls = advance, calls
      end

      def any?
        @advance.call
        yield first
      rescue ArgumentError, Schemurai::LimitExceeded => error
        @calls << error.class
        true
      ensure
        @calls << :ensure
      end
    end
    special = Object.new
    special.define_singleton_method(:is_a?) { |_type| raise ArgumentError, "predicate after clock advance" }
    delayed_advance = -> do
      sleep(0.2)
      advance.call
    end
    advances = [advance, delayed_advance]
    [{"type" => "number"}, {"minimum" => 0}, {"minLength" => 0}].product(advances).each do |child, advance_clock|
      [:vm, :native].map do |backend|
        validator = Schemurai.compile({"contains" => child}, backend: backend)
        calls = []
        allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(0.0)
        [capture_validation(validator, :valid?, klass.new(advance_clock, calls, special), timeout: 0.1), calls]
      end.then { |expected, actual| expect(actual).to eq(expected) }
    end
  end

  it "polls the native deadline between scalar yields without VM execution" do
    klass = Class.new(Array) do
      attr_reader :yields

      def any?
        @yields = 0
        1_000_000.times do
          @yields += 1
          yield 1
        end
        false
      end
    end
    native = Schemurai.compile({"contains" => true}, backend: :native)
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(0.0)
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    value = klass.new
    expect { native.valid?(value, timeout: 0.01) }.to raise_error(Schemurai::LimitExceeded) { |error| expect(error.limit).to eq(:timeout) }
    expect(value.yields || 0).to be < 1_000_000
  end

  it "isolates a reentrant native validation from its contains callback" do # rubocop:disable RSpec/ExampleLength
    klass = Class.new(Array) do
      def initialize(validator)
        super([1])
        @validator = validator
      end

      def any?
        raise "nested validation failed" unless @validator.valid?([1])

        yield first
      end
    end
    schema = {"contains" => {"type" => "integer"}}
    vm = Schemurai.compile(schema, backend: :vm)
    expected = [{}, {timeout: 10}].map { |options| capture_validation(vm, :valid?, klass.new(vm), **options) }
    native = Schemurai.compile(schema, backend: :native)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    [{}, {timeout: 10}].zip(expected).each do |options, outcome|
      expect(capture_validation(native, :valid?, klass.new(native), **options)).to eq(outcome)
    end
  end

  it "guards unsupported contains diagnostics and depth before scalar methods" do # rubocop:disable RSpec/ExampleLength
    klass = Class.new(Array) do
      attr_reader :calls

      def initialize
        super([1])
        @calls = []
      end

      def is_a?(type)
        @calls << type
        super
      end
    end
    leaf = {"minimum" => 0, "contains" => {"type" => "integer"}}
    definitions = 256.times.to_h { |index| ["n#{index}", (index == 255) ? leaf : {"$ref" => "#/$defs/n#{index + 1}"}] }
    schemas = [leaf, {"$defs" => definitions, "$ref" => "#/$defs/n0"}]
    schemas.product([:valid?, :validate]).each do |schema, method|
      outcomes = [:vm, :native].map do |backend|
        value = klass.new
        outcome = capture_validation(Schemurai.compile(schema, backend: backend), method, value)
        [outcome, value.calls]
      end
      expect(outcomes.last).to eq(outcomes.first)
    end
  end

  it "keeps native contains callbacks private to independent Ractor runners" do
    registry = Schemurai::SchemaRegistry.new(schemas: {"urn:contains" => {"contains" => {"type" => "integer"}}}, backend: :native).make_shareable
    workers = Array.new(2) do
      Ractor.new(registry) do |shared|
        runner = shared.validator_for("urn:contains").instance_variable_get(:@evaluator).instance_variable_get(:@program)
        klass = Class.new(Array)
        GC.start
        [runner.valid?(klass.new([1])), runner.valid?(klass.new(["bad"])), runner.valid?(klass.new([2]))]
      end
    end
    workers.each { |worker| expect(worker.respond_to?(:value) ? worker.value : worker.take).to eq([true, false, true]) }
  end

  it "preserves dependency triggers, key occurrences and message exceptions" do # rubocop:disable RSpec/ExampleLength
    klass = Class.new(Hash) do
      def initialize(calls)
        super()
        @calls = calls
        @triggers = 0
      end

      def length
        @calls << :length
        0
      end

      def key?(name)
        @calls << [:key?, name]
        return false unless name == "start"

        @triggers += 1
        @triggers.odd?
      end

      def each(&block)
        @calls << :each
        super
      end
    end
    calls = nil
    allow(Schemurai.const_get(:Internal)::ErrorMessage).to receive(:dependent_required).and_wrap_original do |original, name, required_name|
      calls << [:message, name, required_name]
      raise RegexpError, "dependency message callback" if required_name == "boom"

      original.call(name, required_name)
    end
    names = {"start" => ["missing", "missing", "boom"], "absent" => ["other"]}
    rules = [{"dependencies" => names}, {"$schema" => "https://json-schema.org/draft/2020-12/schema", "dependentRequired" => names}]
    wrappers = [->(rule, value) { [rule, value] }, ->(rule, value) { [{"items" => rule}, [value, value]] },
      ->(rule, value) { [{"anyOf" => [rule, false]}, value] },
      ->(rule, value) { [{"$defs" => {"v" => rule}, "allOf" => [{"$ref" => "#/$defs/v"}, {"$ref" => "#/$defs/v"}]}, value] }]
    cases = rules.product(wrappers, [:valid?, :validate], [{}, {timeout: 10}, {max_errors: 0}, {max_errors: 1}, {max_errors: 2}]).map do |rule, wrap, method, options|
      calls = []
      schema, input = wrap.call(rule, klass.new(calls))
      outcome = capture_validation(Schemurai.compile(schema, backend: :vm), method, input, **options)
      [Schemurai.compile(schema, backend: :native), wrap, rule, method, options, outcome, calls]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    cases.each do |native, wrap, rule, method, options, outcome, expected_calls|
      calls = []
      input = wrap.call(rule, klass.new(calls)).last
      expect(capture_validation(native, method, input, **options)).to eq(outcome)
      expect(calls).to eq(expected_calls)
    end
  end

  it "preserves required key occurrences, messages and short circuits" do # rubocop:disable RSpec/ExampleLength
    klass = Class.new(Hash) do
      def initialize(calls)
        super()
        @calls = calls
        @lookups = 0
      end

      def length
        @calls << :length
        1
      end

      def key?(name)
        @calls << [:key?, name]
        @lookups += 1
        raise ArgumentError, "third key lookup" if @lookups == 3

        false
      end

      def each(&block)
        @calls << :each
        super
      end
    end
    calls = nil
    allow(Schemurai.const_get(:Internal)::ErrorMessage).to receive(:required).and_wrap_original do |original, name|
      calls << [:message, name]
      original.call(name)
    end
    wrappers = [->(rule) { rule }, ->(rule) { {"anyOf" => [rule, false]} },
      ->(rule) { {"oneOf" => [rule, false]} }, ->(rule) { {"not" => rule} },
      ->(rule) { {"if" => rule, "then" => true, "else" => false} },
      ->(rule) { {"$defs" => {"v" => rule}, "allOf" => [{"$ref" => "#/$defs/v"}, {"$ref" => "#/$defs/v"}]} }]
    schemas = wrappers.flat_map do |wrap|
      [wrap.call({"required" => ["x", "x", "y"]}), wrap.call({"maxProperties" => 0, "required" => ["x", "x", "y"]})]
    end
    cases = schemas.product([:valid?, :validate], [{}, {timeout: 10}, {max_errors: 0}, {max_errors: 1}, {max_errors: 2}]).map do |schema, method, options|
      calls = []
      outcome = capture_validation(Schemurai.compile(schema, backend: :vm), method, klass.new(calls), **options)
      [Schemurai.compile(schema, backend: :native), method, options, outcome, calls]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    cases.each do |native, method, options, outcome, expected_calls|
      calls = []
      expect(capture_validation(native, method, klass.new(calls), **options)).to eq(outcome)
      expect(calls).to eq(expected_calls)
    end
  end

  it "roots generated required and dependency keys and retains message exceptions" do # rubocop:disable RSpec/ExampleLength
    cases = [false, true].flat_map do |explode|
      klass = Class.new(Hash)
      klass.define_method(:key?) do |name|
        return true if name == "start"

        name.define_singleton_method(:inspect) do
          GC.verify_compaction_references(double_heap: true, toward: :empty) if GC.respond_to?(:verify_compaction_references)
          raise RegexpError, "required message callback" if explode

          super()
        end
        false
      end
      [{"required" => {"x" => 1, "y" => 2}},
        {"$schema" => "https://json-schema.org/draft/2020-12/schema", "dependentRequired" => {"start" => {"x" => 1, "y" => 2}}}].map do |schema|
        vm = Schemurai.compile(schema, backend: :vm)
        native = Schemurai.compile(schema, backend: :native)
        options = [{}, {timeout: 10}, {max_errors: 0}, {max_errors: 1}]
        expected = options.map { |limits| capture_validation(vm, :validate, klass.new, **limits) }
        [native, klass, options, expected]
      end
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    cases.each do |native, klass, options, expected|
      options.zip(expected).each do |limits, result|
        expect(capture_validation(native, :validate, klass.new, **limits)).to eq(result)
      end
    end
  end

  it "preserves container length reads, message reads and trial short circuits" do # rubocop:disable RSpec/ExampleLength
    [Array, Hash].each do |base|
      klass = Class.new(base) do
        attr_reader :calls
        def initialize
          super
          @calls = []
          @reads = 0
        end

        def is_a?(type)
          @calls << [:is_a?, type]
          super
        end

        def length
          @reads += 1
          @calls << [:length, @reads]
          @reads % 5
        end

        def each(*args, &block)
          @calls << :each
          super
        end
      end
      rule = (base == Array) ? {"maxItems" => 0, "minItems" => 4, "uniqueItems" => true} : {"maxProperties" => 0, "minProperties" => 4}
      schemas = [rule, rule.merge("type" => "string"), {"items" => rule}, {"properties" => {"v" => rule}},
        {"contains" => rule}, {"anyOf" => [rule, rule]}, {"oneOf" => [rule, rule]}, {"not" => rule},
        {"if" => rule, "then" => rule, "else" => rule},
        {"$defs" => {"v" => rule}, "allOf" => [{"$ref" => "#/$defs/v"}, {"$ref" => "#/$defs/v"}]}]
      schemas << {"items" => []} if base == Array
      schemas.each do |schema|
        [:valid?, :validate].product([{}, {timeout: 10}, {max_errors: 0}, {max_errors: 1}]).each do |method, options|
          vm = Schemurai.compile(schema, backend: :vm)
          native = Schemurai.compile(schema, backend: :native)
          evaluator = native.instance_variable_get(:@evaluator)
          allow(evaluator.instance_variable_get(:@vm)).to receive(:valid?).and_raise("VM execution")
          allow(evaluator.instance_variable_get(:@vm)).to receive(:validate).and_raise("VM execution")
          allow(evaluator).to receive(:limited_vm).and_raise("VM execution")
          values = Array.new(2) do
            value = klass.new
            (base == Array) ? value.concat([1, 1]) : value.merge!("x" => 1)
            value
          end
          inputs = values.map do |value|
            if schema["items"].is_a?(Hash) || schema.key?("contains")
              [value]
            elsif schema.key?("properties")
              {"v" => value}
            else
              value
            end
          end
          [options, {}, options].each do |limits|
            values.each { |value| value.calls.clear }
            expected = capture_validation(vm, method, inputs.first, **limits)
            expect(capture_validation(native, method, inputs.last, **limits)).to eq(expected)
            expect(values.last.calls).to eq(values.first.calls), [base, schema, method, limits].inspect
          end
        end
      end
    end
  end

  it "keeps container exceptions ahead of deadline checks between runtime stages" do # rubocop:disable RSpec/ExampleLength
    allow(Process).to receive(:clock_gettime).and_call_original
    advance = -> { allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(0.2) }
    [Array, Hash].each do |base|
      klass = Class.new(base) do
        def initialize(advance)
          super()
          @advance = advance
          @reads = 0
        end

        def length
          @reads += 1
          @advance.call
          raise ArgumentError, "later container length" if @reads > 1

          1
        end

        def each(*) = raise(ArgumentError, "later container each")
      end
      rules = (base == Array) ? [{"maxItems" => 2, "minItems" => 0}, {"maxItems" => 0}] :
        [{"maxProperties" => 2, "minProperties" => 0}, {"maxProperties" => 0}, {"maxProperties" => 2}]
      rules.each do |rule|
        [:valid?, :validate].each do |method|
          outcomes = [:vm, :native].map do |backend|
            validator = Schemurai.compile(rule, backend: backend)
            allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(0.0)
            capture_validation(validator, method, klass.new(advance), timeout: 0.1)
          end
          expect(outcomes.last).to eq(outcomes.first)
          expect(outcomes.last[1]).to eq((method == :valid?) ? Schemurai::LimitExceeded : ArgumentError)
        end
      end
    end
  end

  it "retains container iterator exceptions and message exceptions after earlier error limits" do # rubocop:disable RSpec/ExampleLength
    cases = [Array, Hash].product([:length, :each, :each_with_index]).flat_map do |base, method|
      klass = Class.new(base) { define_method(method) { |*| raise RegexpError, "container #{method}" } }
      value = (base == Array) ? klass.new([1, 1]) : klass["a", 1]
      rule = (base == Array) ? {"maxItems" => 0, "minItems" => 3, "uniqueItems" => true} : {"maxProperties" => 0, "minProperties" => 3}
      [rule, {"anyOf" => [rule, true]}, {"contains" => rule}].map do |schema|
        input = schema.key?("contains") ? [value] : value
        vm = Schemurai.compile(schema, backend: :vm)
        expected = [:valid?, :validate].product([{}, {timeout: 10}, {max_errors: 0}, {max_errors: 1}]).map do |operation, options|
          [operation, options, capture_validation(vm, operation, input, **options)]
        end
        [Schemurai.compile(schema, backend: :native), input, expected]
      end
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    cases.each do |native, input, expected|
      expected.each { |operation, options, result| expect(capture_validation(native, operation, input, **options)).to eq(result) }
    end
  end

  it "roots arbitrary container length results while rendering messages during compaction" do
    length = Class.new do
      def >(_other) = true
      def <(_other) = true

      def to_s
        GC.verify_compaction_references(double_heap: true, toward: :empty)
        "virtual"
      end
    end
    value = Class.new(Hash).new
    value.define_singleton_method(:length) { length.new }
    rule = {"maxProperties" => 0, "minProperties" => 4}
    expect_native_policy_results([rule, {"allOf" => [rule, rule]}], [value])
  end

  it "keeps container header frames private to independent Ractor runners" do
    schemas = {"urn:array-header" => {"maxItems" => 0, "uniqueItems" => true},
               "urn:object-header" => {"minProperties" => 2, "required" => ["y", "y"], "dependencies" => {"x" => ["z", "z"]}}}
    registry = Schemurai::SchemaRegistry.new(schemas: schemas, backend: :native).make_shareable
    workers = Array.new(2) do
      Ractor.new(registry) do |shared|
        array = shared.validator_for("urn:array-header").instance_variable_get(:@evaluator).instance_variable_get(:@program)
        object = shared.validator_for("urn:object-header").instance_variable_get(:@evaluator).instance_variable_get(:@program)
        values = [Class.new(Array).new([1, 1]), Class.new(Hash)["x", 1]]
        GC.start
        [array.valid?(values.first), array.diagnostics(values.first).map(&:first),
          object.valid?(values.last), object.diagnostics(values.last).map(&:first)]
      end
    end
    workers.each { |worker| expect(worker.respond_to?(:value) ? worker.value : worker.take).to eq([false, %w[maxItems uniqueItems], false, %w[minProperties required required dependencies dependencies]]) }
  end

  it "compares special values for const and enum without VM execution" do # rubocop:disable RSpec/ExampleLength
    fake = Object.new
    fake.define_singleton_method(:class) { Array }
    fake.define_singleton_method(:length) { 1 }
    fake.define_singleton_method(:[]) { |_index| 1 }
    values = [Rational(3, 2), Rational(1, 1), Complex(1, 2), BasicObject.new, Class.new.new,
      Class.new(String).new("a"), Class.new(Array).new([1]), Class.new(Hash)["a", 1], {Object.new => 1}, fake]
    choices = [nil, true, false, 1, 1.5, "a", [1], {"a" => 1}]
    rules = choices.map { |value| {"const" => value} } + [{"enum" => choices},
      {"enum" => Array.new(17) { |index| index }}, {"enum" => Array.new(17) { |index| [index] }}]
    wrappers = [->(rule, value) { [rule, value] }, ->(rule, value) { [{"items" => rule}, [value, value]] },
      ->(rule, value) { [{"properties" => {"v~/s" => rule}}, {"v~/s" => value}] },
      ->(rule, value) { [{"contains" => rule}, [value]] },
      ->(rule, value) { [{"$defs" => {"v" => rule}, "allOf" => [{"$ref" => "#/$defs/v"}, {"$ref" => "#/$defs/v"}]}, value] }]
    cases = rules.product(wrappers).map do |rule, wrap|
      schema = wrap.call(rule, nil).first
      vm = Schemurai.compile(schema, backend: :vm)
      expected = values.product([:valid?, :validate], [{}, {timeout: 10}, {max_errors: 0}, {max_errors: 1}]).map do |value, method, options|
        input = wrap.call(rule, value).last
        [input, method, options, capture_validation(vm, method, input, **options)]
      end
      [Schemurai.compile(schema, backend: :native), expected]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    cases.each do |native, expected|
      expected.each { |input, method, options, result| expect(capture_validation(native, method, input, **options)).to eq(result) }
    end
  end

  it "uses Ruby equality and fingerprints across the uniqueItems indexing threshold" do # rubocop:disable RSpec/ExampleLength
    special = [Rational(1, 1), Rational(3, 2), Complex(1, 2), Class.new.new,
      Class.new(String).new("a"), Class.new(Array).new([1]), Class.new(Hash)["a", 1], {Object.new => 1}, BasicObject.new]
    inputs = special.product([0, 1, 2, 16, 17, 33]).flat_map do |value, count|
      prefix = Array.new(count) { |index| index }
      [prefix + [value], prefix + [value, value], prefix + [[value], [value]], prefix + [{"a" => value}, {"a" => value}]]
    end
    schemas = [{"uniqueItems" => true}, {"type" => "array", "uniqueItems" => true, "maxItems" => 0},
      {"allOf" => [{"uniqueItems" => true}, {"uniqueItems" => true}]}]
    cases = schemas.map do |schema|
      vm = Schemurai.compile(schema, backend: :vm)
      expected = inputs.product([:valid?, :validate], [{}, {timeout: 10}, {max_errors: 0}, {max_errors: 1}]).map do |value, method, options|
        [value, method, options, capture_validation(vm, method, value, **options)]
      end
      [Schemurai.compile(schema, backend: :native), expected]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    cases.each do |native, expected|
      expected.each { |input, method, options, result| expect(capture_validation(native, method, input, **options)).to eq(result) }
    end
  end

  it "preserves schema-order enum comparisons and Ruby collection access methods" do # rubocop:disable RSpec/ExampleLength
    proxy = Class.new do
      attr_reader :calls
      def initialize
        @calls = []
      end

      def class
        @calls << :class
        Array
      end

      def length
        @calls << :length
        1
      end

      def [](index)
        @calls << [:entry, index]
        7
      end
    end
    choices = Array.new(24) { |index| [index] }
    rules = [{"const" => [7]}, {"enum" => choices}, {"enum" => choices.reverse}]
    rules.each do |rule|
      schemas = [rule, {"items" => rule}, {"anyOf" => [rule, rule]},
        {"$defs" => {"v" => rule}, "allOf" => [{"$ref" => "#/$defs/v"}, {"$ref" => "#/$defs/v"}]}]
      schemas.each do |schema|
        [:valid?, :validate].product([{}, {timeout: 10}, {max_errors: 0}]).each do |method, options|
          vm = Schemurai.compile(schema, backend: :vm)
          native = Schemurai.compile(schema, backend: :native)
          evaluator = native.instance_variable_get(:@evaluator)
          allow(evaluator.instance_variable_get(:@vm)).to receive(:valid?).and_raise("VM execution")
          allow(evaluator.instance_variable_get(:@vm)).to receive(:validate).and_raise("VM execution")
          allow(evaluator).to receive(:limited_vm).and_raise("VM execution")
          values = [proxy.new, proxy.new]
          inputs = values.map { |value| schema.key?("items") ? [value, value] : value }
          2.times do
            values.each { |value| value.calls.clear }
            expected = capture_validation(vm, method, inputs.first, **options)
            expect(capture_validation(native, method, inputs.last, **options)).to eq(expected)
            expect(values.last.calls).to eq(values.first.calls)
          end
        end
      end
    end
  end

  it "preserves stateful uniqueItems equality and hash calls in repeated branches" do # rubocop:disable RSpec/ExampleLength
    klass = Class.new do
      def initialize(events, role)
        @events = events
        @role = role
        @comparisons = 0
      end

      def is_a?(type)
        @events << [@role, :is_a?, type]
        super
      end

      def class
        @events << [@role, :class]
        super
      end

      def instance_of?(type)
        @events << [@role, :instance_of?, type]
        super
      end

      def hash
        @events << [@role, :hash]
        17
      end

      def ==(_other)
        @events << [@role, :equal]
        @comparisons += 1
        @comparisons.even?
      end
    end
    rule = {"uniqueItems" => true}
    schemas = [rule, {"allOf" => [rule, rule]}, {"anyOf" => [rule, rule]}, {"oneOf" => [rule, rule]},
      {"not" => rule}, {"contains" => rule},
      {"$defs" => {"v" => rule}, "allOf" => [{"$ref" => "#/$defs/v"}, {"$ref" => "#/$defs/v"}]}]
    schemas.product([0, 17]).each do |schema, count|
      [:valid?, :validate].product([{}, {timeout: 10}, {max_errors: 0}, {max_errors: 1}]).each do |method, options|
        vm = Schemurai.compile(schema, backend: :vm)
        native = Schemurai.compile(schema, backend: :native)
        evaluator = native.instance_variable_get(:@evaluator)
        allow(evaluator.instance_variable_get(:@vm)).to receive(:valid?).and_raise("VM execution")
        allow(evaluator.instance_variable_get(:@vm)).to receive(:validate).and_raise("VM execution")
        allow(evaluator).to receive(:limited_vm).and_raise("VM execution")
        events = [[], []]
        inputs = events.map do |calls|
          value = Array.new(count) { |index| index } + [klass.new(calls, :left), klass.new(calls, :right)]
          schema.key?("contains") ? [value] : value
        end
        [options, {}, options].each do |limits|
          events.each(&:clear)
          expected = capture_validation(vm, method, inputs.first, **limits)
          expect(capture_validation(native, method, inputs.last, **limits)).to eq(expected)
          expect(events.last).to eq(events.first), [schema, count, method, limits].inspect
        end
      end
    end
  end

  it "retains equality and fingerprint exceptions after earlier error limits" do # rubocop:disable RSpec/ExampleLength
    methods = [:hash, :class, :is_a?, :==]
    cases = methods.flat_map do |method|
      value = Object.new
      value.define_singleton_method(method) { |*| raise "value #{method}" }
      schemas = [{"const" => "x"}, {"const" => 1}, {"enum" => (0...24).to_a},
        {"uniqueItems" => true}, {"maxItems" => 0, "uniqueItems" => true}]
      schemas.flat_map do |schema|
        inputs = schema.key?("uniqueItems") ? [[value, value], (0...17).to_a + [value], (0...17).to_a + [value, value]] : [value]
        vm = Schemurai.compile(schema, backend: :vm)
        expected = inputs.product([:valid?, :validate], [{}, {timeout: 10}, {max_errors: 0}, {max_errors: 1}]).map do |input, operation, options|
          [input, operation, options, capture_validation(vm, operation, input, **options)]
        end
        [[Schemurai.compile(schema, backend: :native), expected]]
      end
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    cases.each do |native, expected|
      expected.each { |input, operation, options, result| expect(capture_validation(native, operation, input, **options)).to eq(result) }
    end
  end

  it "roots Ruby equality operands while custom access methods compact the heap" do
    proxy = Class.new do
      def class = Array
      def length = 1

      def [](_index)
        GC.verify_compaction_references(double_heap: true, toward: :empty)
        Rational(1, 1)
      end
    end
    schemas = [{"const" => [1]}, {"enum" => Array.new(24) { |index| [index] }},
      {"allOf" => [{"const" => [1]}, {"const" => [1]}]}]
    expect_native_policy_results(schemas, [proxy.new])
  end

  it "runs libruby equality primitives on independent Ractor runners" do
    schema = {"items" => {"enum" => Array.new(24) { |index| [index] }}}
    registry = Schemurai::SchemaRegistry.new(schemas: {"urn:equality" => schema}, backend: :native).make_shareable
    workers = Array.new(2) do
      Ractor.new(registry) do |shared|
        proxy = Class.new do
          def class = Array
          def length = 1
          def [](_index) = 7
        end
        validator = shared.validator_for("urn:equality")
        runner = validator.instance_variable_get(:@evaluator).instance_variable_get(:@program)
        value = [proxy.new]
        GC.start
        [runner.valid?(value), runner.diagnostics(value)]
      end
    end
    workers.each { |worker| expect(worker.respond_to?(:value) ? worker.value : worker.take).to eq([true, []]) }
  end

  it "borrows guarded container and string views for structural fingerprints" do # rubocop:disable RSpec/ExampleLength
    values = Array.new(40) do |i|
      {"id" => i, "nested" => [nil, true, false, [], {}, "", "日", "\xff".b, "x" * 1024, i + 0.5]}
    end
    datasets = [values, values + [values[17].dup],
      Array.new(40) { |i| [i, "", [], {}] }, Array.new(40) { |i| [i, [nil, true, false]] }]
    vm = Schemurai.compile({"uniqueItems" => true}, backend: :vm)
    expected = datasets.map { |value| [vm.valid?(value), vm.validate(value).errors] }
    native = Schemurai.compile({"uniqueItems" => true}, backend: :native)
    program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
    [Class.new(Array).new, Class.new(Hash).new, Class.new(String).new("item")].each do |special|
      expect(program.valid?(values + [{"special" => special}])).to be(true)
      expect(program.diagnostics(values + [{"special" => special}])).to eq([])
      duplicates = values + Array.new(2) { {"special" => special} }
      expect(program.valid?(duplicates)).to be(false)
      expect(program.diagnostics(duplicates)).not_to be_nil
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    datasets.zip(expected).each do |value, (valid, errors)|
      expect(native.valid?(value)).to eq(valid)
      expect(native.validate(value).errors).to eq(errors)
    end
  end

  it "hashes Bignums without Ruby hash callbacks" do
    script = <<~RUBY
      require "schemurai"
      validator = Schemurai.compile({"uniqueItems" => true}, backend: :native)
      values = Array.new(40) { |i| 2**200 + i }.shuffle(random: Random.new(9571))
      Integer.define_method(:hash) { raise "Ruby Integer#hash callback" }
      Integer.define_method(:to_int) { raise "Ruby Integer#to_int callback" }
      vm = Schemurai.const_get(:VM)::Evaluator
      vm.define_method(:valid?) { |_| raise "VM execution" }
      vm.define_method(:validate) { |_| raise "VM execution" }
      abort "expected unique integers" unless validator.valid?(values)
      abort "expected duplicate integers" if validator.valid?(values + [2**200 + 17])
      abort "expected Float duplicate" if validator.valid?(values + [(2**200).to_f])
      abort "expected duplicate diagnostic" if validator.validate(values + [2**200 + 17]).valid?
    RUBY
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-W0", "-Ilib", "-Iext/schemurai_native", "-e", script)
    expect(status.success?).to be(true), stderr
  end

  it "reuses shared inputs through cyclic static dynamic and recursive schemas" do # rubocop:disable RSpec/ExampleLength
    schemas = [
      [{"$defs" => {"n" => {"anyOf" => [{"type" => "integer", "minimum" => 3},
        {"type" => "array", "items" => {"$ref" => "#/$defs/n"}}]}}, "$ref" => "#/$defs/n"}, ->(child) { [child, child] }],
      [{"$defs" => {"n" => {"anyOf" => [{"type" => "integer", "minimum" => 3},
        {"type" => "object", "properties" => {"a" => {"$ref" => "#/$defs/n"}, "b" => {"$ref" => "#/$defs/n"}}}]}},
        "$ref" => "#/$defs/n"}, ->(child) { {"a" => child, "b" => child} }],
      [{"anyOf" => [{"type" => "integer", "minimum" => 3},
        {"type" => "object", "properties" => {"a" => {"$ref" => "#"}, "b" => {"$ref" => "#"}}}]},
        ->(child) { {"a" => child, "b" => child} }],
      [{"$schema" => "https://json-schema.org/draft/2020-12/schema", "$dynamicAnchor" => "n",
        "anyOf" => [{"type" => "integer", "minimum" => 3},
          {"type" => "object", "properties" => {"a" => {"$dynamicRef" => "#n"}, "b" => {"$dynamicRef" => "#n"}}}]},
        ->(child) { {"a" => child, "b" => child} }],
      [{"$schema" => "https://json-schema.org/draft/2019-09/schema", "$recursiveAnchor" => true,
        "anyOf" => [{"type" => "integer", "minimum" => 3},
          {"type" => "object", "properties" => {"a" => {"$recursiveRef" => "#"}, "b" => {"$recursiveRef" => "#"}}}]},
        ->(child) { {"a" => child, "b" => child} }],
      [{"$schema" => "https://json-schema.org/draft/2020-12/schema", "$dynamicAnchor" => "n",
        "anyOf" => [{"type" => "integer", "minimum" => 3}, {"type" => "array", "items" => {"$dynamicRef" => "#n"}}]},
        ->(child) { [child, child] }],
      [{"$schema" => "https://json-schema.org/draft/2019-09/schema", "$recursiveAnchor" => true,
        "anyOf" => [{"type" => "integer", "minimum" => 3}, {"type" => "array", "items" => {"$recursiveRef" => "#"}}]},
        ->(child) { [child, child] }]
    ]
    schemas.each do |schema, shape|
      native = Schemurai.compile(schema, backend: :native)
      program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
      value = 8
      32.times { value = shape.call(value) }
      expect(program.valid?(value)).to be(true)
      expect(program.diagnostics(value)).to eq([])
      vm = Schemurai.compile(schema, backend: :vm)
      [2, 8, "bad"].each do |leaf|
        shallow = leaf
        4.times { shallow = shape.call(shallow) }
        expect(program.valid?(shallow)).to eq(vm.valid?(shallow))
        expect(program.diagnostics(shallow)).not_to be_nil
        expect(native.validate(shallow).errors).to eq(vm.validate(shallow).errors)
      end
    end
  end

  it "preserves cyclic instance guard membership and bounded input proofs" do # rubocop:disable RSpec/ExampleLength
    schema = {"anyOf" => [{"type" => "integer", "minimum" => 3}, {"type" => "array", "items" => {"$ref" => "#"}}]}
    native = Schemurai.compile(schema, backend: :native)
    program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
    vm = Schemurai.compile(schema, backend: :vm)
    direct = []
    direct.push(direct, 8)
    a = []
    b = [a, 8]
    a.push(b, b)
    wide = Array.new(4200) { [8] }
    values = [direct, a, [[wide, wide], [wide, wide]]]
    values.each do |value|
      expect(program.valid?(value)).to eq(vm.valid?(value))
      expect(program.diagnostics(value)).not_to be_nil
      expect(native.validate(value).errors).to eq(vm.validate(value).errors)
    end
    direct[1] = 2
    expect(program.valid?(direct)).to eq(vm.valid?(direct))
    expect(native.validate(direct).errors).to eq(vm.validate(direct).errors)
  end

  it "separates cyclic dynamic and recursive overrides at the same shared value" do # rubocop:disable RSpec/ExampleLength
    [true, false].each do |dynamic|
      dialect = {"$schema" => dynamic ? "https://json-schema.org/draft/2020-12/schema" : "https://json-schema.org/draft/2019-09/schema"}
      anchor = dynamic ? {"$dynamicAnchor" => "n"} : {"$recursiveAnchor" => true}
      ref = dynamic ? {"$dynamicRef" => "#n"} : {"$recursiveRef" => "#"}
      resources = {
        "urn:base" => dialect.merge(anchor).merge("$id" => "urn:base",
          "anyOf" => [{"type" => "integer"}, {"type" => "array", "items" => ref}]),
        "urn:loose" => dialect.merge(anchor).merge("$id" => "urn:loose", "$ref" => "urn:base", "minimum" => 3),
        "urn:strict" => dialect.merge(anchor).merge("$id" => "urn:strict", "$ref" => "urn:base", "minimum" => 7)
      }
      schema = dialect.merge("allOf" => [{"$ref" => "urn:loose"}, {"$ref" => "urn:strict"}])
      native = Schemurai.compile(schema, schemas: resources, backend: :native)
      program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
      deep = 8
      24.times { deep = [deep, deep] }
      expect(program.valid?(deep)).to be(true)
      expect(program.diagnostics(deep)).to eq([])
      vm = Schemurai.compile(schema, schemas: resources, backend: :vm)
      [2, 5, 8, "bad"].each do |leaf|
        value = leaf
        4.times { value = [value, value] }
        expect(program.valid?(value)).to eq(vm.valid?(value))
        expect(native.validate(value).errors).to eq(vm.validate(value).errors)
      end
    end
  end

  it "memoizes shared schema chains whose leaf has a reference cycle" do # rubocop:disable RSpec/ExampleLength
    definitions = {"cycle" => {"$ref" => "#/$defs/cycle"}, "n0" => {"$ref" => "#/$defs/cycle"}}
    1.upto(32) { |i| definitions["n#{i}"] = {"allOf" => Array.new(2) { {"$ref" => "#/$defs/n#{i - 1}"} }} }
    native = Schemurai.compile({"$defs" => definitions, "$ref" => "#/$defs/n32"}, backend: :native)
    program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
    expect(program.valid?(8)).to be(true)
    expect(program.diagnostics(8)).to eq([])
  end

  it "reuses acyclic children evaluated at repeated instance positions" do # rubocop:disable RSpec/ExampleLength
    dialect = {"$schema" => "https://json-schema.org/draft/2020-12/schema"}
    rules = [
      [->(ref) { {"items" => ref} }, ->(v) { [v, v] }],
      [->(ref) { {"contains" => ref, "minContains" => 2} }, ->(v) { [v, v] }],
      [->(ref) { {"unevaluatedItems" => ref} }, ->(v) { [v, v] }],
      [->(ref) { {"additionalProperties" => ref} }, ->(v) { {"x" => v, "y" => v} }],
      [->(ref) { {"patternProperties" => {"." => ref}} }, ->(v) { {"x" => v, "y" => v} }],
      [->(ref) { {"unevaluatedProperties" => ref} }, ->(v) { {"x" => v, "y" => v} }]
    ]
    rules.each do |rule, shape|
      [4, 24].each do |depth|
        definitions = {"n0" => {"type" => "integer"}}
        value = 0
        1.upto(depth) do |i|
          definitions["n#{i}"] = rule.call({"$ref" => "#/$defs/n#{i - 1}"})
          value = shape.call(value)
        end
        schema = dialect.merge("$defs" => definitions, "$ref" => "#/$defs/n#{depth}")
        native = Schemurai.compile(schema, backend: :native)
        program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
        expect(program.valid?(value)).to be(true)
        expect(program.diagnostics(value)).to eq([])
        if depth == 4
          invalid = "bad"
          depth.times { invalid = shape.call(invalid) }
          vm = Schemurai.compile(schema, backend: :vm)
          expect(native.valid?(invalid)).to eq(vm.valid?(invalid))
          expect(native.validate(invalid).errors).to eq(vm.validate(invalid).errors)
        end
      end
    end
  end

  it "compiles shared constant and enum operands without expanding their graphs" do # rubocop:disable RSpec/ExampleLength
    leaf = [+"fixed"]
    value = leaf
    32.times { value = [value, value] }
    [{"const" => value}, {"enum" => [value, *Array.new(17, "padding")]}].each do |schema|
      validator = Schemurai.compile(schema, backend: :native)
      program = validator.instance_variable_get(:@evaluator).instance_variable_get(:@program)
      expect(program.valid?(value)).to be(true)
      expect(program.diagnostics(value)).not_to be_nil
      leaf[0].replace("changed")
      expect(program.valid?(value)).to be(false)
      leaf[0].replace("fixed")
    end
  end

  it "indexes shared enum candidates with exact structural matching" do # rubocop:disable RSpec/ExampleLength
    shared = Array.new(128) { |i| [i, "value#{i}"] }
    values = Array.new(64) { |i| [i, shared] }
    schema = {"enum" => values}
    native = Schemurai.compile(schema, backend: :native)
    program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
    expect(program.valid?(values.last)).to be(true)
    expect(program.valid?([64, shared])).to be(false)
    shared[0][0] = -1
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    expect(program.valid?(values.last)).to be(false)
    shared[0][0] = 0
    expect(program.valid?(values.last)).to be(true)
    expect(program.diagnostics(values.last)).not_to be_nil
  end

  it "checks shared container graphs without expanding repeated descendants" do # rubocop:disable RSpec/ExampleLength
    shapes = [->(child) { [child, 1, child] }, ->(child) { {"a" => child, "b" => 1, "c" => child} }]
    native = Schemurai.compile({"uniqueItems" => true}, backend: :native)
    program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
    shapes.each do |shape|
      left = right = 0
      32.times do
        left = shape.call(left)
        right = shape.call(right)
      end
      [[], Array.new(17) { |i| "padding#{i}" }].each do |padding|
        values = [*padding, left, right]
        expect(program.valid?(values)).to be(false)
        expect(program.diagnostics(values)).not_to be_nil
      end
    end
  end

  it "shares batch fingerprints without reusing stale or wrong-depth containers" do # rubocop:disable RSpec/ExampleLength
    shared = Array.new(128) { |i| [i, "value#{i}"] }
    values = Array.new(64) { |i| [i, shared] }
    native = Schemurai.compile({"uniqueItems" => true}, backend: :native)
    program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
    expect(program.valid?(values)).to be(true)
    expect(program.diagnostics(values)).not_to be_nil
    values[-1][0] = 0
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    expect(program.valid?(values)).to be(false)
    values[-1][0] = 63
    expect(program.valid?(values)).to be(true)
    # The same container is reachable at shallow and deep fingerprint depths.
    # Exact native comparisons remain available when the deeper hash declines.
    deep = shared
    520.times { deep = [deep] }
    expect(program.valid?([*values, deep])).to be(true)
    expect(program.diagnostics([*values, deep])).not_to be_nil
    shared[0] = Object.new
    expect(program.valid?(values)).to be(true)
    values[-1][0] = 0
    expect(program.valid?(values)).to be(false)
  end

  it "discards structural results between calls and after compaction" do # rubocop:disable RSpec/ExampleLength
    leaf = [0.0]
    shared = [leaf, 1, leaf]
    other_leaf = [0.0]
    other = [other_leaf, 1, other_leaf]
    padding = Array.new(17) { |i| "padding#{i}" }
    native = Schemurai.compile({"uniqueItems" => true}, backend: :native)
    vm = Schemurai.compile({"uniqueItems" => true}, backend: :vm)
    [0.0, 1.0, Float::NAN, Float::INFINITY, 0.0].each do |number|
      leaf[0] = number
      GC.verify_compaction_references(double_heap: true, toward: :empty)
      [[], padding].each do |prefix|
        values = [*prefix, shared, other]
        expect(native.valid?(values)).to eq(vm.valid?(values))
        expect(native.validate(values).errors).to eq(vm.validate(values).errors)
      end
    end
  end

  it "compares shared containers recursively for non-finite uniqueness" do # rubocop:disable RSpec/ExampleLength
    containers = [Float::NAN, Float::INFINITY, -Float::INFINITY, 0.0, -0.0].flat_map do |number|
      [[number], {"number" => number}, [{"nested" => [number]}]]
    end
    padding = Array.new(17) { |i| "padding#{i}" }
    datasets = containers.flat_map do |container|
      [[container, container], [*padding, container, container]]
    end
    schema = {"uniqueItems" => true}
    vm = Schemurai.compile(schema, backend: :vm)
    expected = datasets.map { |value| [vm.valid?(value), vm.validate(value).errors] }
    native = Schemurai.compile(schema, backend: :native)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    datasets.zip(expected).each do |value, (valid, errors)|
      expect(native.valid?(value)).to eq(valid), value.inspect
      expect(native.validate(value).errors).to eq(errors), value.inspect
    end
  end

  it "uses libruby for shared containers with custom nested equality" do # rubocop:disable RSpec/ExampleLength
    value_class = Class.new do
      def ==(_other) = false
    end
    value = value_class.new
    containers = [[value], {"value" => value}]
    schema = {"uniqueItems" => true}
    vm = Schemurai.compile(schema, backend: :vm)
    native = Schemurai.compile(schema, backend: :native)
    program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
    containers.each do |container|
      values = [container, container]
      expect(program.valid?(values)).to be(true)
      expect(program.diagnostics(values)).to eq([])
      expect(native.valid?(values)).to eq(vm.valid?(values))
      expect(native.validate(values).errors).to eq(vm.validate(values).errors)
    end
  end

  it "checks container constants and enums against non-finite values" do # rubocop:disable RSpec/ExampleLength
    shapes = [->(number) { [number] }, ->(number) { {"number" => number} }, ->(number) { [{"nested" => [number]}] }]
    cases = shapes.flat_map do |shape|
      container = shape.call(0.0)
      values = [container, *[Float::NAN, Float::INFINITY, -Float::INFINITY, -0.0].map { |number| shape.call(number) }]
      [{"const" => container}, {"enum" => [container]}].map do |schema|
        vm = Schemurai.compile(schema, backend: :vm)
        [Schemurai.compile(schema, backend: :native), values.map { |value| [value, vm.valid?(value), vm.validate(value).errors] }]
      end
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |native, values|
      values.each do |value, valid, errors|
        expect(native.valid?(value)).to eq(valid), value.inspect
        expect(native.validate(value).errors).to eq(errors), value.inspect
      end
    end
  end

  it "matches mixed numeric enums including the largest finite Float" do # rubocop:disable RSpec/ExampleLength
    schema = {"enum" => [Float::MAX, -(2**200), {"id" => 2**4096}]}
    values = [Float::MAX.to_i, Float::MAX.to_i + 1, -(2**200).to_f, {"id" => 2**4096}, {"id" => 2**4096 + 1}, 0]
    vm = Schemurai.compile(schema, backend: :vm)
    expected = values.map { |value| [vm.valid?(value), vm.validate(value).errors] }
    native = Schemurai.compile(schema, backend: :native)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    values.zip(expected).each do |value, (valid, errors)|
      expect(native.valid?(value)).to eq(valid), value.inspect
      expect(native.validate(value).errors).to eq(errors), value.inspect
    end
  end

  it "indexes large enums with exact numeric and structural equality after compaction" do # rubocop:disable RSpec/ExampleLength
    integers = [-(2**62), -(2**53) - 1, -1, 0, 1, 2**53, 2**53 + 1, 2**62, 2**200, 2**1024, 2**4096]
    choices = integers + [Float::MAX, 0.5, nil, true, false, "item", [1, "two"], {"id" => 1, "nested" => [2, "three"]}]
    rule = {"enum" => choices}
    values = choices + integers.map(&:to_f) + [Float::NAN, Float::INFINITY, -Float::INFINITY, -0.0,
      {"nested" => [2.0, "three"], "id" => 1.0}, [1.0, "two"], [1, "bad"], {"id" => 1, "nested" => [3, "three"]}, "missing"]
    schemas = [rule, {"type" => "array", "items" => rule},
      {"type" => "object", "properties" => {"value" => rule}, "required" => ["value"]}]
    expect_native_policy_results(schemas, values + [values] + values.map { |value| {"value" => value} })
  end

  it "resolves large enum fingerprint collisions with full equality" do # rubocop:disable RSpec/ExampleLength
    choices = Array.new(32) { |index| 2**4096 + (index << 1088) + 1 }
    rules = [{"enum" => choices}, {"enum" => choices.map { |value| {"id" => value} }}]
    values = choices + [2**4096 + (32 << 1088) + 1, -choices.first, choices.first.to_f]
    expect_native_policy_results(rules, values + values.map { |value| {"id" => value} })
  end

  it "retains linear enum comparisons when nested inputs cannot be fingerprinted" do # rubocop:disable RSpec/ExampleLength
    choices = Array.new(17) { |index| [index] }
    schema = {"enum" => choices}
    native = Schemurai.compile(schema, backend: :native)
    vm = Schemurai.compile(schema, backend: :vm)
    program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
    # Different lengths reject the container without inspecting its contents.
    rejected = [Object.new, 1]
    expect(program.valid?(rejected)).to be(false)
    expect(program.diagnostics(rejected)).not_to be_nil
    # Equal shapes dispatch Ruby comparisons for user-defined object classes.
    unsupported = [Class.new.new]
    expect(program.valid?(unsupported)).to be(false)
    expect(program.diagnostics(unsupported)).not_to be_nil
    [rejected, unsupported].each do |value|
      expect(native.valid?(value)).to eq(vm.valid?(value))
      expect(native.validate(value).errors).to eq(vm.validate(value).errors)
    end
  end

  it "matches enum validity and errors across the linear lookup threshold" do
    schemas = [16, 17, 64].map { |size| {"enum" => Array.new(size) { |index| index }} }
    expect_native_policy_results(schemas, [-1, 0, 15, 16, 63, 64, -0.0, 16.0, 63.0, "16", nil, [Object.new]])
  end

  it "retains schema-order enum comparisons when a candidate cannot be fingerprinted" do # rubocop:disable RSpec/ExampleLength
    deep = 0
    257.times { deep = [deep] }
    schema = {"enum" => Array.new(17) { |index| [index] } + [deep]}
    native = Schemurai.compile(schema, backend: :native)
    vm = Schemurai.compile(schema, backend: :vm)
    program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
    expect(program.valid?([16])).to be(true)
    expect(program.diagnostics([16])).not_to be_nil
    expect(program.valid?(42)).to be(false)
    expect(program.diagnostics(42)).not_to be_nil
    expect(program.valid?(deep)).to be(true)
    expect(program.diagnostics(deep)).to eq([])
    [[16], 42, deep].each do |value|
      expect(native.valid?(value)).to eq(vm.valid?(value))
      expect(native.validate(value).errors).to eq(vm.validate(value).errors)
    end
  end

  it "compares deep constants and enum candidates without VM execution" do # rubocop:disable RSpec/ExampleLength
    wrap = lambda do |value|
      300.times { |i| value = i.even? ? [value] : {"a/b~c" => value} }
      value
    end
    constant = wrap.call(1)
    schemas = [{"const" => constant}, {"enum" => [constant]},
      {"enum" => Array.new(17) { |i| i } + [constant]}]
    expect_native_policy_results(schemas, [wrap.call(1.0), wrap.call(2), wrap.call(Float::NAN), []])
  end

  it "compares very deep uniqueness operands on an explicit native stack" do # rubocop:disable RSpec/ExampleLength
    left = 1
    right = 1.0
    20_000.times do |i|
      left = i.even? ? [left] : {"n" => left}
      right = i.even? ? [right] : {"n" => right}
    end
    native = Schemurai.compile({"uniqueItems" => true}, backend: :native)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    expect(native.valid?([left, right])).to be(false)
    expect(native.validate([left, right]).errors.map(&:keyword)).to eq(["uniqueItems"])
    expect(native.valid?([*Array.new(17) { |i| i }, left, right], timeout: 10)).to be(false)
    expect(native.validate([left, right], timeout: 10).errors.map(&:keyword)).to eq(["uniqueItems"])
  end

  it "uses libruby for depth-first special-value equality after the recursive prefix" do
    klass = Class.new
    left = [klass.new, 0]
    right = [klass.new, 1]
    300.times do
      left = [left]
      right = [right]
    end
    native = Schemurai.compile({"uniqueItems" => true}, backend: :native)
    program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
    expect(program.valid?([left, right])).to be(true)
    expect(program.diagnostics([left, right])).to eq([])
  end

  it "does not skip custom fingerprint exceptions when direct comparisons would see disjoint shapes" do
    special = Object.new
    special.define_singleton_method(:hash) { raise "custom fingerprint" }
    value = Array.new(17) { |i| i } + [{"unused" => special}]
    schema = {"uniqueItems" => true}
    native = Schemurai.compile(schema, backend: :native)
    vm = Schemurai.compile(schema, backend: :vm)
    [native, vm].each do |validator|
      expect { validator.valid?(value) }.to raise_error(RuntimeError, "custom fingerprint")
      expect { validator.validate(value) }.to raise_error(RuntimeError, "custom fingerprint")
    end
  end

  it "raises cyclic equality stack errors after native unwinding without VM execution" do # rubocop:disable RSpec/ExampleLength
    array = []
    array << array
    object = {}
    object["self"] = object
    datasets = [array, object].flat_map do |cycle|
      padding = Array.new(17) { |i| i }
      [[cycle, cycle], [*padding, cycle], [*padding, cycle, cycle]]
    end
    schema = {"uniqueItems" => true}
    vm = Schemurai.compile(schema, backend: :vm)
    datasets.each do |value|
      expect { vm.valid?(value) }.to raise_error(SystemStackError, "stack level too deep")
      expect { vm.validate(value) }.to raise_error(SystemStackError, "stack level too deep")
    end
    native = Schemurai.compile(schema, backend: :native)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    program = native.instance_variable_get(:@evaluator).instance_variable_get(:@compiled)
    expect { program.valid?(datasets.first) }.to raise_error(SystemStackError, "stack level too deep")
    expect { program.diagnostics(datasets.first) }.to raise_error(SystemStackError, "stack level too deep")
    datasets.each do |value|
      expect { native.valid?(value) }.to raise_error(SystemStackError, "stack level too deep")
      expect { native.validate(value) }.to raise_error(SystemStackError, "stack level too deep")
      expect { native.valid?(value, timeout: 10) }.to raise_error(SystemStackError, "stack level too deep")
      expect { native.validate(value, timeout: 10) }.to raise_error(SystemStackError, "stack level too deep")
    end
    expect(native.valid?([1, 2])).to be(true)
    expect(native.validate([1, 1]).errors.map(&:keyword)).to eq(["uniqueItems"])
    expect(native.valid?([array])).to be(true)
    expect(native.valid?([0, 0, *Array.new(17) { |i| i }, array])).to be(false)
  end

  it "preserves conclusive validity and earlier limits before cyclic comparison errors" do
    cycle = []
    cycle << cycle
    first_failure = Schemurai.compile({"allOf" => [false, {"uniqueItems" => true}]}, backend: :native)
    first_success = Schemurai.compile({"anyOf" => [true, {"uniqueItems" => true}]}, backend: :native)
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    expect(first_failure.valid?([cycle, cycle])).to be(false)
    expect(first_success.valid?([cycle, cycle])).to be(true)
    expect { first_failure.validate([cycle, cycle], max_errors: 0) }.to raise_error(Schemurai::LimitExceeded)
    expect { first_failure.validate([cycle, cycle], max_errors: 1) }.to raise_error(SystemStackError)
    expect { first_success.validate([cycle, cycle], timeout: 10) }.to raise_error(SystemStackError)
  end

  it "keeps enum comparisons native at the schema evaluation depth boundary" do # rubocop:disable RSpec/ExampleLength
    rule = {"enum" => Array.new(17) { |index| [index] }}
    instance = [16]
    256.times do
      rule = {"items" => rule}
      instance = [instance]
    end
    native = Schemurai.compile(rule, backend: :native)
    vm = Schemurai.compile(rule, backend: :vm)
    program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
    expect(program.valid?(instance)).to be(true)
    expect(program.diagnostics(instance)).to eq([])
    expect(native.valid?(instance)).to eq(vm.valid?(instance))
    expect(native.validate(instance).errors).to eq(vm.validate(instance).errors)
  end

  it "checks small records with required duplicates and additional-property rules in Rust" do # rubocop:disable RSpec/ExampleLength
    cases = [
      [{"type" => "object", "properties" => {"id" => {"type" => "integer"}}, "required" => Array.new(64, "id"), "additionalProperties" => false},
        [{"id" => 1}, {}, {"id" => "bad"}, {"id" => 1, "extra" => 2}]],
      [{"required" => ["flag"], "properties" => {"id" => {"type" => "integer"}}, "additionalProperties" => {"type" => "string"}},
        [{"flag" => "yes", "id" => 1}, {"flag" => "yes"}, {"flag" => 1}, {"id" => 1}]],
      [{"properties" => {"optional" => false}, "minProperties" => 1, "maxProperties" => 2},
        [{}, {"extra" => nil}, {"optional" => nil}, {"a" => 1, "b" => 2, "c" => 3}]],
      [{"properties" => 8.times.to_h { |i| ["p#{i}", {"type" => "integer"}] }, "required" => ["p7"], "additionalProperties" => false},
        [8.times.to_h { |i| ["p#{i}", i] }, 9.times.to_h { |i| ["p#{i}", i] }, 7.times.to_h { |i| ["p#{i}", i] }]],
      [{"properties" => 8.times.to_h { |i| ["p#{i}", {"type" => "integer"}] }, "required" => %w[p7 p0 p7 p3], "additionalProperties" => false},
        [{"p7" => 7, "p0" => 0, "p3" => 3}, {"p7" => 7, "p3" => 3}, {"p7" => 7, "p0" => 0},
          {"p0" => 0, "p3" => 3}, {"p2" => 2, "p4" => 4}, 8.times.to_h { |i| ["p#{i}", i] }]],
      [{"properties" => {"id" => {"type" => "integer", "exclusiveMinimum" => -(2**62), "exclusiveMaximum" => 2**62 - 1}}},
        [{"id" => -(2**62)}, {"id" => 0}, {"id" => 2**62 - 1}]],
      [{"properties" => {"id" => {"exclusiveMinimum" => 2**63 - 1}}}, [{"id" => 0}, {"id" => 2**63}]]
    ].map do |schema, values|
      vm = Schemurai.compile(schema, backend: :vm)
      [Schemurai.compile(schema, backend: :native), values.map { |value| [value, vm.valid?(value), vm.validate(value).errors] }]
    end
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |native, values|
      values.each do |value, expected, errors|
        expect(native.valid?(value)).to eq(expected), value.inspect
        expect(native.validate(value).errors).to eq(errors), value.inspect
      end
    end
  end

  it "checks empty, full and overflowing small-record buffers without VM execution" do # rubocop:disable RSpec/ExampleLength
    properties = 8.times.to_h { |i| ["k#{i}", {"type" => "integer", "minimum" => 0}] }
    schema = {"properties" => properties, "additionalProperties" => false}
    values = (0..9).flat_map do |length|
      valid = length.times.to_h { |i| ["k#{i}", i] }
      length.zero? ? [valid] : [valid, valid.merge("k0" => -1)]
    end
    # Keep a large backing table after deletion, including empty tables. This
    # exercises both CRuby storage paths with holes and frozen inputs.
    [0, 1, 8].each do |length|
      table = 40.times.to_h { |i| ["k#{i}", i] }
      table.delete_if { |key, _| key.delete_prefix("k").to_i >= length }
      values.concat([table, table.dup.freeze])
      values << table.merge("k0" => -1) unless length.zero?
    end
    vm = Schemurai.compile(schema, backend: :vm)
    expected = values.map { |value| [vm.valid?(value), vm.validate(value).errors] }
    native = Schemurai.compile(schema, backend: :native)
    bounded_schema = schema.merge("minProperties" => 2, "maxProperties" => 7)
    bounded_vm = Schemurai.compile(bounded_schema, backend: :vm)
    bounded_expected = values.map { |value| [bounded_vm.valid?(value), bounded_vm.validate(value).errors] }
    bounded_native = Schemurai.compile(bounded_schema, backend: :native)
    program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
    [0, 7, 8].each do |position|
      entries = Array.new(9) { |i| [(i == position) ? :unsupported : "k#{i}", i] }
      expect(program.valid?(entries.to_h)).to be_nil
      expect(program.diagnostics(entries.to_h)).to be_nil
      expect(program.valid?(entries.take(8).to_h)).to be_nil if position < 8
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    values.zip(expected, bounded_expected).each do |value, (valid, errors), (bounded_valid, bounded_errors)|
      expect(native.valid?(value)).to eq(valid)
      expect(native.validate(value).errors).to eq(errors)
      expect(bounded_native.valid?(value)).to eq(bounded_valid)
      expect(bounded_native.validate(value).errors).to eq(bounded_errors)
    end
  end

  it "filters dynamic record keys by fingerprint before exact string equality" do # rubocop:disable RSpec/ExampleLength
    names = ["", "a", "ab", "abcdefg", "abcdefgh", "abcdefghi", "é", "日"]
    schema = {"type" => "array", "items" => {
      "type" => "object",
      "properties" => names.to_h { |name| [name, {"type" => "integer", "minimum" => 0}] },
      "required" => names, "additionalProperties" => false
    }}
    record = names.reverse.to_h { |name| [+name, 1] }
    binary_ascii = record.transform_keys { |key| key.ascii_only? ? key.dup.force_encoding(Encoding::ASCII_8BIT) : key.dup }
    datasets = [[record], [binary_ascii], [record.except("é")],
      [record.merge("abcdefgh" => -1)], [record.merge("abcdefgj" => 1)],
      [record.merge("abcdefghi" => "bad")]]
    vm = Schemurai.compile(schema, backend: :vm)
    expected = datasets.map { |value| [vm.valid?(value), vm.validate(value).errors] }
    native = Schemurai.compile(schema, backend: :native)
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    datasets.zip(expected).each do |value, (valid, errors)|
      expect(native.valid?(value)).to eq(valid)
      expect(native.validate(value).errors).to eq(errors)
    end
    record.delete("abcdefgh")
    expect(native.valid?([record])).to be(false)
    record[+"abcdefgh"] = 2
    expect(native.valid?([record])).to be(true)
  end

  it "handles short record keys and encoding differences with exact string equality" do # rubocop:disable RSpec/ExampleLength
    names = ["", "\u0001", "a", "aa", "aaa", "aaaa", "aaaaaaaa", "abcdefghi"]
    schema = {"items" => {"properties" => names.each_with_index.to_h { |name, index| [name, {"const" => index}] },
                          "required" => names, "additionalProperties" => false}}
    record = names.each_with_index.to_h { |name, index| [String.new(name).freeze, index] }
    binary = record.transform_keys { |key| String.new(key).force_encoding(Encoding::ASCII_8BIT).freeze }
    ascii = record.transform_keys { |key| String.new(key).force_encoding(Encoding::US_ASCII).freeze }
    utf16 = record.transform_keys { |key| String.new(key).force_encoding(Encoding::UTF_16LE).freeze }
    values = [[record], [record.to_a.reverse.to_h], [record.merge(String.new("\u0001").freeze => 0)],
      [record.except("")], [record.except("\u0001")], [record.merge("extra" => 0)], [binary], [ascii]]
    vm = Schemurai.compile(schema, backend: :vm)
    expected = values.map { |value| [vm.valid?(value), vm.validate(value).errors] }
    native = Schemurai.compile(schema, backend: :native)
    utf16_schema = {"items" => schema.fetch("items").merge("additionalProperties" => true)}
    utf16_vm = Schemurai.compile(utf16_schema, backend: :vm)
    utf16_native = Schemurai.compile(utf16_schema, backend: :native)
    utf16_expected = [utf16_vm.valid?([utf16]), utf16_vm.validate([utf16]).errors]
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    values.zip(expected).each do |value, (valid, errors)|
      expect(native.valid?(value)).to eq(valid)
      expect(native.validate(value).errors).to eq(errors)
    end
    expect(utf16_native.valid?([utf16])).to eq(utf16_expected.first)
    expect(utf16_native.validate([utf16]).errors).to eq(utf16_expected.last)
  end

  it "compares every byte of short record keys and preserves encoding compatibility" do # rubocop:disable RSpec/ExampleLength
    names = (1..9).map { |length| 4.times.map { |index| (65 + index).chr + "x" * (length - 1) } }
    names << ["é", "日", "ééé", "日日"]
    names << 8.times.map { |offset| ("\u0000" * 8).tap { |key| key.setbyte(offset, 1) } }
    cases = names.map do |keys|
      schema = {"items" => {"properties" => keys.each_with_index.to_h { |key, index| [key, {"const" => index}] },
                            "required" => keys, "additionalProperties" => true}}
      record = keys.each_with_index.to_h { |key, index| [String.new(key).freeze, index] }
      changed = keys.flat_map do |key|
        key.bytesize.times.map do |offset|
          other = String.new(key)
          other.setbyte(offset, other.getbyte(offset) ^ 1)
          record.except(key).merge(other.freeze => record.fetch(key))
        end
      end
      values = [record, record.to_a.reverse.to_h, *changed]
      values.concat([Encoding::ASCII_8BIT, Encoding::US_ASCII, Encoding::UTF_16LE].map do |encoding|
        record.transform_keys { |key| String.new(key).force_encoding(encoding).freeze }
      end)
      vm = Schemurai.compile(schema, backend: :vm)
      [Schemurai.compile(schema, backend: :native), values.map { |value| [[value], vm.valid?([value]), vm.validate([value]).errors] }]
    end
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |native, values|
      values.each do |value, valid, errors|
        expect(native.valid?(value)).to eq(valid), value.inspect
        expect(native.validate(value).errors).to eq(errors), value.inspect
      end
    end
  end

  it "preserves identity-key Hash behavior for small-record validation" do # rubocop:disable RSpec/ExampleLength
    values = [{}.compare_by_identity, {}.compare_by_identity, {}.compare_by_identity]
    values[0][+"id"] = "bad"
    values[1][+"id"] = 1
    values[1][+"id"] = "bad"
    values[2][+"extra"] = 1
    # Exercise conversion after population, duplication, freezing and clearing.
    (1..8).each do |size|
      ordinary = size.times.to_h { |i| [i.zero? ? "id" : "extra#{i}", i] }
      identity = ordinary.dup.compare_by_identity
      values.concat([identity, identity.dup.freeze, identity.dup.clear,
        identity.dup.tap { |h| h.delete("id") }])
    end
    schemas = [{"properties" => {"id" => {"type" => "integer"}}},
      {"properties" => {"id" => true}, "required" => ["id"]}, {"properties" => {"id" => true}, "additionalProperties" => false},
      {"properties" => {"id" => true}, "minProperties" => 2, "maxProperties" => 7}]
    schemas.each do |schema|
      native = Schemurai.compile(schema, backend: :native)
      vm = Schemurai.compile(schema, backend: :vm)
      values.each do |value|
        expect(native.valid?(value)).to eq(vm.valid?(value)), [schema, value].inspect
        expect(native.validate(value).errors).to eq(vm.validate(value).errors), [schema, value].inspect
      end
    end
  end

  it "evaluates special strings through libruby without VM execution" do # rubocop:disable RSpec/ExampleLength
    subclass = Class.new(String)
    short = +"abc"
    short.define_singleton_method(:length) { 0 }
    fractional = subclass.new("abc")
    fractional.define_singleton_method(:length) { Rational(3, 2) }
    fake = Object.new
    fake.define_singleton_method(:is_a?) { |klass| klass == String }
    fake.define_singleton_method(:length) { 1 }
    fake.define_singleton_method(:to_str) { "aaa" }
    values = [subclass.new("aaa"), subclass.new(""), subclass.new("2024-02-29"), subclass.new("W10="),
      subclass.new("bad"), short, fractional, fake, BasicObject.new, Rational(1, 2),
      Class.new(Array).new, Class.new(Hash).new, {Object.new => 1},
      subclass.new("é".encode(Encoding::UTF_16LE)), subclass.new("\xff".b.force_encoding(Encoding::UTF_8))]
    rules = [{"minLength" => "bad"}, {"maxLength" => "bad"}, {"minLength" => false}, {"pattern" => false}, {"minLength" => 4}, {"maxLength" => 0}, {"maxLength" => 1, "minLength" => 4},
      {"pattern" => "^a+$"}, {"pattern" => "["}, {"format" => "date"},
      {"contentEncoding" => "base64", "contentMediaType" => "application/json"},
      {"contentMediaType" => "application/json"}, {"maxLength" => 0, "pattern" => "[", "format" => "date"}]
    rules = rules.flat_map { |rule| [rule, rule.merge("type" => "string"), rule.merge("type" => ["string", "integer"])] }
    wrappers = [->(rule, value) { [rule, value] }, ->(rule, value) { [{"items" => rule}, ["aaa", value, value]] },
      ->(rule, value) { [{"properties" => {"s~/v" => rule}}, {"s~/v" => value}] },
      ->(rule, value) { [{"contains" => rule}, [value]] },
      ->(rule, value) { [{"$defs" => {"s" => rule}, "allOf" => [{"$ref" => "#/$defs/s"}, {"$ref" => "#/$defs/s"}]}, value] }]
    cases = rules.product(wrappers).map do |rule, wrap|
      schema = wrap.call(rule, nil).first
      vm = Schemurai.compile(schema, backend: :vm, format: true, content: true)
      expected = values.product([:valid?, :validate], [{}, {timeout: 10}, {max_errors: 0}, {max_errors: 1}]).map do |value, method, options|
        input = wrap.call(rule, value).last
        [input, method, options, capture_validation(vm, method, input, **options)]
      end
      [Schemurai.compile(schema, backend: :native, format: true, content: true), schema, expected]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    cases.each do |native, schema, expected|
      expected.each_with_index do |(input, method, options, result), index|
        expect(capture_validation(native, method, input, **options)).to eq(result), [schema, method, options, index].inspect
      end
    end
  end

  it "preserves special string method order across trials, diagnostics and repeated calls" do # rubocop:disable RSpec/ExampleLength
    klass = Class.new(String) do
      attr_reader :calls
      def initialize(value)
        super
        @calls = []
      end

      def is_a?(type)
        @calls << [:is_a?, type]
        super
      end

      [:length, :bytesize, :getbyte, :unpack1, :to_str].each do |method|
        define_method(method) do |*args, **options|
          @calls << [method, args, options]
          super(*args, **options)
        end
      end
    end
    rules = [{"maxLength" => 1, "minLength" => 4, "pattern" => "^a+$", "format" => "date"},
      {"type" => "string", "pattern" => "[", "format" => "date"},
      {"format" => "date", "contentEncoding" => "base64", "contentMediaType" => "application/json"}]
    rules.each do |rule|
      schemas = [rule, {"items" => rule}, {"properties" => {"s" => rule}},
        {"anyOf" => [rule, rule]}, {"oneOf" => [rule, rule]}, {"not" => rule},
        {"if" => rule, "then" => false, "else" => rule},
        {"$defs" => {"s" => rule}, "allOf" => [{"$ref" => "#/$defs/s"}, {"$ref" => "#/$defs/s"}]}]
      schemas.each do |schema|
        [:valid?, :validate].product([{}, {timeout: 10}, {max_errors: 0}, {max_errors: 1}]).each do |method, options|
          vm = Schemurai.compile(schema, backend: :vm, format: true, content: true)
          native = Schemurai.compile(schema, backend: :native, format: true, content: true)
          evaluator = native.instance_variable_get(:@evaluator)
          allow(evaluator.instance_variable_get(:@vm)).to receive(:valid?).and_raise("VM execution")
          allow(evaluator.instance_variable_get(:@vm)).to receive(:validate).and_raise("VM execution")
          allow(evaluator).to receive(:limited_vm).and_raise("VM execution")
          values = [klass.new("aaa"), klass.new("aaa")]
          inputs = values.map do |value|
            if schema.key?("items")
              ["aaa", value, value]
            elsif schema.key?("properties")
              {"s" => value}
            else
              value
            end
          end
          [options, {}, options].each do |limits|
            values.each { |value| value.calls.clear }
            expected = capture_validation(vm, method, inputs.first, **limits)
            expect(capture_validation(native, method, inputs.last, **limits)).to eq(expected)
            expect(values.last.calls).to eq(values.first.calls), [schema, method, limits].inspect
          end
        end
      end
    end
  end

  it "preserves string rescue boundaries and error reservations during message rendering" do # rubocop:disable RSpec/ExampleLength
    truthy = Object.new
    truthy.define_singleton_method(:!) { raise "comparison negation" }
    length_class = Class.new do
      define_method(:>) { |_other| truthy }
      def to_s = raise(RegexpError, "length message")
    end
    klass = Class.new(String) do
      attr_accessor :length_value
      def length = length_value
    end
    rules = [{"maxLength" => 1}, {"type" => "string", "maxLength" => 1, "pattern" => "a", "format" => "date"}]
    cases = rules.map do |rule|
      value = klass.new("abc")
      value.length_value = length_class.new
      vm = Schemurai.compile(rule, backend: :vm, format: true)
      combinations = [:valid?, :validate].product([{}, {max_errors: 0}, {max_errors: 1}, {max_errors: 2}, {timeout: 10}])
      [Schemurai.compile(rule, backend: :native, format: true), value, combinations.map do |method, options|
        [method, options, capture_validation(vm, method, value, **options)]
      end]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    cases.each do |native, value, expected|
      expected.each do |method, options, result|
        expect(capture_validation(native, method, value, **options)).to eq(result)
      end
    end
  end

  it "rescues a string diagnostic path error once and preserves the handler's exceptions" do # rubocop:disable RSpec/ExampleLength
    key = "é".encode(Encoding::ISO_8859_1)
    schema = {"properties" => {key => {"maxLength" => 1}}}
    value = {key => Class.new(String).new("abc")}
    helper = Schemurai.const_get(:Internal)::JsonPointer
    [:once, :always].product([{}, {max_errors: 0}, {max_errors: 1}, {max_errors: 2}, {timeout: 10}]).each do |mode, options|
      outcomes = [:vm, :native].map do |backend|
        validator = Schemurai.compile(schema, backend: backend)
        if backend == :native
          evaluator = validator.instance_variable_get(:@evaluator)
          allow(evaluator.instance_variable_get(:@vm)).to receive(:validate).and_raise("VM execution")
          allow(evaluator).to receive(:limited_vm).and_raise("VM execution")
        end
        calls = 0
        allow(helper).to receive(:escape).and_wrap_original do |original, segment|
          if segment == key
            calls += 1
            raise RegexpError, "diagnostic path" if mode == :always || calls == 1
          end
          original.call(segment)
        end
        capture_validation(validator, :validate, value, **options)
      end
      expect(outcomes.last).to eq(outcomes.first), [mode, options].inspect
    end
  end

  it "roots special string lengths across GC and independent Ractors" do # rubocop:disable RSpec/ExampleLength
    klass = Class.new(String) do
      def length
        GC.verify_compaction_references(double_heap: true, toward: :empty)
        Rational(3, 2)
      end
    end
    rule = {"maxLength" => 1, "minLength" => 4}
    expect_native_policy_results([rule, {"allOf" => [rule, rule]}], [klass.new("aaa")])
    registry = Schemurai::SchemaRegistry.new(schemas: {"urn:string" => {"items" => {"minLength" => 4, "format" => "date"}}}, backend: :native).make_shareable
    workers = Array.new(2) do
      Ractor.new(registry) do |shared|
        validator = shared.validator_for("urn:string")
        runner = validator.instance_variable_get(:@evaluator).instance_variable_get(:@program)
        value = [Class.new(String).new("aaa")]
        GC.start
        [runner.valid?(value), runner.diagnostics(value).map(&:first)]
      end
    end
    workers.each { |worker| expect(worker.respond_to?(:value) ? worker.value : worker.take).to eq([false, ["minLength"]]) }
  end

  it "preserves string stage exceptions and trial rescue behavior" do # rubocop:disable RSpec/ExampleLength
    faults = [RegexpError, IPAddr::InvalidAddressError, ArgumentError]
    cases = [:length, :bytesize, :unpack1].product(faults).flat_map do |method, fault|
      klass = Class.new(String) { define_method(method) { |*| raise fault, "string stage" } }
      value = klass.new("aaa")
      rule = {"maxLength" => 1, "minLength" => 4, "pattern" => "a", "format" => "date",
              "contentEncoding" => "base64", "contentMediaType" => "application/json"}
      [rule, {"items" => rule}, {"contains" => rule}, {"anyOf" => [rule, true]}].map do |schema|
        input = (schema.key?("items") || schema.key?("contains")) ? [value] : value
        vm = Schemurai.compile(schema, backend: :vm, format: true, content: true)
        expected = [:valid?, :validate].product([{}, {max_errors: 0}, {max_errors: 1}, {timeout: 10}]).map do |operation, options|
          [operation, options, capture_validation(vm, operation, input, **options)]
        end
        [Schemurai.compile(schema, backend: :native, format: true, content: true), input, expected]
      end
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    cases.each do |native, input, expected|
      expected.each { |operation, options, result| expect(capture_validation(native, operation, input, **options)).to eq(result) }
    end
  end

  it "retains string method deadline boundaries before later Ruby exceptions" do
    length = Object.new
    length.define_singleton_method(:>) { |_value| raise ArgumentError, "length comparison" }
    value = Class.new(String).new("abc")
    elapsed = -> { allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(0.2) }
    value.define_singleton_method(:length) do
      elapsed.call
      length
    end
    allow(Process).to receive(:clock_gettime).and_call_original
    [:vm, :native].each do |backend|
      validator = Schemurai.compile({"maxLength" => 1}, backend: backend)
      [:valid?, :validate].each do |method|
        allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(0.0)
        expect { validator.public_send(method, value, timeout: 0.1) }.to raise_error(ArgumentError, "length comparison")
      end
    end
  end

  it "preserves overridden methods on singleton objects and builtin subclasses" do # rubocop:disable RSpec/ExampleLength
    string = +"abc"
    string.define_singleton_method(:length) { 0 }
    array = [1]
    array.define_singleton_method(:length) { 0 }
    object = {"id" => 1}
    object.define_singleton_method(:key?) { |_key| false }
    identity = Object.new
    identity.define_singleton_method(:==) { |_other| false }
    values = [[{"uniqueItems" => true}, [identity, identity]],
      [{"minLength" => 1}, string], [{"minItems" => 1}, array], [{"required" => ["id"]}, object],
      [{"type" => "string", "minLength" => 1}, Class.new(String).new("abc")],
      [{"type" => "array", "minItems" => 1}, Class.new(Array).new([1])],
      [{"items" => {"pattern" => "^a+$", "minLength" => 1}}, [string]],
      [{"items" => {"pattern" => "^a+$"}}, [Class.new(String).new("aaa")]],
      [{"items" => {"pattern" => "^a+$"}}, [{Object.new => 1}]],
      [{"type" => "object", "required" => ["id"]}, Class.new(Hash)["id", 1]]]
    values.each do |schema, value|
      native = Schemurai.compile(schema, backend: :native)
      vm = Schemurai.compile(schema, backend: :vm)
      program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
      expect(program.valid?(value)).to eq(vm.valid?(value))
      expect(program.diagnostics(value)).not_to be_nil
      expect(native.valid?(value)).to eq(vm.valid?(value))
      expect(native.validate(value).errors).to eq(vm.validate(value).errors)
    end
  end

  it "leaves arbitrary Hash keys to the VM before performing native lookups" do # rubocop:disable RSpec/ExampleLength
    calls = 0
    key = Object.new
    key.define_singleton_method(:hash) do
      calls += 1 # rubocop:disable Security/CompoundHash -- Count callbacks while deliberately colliding with a schema key.
      "id".hash
    end
    key.define_singleton_method(:eql?) do |_other|
      calls += 1
      GC.start
      false
    end
    values = [{key => 1}, {Class.new(String).new("id") => 1}, {"id" => "bad", key => 1}]
    table = 40.times.to_h { |i| ["spare#{i}", i] }.merge(key => 1)
    table.delete_if { |entry, _| entry.is_a?(String) && entry.start_with?("spare") }
    values.concat([table, table.dup.freeze])
    schema = {"required" => ["id"], "properties" => {"id" => {"type" => "integer"}}}
    [schema, schema.merge("propertyNames" => true)].each do |rules|
      native = Schemurai.compile(rules, backend: :native)
      vm = Schemurai.compile(rules, backend: :vm)
      program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
      before = calls
      values.each do |value|
        expect(program.valid?(value)).to be_nil
        expect(program.diagnostics(value)).to be_nil
      end
      expect(calls).to eq(before)
      values.each do |value|
        expect(native.valid?(value)).to eq(vm.valid?(value))
        expect(native.validate(value).errors).to eq(vm.validate(value).errors)
      end
    end
  end

  it "collects every official unevaluated-location diagnostic without VM evaluation" do # rubocop:disable RSpec/ExampleLength
    remotes = SchemuraiOracle::CaseCatalog.new.remotes
    cases = %w[draft2019-09 draft2020-12].flat_map do |draft|
      %w[unevaluatedItems unevaluatedProperties].flat_map do |keyword|
        JSON.parse(File.read("references/JSON-Schema-Test-Suite/tests/#{draft}/#{keyword}.json")).map do |group|
          schema = group.fetch("schema")
          vm = Schemurai.compile(schema, schemas: remotes, backend: :vm)
          [Schemurai.compile(schema, schemas: remotes, backend: :native), group.fetch("tests").map { |test| [test.fetch("data"), vm.validate(test.fetch("data")).errors] }]
        end
      end
    end
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |validator, tests|
      tests.each { |value, expected| expect(validator.validate(value).errors).to eq(expected), value.inspect }
    end
  end

  it "retains local failed-item coverage while dropping failed applicator annotations" do # rubocop:disable RSpec/ExampleLength
    cases = [
      [{"type" => "array", "allOf" => [{"properties" => {"x" => true}}, {"type" => "string"}],
        "properties" => {"local" => {"type" => "integer"}}, "unevaluatedProperties" => false}, {"x" => 1, "local" => "bad", "extra" => 9}],
      [{"prefixItems" => [{"minimum" => 5}], "contains" => {"type" => "integer"}, "minContains" => 3, "unevaluatedItems" => false}, [0, "bad"]],
      [{"oneOf" => [{"prefixItems" => [true]}, {"items" => true}], "unevaluatedItems" => false}, [1, 2]],
      [{"dependentSchemas" => {"flag" => {"properties" => {"value" => {"type" => "integer"}}}}, "properties" => {"flag" => true}, "unevaluatedProperties" => false}, {"flag" => nil, "value" => "bad"}]
    ].map do |schema, value|
      schema = {"$schema" => "https://json-schema.org/draft/2020-12/schema"}.merge(schema)
      [Schemurai.compile(schema, backend: :native), value, Schemurai.compile(schema, backend: :vm).validate(value).errors]
    end
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each { |validator, value, expected| expect(validator.validate(value).errors).to eq(expected) }
  end

  it "keeps required and dependency checks on either side of unsupported properties" do # rubocop:disable RSpec/ExampleLength
    base = {"$schema" => "https://json-schema.org/draft/2020-12/schema",
            "properties" => {"must" => true, "probe" => {"type" => "string", "pattern" => "(?=example)"}},
            "patternProperties" => {"^flag$" => true}}
    [false, true].each do |tracked|
      schema = tracked ? base.merge("unevaluatedProperties" => false) : base
      required = Schemurai.compile(schema.merge("required" => ["must"]), backend: :native)
      dependent = Schemurai.compile(schema.merge("dependentRequired" => {"flag" => ["must"]}), backend: :native)
      required_program = required.instance_variable_get(:@evaluator).instance_variable_get(:@program)
      dependent_program = dependent.instance_variable_get(:@evaluator).instance_variable_get(:@program)
      # Required failures precede properties; dependencies follow properties.
      expect(required_program.valid?({"probe" => "example.test"})).to be(false)
      expect(required_program.valid?({"must" => true, "probe" => "example.test"})).to be(true)
      expect(dependent_program.valid?({"flag" => true, "probe" => "example.test"})).to be(false)
      expect(dependent_program.valid?({"flag" => true})).to be(false)
      expect(dependent_program.valid?({"flag" => true, "must" => true})).to be(true)
      expect(dependent_program.valid?({})).to be(true)
    end
  end

  it "evaluates non-string required and dependency operands without VM execution" do # rubocop:disable RSpec/ExampleLength
    names = [nil, false, true, 1, 0.5, 2**200, [], [1], {}, {"key" => ["value"]}]
    dialect = {"$schema" => "https://json-schema.org/draft/2020-12/schema"}
    rules = names.flat_map do |name|
      [{"required" => [name]}, {"dependencies" => {"present" => [name]}},
        dialect.merge("dependentRequired" => {"present" => [name]})]
    end
    rules << {"required" => ["present", *names, "missing", nil]}
    [0, 8, 9, 64, 70].each do |count|
      properties = count.times.to_h { |i| ["p#{i}", {"type" => "integer"}] }
      [0, 1, 2].each do |position|
        required = %w[p0 missing p0].insert(position, {"key" => 1})
        rules << {"properties" => properties, "required" => required}
      end
    end
    schemas = rules.flat_map { |rule| [rule, {"items" => rule}, {"properties" => {"value" => rule}}] }
    objects = [{}, {"present" => 1}, {"present" => "bad", "missing" => nil},
      70.times.to_h { |i| ["p#{i}", i] }]
    values = [nil, false, 1, "value", *objects, objects, *objects.map { |value| {"value" => value} }]
    expect_native_policy_results(schemas, values)
  end

  it "preserves non-string required error order, annotations and limits" do # rubocop:disable RSpec/ExampleLength
    dialect = {"$schema" => "https://json-schema.org/draft/2020-12/schema"}
    required = {"required" => ["present", nil, "missing", nil], "properties" => {"present" => {"type" => "integer"}}}
    dependency = dialect.merge("dependentRequired" => {"present" => [true, "missing", true]},
      "dependentSchemas" => {"schema2" => {"required" => [{}]}})
    legacy = {"dependencies" => {"schema1" => false, "present" => [[], "missing", []], "schema2" => {"required" => [1]}}}
    schemas = [required, dependency, legacy].flat_map do |rule|
      [rule, {"items" => rule}, {"additionalProperties" => rule}, {"allOf" => [rule, false]},
        {"anyOf" => [true, rule]}, {"oneOf" => [true, rule]}, {"not" => rule},
        {"if" => rule, "then" => false, "else" => {"required" => [false]}},
        dialect.merge("allOf" => [rule], "unevaluatedProperties" => false)]
    end
    object = {"present" => "bad", "schema1" => 1, "schema2" => 2}
    values = [nil, 1, {}, object, {"present" => 1, "extra" => 2}, [object],
      {"a/b~" => object}, {"x".encode(Encoding::UTF_16LE) => object}]
    combinations = values.product([:valid?, :validate], [{}, {timeout: 10}, {max_errors: 0}, {max_errors: 1}, {max_errors: 2}])
    cases = schemas.map do |schema|
      vm = Schemurai.compile(schema, backend: :vm)
      [Schemurai.compile(schema, backend: :native), combinations.map do |value, method, options|
        capture_validation(vm, method, value, **options)
      end]
    end
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    cases.each do |native, expected|
      combinations.zip(expected).each do |(value, method, options), result|
        expect(capture_validation(native, method, value, **options)).to eq(result)
      end
    end
  end

  it "uses libruby for required String operands with singleton methods" do
    name = String.new("present")
    name.define_singleton_method(:hash) { super() }
    name.freeze
    schemas = [{"required" => [name]}, {"dependencies" => {"present" => [name]}},
      {"$schema" => "https://json-schema.org/draft/2020-12/schema", "dependentRequired" => {"present" => [name]}}]
    expect_native_policy_results(schemas, [{}, {"present" => 1}])
  end

  it "preserves Ruby key lookup exceptions and observes method changes between calls" do # rubocop:disable RSpec/ExampleLength
    script = <<~RUBY
      require "schemurai"
      rules = [{"required"=>[1,[]]}, {"required"=>[[]]}, {"required"=>["missing",[]]}, {"required"=>[[],"missing"]},
        {"dependencies"=>{"present"=>[{}]}},
        {"$schema"=>"https://json-schema.org/draft/2020-12/schema", "dependentRequired"=>{"present"=>[[]]}}]
      pairs = rules.map { |rule| [Schemurai.compile(rule,backend: :vm),Schemurai.compile(rule,backend: :native)] }
      pairs.each do |_vm,native|
        evaluator = native.instance_variable_get(:@evaluator).instance_variable_get(:@vm)
        evaluator.define_singleton_method(:valid?) { |*| raise "VM execution" }
        evaluator.define_singleton_method(:validate) { |*| raise "VM execution" }
      end
      original_array_hash = Array.instance_method(:hash)
      original_hash_hash = Hash.instance_method(:hash)
      original_key = Hash.instance_method(:key?)
      Array.define_method(:hash) do
        GC.verify_compaction_references(double_heap: true, toward: :empty)
        raise "array key hash"
      end
      Hash.define_method(:hash) { raise "hash key hash" }
      capture = lambda do |validator,method,options|
        result = validator.public_send(method,{"present"=>1},**options)
        method == :validate ? result.errors : result
      rescue => error
        [error.class.name,error.message]
      end
      compare = lambda do
        pairs.each do |vm,native|
          [:valid?,:validate].product([{}, {max_errors: 0}, {max_errors: 1}, {timeout: 10}]).each do |method,options|
            abort "different lookup behavior" unless capture.call(vm,method,options) == capture.call(native,method,options)
          end
        end
      end
      compare.call
      Array.define_method(:hash,original_array_hash)
      Hash.define_method(:hash,original_hash_hash)
      compare.call
      Hash.define_method(:key?) { |key| key.is_a?(Array) || original_key.bind_call(self,key) }
      compare.call
      Hash.define_method(:key?,original_key)
      Integer.define_method(:inspect) do
        GC.verify_compaction_references(double_heap: true, toward: :empty)
        raise "earlier required message"
      end
      Array.define_method(:hash) { raise "later key hash" }
      compare.call
      puts "ok"
    RUBY
    output, errors, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-Iext/schemurai_native", "-e", script)
    expect(status.success?).to be(true), errors
    expect(output).to eq("ok\n")
  end

  it "retains independent required messages through compaction and repeated calls" do
    key = ["payload"]
    schema = {"required" => [key, {}, key]}
    value = {"present" => 1}
    expected = Schemurai.compile(schema, backend: :vm).validate(value).errors
    native = Schemurai.compile(schema, backend: :native)
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    renderer = Schemurai.const_get(:Native)::Diagnostics
    allow(renderer).to receive(:message).and_wrap_original do |original, *arguments|
      GC.verify_compaction_references(double_heap: true, toward: :empty)
      original.call(*arguments)
    end
    errors = native.validate(value).errors
    expect(errors).to eq(expected)
    errors.first.message << " changed"
    expect(errors.last.message).to eq(expected.last.message)
    expect(native.validate(value).errors).to eq(expected)
  end

  it "keeps required operand runtime lookups isolated in Ractor runners" do
    schema = {"$schema" => "https://json-schema.org/draft/2020-12/schema", "dependentRequired" => {"present" => [[], {}]}}
    registry = Schemurai::SchemaRegistry.new(schemas: {"urn:required" => schema}, backend: :native).make_shareable
    workers = Array.new(2) do
      Ractor.new(registry) do |shared|
        validator = shared.validator_for("urn:required")
        runner = validator.instance_variable_get(:@evaluator).instance_variable_get(:@program)
        value = {}
        first = runner.valid?(value)
        value["present"] = true
        GC.start
        [first, runner.valid?(value), runner.diagnostics(value).map(&:first)]
      end
    end
    workers.each { |worker| expect(worker.respond_to?(:value) ? worker.value : worker.take).to eq([true, false, %w[dependentRequired dependentRequired]]) }
  end

  it "diagnoses every official dependency case without VM evaluation" do # rubocop:disable RSpec/ExampleLength
    cases = %w[draft7 draft2019-09 draft2020-12].flat_map do |draft|
      %w[dependencies dependentRequired dependentSchemas].flat_map do |keyword|
        path = "references/JSON-Schema-Test-Suite/tests/#{draft}/#{keyword}.json"
        next [] unless File.file?(path)

        JSON.parse(File.read(path)).map do |group|
          schema = group.fetch("schema")
          vm = Schemurai.compile(schema, backend: :vm)
          [Schemurai.compile(schema, backend: :native), group.fetch("tests").map { |test| [test.fetch("data"), vm.validate(test.fetch("data")).errors] }]
        end
      end
    end
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |validator, tests|
      tests.each { |value, expected| expect(validator.validate(value).errors).to eq(expected), value.inspect }
    end
  end

  it "keeps mixed dependency errors in schema order and escapes their reference paths" do # rubocop:disable RSpec/ExampleLength
    cases = [
      [{"dependencies" => {"schema1" => {"required" => ["firstMissing"]}, "required" => %w[secondMissing thirdMissing], "schema2" => false}},
        {"schema2" => nil, "required" => false, "schema1" => 0}],
      [{"$schema" => "https://json-schema.org/draft/2020-12/schema", "dependentRequired" => {"depB" => ["missingB"], "depA" => ["missingA"]},
        "dependentSchemas" => {"dep/A~" => {"properties" => {"depB" => {"type" => "integer"}}, "required" => ["lastMissing"]}}},
        {"dep/A~" => nil, "depB" => false, "depA" => 0}]
    ].map do |schema, value|
      [Schemurai.compile(schema, backend: :native), value, Schemurai.compile(schema, backend: :vm).validate(value).errors]
    end
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each { |validator, value, expected| expect(validator.validate(value).errors).to eq(expected) }
  end

  it "collects ordered scalar, array, and object diagnostics without VM evaluation" do # rubocop:disable RSpec/ExampleLength
    cases = [
      [false, [nil, 1]],
      [{"type" => ["integer", "array"], "const" => 2, "enum" => [1, 2]}, ["x", 3]],
      [{"allOf" => [{"type" => "integer", "minimum" => 4, "maximum" => 1, "multipleOf" => 2}, {"not" => {"const" => 3}}]}, [3, 0.5]],
      [{"type" => "string", "minLength" => 4, "maxLength" => 1, "pattern" => "^a+$", "format" => "date", "contentMediaType" => "application/json"}, ["xx", 1]],
      [{"type" => "array", "minItems" => 4, "maxItems" => 1, "uniqueItems" => true, "items" => {"type" => "integer", "minimum" => 5, "maximum" => 1, "multipleOf" => 2},
        "contains" => {"const" => 6}, "minContains" => 2, "maxContains" => 2}, [[3, 3, "a"], nil]],
      [{"prefixItems" => [{"type" => "integer"}], "items" => false}, [["x", 2, 3]]],
      [{"$schema" => "http://json-schema.org/draft-07/schema#", "items" => [{"type" => "integer"}], "additionalItems" => false}, [["x", 2]]],
      [{"$defs" => {"n" => {"type" => "integer", "minimum" => 2}}, "items" => {"$ref" => "#/$defs/n"}}, [[0, "x"]]],
      [{"oneOf" => [true, true, true], "anyOf" => [false, false], "if" => {"type" => "integer"}, "then" => false, "else" => {"type" => "array"}}, [1, "x"]],
      [{"contentEncoding" => "base64", "contentMediaType" => "application/json"}, ["e30g!!!!", "ezp9"]],
      [{"type" => "object", "maxProperties" => 1, "minProperties" => 5, "required" => %w[tail missing z/key],
        "properties" => {"missing" => true, "z/key" => {"minLength" => 4}, "a~key" => {"type" => "integer"}},
        "patternProperties" => {"^z" => {"maxLength" => 1}, "key$" => false}, "additionalProperties" => false,
        "propertyNames" => {"pattern" => "^[a-z]+$"}}, [{"a~key" => "x", "extra" => 1, "z/key" => "xx"}, false]],
      [{"properties" => {"日本/~" => {"type" => "boolean"}}, "additionalProperties" => false}, [{"日本/~" => 1}]]
    ].map do |schema, values|
      schema = {"$schema" => "https://json-schema.org/draft/2020-12/schema"}.merge(schema) if schema.is_a?(Hash)
      vm = Schemurai.compile(schema, content: true, format: true, backend: :vm)
      [Schemurai.compile(schema, content: true, format: true, backend: :native), values.map { |value| [value, vm.validate(value).errors.map(&:to_h)] }]
    end
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |validator, values|
      values.each { |value, expected| expect(validator.validate(value).errors.map(&:to_h)).to eq(expected), value.inspect }
    end
  end

  def capture_pointer_validation(validator, method, value, **options)
    outcome = capture_validation(validator, method, value, **options)
    return outcome unless method == :validate && outcome.first == :result

    [:result, outcome.last.map { |error| [error, error.instance_path.encoding, error.schema_path.encoding] }]
  end

  it "builds encoded diagnostic pointers through libruby without VM execution" do # rubocop:disable RSpec/ExampleLength
    keys = ["a~/b", "é~/x", "é~/x".encode(Encoding::ISO_8859_1), "ミ~/x".encode(Encoding::Shift_JIS),
      "\xff~/x".b, "a~/b".b, "a".encode(Encoding::UTF_16LE), "\xff".dup.force_encoding(Encoding::UTF_8),
      "\xff".dup.force_encoding(Encoding::US_ASCII)]
    dialect = {"$schema" => "https://json-schema.org/draft/2020-12/schema"}
    rule = {"additionalProperties" => false}
    schemas = [rule, {"items" => rule}, {"additionalProperties" => rule},
      {"propertyNames" => {"maxLength" => 0}}, dialect.merge("unevaluatedProperties" => false)]
    values = keys.flat_map { |key| [{key => 1}, [{key => 1}], {"outer" => {key => 1}}, {key => {key => 1}}] }
    values += [{"é" => {keys[2] => 1}}, {keys[2] => {"é" => 1}}, {keys[2] => {keys[3] => 1}}]
    combinations = values.product([:valid?, :validate], [{}, {timeout: 10}, {max_errors: 0}, {max_errors: 1}])
    cases = schemas.map do |schema|
      vm = Schemurai.compile(schema, backend: :vm)
      [Schemurai.compile(schema, backend: :native), combinations.map do |value, method, options|
        capture_pointer_validation(vm, method, value, **options)
      end]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    cases.each do |native, expected|
      combinations.zip(expected).each do |(value, method, options), result|
        expect(capture_pointer_validation(native, method, value, **options)).to eq(result)
      end
    end
  end

  it "retains encoded schema pointer names for properties and dependencies" do # rubocop:disable RSpec/ExampleLength
    keys = ["é~/x".encode(Encoding::ISO_8859_1), "ミ~/x".encode(Encoding::Shift_JIS), "\xff~/x".b]
    cases = keys.flat_map do |key|
      schemas = [{"properties" => {key => false}}, {"dependencies" => {key => {"required" => ["missing"]}}},
        {"$schema" => "https://json-schema.org/draft/2020-12/schema", "dependentSchemas" => {key => {"required" => ["missing"]}}}]
      schemas.map do |schema|
        value = {key => 1}
        vm = Schemurai.compile(schema, backend: :vm)
        [Schemurai.compile(schema, backend: :native), value, capture_pointer_validation(vm, :validate, value)]
      end
    end
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |native, value, expected|
      expect(capture_pointer_validation(native, :validate, value)).to eq(expected)
      expect(capture_pointer_validation(native, :validate, value, timeout: 10)).to eq(expected)
    end
  end

  it "raises pointer exceptions at the first recorded error before later regexp exceptions" do
    incompatible = "a".encode(Encoding::UTF_16LE)
    schema = {"properties" => {"later" => {"pattern" => "(?=a)a"}}, "additionalProperties" => false}
    values = [{incompatible => 1, "later" => incompatible}, {"later" => incompatible, incompatible => 1}]
    vm = Schemurai.compile(schema, backend: :vm)
    native = Schemurai.compile(schema, backend: :native)
    expected = values.map { |value| capture_pointer_validation(vm, :validate, value) }
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    values.zip(expected).each do |value, result|
      expect(capture_pointer_validation(native, :validate, value)).to eq(result)
      expect(capture_pointer_validation(native, :validate, value, timeout: 10)).to eq(result)
    end
  end

  it "pins encoded pointer strings across compaction and clears observations between calls" do
    key = "é~/x".encode(Encoding::ISO_8859_1)
    native = Schemurai.compile({"additionalProperties" => false}, backend: :native)
    helper = Schemurai.const_get(:Internal)::JsonPointer
    allow(helper).to receive(:escape).and_wrap_original do |original, segment|
      GC.verify_compaction_references(double_heap: true, toward: :empty)
      original.call(segment)
    end
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    value = {key => 1}
    expect(native.validate(value).errors.first.instance_path).to eq("/é~0~1x".encode(Encoding::ISO_8859_1))
    value.clear
    value["ミ".encode(Encoding::Shift_JIS)] = 1
    result = native.validate(value, timeout: 10)
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    expect(result.errors.first.instance_path).to eq("/ミ".encode(Encoding::Shift_JIS))
    expect(native.validate({}).errors).to be_empty
  end

  it "returns independently mutable encoded paths for repeated errors" do
    schema = {"additionalProperties" => {"allOf" => [false, false]}}
    key = "é".encode(Encoding::ISO_8859_1)
    native = Schemurai.compile(schema, backend: :native)
    expected = Schemurai.compile(schema, backend: :vm).validate({key => 1}).errors
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    errors = native.validate({key => 1}).errors
    expect(errors).to eq(expected)
    errors.first.instance_path.replace("changed")
    expect(errors.last.instance_path).to eq("/é".encode(Encoding::ISO_8859_1))
    expect(native.validate({key => 1}).errors).to eq(expected)
  end

  it "keeps encoded diagnostic pointer requests private to each Ractor" do
    registry = Schemurai::SchemaRegistry.new(schemas: {"urn:pointers" => {"additionalProperties" => false}}, backend: :native).make_shareable
    workers = Array.new(2) do
      Ractor.new(registry) do |shared|
        validator = shared.validator_for("urn:pointers")
        runner = validator.instance_variable_get(:@evaluator).instance_variable_get(:@program)
        key = "é".encode(Encoding::ISO_8859_1)
        GC.start
        first = runner.diagnostics({key => 1}).first
        second = runner.diagnostics({"\xff".b => 1}).first
        [first[1], first[1].encoding, first[2], second[1], second[1].encoding]
      end
    end
    expected = ["/é".encode(Encoding::ISO_8859_1), Encoding::ISO_8859_1, "/additionalProperties", "/\xff".b, Encoding::ASCII_8BIT]
    workers.each { |worker| expect(worker.respond_to?(:value) ? worker.value : worker.take).to eq(expected) }
  end

  it "pins diagnostic operands and instances during GC stress and compaction" do
    validator = Schemurai.compile({"items" => {"type" => "string", "minLength" => 4}}, backend: :native)
    instance = ["a".dup, "b".dup]
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    begin
      GC.stress = true
      expect(validator.validate(instance).errors.map(&:instance_path)).to eq(%w[/0 /1])
    ensure
      GC.stress = false
    end
    GC.compact
    expect(validator.validate(instance).errors.map(&:instance_path)).to eq(%w[/0 /1])
  end

  it "collects independent diagnostic output in Ractors sharing a registry" do
    schema = {"type" => "array", "items" => {"type" => "integer", "minimum" => 1}}
    registry = Schemurai::SchemaRegistry.new(schemas: {"urn:diagnostics" => schema}, backend: :native).make_shareable
    workers = Array.new(2) do
      Ractor.new(registry) do |shared|
        validator = shared.validator_for("urn:diagnostics")
        [validator.validate([0, "x"]).errors.map { |e| [e.keyword, e.instance_path, e.schema_path] }, validator.validate([2]).valid?]
      end
    end
    workers.each do |worker|
      result = worker.respond_to?(:value) ? worker.value : worker.take
      expect(result).to eq([[["minimum", "/0", "/items/minimum"], ["type", "/1", "/items/type"]], true])
    end
  end

  it "preserves dynamic and recursive reference diagnostic paths without VM evaluation" do # rubocop:disable RSpec/ExampleLength
    schema = {"$schema" => "https://json-schema.org/draft/2020-12/schema", "$id" => "urn:outer", "$ref" => "urn:list",
              "$defs" => {"value" => {"$dynamicAnchor" => "value", "type" => "integer", "minimum" => 2}}}
    list = {"$schema" => "https://json-schema.org/draft/2020-12/schema", "$id" => "urn:list", "type" => "array",
            "items" => {"$dynamicRef" => "#value"}, "$defs" => {"value" => {"$dynamicAnchor" => "value"}}}
    recursive = {"$schema" => "https://json-schema.org/draft/2019-09/schema", "$id" => "urn:outer-rec", "$recursiveAnchor" => true, "$ref" => "urn:recurse", "maxItems" => 1}
    body = {"$schema" => "https://json-schema.org/draft/2019-09/schema", "$id" => "urn:recurse", "$recursiveAnchor" => true,
            "type" => ["array", "integer"], "items" => {"$recursiveRef" => "#"}}
    cases = [[schema, {"urn:list" => list}, [1, "bad"]], [recursive, {"urn:recurse" => body}, [[1, 2], ["bad"]]]].map do |root, schemas, value|
      expected = Schemurai.compile(root, schemas: schemas, backend: :vm).validate(value).errors
      [Schemurai.compile(root, schemas: schemas, backend: :native), value, expected]
    end
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each { |validator, value, expected| expect(validator.validate(value).errors).to eq(expected) }
  end

  it "scans content arrays with guarded byte views and complete diagnostics" do # rubocop:disable RSpec/ExampleLength
    samples = [
      [{"contentEncoding" => "base64"}, Base64.strict_encode64("payload"), "!"],
      [{"contentMediaType" => "application/json"}, '{"id":1}', '{"id":}'],
      [{"contentEncoding" => "base64", "contentMediaType" => "application/json"}, Base64.strict_encode64('{"id":1}'), Base64.strict_encode64('{"id":}')]
    ]
    cases = samples.flat_map do |rule, valid, invalid|
      [rule, rule.merge("type" => "string")].flat_map do |items|
        [{"items" => items}, {"prefixItems" => [{"const" => "header"}], "items" => items, "unevaluatedItems" => false},
          {"allOf" => [{"items" => items}], "unevaluatedItems" => false}, {"items" => items.merge("minLength" => 1)}].map do |body|
          schema = {"$schema" => "https://json-schema.org/draft/2020-12/schema", "type" => "array"}.merge(body)
          prefix = body.key?("prefixItems") ? ["header"] : []
          values = [[], [valid], [valid, invalid, invalid], [valid, nil, true, 1, {}, []],
            [valid.b], [valid.encode(Encoding::US_ASCII)], ["", invalid, valid]].map { |value| prefix + value }
          vm = Schemurai.compile(schema, content: true, backend: :vm)
          native = Schemurai.compile(schema, content: true, backend: :native)
          program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
          expect(program.valid?(prefix + [Class.new(String).new(valid)])).to be(true)
          expect(program.diagnostics(prefix + [{Object.new => 1}])).not_to be_nil
          if rule["contentEncoding"].nil?
            transcoded = prefix + [valid.encode(Encoding::UTF_16LE)]
            expect(program.valid?(transcoded)).to be(true)
            expect(program.diagnostics(transcoded)).to eq([])
            values << transcoded
          end
          [native, values.map { |value| [value, vm.valid?(value), vm.validate(value).errors] }]
        end
      end
    end
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |native, values|
      values.each do |value, valid, errors|
        expect(native.valid?(value)).to eq(valid)
        expect(native.validate(value).errors).to eq(errors)
      end
    end
  end

  it "executes official opt-in content assertions without VM evaluation" do # rubocop:disable RSpec/ExampleLength
    cases = %w[draft7 draft2019-09 draft2020-12].flat_map do |draft|
      candidates = ["references/JSON-Schema-Test-Suite/tests/#{draft}/content.json", "references/JSON-Schema-Test-Suite/tests/#{draft}/optional/content.json"]
      path = candidates.find { |candidate| File.file?(candidate) }
      JSON.parse(File.read(path)).map do |group|
        schema = group.fetch("schema")
        vm = Schemurai.compile(schema, content: true, backend: :vm)
        [Schemurai.compile(schema, content: true, backend: :native), group.fetch("tests").map { |test| [test.fetch("data"), vm.valid?(test.fetch("data")), vm.validate(test.fetch("data")).errors] }]
      end
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |validator, tests|
      tests.each do |data, expected, errors|
        expect(validator.valid?(data)).to eq(expected), data.inspect
        expect(validator.validate(data).errors).to eq(errors), data.inspect
      end
    end
  end

  it "preserves strict padding and JSON syntax without constructing JSON trees" do # rubocop:disable RSpec/ExampleLength
    strings = ["", "null", "true", "false", "0", "-0", "-1.25e+2", "1e999", "01", "-01", "1.", "[1,]", "{\"a\":1,}", "{\"a\":[true, false, null]}",
      "\"\\uD800\"", "\"\\uDC00\"", "\"\\uD800\\uDFFF\"", "\"\\uD800\\u0041\"", "\"\\q\"", "\"\xFF\"".b, "\"a\nb\"", "\xEF\xBB\xBF{}", "{}x",
      "[" * 100 + "0" + "]" * 100, "[" * 101 + "0" + "]" * 101]
    strings.concat(%w[true false null].flat_map do |literal|
      prefixes = (0...literal.length).map { |length| literal[0, length] }
      changed = literal.length.times.map { |index| literal.dup.tap { |value| value.setbyte(index, 120) } }
      boundaries = (8445..8450).chain(9213..9218).flat_map { |offset| [" " * offset + literal, " " * offset + literal[0...-1]] }
      prefixes + changed + boundaries + [literal + "x", "[" + literal + "]"]
    end)
    schemas = [{"contentMediaType" => "application/json"}, {"contentEncoding" => "base64", "contentMediaType" => "application/json"}]
    cases = schemas.map do |schema|
      values = schema.key?("contentEncoding") ? strings.map { |string| Base64.strict_encode64(string) } : strings
      vm = Schemurai.compile(schema, content: true, backend: :vm)
      [Schemurai.compile(schema, content: true, backend: :native), values.map { |value| [value, vm.valid?(value)] }]
    end
    base64_values = %w[TQ== TR== TWE= TWF= TWFu TQ TWE TQ=== ==== A=== AA== AAA= AAAA] + ["", "TQ==\n", " TQ=="]
    vm = Schemurai.compile({"contentEncoding" => "base64"}, content: true, backend: :vm)
    cases << [Schemurai.compile({"contentEncoding" => "base64"}, content: true, backend: :native), base64_values.map { |value| [value, vm.valid?(value)] }]
    schema = schemas.last
    vm = Schemurai.compile(schema, content: true, backend: :vm)
    values = %w[e30g!!!! e30gAA=A e30g==== e30=AAAA bnVsbA==AAAA e30g e30gICA=]
    cases << [Schemurai.compile(schema, content: true, backend: :native), values.map { |value| [value, vm.valid?(value)] }]
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |validator, tests|
      tests.each { |value, expected| expect(validator.valid?(value)).to eq(expected), value.inspect }
    end
  end

  it "shares string views across pattern, format and content assertions" do # rubocop:disable RSpec/ExampleLength
    checks = [
      {"type" => "string", "minLength" => 1, "pattern" => "^[0-9]+$", "format" => "relative-json-pointer", "contentMediaType" => "application/json"},
      {"type" => "string", "format" => "relative-json-pointer", "contentMediaType" => "application/json"},
      {"contentMediaType" => "application/json"},
      {"contentEncoding" => "base64", "contentMediaType" => "application/json"}
    ]
    values = ["", "1", "12", "01", "2#", "-1", "1" * 64, "日", "1".b, "1".encode(Encoding::US_ASCII), "e30=", "ezp9", true, nil, 2, 2.5, [], {}]
    cases = checks.flat_map do |check|
      [[check, ->(value) { value }], [{"items" => check}, ->(value) { [value] }],
        [{"properties" => {"value" => check}}, ->(value) { {"value" => value} }]].map do |schema, wrap|
        vm = Schemurai.compile(schema, content: true, format: true, backend: :vm)
        inputs = values.reject { |value| check.key?("pattern") && value.is_a?(String) && value.encoding == Encoding::ASCII_8BIT }.map(&wrap)
        [Schemurai.compile(schema, content: true, format: true, backend: :native),
          inputs.map { |value| [value, vm.valid?(value), vm.validate(value).errors.map(&:to_h)] }]
      end
    end
    GC.start
    GC.compact
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |validator, inputs|
      inputs.each do |value, valid, errors|
        expect(validator.valid?(value)).to eq(valid), value.inspect
        expect(validator.validate(value).errors.map(&:to_h)).to eq(errors), value.inspect
      end
    end
  end

  it "preserves content validity and diagnostics at the stack decoding boundary" do # rubocop:disable RSpec/ExampleLength
    schema = {"contentEncoding" => "base64", "contentMediaType" => "application/json"}
    vm = Schemurai.compile(schema, content: true, backend: :vm)
    native = Schemurai.compile(schema, content: true, backend: :native)
    inputs = (94..99).chain(126..131).chain(382..387).chain(8190..8195).flat_map do |length|
      json = '"' + "x" * (length - 2) + '"'
      encoded = Base64.strict_encode64(json)
      malformed = Base64.strict_encode64(json[0...-1] + "]")
      offsets = [0, encoded.bytesize / 2, encoded.bytesize - 1]
      offsets.concat([511, 512, 513, 1023, 1024, 1025, 2047, 2048, 2049]) if length > 8192
      [encoded, malformed] + offsets.map do |at|
        value = encoded.dup
        value.setbyte(at, 0)
        value
      end
    end
    cases = inputs.map { |value| [value, vm.valid?(value), vm.validate(value).errors.map(&:to_h)] }
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |value, valid, errors|
      expect(native.valid?(value)).to eq(valid), value.inspect
      expect(native.validate(value).errors.map(&:to_h)).to eq(errors), value.inspect
    end
  end

  it "checks every Base64 byte position including padded JSON endings" do # rubocop:disable RSpec/ExampleLength
    schema = {"contentEncoding" => "base64", "contentMediaType" => "application/json"}
    vm = Schemurai.compile(schema, content: true, backend: :vm)
    native = Schemurai.compile(schema, content: true, backend: :native)
    inputs = ["null", "false", '"a"', "[0,true]"].flat_map do |json|
      encoded = Base64.strict_encode64(json).b
      encoded.bytesize.times.flat_map do |at|
        256.times.map do |byte|
          value = encoded.dup
          value.setbyte(at, byte)
          [value, vm.valid?(value)]
        end
      end
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    inputs.each { |value, expected| expect(native.valid?(value)).to eq(expected), value.inspect }
  end

  it "rejects invalid Base64 bytes across SIMD and refill boundaries" do # rubocop:disable RSpec/ExampleLength
    encoded = Base64.strict_encode64('"' + "x" * 8193 + '"').b
    offsets = [0, 1, 15, 16, 31, 32, 63, 64, 127, 128, 255, 256, 511, 512, 513, 514, 1023, 1024, 1025, 1026,
      2047, 2048, 2049, encoded.bytesize - 2, encoded.bytesize - 1]
    inputs = offsets.flat_map do |at|
      256.times.map do |byte|
        value = encoded.dup
        value.setbyte(at, byte)
        value
      end
    end
    inputs.concat([128, 256, 512, 1024, 2048].flat_map do |boundary|
      ["TQ==", "TWE="].map { |tail| encoded[0...boundary - 4] + tail + encoded[boundary..] }
    end)
    schemas = [{"contentEncoding" => "base64"}, {"contentEncoding" => "base64", "contentMediaType" => "application/json"}]
    cases = schemas.map do |schema|
      vm = Schemurai.compile(schema, content: true, backend: :vm)
      [Schemurai.compile(schema, content: true, backend: :native), inputs.map { |value| [value, vm.valid?(value)] }]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |validator, tests|
      tests.each { |value, expected| expect(validator.valid?(value)).to eq(expected), value.inspect }
    end
  end

  it "stops content string runs at every byte value and group alignment" do # rubocop:disable RSpec/ExampleLength
    json = ('"' + "x" * 1024 + '"').b
    values = [*(1..40), 63, 64, 65, 96, 97, 98,
      127, 128, 129, 383, 384, 385, 767, 768, 769, 1023, 1024].flat_map do |at|
      256.times.map do |byte|
        value = json.dup
        value.setbyte(at, byte)
        value
      end
    end
    values.concat([90, 186, 378, 762, 9210].flat_map do |prefix|
      8.times.flat_map do |alignment|
        ['\\"', "\\\\", '\\n', '\\u1234', '\\uD800\\uDFFF', '\\uD800\\u0041', '\\q'].map do |escape|
          '"' + "x" * (prefix + alignment) + escape + "x" * 16 + '"'
        end
      end
    end)
    schemas = [{"contentMediaType" => "application/json"}, {"contentEncoding" => "base64", "contentMediaType" => "application/json"}]
    cases = schemas.map do |schema|
      vm = Schemurai.compile(schema, content: true, backend: :vm)
      inputs = schema.key?("contentEncoding") ? values.map { |value| Base64.strict_encode64(value) } : values
      [Schemurai.compile(schema, content: true, backend: :native), inputs.map { |value| [value, vm.valid?(value)] }]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |validator, inputs|
      inputs.each { |value, expected| expect(validator.valid?(value)).to eq(expected), value.inspect }
    end
  end

  it "matches VM syntax decisions for mutated JSON and Base64 inputs" do # rubocop:disable RSpec/ExampleLength
    random = Random.new(42)
    samples = ["{\"a\":[1,-2.5e+20,true,false,null,\"a\\n\\u1234\"]}", "\"日本\"", "[{},[],0]", " 123.456e-7 "]
    values = samples + Array.new(500) do
      bytes = samples.sample(random: random).bytes
      at = random.rand(bytes.length)
      case random.rand(3)
      when 0 then bytes[at] = random.rand(256)
      when 1 then bytes.insert(at, random.rand(256))
      else bytes.delete_at(at)
      end
      bytes.pack("C*")
    end
    schemas = [{"contentMediaType" => "application/json"}, {"contentEncoding" => "base64", "contentMediaType" => "application/json"}]
    cases = schemas.map do |schema|
      inputs = schema.key?("contentEncoding") ? values.map { |value| Base64.strict_encode64(value) } : values
      vm = Schemurai.compile(schema, content: true, backend: :vm)
      [Schemurai.compile(schema, content: true, backend: :native), inputs.map { |value| [value, vm.valid?(value)] }]
    end
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/= \n"
    inputs = Array.new(500) { Array.new(random.rand(17)) { alphabet[random.rand(alphabet.length)] }.join }
    encoded_samples = samples.map { |value| Base64.strict_encode64(value) } + %w[e30g bnVsbA==]
    inputs.concat(Array.new(500) do
      bytes = encoded_samples.sample(random: random).bytes
      bytes[random.rand(bytes.length)] = random.rand(256)
      bytes.pack("C*")
    end)
    vm = Schemurai.compile({"contentEncoding" => "base64"}, content: true, backend: :vm)
    cases << [Schemurai.compile({"contentEncoding" => "base64"}, content: true, backend: :native), inputs.map { |value| [value, vm.valid?(value)] }]
    schema = schemas.last
    vm = Schemurai.compile(schema, content: true, backend: :vm)
    cases << [Schemurai.compile(schema, content: true, backend: :native), inputs.map { |value| [value, vm.valid?(value)] }]
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |validator, tests|
      tests.each { |value, expected| expect(validator.valid?(value)).to eq(expected), value.inspect }
    end
  end

  it "checks transcoded JSON content without VM execution" do
    rule = {"contentMediaType" => "application/json"}
    dialect = {"$schema" => "https://json-schema.org/draft/2020-12/schema"}
    schemas = [rule, {"items" => rule}, {"properties" => {"value" => rule}},
      dialect.merge("anyOf" => [{"items" => rule}], "unevaluatedItems" => false)]
    encodings = [Encoding::UTF_16LE, Encoding::UTF_16BE, Encoding::UTF_32LE, Encoding::UTF_32BE, Encoding::ISO_8859_1, Encoding::Shift_JIS]
    values = encodings.flat_map { |encoding| ['{"a":1}', "[false,null,1]", "false", "null", "bad"].map { |value| value.encode(encoding) } }
    values += ['"é"'.encode(Encoding::ISO_8859_1), '"日本"'.encode(Encoding::Shift_JIS)]
    inputs = values + values.map { |value| [value, value] } + values.map { |value| {"value" => value} }
    expect_native_policy_results(schemas, inputs, content: true)
  end

  it "preserves JSON transcoding exceptions and bounded runtime ordering" do # rubocop:disable RSpec/ExampleLength
    rule = {"contentMediaType" => "application/json"}
    properties = {"value" => rule, "count" => {"type" => "integer"}}
    schemas = [rule, {"items" => rule}, {"properties" => properties}]
    broken = "\"\xFF\"".dup.force_encoding(Encoding::US_ASCII)
    values = [broken, "\x00".dup.force_encoding(Encoding::UTF_16LE), "[]".encode(Encoding::UTF_16LE),
      [broken], ["bad".encode(Encoding::UTF_16LE), broken], {"count" => "bad", "value" => broken}, {"value" => broken, "count" => "bad"}]
    limits = [{}, {timeout: 10}, {max_errors: 0}, {max_errors: 1}]
    combinations = values.product([:valid?, :validate], limits)
    cases = schemas.map do |schema|
      vm = Schemurai.compile(schema, content: true, backend: :vm)
      [Schemurai.compile(schema, content: true, backend: :native), combinations.map do |value, method, options|
        capture_validation(vm, method, value, **options)
      end]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    cases.each do |native, expected|
      combinations.zip(expected).each do |(value, method, options), result|
        expect(capture_validation(native, method, value, **options)).to eq(result)
      end
    end
  end

  it "roots JSON runtime observations and rechecks mutable content" do # rubocop:disable RSpec/ExampleLength
    schema = {"properties" => {"pattern" => {"pattern" => "(?=x)x"}, "json" => {"contentMediaType" => "application/json"}}}
    native = Schemurai.compile(schema, content: true, backend: :native)
    value = {"pattern" => "x", "json" => "[1]".encode(Encoding::UTF_16LE)}
    parses = 0
    allow(JSON).to receive(:parse).and_wrap_original do |original, *args|
      parses += 1
      GC.verify_compaction_references(double_heap: true, toward: :empty)
      original.call(*args)
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    expect(native.valid?(value)).to be(true)
    expect(native.validate(value).valid?).to be(true)
    value["json"].replace("bad".encode(Encoding::UTF_16LE))
    expect(native.valid?(value)).to be(false)
    expect(native.validate(value).errors.map(&:keyword)).to eq(["contentMediaType"])
    value["json"].replace("null".encode(Encoding::UTF_16LE))
    expect(native.valid?(value)).to be(true)
    expect(parses).to eq(5)
    annotation = Schemurai.compile(schema, backend: :native)
    expect(annotation.valid?(value)).to be(true)
    expect(parses).to eq(5)
  end

  it "keeps JSON runtime observations private to each Ractor" do
    schema = {"items" => {"contentMediaType" => "application/json"}}
    registry = Schemurai::SchemaRegistry.new(schemas: {"urn:json" => schema}, backend: :native).make_shareable
    workers = Array.new(2) do
      Ractor.new(registry) do |shared|
        validator = shared.validator_for("urn:json", content: true)
        runner = validator.instance_variable_get(:@evaluator).instance_variable_get(:@program)
        valid = "[1]".encode(Encoding::UTF_16LE)
        invalid = "bad".encode(Encoding::UTF_16LE)
        GC.start
        [runner.valid?([valid]), runner.valid?([invalid]), runner.diagnostics([invalid]).map(&:first)]
      end
    end
    workers.each { |worker| expect(worker.respond_to?(:value) ? worker.value : worker.take).to eq([true, false, ["contentMediaType"]]) }
  end

  it "isolates streamed content assertions in Ractors using a shared registry" do # rubocop:disable RSpec/ExampleLength
    schema = {"type" => "array", "items" => {"contentEncoding" => "base64", "contentMediaType" => "application/json"}}
    registry = Schemurai::SchemaRegistry.new(schemas: {"urn:content" => schema}, backend: :native)
    registry.make_shareable
    workers = Array.new(2) do
      Ractor.new(registry) do |shared|
        asserted = shared.validator_for("urn:content", content: true)
        annotation = shared.validator_for("urn:content")
        [asserted.valid?(["e30=", "W10="]), asserted.valid?(["ezp9"]), annotation.valid?(["ezp9"]), asserted.valid?(["bnVsbA=="])]
      end
    end
    workers.each do |worker|
      result = worker.respond_to?(:value) ? worker.value : worker.take
      expect(result).to eq([true, false, true, true])
    end
  end

  it "executes all supported official format cases without VM evaluation" do # rubocop:disable RSpec/ExampleLength
    formats = %w[date time date-time duration ipv4 ipv6 uuid json-pointer relative-json-pointer]
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    %w[draft7 draft2019-09 draft2020-12].each do |draft|
      formats.each do |format|
        path = "references/JSON-Schema-Test-Suite/tests/#{draft}/optional/format/#{format}.json"
        next unless File.file?(path)

        JSON.parse(File.read(path)).each do |group|
          validator = Schemurai.compile(group.fetch("schema"), format: true, backend: :native)
          group.fetch("tests").each do |record|
            value = record.fetch("data")
            expect(validator.valid?(value)).to eq(record.fetch("valid")), "#{draft}/#{format}: #{record.fetch("description")}"
            expect(validator.validate(value).valid?).to be(true) if record.fetch("valid")
          end
        end
      end
    end
  end

  it "scans format arrays with guarded byte views and complete error coverage" do # rubocop:disable RSpec/ExampleLength
    samples = {
      "date" => ["2024-02-29", "2023-02-29"],
      "time" => ["12:34:56Z", "25:34:56Z"],
      "date-time" => ["2024-02-29T12:34:56Z", "2023-02-29T12:34:56Z"],
      "duration" => ["P1Y2M3DT4H5M6S", "P1Y2M3DT4H5M6"],
      "ipv4" => ["192.168.1.1", "192.168.1.256"],
      "ipv6" => ["2001:db8::1", "2001:db8::x"],
      "uuid" => ["123e4567-e89b-12d3-a456-426614174000", "123e4567-e89b-12d3-a456-42661417400z"],
      "json-pointer" => ["/items/0/a~1b/~0value", "/items/0/a~2b"],
      "relative-json-pointer" => ["123/items/0/a~1b/~0value", "01/items"]
    }
    cases = samples.flat_map do |format, (valid, invalid)|
      schemas = [{"items" => {"format" => format}},
        {"items" => {"type" => "string", "format" => format}},
        {"$schema" => "https://json-schema.org/draft/2020-12/schema", "prefixItems" => [{"const" => "header"}],
         "items" => {"type" => "string", "format" => format}, "unevaluatedItems" => false}]
      schemas.map do |schema|
        prefix = schema.key?("prefixItems") ? ["header"] : []
        values = [[], [valid], [valid, invalid, invalid], [valid, nil, true, 1, {}, []],
          [valid.b], [valid.encode(Encoding::UTF_16LE)], ["", invalid, valid]]
        values = values.map { |items| prefix + items }
        vm = Schemurai.compile(schema, format: true, backend: :vm)
        native = Schemurai.compile(schema, format: true, backend: :native)
        program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
        special = Class.new(String).new(valid)
        expect(program.valid?(prefix + [special])).to be(true)
        expect(program.diagnostics(prefix + [special])).to eq([])
        expect(program.valid?(prefix + [{Object.new => 1}])).to eq(vm.valid?(prefix + [{Object.new => 1}]))
        [native, values.map { |value| [value, vm.valid?(value), vm.validate(value).errors] }]
      end
    end
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |native, values|
      values.each do |value, valid, errors|
        expect(native.valid?(value)).to eq(valid)
        expect(native.validate(value).errors).to eq(errors)
      end
    end
  end

  it "searches pointer escapes across byte and vector boundaries without VM execution" do # rubocop:disable RSpec/ExampleLength
    values = ["", "/", "~", "/~", "/~0", "/~1", "/~~0", "/~01", "/~10", "/é日/~0~1"]
    [0, 7, 8, 15, 16, 31, 32, 63, 64].each do |offset|
      prefix = ("/" + "a" * offset).b
      256.times do |byte|
        character = byte.chr(Encoding::ASCII_8BIT)
        values << prefix + "~" + character + "tail"
        values << prefix + character + "tail"
      end
    end
    [127, 128, 255, 256, 511, 512, 4095, 4096].each do |length|
      prefix = "/" + "a" * length
      values.concat([prefix, prefix + "~", prefix + "~0", prefix + "~1", prefix + "~2", prefix + "~0~1", prefix + "~0~"])
    end
    cases = %w[json-pointer relative-json-pointer].map do |format|
      schema = {"type" => "string", "format" => format}
      vm = Schemurai.compile(schema, format: true, backend: :vm)
      inputs = values.map { |value| (format == "json-pointer") ? value : "123" + value }
      [Schemurai.compile(schema, format: true, backend: :native),
        inputs.map { |value| [value, vm.valid?(value), vm.validate(value).errors] }]
    end
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |native, inputs|
      inputs.each do |value, valid, errors|
        expect(native.valid?(value)).to eq(valid)
        expect(native.validate(value).errors).to eq(errors)
      end
    end
  end

  it "honors Format-Assertion vocabulary without the format option" do # rubocop:disable RSpec/ExampleLength
    uri = "https://example.test/native-format-assertion"
    meta = {"$schema" => "https://json-schema.org/draft/2020-12/schema", "$id" => uri, "$vocabulary" => {
      "https://json-schema.org/draft/2020-12/vocab/core" => true,
      "https://json-schema.org/draft/2020-12/vocab/format-assertion" => true
    }}
    validator = Schemurai.compile({"$schema" => uri, "format" => "date"}, schemas: {uri => meta}, backend: :native)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    expect(validator.valid?("2024-02-29")).to be(true)
    expect(validator.valid?("2023-02-29")).to be(false)
    expect(validator.valid?(1)).to be(true)
  end

  it "isolates native format options in Ractors with a shared registry" do # rubocop:disable RSpec/ExampleLength
    schema = {"type" => "array", "items" => {"type" => "string", "format" => "date-time"}}
    registry = Schemurai::SchemaRegistry.new(schemas: {"urn:formats" => schema}, backend: :native)
    registry.make_shareable
    workers = Array.new(2) do
      Ractor.new(registry) do |shared|
        asserted = shared.validator_for("urn:formats", format: true)
        annotation = shared.validator_for("urn:formats")
        valid = ["2024-02-29T23:59:60Z"]
        invalid = ["2023-02-29T23:59:60Z"]
        [asserted.valid?(valid), asserted.valid?(invalid), annotation.valid?(invalid), asserted.valid?(valid)]
      end
    end
    workers.each do |worker|
      result = worker.respond_to?(:value) ? worker.value : worker.take
      expect(result).to eq([true, false, true, true])
    end
  end

  it "keeps format and content annotations native when assertions are disabled" do # rubocop:disable RSpec/ExampleLength
    validators = [
      Schemurai.compile({"format" => "date"}, backend: :native),
      Schemurai.compile({"format" => "unsupported-format"}, format: true, backend: :native),
      Schemurai.compile({"contentEncoding" => "base64", "contentMediaType" => "application/json"}, backend: :native)
    ]
    asserted = Schemurai.compile({"format" => "date"}, format: true, backend: :native)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    validators.each do |validator|
      expect(validator.valid?("invalid")).to be(true)
      expect(validator.validate("invalid").valid?).to be(true)
    end
    expect(asserted.valid?("invalid")).to be(false)
  end

  it "executes nested constraints without reentering the VM" do # rubocop:disable RSpec/ExampleLength
    schema = {
      "type" => "object", "required" => ["items"], "additionalProperties" => false,
      "properties" => {"items" => {
        "type" => "array", "minItems" => 1,
        "items" => {"type" => "object", "properties" => {
          "id" => {"type" => "integer", "minimum" => 1},
          "name" => {"type" => "string", "minLength" => 2}
        }, "required" => %w[id name], "additionalProperties" => false}
      }}
    }
    validator = Schemurai.compile(schema, backend: :native)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    expect(validator.valid?({"items" => [{"id" => 1, "name" => "日本"}]})).to be(true)
    expect(validator.valid?({"items" => [{"id" => 0, "name" => "ab"}]})).to be(false)
    expect(validator.valid?({"items" => [], "extra" => 1})).to be(false)
    expect(validator.validate({"items" => [{"id" => 1, "name" => "ab"}]}).valid?).to be(true)
  end

  it "retains schema handles through GC and compaction" do # rubocop:disable RSpec/ExampleLength
    validator = Schemurai.compile({"type" => "object", "properties" => {
      "value" => {"enum" => ["yes", [1, "two"]]}
    }, "required" => ["value"], "additionalProperties" => false}, backend: :native)
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    expect(validator.valid?({"value" => [1, "two"]})).to be(true)
    expect(validator.valid?({"value" => "no"})).to be(false)
    expect(validator.valid?({"other" => "yes"})).to be(false)
  end

  it "keeps Ruby values live during compilation under GC stress" do
    previous = GC.stress
    GC.stress = true
    validator = Schemurai.compile({"type" => "array", "items" => {"anyOf" => [
      {"const" => "hello", "pattern" => "^hello$"}, {"type" => "number", "minimum" => 0.1, "multipleOf" => 0.1}
    ]}}, backend: :native)
    expect(validator.valid?(["hello", 0.3, 2**100])).to be(true)
  ensure
    GC.stress = previous
  end

  it "preserves exact numeric comparisons at the float precision boundary" do
    validator = Schemurai.compile({"const" => 9_007_199_254_740_993}, backend: :native)
    expect(validator.valid?(9_007_199_254_740_992.0)).to be(false)
    expect(validator.valid?(9_007_199_254_740_993)).to be(true)
  end

  it "compares numeric bounds and decimal multiples without VM evaluation" do # rubocop:disable RSpec/ExampleLength
    bounds = [-(2**127), -(2**100), -9_007_199_254_740_993, -1.5, -0.3, 0, 0.3, 1.5, 9_007_199_254_740_993, 2**100, (2**127) - 1]
    values = bounds + [-0.0, 0.1 + 0.2, 9_007_199_254_740_992.0, (2**100).to_f, ((2**127) - 1).to_f, "text", nil]
    schemas = bounds.flat_map { |bound| %w[minimum maximum exclusiveMinimum exclusiveMaximum].map { |keyword| {keyword => bound} } }
    schemas += [0, -2, 0.0001, 0.1, 0.3, 1.5, 2, 7, 2**100].map { |divisor| {"multipleOf" => divisor} }
    schemas += [{"minimum" => 0.3, "maximum" => 0.3, "multipleOf" => 0.1}]
    cases = schemas.map do |schema|
      vm = Schemurai.compile(schema, backend: :vm)
      [schema, Schemurai.compile(schema, backend: :native), values.map { |value| vm.valid?(value) }]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |schema, validator, expected|
      values.zip(expected).each do |value, result|
        expect(validator.valid?(value)).to eq(result), "#{schema.inspect} on #{value.inspect}"
      end
    end
  end

  it "folds array integer bounds while preserving mixed values and exclusive endpoints" do # rubocop:disable RSpec/ExampleLength
    limits = [-(2**63), -(2**62), -1, 0, 1, 2**62 - 1, 2**63 - 1]
    values = limits.flat_map { |n| [n - 1, n, n + 1, n.to_f] } + [nil, "text", true]
    rules = limits.flat_map { |n| %w[minimum maximum exclusiveMinimum exclusiveMaximum].map { |keyword| {keyword => n} } }
    rules.concat([{"minimum" => 2, "maximum" => 1}, {"minimum" => -1, "exclusiveMinimum" => 0, "maximum" => 2, "exclusiveMaximum" => 1}])
    instances = values.map { |n| [0, n] } + [[], values, [0] * 1000]
    cases = rules.flat_map do |rule|
      [rule, rule.merge("type" => "integer"), rule.merge("type" => "number")].map do |items|
        schema = {"$schema" => "https://json-schema.org/draft/2020-12/schema", "type" => "array", "prefixItems" => [{"type" => "integer"}], "items" => items}
        vm = Schemurai.compile(schema, backend: :vm)
        [Schemurai.compile(schema, backend: :native), instances.map { |value| [vm.valid?(value), vm.validate(value).errors] }]
      end
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |native, expected|
      instances.zip(expected).each do |value, (valid, errors)|
        expect(native.valid?(value)).to eq(valid), value.inspect
        expect(native.validate(value).errors).to eq(errors), value.inspect
      end
    end
  end

  it "preserves mixed-item results at every vector block position" do # rubocop:disable RSpec/ExampleLength
    schema = {"type" => "array", "items" => {"type" => "integer", "minimum" => -16, "maximum" => 16}}
    vm = Schemurai.compile(schema, backend: :vm)
    native = Schemurai.compile(schema, backend: :native)
    original = Array.new(33) { |at| at % 33 - 16 }
    inputs = original.each_index.flat_map do |at|
      [-17, 17, -(2**62) - 1, 2**62, 1.5, nil, "value", Rational(1, 2)].map do |value|
        input = original.dup
        input[at] = value
        input
      end
    end
    inputs.concat([[], original, [0] * 16, [0] * 17, [0] * 32, [0] * 65])
    inputs.concat([[-17, Rational(1, 2)], [Rational(1, 2), -17]].map { |tail| [0] * 16 + tail })
    inputs.each do |input|
      expect(native.valid?(input)).to eq(vm.valid?(input)), input.inspect
      expect(native.validate(input).errors).to eq(vm.validate(input).errors), input.inspect
    end
  end

  it "checks oversized Integer bounds and ordered diagnostics without VM execution" do # rubocop:disable RSpec/ExampleLength
    bounds = [-(2**127), -0.3, 0, 0.3, 2**100, 2**127 - 1]
    values = [127, 128, 129, 200, 1024, 4096].flat_map { |power| [2**power - 1, 2**power, 2**power + 1, -(2**power) - 1, -(2**power), -(2**power) + 1] }
    schemas = bounds.flat_map { |bound| %w[minimum maximum exclusiveMinimum exclusiveMaximum].map { |keyword| {keyword => bound} } }
    schemas << {"minimum" => 2**100, "maximum" => 0, "exclusiveMinimum" => 1, "exclusiveMaximum" => -1}
    cases = schemas.flat_map do |schema|
      [[schema, values], [{"items" => schema}, values.map { |value| [value] }],
        [{"properties" => {"value" => schema}}, values.map { |value| {"value" => value} }]].map do |rule, instances|
        vm = Schemurai.compile(rule, backend: :vm)
        [Schemurai.compile(rule, backend: :native), instances,
          instances.map { |value| [vm.valid?(value), vm.validate(value).errors] }]
      end
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |native, instances, expected|
      instances.zip(expected).each do |value, (valid, errors)|
        expect(native.valid?(value)).to eq(valid), value.inspect
        expect(native.validate(value).errors).to eq(errors), value.inspect
      end
    end
  end

  it "compares wide schema Integer bounds through rooted handles without VM execution" do # rubocop:disable RSpec/ExampleLength
    cases = [2**127, 2**200 + 7, 2**1024 + 1, 2**4096 + 3].flat_map do |magnitude|
      [magnitude, -magnitude].flat_map do |bound|
        values = [bound - 1, bound, bound + 1, -bound, -(2**127), 2**100, -1, 0, 1, nil, false, "item", 0.5, -0.5, 3.0, -3.0]
        rules = %w[minimum maximum exclusiveMinimum exclusiveMaximum].map { |keyword| {keyword => bound} }
        rules << {"type" => "integer", "minimum" => bound}
        rules << {"type" => ["integer", "null"], "maximum" => bound}
        rules << {"minimum" => bound, "maximum" => bound, "exclusiveMinimum" => bound, "exclusiveMaximum" => bound}
        if magnitude.bit_length <= 1024
          rules.concat(%w[minimum maximum exclusiveMinimum exclusiveMaximum].map { |keyword| {keyword => bound, "multipleOf" => 3} })
        end
        rules.flat_map do |rule|
          [[rule, values], [{"items" => rule}, values.map { |value| [value] }],
            [{"properties" => {"value" => rule}}, values.map { |value| {"value" => value} }]]
        end
      end
    end.map do |schema, instances|
      vm = Schemurai.compile(schema, backend: :vm)
      [Schemurai.compile(schema, backend: :native), instances, instances.map { |instance| [vm.valid?(instance), vm.validate(instance).errors] }]
    end
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |native, instances, expected|
      instances.zip(expected).each do |instance, (valid, errors)|
        expect(native.valid?(instance)).to eq(valid), instance.inspect
        expect(native.validate(instance).errors).to eq(errors), instance.inspect
      end
    end
  end

  it "compares Float instances against wide Integer bounds at rounding ties without VM execution" do # rubocop:disable RSpec/ExampleLength
    bounds = [127, 128, 200, 511, 1023, 1024, 4096].flat_map { |power| [2**power - 1, 2**power, 2**power + 1] }
    bounds.concat([-1, 0, 1].flat_map { |offset| [2**200 + 2**147 + offset, 2**200 + 2**148 + 2**147 + offset, Float::MAX.to_i + offset] })
    cases = bounds.flat_map { |bound| [bound, -bound] }.flat_map do |bound|
      rounded = bound.to_f
      values = [rounded.prev_float, rounded, rounded.next_float, 0.0, Float::INFINITY, -Float::INFINITY, Float::NAN]
      rules = %w[minimum maximum exclusiveMinimum exclusiveMaximum].map { |keyword| {keyword => bound} }
      rules << {"type" => "integer", "minimum" => bound}
      rules << {"type" => ["integer", "null"], "maximum" => bound}
      rules << {"type" => "number", "minimum" => bound}
      rules << {"minimum" => bound, "maximum" => bound, "exclusiveMinimum" => bound, "exclusiveMaximum" => bound}
      rules.flat_map do |rule|
        [[rule, values], [{"items" => rule}, values.map { |value| [value] }],
          [{"properties" => {"value" => rule}}, values.map { |value| {"value" => value} }]]
      end
    end.map do |schema, instances|
      vm = Schemurai.compile(schema, backend: :vm)
      [Schemurai.compile(schema, backend: :native), instances, instances.map { |instance| [vm.valid?(instance), vm.validate(instance).errors] }]
    end
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |native, instances, expected|
      instances.zip(expected).each do |instance, (valid, errors)|
        expect(native.valid?(instance)).to eq(valid), instance.inspect
        expect(native.validate(instance).errors).to eq(errors), instance.inspect
      end
    end
  end

  it "checks integer multiples with fused bounds and ordered diagnostics" do # rubocop:disable RSpec/ExampleLength
    divisors = [0, -1, -(2**63), 0.0001, 0.1, 0.3, 1.5, 1, 3, 7, 2**63 - 1, 2**63, 2**100]
    rules = divisors.flat_map do |divisor|
      [{"multipleOf" => divisor},
        {"type" => "integer", "multipleOf" => divisor, "minimum" => -9, "maximum" => 9, "exclusiveMinimum" => -8, "exclusiveMaximum" => 8},
        {"multipleOf" => divisor, "minimum" => 9, "maximum" => -9, "exclusiveMinimum" => 8, "exclusiveMaximum" => -8},
        {"multipleOf" => divisor, "minimum" => 0.3}]
    end
    values = [-(2**127), -(2**62), -9, -8, -7, -3, -1, 0, 1, 3, 7, 8, 9, 2**62 - 1, 2**100,
      0.0, 3.0, 3.5, nil, false, "entry"]
    cases = rules.flat_map do |rule|
      [[rule, values], [{"items" => rule}, values.map { |value| [value] }],
        [{"properties" => {"value" => rule}}, values.map { |value| {"value" => value} }]]
    end.map do |schema, instances|
      vm = Schemurai.compile(schema, backend: :vm)
      [Schemurai.compile(schema, backend: :native), instances, instances.map { |instance| [vm.valid?(instance), vm.validate(instance).errors] }]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |native, instances, expected|
      instances.zip(expected).each do |instance, (valid, errors)|
        expect(native.valid?(instance)).to eq(valid), instance.inspect
        expect(native.validate(instance).errors).to eq(errors), instance.inspect
      end
    end
  end

  it "checks wide Integer multiples and conflicting bounds without VM execution" do # rubocop:disable RSpec/ExampleLength
    divisors = [0.1, 0.3, 1.5, 3, 7, 17, 257, 2**64 - 1, 2**64 + 1, 2**100, 2**126 + 5]
    cases = divisors.flat_map do |divisor|
      numerator = divisor.to_s.to_r.numerator
      values = [128, 200, 511, 768].flat_map do |power|
        multiple = 2**power * numerator
        [multiple - 1, multiple, multiple + 1, -multiple - 1, -multiple, -multiple + 1]
      end + [2**126, 2**127 - 1, 2**127, -(2**127), -(2**127) - 1,
        2**1023, -(2**1023), 2**1024 - 1, -(2**1024) + 1]
      rule = {"multipleOf" => divisor, "minimum" => -(2**100), "maximum" => 2**100}
      [{"multipleOf" => divisor}, rule].flat_map do |schema|
        [[schema, values], [{"items" => schema}, values.map { |value| [value] }]]
      end
    end
    [0, -3, 1, 0.1].each do |divisor|
      cases << [{"multipleOf" => divisor}, [2**4096, -(2**4096)]]
    end
    cases.map! do |schema, values|
      vm = Schemurai.compile(schema, backend: :vm)
      [Schemurai.compile(schema, backend: :native), values, values.map { |value| [vm.valid?(value), vm.validate(value).errors] }]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |native, values, expected|
      values.zip(expected).each do |value, (valid, errors)|
        expect(native.valid?(value)).to eq(valid), value.inspect
        expect(native.validate(value).errors).to eq(errors), value.inspect
      end
    end
  end

  it "checks unbounded Integer multiples without VM execution" do # rubocop:disable RSpec/ExampleLength
    divisors = [3, 7, 0.3, 1.25, 2**64 - 1, 2**64 + 1, 2**126 + 1]
    cases = divisors.flat_map do |divisor|
      numerator = divisor.to_s.to_r.numerator
      values = [1023, 1024, 1025, 4096, 65_536].flat_map do |power|
        multiple = 2**power * numerator
        [multiple - 1, multiple, multiple + 1, -multiple - 1, -multiple, -multiple + 1]
      end
      schemas = [{"multipleOf" => divisor}, {"minimum" => 0, "maximum" => 1, "multipleOf" => divisor}]
      schemas.flat_map do |schema|
        [[schema, values], [{"items" => schema}, [values]],
          [{"properties" => {"n" => schema}}, values.map { |value| {"n" => value} }]]
      end
    end
    cases.map! do |schema, values|
      vm = Schemurai.compile(schema, backend: :vm)
      [Schemurai.compile(schema, backend: :native), values,
        values.map { |value| [vm.valid?(value), vm.validate(value).errors] }]
    end
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |native, values, expected|
      values.zip(expected).each do |value, (valid, errors)|
        expect(native.valid?(value)).to eq(valid)
        expect(native.validate(value).errors).to eq(errors)
        expect(native.valid?(value, timeout: 10)).to eq(valid)
        expect(native.validate(value, timeout: 10).errors).to eq(errors)
      end
    end
  end

  it "retains bound failures and complete multiple diagnostics for unbounded Integers" do
    schemas = [{"maximum" => 0, "multipleOf" => 3}, {"minimum" => 0, "multipleOf" => 7}]
    values = [2**1024, 2**4096 * 3, -(2**4096), -(2**4096) * 7]
    expect_native_policy_results(schemas, values)
  end

  it "scans typed and untyped numeric arrays with preselected rules" do # rubocop:disable RSpec/ExampleLength
    rule = {"minimum" => 0.3, "maximum" => 2**100}
    schemas = [rule, rule.merge("type" => "number"), rule.merge("type" => "integer"),
      rule.merge("type" => ["number", "string"]), {"minimum" => 2**100},
      {"type" => "integer", "minimum" => 2**100}]
      .map { |items| {"items" => items} }
    schemas << {"$schema" => "https://json-schema.org/draft/2020-12/schema", "prefixItems" => [true], "items" => rule}
    schemas << {"$schema" => "https://json-schema.org/draft/2020-12/schema", "items" => rule, "unevaluatedItems" => false}
    values = [[], [1, 2.0, 0.5], [0.25, 1], [-1, 1], [2**100], [2**200], [-(2**200)],
      [-(2**62), 2**62 - 1], [Float::NAN], [Float::INFINITY], [-Float::INFINITY],
      [nil, false, "entry", [], {"id" => 1}], ["entry", 1], [-1, 2**100]]
    cases = schemas.map do |schema|
      vm = Schemurai.compile(schema, backend: :vm)
      [Schemurai.compile(schema, backend: :native), values.map { |value| [vm.valid?(value), vm.validate(value).errors] }]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |native, expected|
      values.zip(expected).each do |value, (valid, errors)|
        expect(native.valid?(value)).to eq(valid), value.inspect
        expect(native.validate(value).errors).to eq(errors), value.inspect
      end
    end
  end

  it "dispatches special numeric values without entering the Integer scalar adapter" do # rubocop:disable RSpec/ExampleLength
    numeric = Class.new(Numeric) do
      def to_int = raise("numeric coercion")
      def to_f = raise("numeric coercion")
      def to_s = raise("numeric coercion")
    end.new
    rule = {"type" => "number", "minimum" => 0, "maximum" => 2**100}
    schemas = [rule, {"items" => rule}, {"properties" => {"value" => rule}}]
    cases = [numeric, Rational(3, 2), Complex(1, 2)].flat_map do |value|
      schemas.each_with_index.map do |schema, index|
        instance = [value, [value], {"value" => value}].fetch(index)
        vm = Schemurai.compile(schema, backend: :vm)
        [Schemurai.compile(schema, backend: :native), instance,
          [:valid?, :validate].map { |method| capture_validation(vm, method, instance) }]
      end
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |native, instance, expected|
      [:valid?, :validate].zip(expected).each do |method, result|
        expect(capture_validation(native, method, instance)).to eq(result)
      end
    end
  end

  it "evaluates special numeric bounds and multiples through native traversal" do # rubocop:disable RSpec/ExampleLength
    rules = [{"maximum" => 1}, {"minimum" => 1}, {"exclusiveMaximum" => 1},
      {"exclusiveMinimum" => 1}, {"multipleOf" => 0.3},
      {"maximum" => 1, "minimum" => 2, "exclusiveMaximum" => 1, "exclusiveMinimum" => 2, "multipleOf" => 0.5}]
    rules = rules.flat_map do |rule|
      [rule, rule.merge("type" => "number"), rule.merge("type" => "integer"), rule.merge("type" => ["integer", "string"])]
    end
    fake = Object.new
    fake.define_singleton_method(:is_a?) { |klass| klass == Numeric }
    fake.define_singleton_method(:finite?) { true }
    fake.define_singleton_method(:to_i) { 1 }
    fake.define_singleton_method(:to_s) { "1.5" }
    [:>, :<, :>=, :<=].each { |operator| fake.define_singleton_method(operator) { |limit| 1.5.public_send(operator, limit) } }
    values = [fake, BasicObject.new, Class.new(String).new("x"), Class.new(Array).new, Class.new(Hash).new,
      Rational(3, 2), Rational(1, 1), Rational(-1, 3), Rational(2**4096, 3), Complex(1, 2)]
    cases = rules.flat_map do |rule|
      wrappers = [->(value) { [rule, value] }, ->(value) { [{"items" => rule}, [1, value, value]] },
        ->(value) { [{"properties" => {"a~/b" => rule}}, {"a~/b" => value}] },
        ->(value) { [{"contains" => rule}, [value]] },
        ->(value) { [{"$defs" => {"n" => rule}, "allOf" => [{"$ref" => "#/$defs/n"}, {"$ref" => "#/$defs/n"}]}, value] }]
      wrappers.map do |wrap|
        schema = wrap.call(nil).first
        vm = Schemurai.compile(schema, backend: :vm)
        expected = values.product([:valid?, :validate], [{}, {timeout: 10}, {max_errors: 0}, {max_errors: 1}]).map do |value, method, options|
          input = wrap.call(value).last
          [input, method, options, capture_validation(vm, method, input, **options)]
        end
        [Schemurai.compile(schema, backend: :native), expected]
      end
    end
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    cases.each do |native, expected|
      expected.each do |input, method, options, result|
        expect(capture_validation(native, method, input, **options)).to eq(result)
      end
    end
  end

  it "preserves numeric method order, cache observations and staged diagnostic failures" do # rubocop:disable RSpec/ExampleLength
    klass = Class.new(Numeric) do
      attr_reader :calls
      def initialize
        @calls = []
      end

      def is_a?(klass)
        @calls << [:is_a?, klass]
        super
      end

      def finite?
        @calls << :finite?
        true
      end

      def to_i
        @calls << :to_i
        1
      end

      def to_s
        @calls << :to_s
        "1.5"
      end

      def inspect = "special number"

      def hash
        @calls << :hash
        15
      end

      def ==(other)
        @calls << [:==, other]
        false
      end

      [:>, :<, :>=, :<=].each do |operator|
        define_method(operator) do |other|
          @calls << [operator, other]
          1.5.public_send(operator, other)
        end
      end
    end
    rules = [{"maximum" => 1, "minimum" => 2, "exclusiveMaximum" => 1, "exclusiveMinimum" => 2},
      {"type" => "integer", "maximum" => 1, "multipleOf" => 0.3},
      {"type" => "integer", "maximum" => nil}, {"maximum" => 1, "minimum" => nil}]
    schemas = rules.flat_map do |rule|
      [rule, {"items" => rule}, {"anyOf" => [rule, rule]}, {"oneOf" => [rule, rule]},
        {"$defs" => {"n" => rule}, "allOf" => [{"$ref" => "#/$defs/n"}, {"$ref" => "#/$defs/n"}]}]
    end
    schemas.each do |schema|
      [:valid?, :validate].product([{}, {timeout: 10}, {max_errors: 0}, {max_errors: 1}]).each do |method, options|
        vm = Schemurai.compile(schema, backend: :vm)
        native = Schemurai.compile(schema, backend: :native)
        evaluator = native.instance_variable_get(:@evaluator)
        allow(evaluator).to receive(:limited_vm).and_raise("VM execution")
        fallback = evaluator.instance_variable_get(:@vm)
        allow(fallback).to receive(:valid?).and_raise("VM execution")
        allow(fallback).to receive(:validate).and_raise("VM execution")
        values = [klass.new, klass.new]
        inputs = values.map { |value| schema.key?("items") ? [0.5, value, value] : value }
        2.times do
          values.each { |value| value.calls.clear }
          expected = capture_validation(vm, method, inputs.first, **options)
          expect(capture_validation(native, method, inputs.last, **options)).to eq(expected)
          expect([schema, method, options, values.last.calls]).to eq([schema, method, options, values.first.calls])
        end
      end
    end
  end

  it "retains Ruby truthiness and GC roots between numeric runtime stages" do
    truthy = Object.new
    truthy.define_singleton_method(:!) { raise "truthiness dispatched !" }
    klass = Class.new(Numeric)
    [:>, :<, :>=, :<=].each do |operator|
      klass.define_method(operator) do |_other|
        GC.verify_compaction_references(double_heap: true, toward: :empty)
        truthy
      end
    end
    numeric = klass.new
    rule = {"maximum" => 1, "minimum" => 2, "exclusiveMaximum" => 1, "exclusiveMinimum" => 2}
    expect_native_policy_results([rule, {"allOf" => [rule, rule]}], [numeric])
    expect(Schemurai.compile(rule, backend: :native).validate(numeric).errors.map(&:keyword)).to eq(rule.keys)
  end

  it "keeps numeric runtime frames and decimal caches private to each Ractor" do
    schema = {"items" => {"minimum" => 1, "multipleOf" => 0.5}}
    registry = Schemurai::SchemaRegistry.new(schemas: {"urn:numeric" => schema}, backend: :native).make_shareable
    workers = Array.new(2) do
      Ractor.new(registry) do |shared|
        validator = shared.validator_for("urn:numeric")
        runner = validator.instance_variable_get(:@evaluator).instance_variable_get(:@program)
        value = [Rational(3, 2), Rational(1, 3)]
        GC.start
        [runner.valid?(value), runner.diagnostics(value).map(&:first)]
      end
    end
    workers.each { |worker| expect(worker.respond_to?(:value) ? worker.value : worker.take).to eq([false, %w[minimum multipleOf]]) }
  end

  it "uses truthiness for integer predicates without calling the result's negation" do
    truthy = Object.new
    truthy.define_singleton_method(:!) { raise "predicate negation" }
    integer = Object.new
    integer.define_singleton_method(:==) { |_value| truthy }
    klass = Class.new(Numeric) do
      attr_accessor :integer
      def finite? = true
      def to_i = integer
      def <(_other) = false
    end
    value = klass.new
    value.integer = integer
    expect_native_policy_results([{"type" => "integer", "minimum" => 0}], [value])
  end

  it "roots converted numbers when a cache key triggers compaction" do
    klass = Class.new(Numeric) do
      def to_s = "1.5"

      def hash
        GC.verify_compaction_references(double_heap: true, toward: :empty)
        15
      end
    end
    rule = {"maximum" => 1, "multipleOf" => 1}
    expect_native_policy_results([rule, {"allOf" => [rule, rule]}], [klass.new])
  end

  it "checks the numeric conversion deadline before a later comparison exception" do
    klass = Class.new(Numeric) do
      attr_accessor :converted
      def to_s
        converted.call
        "1.5"
      end
    end
    rule = {"maximum" => nil, "multipleOf" => 0.5}
    allow(Process).to receive(:clock_gettime).and_call_original
    [:vm, :native].each do |backend|
      value = klass.new
      value.converted = -> { allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(0.2) }
      validator = Schemurai.compile(rule, backend: backend)
      [:valid?, :validate].each do |method|
        allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(0.0)
        expect { validator.public_send(method, value, timeout: 0.1) }.to raise_error(Schemurai::LimitExceeded) { |error|
          expect(error.limit).to eq(:timeout)
        }
      end
    end
  end

  it "handles null numeric operands without VM execution" do # rubocop:disable RSpec/ExampleLength
    keys = %w[maximum minimum exclusiveMaximum exclusiveMinimum multipleOf]
    rules = keys.flat_map { |key| [{key => nil}, {key => nil, "multipleOf" => 0.5}] }
    rules += [{"maximum" => 3, "minimum" => nil}, {"maximum" => 3, "minimum" => nil, "multipleOf" => nil},
      {"minimum" => 0, "exclusiveMaximum" => nil}, {"maximum" => 3, "minimum" => 0, "multipleOf" => nil}]
    rules += rules.first(5).flat_map { |rule| [rule.merge("type" => "number"), rule.merge("type" => "integer")] }
    values = [-1, 0, 3, 6, 0.5, 2**4096, Float::MAX, Float::NAN, Float::INFINITY, -Float::INFINITY, "x", nil]
    combinations = values.product([:valid?, :validate], [{}, {timeout: 10}, {max_errors: 0}, {max_errors: 1}])
    wrappers = [->(rule, value) { [rule, value] }, ->(rule, value) { [{"items" => rule}, [value, value]] },
      ->(rule, value) { [{"properties" => {"value" => rule}}, {"value" => value}] }]
    cases = rules.product(wrappers).map do |rule, wrap|
      schema = wrap.call(rule, nil).first
      vm = Schemurai.compile(schema, backend: :vm)
      [Schemurai.compile(schema, backend: :native), combinations.map do |value, method, options|
        input = wrap.call(rule, value).last
        [input, method, options, capture_validation(vm, method, input, **options)]
      end]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    cases.each do |native, inputs|
      inputs.each do |input, method, options, expected|
        expect(capture_validation(native, method, input, **options)).to eq(expected)
      end
    end
  end

  it "preserves null numeric exception order across applicators, paths and limits" do # rubocop:disable RSpec/ExampleLength
    rule = {"maximum" => 3, "minimum" => nil, "multipleOf" => 0.5}
    dialect = {"$schema" => "https://json-schema.org/draft/2020-12/schema"}
    schemas = [{"anyOf" => [true, rule]}, {"allOf" => [false, rule]}, {"oneOf" => [true, rule]},
      dialect.merge("contains" => rule, "unevaluatedItems" => false), {"additionalProperties" => rule}]
    bad_key = "x".encode(Encoding::UTF_16LE)
    values = [1, 5, [5], [5, 1], [1, 5], {bad_key => 5}, {bad_key => 1}, {"x" => 5, bad_key => 1}]
    combinations = values.product([:valid?, :validate], [{}, {timeout: 10}, {max_errors: 0}, {max_errors: 1}])
    cases = schemas.map do |schema|
      vm = Schemurai.compile(schema, backend: :vm)
      [Schemurai.compile(schema, backend: :native), combinations.map do |input, method, options|
        capture_validation(vm, method, input, **options)
      end]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    cases.each do |native, expected|
      combinations.zip(expected).each do |(input, method, options), result|
        expect(capture_validation(native, method, input, **options)).to eq(result)
      end
    end
  end

  it "uses full scalar trials and short-circuiting container children" do # rubocop:disable RSpec/ExampleLength
    numeric = {"maximum" => 3, "minimum" => nil}
    string = {"minLength" => 2, "pattern" => "(?=x)x"}
    incompatible = "x".encode(Encoding::UTF_16LE)
    dialect = {"$schema" => "https://json-schema.org/draft/2020-12/schema"}
    cases = [[{"anyOf" => [true, string]}, incompatible], [{"not" => string}, incompatible],
      [{"anyOf" => [true, {"items" => string}]}, [incompatible]],
      [{"anyOf" => [true, {"properties" => {"x" => numeric}}]}, {"x" => 5}],
      [{"items" => {"anyOf" => [true, numeric]}, "maxItems" => 1}, [1, 5]],
      [{"properties" => {"x" => {"anyOf" => [true, numeric]}}}, {"x" => 5}],
      [{"items" => {"items" => {"anyOf" => [true, numeric]}}}, [[5]]],
      [{"$defs" => {"n" => {"anyOf" => [true, numeric]}}, "items" => {"$ref" => "#/$defs/n"}}, [5]],
      [{"anyOf" => [true, {"maxItems" => 0, "contains" => numeric}]}, [5]],
      [{"$defs" => {"s" => string}, "anyOf" => [true, {"$ref" => "#/$defs/s"}]}, incompatible],
      [dialect.merge(string, "unevaluatedItems" => false), incompatible],
      [dialect.merge(numeric, "unevaluatedProperties" => false), 5]].map do |schema, value|
      vm = Schemurai.compile(schema, backend: :vm)
      [Schemurai.compile(schema, backend: :native), value, [:valid?, :validate].map { |method| capture_validation(vm, method, value) }]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |native, value, expected|
      [:valid?, :validate].zip(expected).each do |method, result|
        expect(capture_validation(native, method, value)).to eq(result)
        expect(capture_validation(native, method, value, timeout: 10)).to eq(result)
      end
    end
  end

  it "separates null numeric runtime operations and clears observations between calls" do # rubocop:disable RSpec/ExampleLength
    script = <<~RUBY
      require "schemurai"
      rules = [{"maximum"=>nil,"minimum"=>nil}, {"multipleOf"=>nil}]
      pairs = rules.map { |rule| [Schemurai.compile(rule,backend: :vm), Schemurai.compile(rule,backend: :native)] }
      original_gt = Integer.instance_method(:>)
      original_lt = Integer.instance_method(:<)
      Integer.define_method(:>) do |other|
        if other.nil?
          GC.verify_compaction_references(double_heap: true, toward: :empty)
          false
        else
          original_gt.bind_call(self,other)
        end
      end
      Integer.define_method(:<) { |other| other.nil? ? true : original_lt.bind_call(self,other) }
      NilClass.define_method(:positive?) { false }
      capture = lambda do |validator, method|
        result = validator.public_send(method, 1)
        method == :validate ? result.errors : result
      rescue => error
        [error.class.name,error.message]
      end
      pairs.each do |vm,native|
        [:valid?, :validate].each do |method|
          abort "different numeric behavior" unless capture.call(vm,method) == capture.call(native,method)
        end
        abort "unsupported numeric operation" if native.instance_variable_get(:@evaluator).instance_variable_get(:@program).valid?(1).nil?
      end
      NilClass.define_method(:positive?) { true }
      capture = lambda do |validator|
        validator.valid?(1)
      rescue => error
        [error.class.name,error.message]
      end
      # The VM retains multiple results, so rebuild its oracle after the method change.
      fresh_vm = Schemurai.compile(rules.last, backend: :vm)
      abort "stale observation" unless capture.call(fresh_vm) == capture.call(pairs.last.last)
      puts "ok"
    RUBY
    output, errors, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-Iext/schemurai_native", "-e", script)
    expect(status.success?).to be(true), errors
    expect(output).to eq("ok\n")
  end

  it "matches Ruby decimal spelling at numeric boundaries" do # rubocop:disable RSpec/ExampleLength
    random = Random.new(1729)
    values = [723340043767187.2, 0.8455124082255701, 1e23, -1e23, 1e-20, 0.1, 0.3, -0.0]
    2000.times do
      value = [random.rand(2**64)].pack("Q").unpack1("d")
      values << value if value.finite?
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    values.each do |value|
      next if value.zero?

      validator = Schemurai.compile({"minimum" => value, "maximum" => value, "multipleOf" => value.abs}, backend: :native)
      expect(validator.valid?(value)).to be(true), value.inspect
      expect(validator.validate(value).errors).to be_empty, value.inspect
    end
  end

  it "evaluates arbitrary decimal exponents and divisors without VM execution" do # rubocop:disable RSpec/ExampleLength
    bounds = [5e-324, -5e-324, 1e-300, -1e-300, Float::MIN, Float::MAX, 1e300, -1e300,
      2**200 + 1, -(2**200) + 1, 2**4096 + 1, 0, -3]
    values = [0, -0.0, 1, -1, 5e-324, -5e-324, 1e-300, -1e-300, 1e-200, 1e200, -1e200,
      Float::MIN, Float::MAX, -Float::MAX, 2**200, 2**4096, -(2**4096), nil, "text"]
    schemas = bounds.flat_map do |bound|
      %w[minimum maximum exclusiveMinimum exclusiveMaximum multipleOf].map { |keyword| {keyword => bound} }
    end
    schemas.concat([5e-324, 1e-300, 1e300, 2**200 + 1].flat_map do |divisor|
      bounds.map do |bound|
        {"minimum" => bound, "maximum" => bound, "exclusiveMinimum" => bound,
         "exclusiveMaximum" => bound, "multipleOf" => divisor}
      end
    end)
    schemas = schemas.flat_map { |schema| [schema, schema.merge("type" => "integer"), {"items" => schema}] }
    expect_native_policy_results(schemas, values + [values])
  end

  it "enforces native budgets while collecting arbitrary decimal failures" do
    schema = {"items" => {"minimum" => 1e-200, "multipleOf" => 1e-300}}
    values = [1e-300, -1e300, 1e300]
    expected = Schemurai.compile(schema, backend: :vm).validate(values).errors
    native = Schemurai.compile(schema, backend: :native)
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    expect(native.valid?(values, timeout: 10)).to be(false)
    expect(native.validate(values, timeout: 10, max_errors: expected.length).errors).to eq(expected)
    expect { native.validate(values, max_errors: 1) }.to raise_error(Schemurai::LimitExceeded)
    expect(native.validate([1e300], max_errors: 0).valid?).to be(true)
  end

  it "preserves VM behavior beyond bounded numeric operands and for non-finite instances" do # rubocop:disable RSpec/ExampleLength
    schemas = [{"minimum" => 2**200}, {"maximum" => -(2**200)}, {"multipleOf" => 1e-100}, {"multipleOf" => 0.1}, {"minimum" => 0.3}, {"exclusiveMaximum" => 0.3}]
    values = [2**200, -(2**200), 1e-100, 1e200, Float::INFINITY, Float::NAN, 0.3]
    schemas.each do |schema|
      vm = Schemurai.compile(schema, backend: :vm)
      native = Schemurai.compile(schema, backend: :native)
      values.each do |value|
        expected = begin
          vm.valid?(value)
        rescue ArgumentError => error
          error.class
        end
        if expected.is_a?(Class)
          expect { native.valid?(value) }.to raise_error(expected)
        else
          expect(native.valid?(value)).to eq(expected)
        end
      end
    end
  end

  it "raises non-finite decimal errors through libruby without VM execution" do # rubocop:disable RSpec/ExampleLength
    capture = lambda do |validator, method, value, **options|
      result = validator.public_send(method, value, **options)
      [:result, (method == :validate) ? result.errors : result]
    rescue ArgumentError => error
      [:error, error.class, error.message]
    end
    number = {"multipleOf" => 0.1}
    schemas = [number, number.merge("type" => "number"), number.merge("type" => "integer"),
      number.merge("minimum" => 0, "maximum" => 0), {"items" => number}, {"contains" => number},
      {"properties" => {"n" => number}}, {"allOf" => [false, number]}, {"anyOf" => [true, number]},
      {"not" => number}, {"if" => number, "then" => false, "else" => true},
      {"maximum" => 0.0}, {"type" => "integer", "minimum" => 0.0},
      {"$schema" => "https://json-schema.org/draft/2020-12/schema", "items" => number, "unevaluatedItems" => false}]
    values = [Float::NAN, Float::INFINITY, -Float::INFINITY].flat_map { |value| [value, [1, value], {"n" => value}] }
    cases = schemas.map do |schema|
      vm = Schemurai.compile(schema, backend: :vm)
      [Schemurai.compile(schema, backend: :native), values.map do |value|
        [:valid?, :validate].map { |method| capture.call(vm, method, value) }
      end, schema]
    end
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    cases.each do |native, expected, schema|
      values.zip(expected).each do |value, results|
        [:valid?, :validate].zip(results).each do |method, result|
          expect(capture.call(native, method, value)).to eq(result), [schema, method, value].inspect
          expect(capture.call(native, method, value, timeout: 10)).to eq(result), [schema, method, value].inspect
        end
      end
    end
  end

  it "retains earlier type failures and error limits before non-finite conversion" do
    native = Schemurai.compile({"type" => "integer", "multipleOf" => 1e-300}, backend: :native)
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    expect(native.valid?(Float::NAN, max_errors: 0)).to be(false)
    expect { native.validate(Float::NAN, max_errors: 0) }.to raise_error(Schemurai::LimitExceeded)
    expect { native.validate(Float::NAN, max_errors: 1) }.to raise_error(ArgumentError, 'invalid value for convert(): "NaN"')
    expect(native.validate(1, max_errors: 0).valid?).to be(true)
  end

  it "keeps invalid nil numeric operands lazy like the VM" do # rubocop:disable RSpec/ExampleLength
    %w[minimum maximum exclusiveMinimum exclusiveMaximum multipleOf].each do |keyword|
      vm = Schemurai.compile({keyword => nil}, backend: :vm)
      native = Schemurai.compile({keyword => nil}, backend: :native)
      expect(native.valid?("text")).to eq(vm.valid?("text"))
      expected = begin
        vm.valid?(4)
      rescue => error
        error.class
      end
      expect { native.valid?(4) }.to raise_error(expected)
    end
  end

  it "executes local and external static references without VM evaluation" do # rubocop:disable RSpec/ExampleLength
    schema = {"type" => "array", "items" => {"$ref" => "urn:integer"}}
    validator = Schemurai.compile(schema, schemas: {"urn:integer" => {"$ref" => "#/$defs/value", "$defs" => {"value" => {"type" => "integer", "minimum" => 1}}}}, backend: :native)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    expect(validator.valid?([1, 2])).to be(true)
    expect(validator.valid?([1, 0])).to be(false)
    expect(validator.valid?(["bad"])).to be(false)
  end

  it "terminates reference cycles with the VM's source-instance guard" do # rubocop:disable RSpec/ExampleLength
    schema = {"$ref" => "#/$defs/cycle", "$defs" => {"cycle" => {"$ref" => "#/$defs/cycle"}}}
    validator = Schemurai.compile(schema, backend: :native)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    expect(validator.valid?({"value" => 1})).to be(true)
    recursive = Schemurai.compile({"type" => "object", "properties" => {"next" => {"$ref" => "#"}, "value" => {"type" => "integer"}}}, backend: :native)
    expect(recursive.valid?({"next" => {"value" => 1}})).to be(true)
    expect(recursive.valid?({"next" => {"value" => "bad"}})).to be(false)
  end

  it "compares nested JSON objects and mixed numeric values in Rust" do # rubocop:disable RSpec/ExampleLength
    validator = Schemurai.compile({"const" => {"a" => [1, 2.0], "b" => {"value" => "yes"}}}, backend: :native)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    expect(validator.valid?({"b" => {"value" => "yes"}, "a" => [1.0, 2]})).to be(true)
    expect(validator.valid?({"a" => [1, 3], "b" => {"value" => "yes"}})).to be(false)
    precision = Schemurai.compile({"const" => 9_007_199_254_740_993}, backend: :native)
    expect(precision.valid?(9_007_199_254_740_992.0)).to be(false)
  end

  it "scans record arrays with shared schema selection while preserving resource scopes" do # rubocop:disable RSpec/ExampleLength
    record = {"properties" => {"id" => {"type" => "integer", "minimum" => 1}, "name" => {"type" => "string", "minLength" => 1}},
              "required" => %w[id name], "additionalProperties" => false}
    dynamic = {"$schema" => "https://json-schema.org/draft/2020-12/schema", "$id" => "urn:record-scan",
               "$defs" => {"value" => {"$dynamicAnchor" => "value", "const" => 3}}, "items" => {
                 "$id" => "urn:record-item", "type" => "object", "required" => ["id"], "additionalProperties" => false,
                 "properties" => {"id" => {"$dynamicRef" => "#value"}},
                 "$defs" => {"value" => {"$dynamicAnchor" => "value", "type" => "integer", "minimum" => 5}}
               }}
    schemas = [{"items" => record}, {"items" => record.merge("type" => "object")},
      {"$schema" => "https://json-schema.org/draft/2020-12/schema", "prefixItems" => [true], "items" => record}, dynamic]
    values = [[], [{"id" => 1, "name" => "entry"}], [{"id" => 1, "name" => "entry"}, nil, 1, "entry"],
      [true], [false], [1.5], [2**200], [[]], [9.times.to_h { |i| ["p#{i}", i] }],
      [{"id" => 0, "name" => ""}], [{"name" => "entry"}], [{"id" => 1, "name" => "entry", "extra" => true}],
      [nil, {"id" => 1, "name" => "entry"}], [{"id" => 3}], [{"id" => 6}],
      [nil, {"id" => 0, "name" => ""}, {"name" => "entry"}]]
    cases = schemas.map do |schema|
      vm = Schemurai.compile(schema, backend: :vm)
      [Schemurai.compile(schema, backend: :native), values.map { |value| [vm.valid?(value), vm.validate(value).errors] }]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |native, expected|
      values.zip(expected).each do |value, (valid, errors)|
        expect(native.valid?(value)).to eq(valid), value.inspect
        expect(native.validate(value).errors).to eq(errors), value.inspect
      end
    end
  end

  it "scans changing record layouts with frozen keys and complete diagnostics" do # rubocop:disable RSpec/ExampleLength
    fields = 8.times.to_h { |index| ["p#{index}", {"type" => "integer", "minimum" => 0}] }
    full = fields.keys.to_h { |key| [+key, 1] }
    reversed = full.to_a.reverse.to_h
    rotated = full.to_a.rotate(3).to_h
    sparse = full.slice("p7", "p0", "p3")
    binary = full.transform_keys { |key| key.dup.force_encoding(Encoding::ASCII_8BIT) }
    frozen = full.transform_keys { |key| String.new(key).freeze }
    mixed = full.to_a.each_with_index.to_h { |(key, value), index| [(index.even? ? String.new(key).freeze : key), value] }
    values = [[full, reversed, rotated, binary, sparse, full], [full, sparse.except("p3")],
      [full, reversed.merge("p7" => -1)], [full, full.merge("extra" => 1), rotated],
      [full, nil, true, 1, [], rotated], [sparse, full, sparse],
      [frozen, frozen.transform_keys { |key| String.new(key).freeze }, reversed, binary, sparse],
      [frozen, rotated.merge("p7" => -1)], [frozen, sparse.except("p0")],
      [frozen, reversed.merge("p7" => -1), sparse.except("p0"), full],
      [mixed, mixed.to_a.reverse.to_h, full, frozen], [mixed, mixed.merge("p7" => -1)]]
    cases = [false, true].flat_map do |additional|
      items = {"properties" => fields, "required" => %w[p7 p0 p7 p3], "additionalProperties" => additional}
      [items, items.merge("type" => "object")].map do |rule|
        schema = {"type" => "array", "items" => rule}
        vm = Schemurai.compile(schema, backend: :vm)
        native = Schemurai.compile(schema, backend: :native)
        program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
        expect(program.valid?([full, {Object.new => 1}])).to be_nil
        expect(program.valid?([full, full.dup.compare_by_identity])).to be_nil
        [native, values.map { |value| [value, vm.valid?(value), vm.validate(value).errors] }]
      end
    end
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |native, expected|
      expected.each do |value, valid, errors|
        expect(native.valid?(value)).to eq(valid)
        expect(native.validate(value).errors).to eq(errors)
      end
    end
    native = cases.first.first
    changing = [full.dup, reversed.dup]
    expect(native.valid?(changing)).to be(true)
    changing.last.delete("p3")
    expect(native.valid?(changing)).to be(false)
    changing.last["p3"] = 2
    expect(native.valid?(changing)).to be(true)
    changing.last["p7"] = -1
    expect(native.valid?(changing)).to be(false)
  end

  it "classifies scalar and overflowing items in record arrays without reading unwritten handles" do # rubocop:disable RSpec/ExampleLength
    properties = {"id" => {"type" => "integer"}}
    items = {"properties" => properties, "required" => ["id"]}
    scalars = [nil, true, false, 1, 1 << 150, 1.5, 2.0, Float::INFINITY, "id", []]
    overflow = {"id" => 1}.merge((0...8).to_h { |i| ["extra#{i}", i] })
    instances = scalars.map { |value| [{"id" => 1}, value, {"id" => 2}] }
    instances.concat([[overflow], [overflow.merge("id" => "wrong")], [{}], []])
    cases = [items, items.merge("type" => "object")].map do |rules|
      schema = {"items" => rules}
      vm = Schemurai.compile(schema, backend: :vm)
      [Schemurai.compile(schema, backend: :native), instances.map { |value| [vm.valid?(value), vm.validate(value).errors] }]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |native, expected|
      instances.zip(expected).each do |value, (valid, errors)|
        expect(native.valid?(value)).to eq(valid)
        expect(native.validate(value).errors).to eq(errors)
      end
    end
  end

  it "delegates unsupported record-array instances after the native Hash guard" do
    schemas = [{"items" => {"properties" => {"id" => true}}}, {"items" => {"type" => "object", "properties" => {"id" => true}}}]
    values = [Class.new(Hash)["id", 1], {Object.new => 1}]
    singleton = {"id" => 1}
    singleton.define_singleton_method(:key?) { |_key| false }
    values << singleton
    schemas.each do |schema|
      native = Schemurai.compile(schema, backend: :native)
      vm = Schemurai.compile(schema, backend: :vm)
      program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
      values.each do |value|
        expect(program.valid?([value])).to be_nil
        expect(program.diagnostics([value])).to be_nil
        expect(native.valid?([value])).to eq(vm.valid?([value]))
        expect(native.validate([value]).errors).to eq(vm.validate([value]).errors)
      end
    end
  end

  it "collects identity Hash diagnostics without the record validity precheck" do
    identity = {"id" => 1}.compare_by_identity
    rules = {"properties" => {"id" => true}}
    cases = [rules, rules.merge("type" => "object")].map do |items|
      schema = {"items" => items}
      vm = Schemurai.compile(schema, backend: :vm)
      [Schemurai.compile(schema, backend: :native), vm.validate([identity]).errors]
    end
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |native, errors|
      expect(native.validate([identity]).errors).to eq(errors)
    end
  end

  it "combines native string guards and character lengths in arrays and record fields" do # rubocop:disable RSpec/ExampleLength
    rules = {"minLength" => 2, "maxLength" => 2}
    values = ["", "a", "ab", "abc", "é日", "é日本", "é日".encode(Encoding::UTF_16LE), "ab".b, nil, false, 1, {}]
    schemas = [{"items" => rules}, {"items" => rules.merge("type" => "string")},
      {"items" => {"properties" => {"name" => rules.merge("type" => "string")}, "required" => ["name"]}}]
    cases = schemas.map do |schema|
      instances = schema.fetch("items").key?("properties") ? values.map { |value| [{"name" => value}] } : values.map { |value| [value] }
      vm = Schemurai.compile(schema, backend: :vm)
      [Schemurai.compile(schema, backend: :native), instances, instances.map { |instance| [vm.valid?(instance), vm.validate(instance).errors] }]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |native, instances, expected|
      instances.zip(expected).each do |instance, (valid, errors)|
        expect(native.valid?(instance)).to eq(valid), instance.inspect
        expect(native.validate(instance).errors).to eq(errors), instance.inspect
      end
    end
  end

  it "tracks character lengths after in-place byte and encoding changes" do # rubocop:disable RSpec/ExampleLength
    operations = [->(value) { value.replace("ab") }, ->(value) { value.replace("é") },
      ->(value) { value.replace("ab") }, ->(value) { value.force_encoding(Encoding::UTF_16LE) },
      ->(value) { value.force_encoding(Encoding::ASCII_8BIT) }, ->(value) { value.replace("\xff\xfe".b) },
      ->(value) { value.replace("é日".encode(Encoding::UTF_32BE)) }]
    rule = {"type" => "string", "minLength" => 2, "maxLength" => 2}
    shapes = [[rule, ->(value) { value }], [{"items" => rule}, ->(value) { [value] }],
      [{"properties" => {"name" => rule}}, ->(value) { {"name" => value} }]]
    cases = shapes.map do |schema, shape|
      vm = Schemurai.compile(schema, backend: :vm)
      value = +""
      expected = operations.map do |operation|
        operation.call(value)
        instance = shape.call(value)
        [vm.valid?(instance), vm.validate(instance).errors]
      end
      [Schemurai.compile(schema, backend: :native), shape, expected]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |native, shape, expected|
      value = +""
      operations.zip(expected).each do |operation, (valid, errors)|
        operation.call(value)
        instance = shape.call(value)
        expect(native.valid?(instance)).to eq(valid)
        expect(native.validate(instance).errors).to eq(errors)
      end
    end
  end

  it "checks uniqueItems directly for small arrays and indexed structural values" do # rubocop:disable RSpec/ExampleLength
    validator = Schemurai.compile({"uniqueItems" => true}, backend: :native)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    values = Array.new(40) { |i| {"id" => i, "nested" => [i, "entry"]} }
    expect(validator.valid?(values)).to be(true)
    expect(validator.valid?(values + [{"nested" => [39.0, "entry"], "id" => 39.0}])).to be(false)
    expect(validator.valid?([1, 1.0])).to be(false)
    expect(validator.valid?([0.0, -0.0])).to be(false)
    expect(validator.valid?([9_007_199_254_740_993, 9_007_199_254_740_992.0])).to be(true)
  end

  it "rechecks borrowed uniqueness views after nested string and array mutations" do # rubocop:disable RSpec/ExampleLength
    schema = {"uniqueItems" => true}
    values = Array.new(40) { |i| {"id" => i, "nested" => [i, +"entry"]} }
    duplicate = {"nested" => [39.0, +"different"], "id" => 39.0}
    values << duplicate
    native = Schemurai.compile(schema, backend: :native)
    vm = Schemurai.compile(schema, backend: :vm)
    expected = [vm.valid?(values), vm.validate(values).errors]
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    expect(native.valid?(values)).to eq(expected.first)
    expect(native.validate(values).errors).to eq(expected.last)
    duplicate.fetch("nested").last.replace("entry")
    expect(native.valid?(values)).to be(false)
    expect(native.validate(values).valid?).to be(false)
    duplicate.fetch("nested") << []
    expect(native.valid?(values)).to be(true)
    expect(native.validate(values).valid?).to be(true)
    duplicate.fetch("nested").pop
    expect(native.valid?(values)).to be(false)
  end

  it "borrows empty, Unicode, binary and heap-backed keys for indexed uniqueness" do # rubocop:disable RSpec/ExampleLength
    keys = ["", "日", "\xff".b, "key" * 100]
    values = Array.new(40) { |i| keys.to_h { |key| [key, [i]] } }
    duplicate = keys.reverse.to_h { |key| [key, [39.0]] }
    datasets = [values, values + [duplicate]]
    schema = {"uniqueItems" => true}
    vm = Schemurai.compile(schema, backend: :vm)
    expected = datasets.map { |value| [vm.valid?(value), vm.validate(value).errors] }
    native = Schemurai.compile(schema, backend: :native)
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    datasets.zip(expected).each do |value, (valid, errors)|
      expect(native.valid?(value)).to eq(valid)
      expect(native.validate(value).errors).to eq(errors)
    end
  end

  it "checks every byte of short strings and keys across the word-size boundary" do # rubocop:disable RSpec/ExampleLength
    padding = Array.new(17) { |i| "padding#{i}" }
    datasets = (0..9).flat_map do |length|
      strings = (0...length).flat_map do |position|
        Array.new(4) { |byte| ("x".b * length).tap { |string| string.setbyte(position, byte) } }
      end
      strings = [""] if length.zero?
      objects = strings.map { |key| {key => nil} }
      [[*padding, *strings], [*padding, *strings, strings.first.dup],
        [*padding, *objects], [*padding, *objects, {strings.first.dup => nil}]]
    end
    schema = {"uniqueItems" => true}
    vm = Schemurai.compile(schema, backend: :vm)
    expected = datasets.map { |value| [vm.valid?(value), vm.validate(value).errors] }
    native = Schemurai.compile(schema, backend: :native)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    datasets.zip(expected).each do |value, (valid, errors)|
      expect(native.valid?(value)).to eq(valid)
      expect(native.validate(value).errors).to eq(errors)
    end
  end

  it "uses libruby for indexed uniqueness with non-string hash keys" do
    schema = {"uniqueItems" => true}
    native = Schemurai.compile(schema, backend: :native)
    vm = Schemurai.compile(schema, backend: :vm)
    program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
    [Object.new, :key, Class.new(String).new("key")].each do |key|
      values = Array.new(20) { |i| [i] } + [{"nested" => {key => 1}}, {"nested" => {key => 2}}]
      expect(program.valid?(values)).to eq(vm.valid?(values))
      expect(program.diagnostics(values)).not_to be_nil
      expect(native.valid?(values)).to eq(vm.valid?(values))
      expect(native.validate(values).errors).to eq(vm.validate(values).errors)
    end
  end

  it "resolves references during compilation under GC stress" do
    previous = GC.stress
    GC.stress = true
    validator = Schemurai.compile({"$ref" => "#/$defs/value", "$defs" => {"value" => {"const" => {"id" => 1}}}}, backend: :native)
    expect(validator.valid?({"id" => 1.0})).to be(true)
  ensure
    GC.stress = previous
  end

  it "marks compiler roots while rejecting evaluation during reference callbacks" do # rubocop:disable RSpec/ExampleLength
    Schemurai.compile(true, backend: :native)
    graph = Schemurai.const_get(:Internal)::SchemaGraph.new
    compiler = Schemurai.const_get(:VM)::Compiler.new(graph)
    root = compiler.compile(graph.compile({"$ref" => "#/$defs/value", "$defs" => {"value" => {"const" => {"id" => 1}}}}))
    program = Schemurai.const_get(:Native)::Program.allocate
    allow(compiler).to receive(:resolve).and_wrap_original do |original, *arguments|
      expect(ObjectSpace.memsize_of(program)).to be_positive
      GC.verify_compaction_references(double_heap: true, toward: :empty)
      expect { program.valid?({"id" => 1}) }.to raise_error(RuntimeError, "native program is still compiling")
      expect { program.diagnostics({"id" => 1}) }.to raise_error(RuntimeError, "native program is still compiling")
      original.call(*arguments)
    end
    program.send(:initialize, root, compiler, false, false)
    expect(compiler).to have_received(:resolve)
    expect(program.valid?({"id" => 1.0})).to be(true)
    expect(program.diagnostics({"id" => 1})).to eq([])
    expect(program.valid?({"id" => 2})).to be(false)
  end

  it "releases roots after compilation exceptions and allows initialization to retry" do # rubocop:disable RSpec/ExampleLength
    Schemurai.compile(true, backend: :native)
    graph = Schemurai.const_get(:Internal)::SchemaGraph.new
    compiler = Schemurai.const_get(:VM)::Compiler.new(graph)
    root = compiler.compile(graph.compile({"$ref" => "#/$defs/value", "$defs" => {"value" => {"type" => "integer"}}}))
    program = Schemurai.const_get(:Native)::Program.allocate
    allow(compiler).to receive(:resolve).and_raise(RuntimeError, "resolution interrupted")
    expect { program.send(:initialize, root, compiler, false, false) }.to raise_error(RuntimeError, "resolution interrupted")
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    expect(ObjectSpace.memsize_of(program)).to be_positive
    expect { program.valid?(1) }.to raise_error(RuntimeError, "uninitialized native program")
    allow(compiler).to receive(:resolve).and_call_original
    program.send(:initialize, root, compiler, false, false)
    expect(program.valid?(1)).to be(true)
    expect(program.valid?("bad")).to be(false)
  end

  it "reports unresolved reference diagnostics without VM execution" do # rubocop:disable RSpec/ExampleLength
    dialect = {"$schema" => "https://json-schema.org/draft/2020-12/schema"}
    missing = {"$ref" => "urn:missing"}
    schemas = [missing, {"$ref" => "#/$defs/missing"}, {"$ref" => "#unknown"},
      {"allOf" => [false, missing]}, {"anyOf" => [true, missing]},
      {"oneOf" => [true, missing]}, {"not" => missing},
      {"properties" => {"a/b~c" => missing}, "unevaluatedProperties" => false},
      {"items" => missing, "unevaluatedItems" => false},
      {"$dynamicRef" => "urn:missing#n"}].map { |schema| dialect.merge(schema) }
    schemas << {"$schema" => "https://json-schema.org/draft/2019-09/schema", "$recursiveRef" => "urn:missing"}
    expect_native_policy_results(schemas, [nil, 1, "bad", [], [1, 2], {}, {"a/b~c" => 1}])
  end

  it "enforces limits on unresolved reference diagnostics without VM execution" do
    validator = Schemurai.compile({"$ref" => "urn:missing"}, backend: :native)
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    expect(validator.valid?(nil, timeout: 10)).to be(false)
    expect(validator.validate(nil, timeout: 10, max_errors: 1).errors.first.keyword).to eq("$ref")
    expect { validator.validate(nil, max_errors: 0) }.to raise_error(Schemurai::LimitExceeded)
  end

  it "preserves late reference resolution in a mutable registry without VM execution" do # rubocop:disable RSpec/ExampleLength
    registry = Schemurai::SchemaRegistry.new(backend: :native)
    validator = registry.compile({"$ref" => "urn:late"})
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    expect(validator.valid?(1)).to be(false)
    expect(validator.validate(1).errors.first.keyword).to eq("$ref")
    registry.compile({"$id" => "urn:late", "type" => "integer"})
    compiler = validator.instance_variable_get(:@evaluator).instance_variable_get(:@compiler)
    allow(compiler).to receive(:resolve).and_raise(RuntimeError, "resolution interrupted")
    expect { validator.valid?(1) }.to raise_error(RuntimeError, "resolution interrupted")
    allow(compiler).to receive(:resolve).and_call_original
    expect(validator.valid?(1)).to be(true)
    expect(validator.validate(1).errors).to be_empty
    expect(validator.valid?("bad")).to be(false)
    expect(validator.validate("bad").errors.first.keyword).to eq("type")
  end

  it "unions successful anyOf array annotations and discards failed branches" do # rubocop:disable RSpec/ExampleLength
    dialect = {"$schema" => "https://json-schema.org/draft/2020-12/schema"}
    union = Schemurai.compile(dialect.merge("anyOf" => [{"prefixItems" => [true]}, {"contains" => {"const" => 2}}], "unevaluatedItems" => false), backend: :native)
    discarded = Schemurai.compile(dialect.merge("anyOf" => [{"prefixItems" => [true, true], "contains" => false}, {"prefixItems" => [true]}], "unevaluatedItems" => false), backend: :native)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    expect(union.valid?([1, 2])).to be(true)
    expect(union.valid?([1, 2, 3])).to be(false)
    expect(discarded.valid?([1, 2])).to be(false)
    expect(discarded.valid?([1])).to be(true)
  end

  it "tracks referenced and dependent object properties by JSON key equality" do # rubocop:disable RSpec/ExampleLength
    schema = {"$schema" => "https://json-schema.org/draft/2020-12/schema", "$ref" => "#/$defs/base",
              "$defs" => {"base" => {"properties" => {"mode" => true}}},
              "dependentSchemas" => {"mode" => {"properties" => {"value" => {"type" => "integer"}}}},
              "unevaluatedProperties" => false}
    validator = Schemurai.compile(schema, backend: :native)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    expect(validator.valid?({+"mode" => true, +"value" => 1})).to be(true)
    expect(validator.valid?({"mode" => true, "value" => "bad"})).to be(false)
    expect(validator.valid?({"mode" => true, "value" => 1, "extra" => nil})).to be(false)
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    expect(validator.valid?({"mode" => true, "value" => 2})).to be(true)
  end

  it "unions overlapping object annotations without leaking failed branches" do # rubocop:disable RSpec/ExampleLength
    dialect = {"$schema" => "https://json-schema.org/draft/2020-12/schema"}
    union = Schemurai.compile(dialect.merge("anyOf" => [{"properties" => {"a" => true}}, {"properties" => {"b" => true}}], "unevaluatedProperties" => false), backend: :native)
    discarded = Schemurai.compile(dialect.merge("anyOf" => [{"allOf" => [{"properties" => {"extra" => true}}, false]}, {"properties" => {"a" => true}}], "unevaluatedProperties" => false), backend: :native)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    expect(union.valid?({"a" => 1, "b" => 2})).to be(true)
    expect(union.valid?({"a" => 1, "b" => 2, "extra" => nil})).to be(false)
    expect(discarded.valid?({"a" => 1, "extra" => nil})).to be(false)
    expect(discarded.valid?({"a" => 1})).to be(true)
  end

  it "preserves applicator multiplicity and coverage when simple object branches repeat" do # rubocop:disable RSpec/ExampleLength
    dialect = {"$schema" => "https://json-schema.org/draft/2020-12/schema"}
    integer = {"properties" => {"id" => {"type" => "integer"}}}
    string = {"properties" => {"id" => {"type" => "string"}}}
    extra = {"properties" => {"extra" => true}}
    branches = [[integer, integer], [integer, string, integer], [integer, extra, integer],
      [integer, integer.merge("required" => ["id"])],
      [integer, integer.merge("minProperties" => 2)],
      [integer, integer.merge("maxProperties" => 1)],
      [integer, integer.merge("type" => "object")],
      Array.new(20, integer)]
    values = [{}, {"id" => 1}, {"id" => "text"}, {"id" => 1, "extra" => nil},
      {"id" => 1, "unknown" => nil}, {"id" => []}, nil, 1, "text"]
    cases = branches.flat_map do |children|
      %w[anyOf oneOf].map do |keyword|
        schema = dialect.merge(keyword => children, "unevaluatedProperties" => false)
        vm = Schemurai.compile(schema, backend: :vm)
        [Schemurai.compile(schema, backend: :native), values.map { |value| [vm.valid?(value), vm.validate(value).errors] }]
      end
    end
    # Keep an unsupported middle branch in order: oneOf must not stop early
    # by counting a later duplicate before that branch is visited.
    passthrough = {"properties" => {"id" => true}}
    ordered = Schemurai.compile(dialect.merge("oneOf" => [passthrough,
      {"properties" => {"id" => {"pattern" => "(?=x)"}}}, passthrough]), backend: :native)
    program = ordered.instance_variable_get(:@evaluator).instance_variable_get(:@program)
    expect(program.valid?({"id" => "x"})).to be(false)
    expect(program.diagnostics({"id" => "x"})).not_to be_nil
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |native, expected|
      values.zip(expected).each do |value, (valid, errors)|
        expect(native.valid?(value)).to eq(valid), value.inspect
        expect(native.validate(value).errors).to eq(errors), value.inspect
      end
    end
  end

  it "merges native annotation buffers across bit boundaries and discards failed branches" do # rubocop:disable RSpec/ExampleLength
    dialect = {"$schema" => "https://json-schema.org/draft/2020-12/schema"}
    cases = [0, 1, 63, 64, 65, 129].flat_map do |count|
      properties = count.times.to_h { |index| ["p#{index}", {"type" => "integer"}] }
      object = properties.keys.to_h { |key| [key, 1] }
      object_schema = dialect.merge("anyOf" => [
        {"properties" => properties},
        {"patternProperties" => {"^dynamic" => true}},
        {"allOf" => [{"properties" => {"extra" => true}}, false]}
      ], "unevaluatedProperties" => false)
      array_schema = dialect.merge("anyOf" => [
        {"prefixItems" => Array.new(count, true)},
        {"contains" => {"const" => "covered"}},
        {"allOf" => [{"items" => true}, false]}
      ], "unevaluatedItems" => false)
      [[object_schema, object], [object_schema, object.merge("dynamic/key" => nil)],
        [object_schema, object.merge("extra" => nil)],
        [array_schema, Array.new(count, 1)], [array_schema, [*Array.new(count, 1), "covered"]],
        [array_schema, [*Array.new(count, 1), "extra"]]]
    end
    expected = cases.map do |schema, value|
      vm = Schemurai.compile(schema, backend: :vm)
      [Schemurai.compile(schema, backend: :native), value, vm.valid?(value), vm.validate(value).errors]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    expected.each do |native, value, valid, errors|
      expect(native.valid?(value)).to eq(valid)
      expect(native.validate(value).errors).to eq(errors)
    end
  end

  it "propagates conditional annotations and excludes not and failed oneOf branches" do # rubocop:disable RSpec/ExampleLength
    dialect = {"$schema" => "https://json-schema.org/draft/2020-12/schema"}
    conditional = Schemurai.compile(dialect.merge("if" => {"prefixItems" => [{"const" => 1}]}, "then" => {"contains" => {"const" => 2}}, "unevaluatedItems" => false), backend: :native)
    negation = Schemurai.compile(dialect.merge("not" => {"prefixItems" => [false, true]}, "unevaluatedItems" => false), backend: :native)
    exclusive = Schemurai.compile(dialect.merge("oneOf" => [{"prefixItems" => [true]}, {"contains" => false, "items" => true}], "unevaluatedItems" => false), backend: :native)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    expect(conditional.valid?([1, 2])).to be(true)
    expect(conditional.valid?([1, 2, 3])).to be(false)
    expect(negation.valid?([1, 2])).to be(false)
    expect(exclusive.valid?([1])).to be(true)
    expect(exclusive.valid?([1, 2])).to be(false)
  end

  it "keeps evaluated properties isolated between instances and Ractors" do # rubocop:disable RSpec/ExampleLength
    schema = {"$schema" => "https://json-schema.org/draft/2020-12/schema", "anyOf" => [
      {"required" => ["a"], "properties" => {"a" => {"type" => "integer"}}},
      {"required" => ["b"], "properties" => {"b" => {"type" => "integer"}}}
    ], "unevaluatedProperties" => false}
    registry = Schemurai::SchemaRegistry.new(schemas: {"urn:tracking" => schema}, backend: :native)
    registry.make_shareable
    workers = Array.new(2) do
      Ractor.new(registry) do |shared|
        validator = shared.validator_for("urn:tracking")
        errors = validator.validate({"a" => "bad", "b" => 2}).errors.map { |e| [e.keyword, e.instance_path, e.schema_path] }
        [validator.valid?({"a" => 1}), validator.valid?({"a" => "bad", "b" => 2}), validator.valid?({"b" => 2}), errors]
      end
    end
    workers.each do |worker|
      result = worker.respond_to?(:value) ? worker.value : worker.take
      expect(result).to eq([true, false, true, [["falseSchema", "/a", "/unevaluatedProperties"]]])
    end
  end

  it "executes Draft 7 schema and property dependencies in Rust" do # rubocop:disable RSpec/ExampleLength
    validator = Schemurai.compile({"dependencies" => {"flag" => ["value"], "value" => {"properties" => {"value" => {"type" => "integer"}}}}}, backend: :native)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    expect(validator.valid?({"flag" => true, "value" => 1})).to be(true)
    expect(validator.valid?({"flag" => true})).to be(false)
    expect(validator.valid?({"value" => "bad"})).to be(false)
  end

  it "executes the official dynamic and recursive reference cases without VM evaluation" do # rubocop:disable RSpec/ExampleLength
    remotes = SchemuraiOracle::CaseCatalog.new.remotes
    paths = ["references/JSON-Schema-Test-Suite/tests/draft2020-12/dynamicRef.json", "references/JSON-Schema-Test-Suite/tests/draft2019-09/recursiveRef.json"]
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    paths.each do |path|
      JSON.parse(File.read(path)).each do |group|
        validator = Schemurai.compile(group.fetch("schema"), schemas: remotes, backend: :native)
        group.fetch("tests").each do |record|
          expect(validator.valid?(record.fetch("data"))).to eq(record.fetch("valid")), "#{group.fetch("description")}: #{record.fetch("description")}"
        end
      end
    end
  end

  it "matches the VM's ASCII pattern subset without VM execution" do # rubocop:disable RSpec/ExampleLength
    patterns = ["", "^", "$", "^$", "record", "record$", "^record[0-9]+$", "^[a-zA-Z0-9_]*$", "^x?$", "\\d+", "\\w+$", "^a\\$$", "[-a]+$", "[a-]", "[0-9]", "^ab", "^ab+$"]
    strings = ["", "record", "record0", "record123", "xrecord12", "record12\n", "ab", "abb", "xx", "x", "a$", "-a", "日本record12", "é", "１２", "\u0000", "abc\n"]
    cases = patterns.map do |pattern|
      schema = {"type" => "string", "pattern" => pattern}
      vm = Schemurai.compile(schema, backend: :vm)
      [pattern, Schemurai.compile(schema, backend: :native), strings.map { |string| vm.valid?(string) }]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |pattern, validator, expected|
      strings.zip(expected).each do |string, result|
        expect(validator.valid?(string)).to eq(result), "#{pattern.inspect} on #{string.inspect}"
      end
      expect(validator.valid?(1)).to be(false)
    end
  end

  it "executes counted ASCII repetitions and their diagnostics without VM evaluation" do # rubocop:disable RSpec/ExampleLength
    patterns = ["^SKU-[A-Z0-9]{8}$", "^ord_[0-9]{6}$", "^a{2}b{3}$", "^a{0}b$", "^a{0}$", "^a{01}$",
      "^a{2,4}$", "a{2,4}", "a{2,4}$", "^a{2,}$", "a{0,2}$", "^a{0,2}$", "a{0,}", "^a{4096}$"]
    strings = ["", "a", "aa", "aaa", "aaaa", "aaaaa", "b", "ab", "aabbb", "aaaabbb", "xaaay", "xaaaaa", "日本aa", "aa\n",
      "SKU-ABC12345", "SKU-ABC1234", "SKU-ABC123456", "ord_123456", "ord_12345", "a" * 4096]
    cases = patterns.map do |pattern|
      schema = {"type" => "string", "pattern" => pattern}
      vm = Schemurai.compile(schema, backend: :vm)
      [pattern, Schemurai.compile(schema, backend: :native), strings.map { |string| [vm.valid?(string), vm.validate(string).errors] }]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |pattern, native, expected|
      strings.zip(expected).each do |string, (valid, errors)|
        expect(native.valid?(string)).to eq(valid), [pattern, string].inspect
        expect(native.validate(string).errors).to eq(errors), [pattern, string].inspect
      end
    end
  end

  it "preserves boolean pattern matches across priority and empty alternatives" do # rubocop:disable RSpec/ExampleLength
    patterns = ["^a|^ab", "^(?:ab|a)$", "^(?:a|ab)$", "^(?:a|)$", "^a*?", "^a*?b$", "^(?:a+|a*b)$",
      "^(?:ab|a)+$", "^(?:a?|ab)*$", "^(?:é|é日)+$", "(?:^a|^ab)$", "^(?:a|ab){0,3}$"]
    strings = ["", "a", "ab", "aa", "aba", "abb", "b", "ba", "abab", "aab", "é", "é日", "éé日", "日é", "a\n", "\na", "a\nb"]
    cases = patterns.flat_map do |pattern|
      [{"type" => "string", "pattern" => pattern}, {"items" => {"type" => "string", "pattern" => pattern}}].map do |schema|
        inputs = schema.key?("items") ? strings.map { |string| [string, string] } : strings
        vm = Schemurai.compile(schema, backend: :vm)
        [Schemurai.compile(schema, backend: :native), inputs.map { |value| [value, vm.valid?(value), vm.validate(value).errors.map(&:to_h)] }]
      end
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |native, inputs|
      inputs.each do |value, valid, errors|
        expect(native.valid?(value)).to eq(valid), value.inspect
        expect(native.validate(value).errors.map(&:to_h)).to eq(errors), value.inspect
      end
    end
  end

  it "uses crate matching for groups, middle repetitions, Unicode literals and VM shorthands" do # rubocop:disable RSpec/ExampleLength
    patterns = ["^(ab|cd)+$", "^(?:ab|cd){1,3}$", "^a+b$", "a{1,2}b", "^a.*b$", "^a.+?b$", "[^a]+", "^é+$",
      "^[é日]+$", "^\\d+$", "^\\D+$", "^\\w+$", "^\\W+$", "^\\s+$", "^\\S+$", "^[a\\D]+$", "^[a\\s]+$"]
    strings = ["", "a", "b", "ab", "aab", "aaab", "abcd", "cdab", "abababcd", "a日本b", "a\nb", "ab\n", "\nab",
      "é", "éé", "日本", "é日", "123", "１２", "a_1", " ", "\t\r\n", "\u00A0", "\uFEFF", "\u0085", "a\u3000"]
    cases = patterns.map do |pattern|
      schema = {"pattern" => pattern}
      vm = Schemurai.compile(schema, backend: :vm)
      [pattern, Schemurai.compile(schema, backend: :native), strings.map { |string| [vm.valid?(string), vm.validate(string).errors] }]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |pattern, native, expected|
      strings.zip(expected).each do |string, (valid, errors)|
        expect(native.valid?(string)).to eq(valid), [pattern, string].inspect
        expect(native.validate(string).errors).to eq(errors), [pattern, string].inspect
      end
    end
  end

  it "uses crate parsing for control escapes and absolute anchors without VM evaluation" do # rubocop:disable RSpec/ExampleLength
    patterns = ['\a', '\f', '\n', '\r', '\t', '\v', '\Aab\z', '\A', '\z',
      '\A[\a\f\n\r\t\v]+\z', '\A[\t-\r]+\z', '\A(?:a\nb|a\tb)\z', '\Aa\\\\n\z']
    strings = ["", "ab", "xab", "ab\n", "\a", "\f", "\n", "\r", "\t", "\v", "\a\f\n\r\t\v",
      "a\nb", "a\tb", 'a\n', "日本\tab", "é\n"]
    cases = patterns.map do |pattern|
      schema = {"pattern" => pattern}
      vm = Schemurai.compile(schema, backend: :vm)
      [pattern, Schemurai.compile(schema, backend: :native), strings.map { |string| [vm.valid?(string), vm.validate(string).errors] }]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |pattern, native, expected|
      strings.zip(expected).each do |string, (valid, errors)|
        expect(native.valid?(string)).to eq(valid), [pattern, string].inspect
        expect(native.validate(string).errors).to eq(errors), [pattern, string].inspect
      end
    end
  end

  it "retains unanchored search and mixed anchor alternatives on long shared prefixes" do # rubocop:disable RSpec/ExampleLength
    patterns = ["record", "record[0-9]+", "(?:record|ord)[0-9]+", "^record|sku", "(?:^a|^b)", "(?:^a)?b"]
    strings = ["r" * 4096, "r" * 4096 + "ecord123", "r" * 4096 + "ecord", "xsku", "xrecord", "a", "b", "xb", "日本record1"]
    cases = patterns.map do |pattern|
      schema = {"pattern" => pattern}
      vm = Schemurai.compile(schema, backend: :vm)
      [Schemurai.compile(schema, backend: :native), strings.map { |string| [vm.valid?(string), vm.validate(string).errors] }]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |native, expected|
      strings.zip(expected).each do |string, (valid, errors)|
        expect(native.valid?(string)).to eq(valid)
        expect(native.validate(string).errors).to eq(errors)
      end
    end
  end

  it "keeps state-heavy patterns native when the eager DFA exceeds its budget" do # rubocop:disable RSpec/ExampleLength
    patterns = ["^(a|b)*a[ab]{20}$", "^a{4096}$"]
    strings = ["", "a" * 21, "b" * 21, "b" * 80 + "a" + "b" * 20, "a" * 4096, "a" * 4095 + "b"]
    cases = patterns.map do |pattern|
      schema = {"pattern" => pattern}
      vm = Schemurai.compile(schema, backend: :vm)
      [Schemurai.compile(schema, backend: :native), strings.map { |string| [vm.valid?(string), vm.validate(string).errors] }]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |native, expected|
      strings.zip(expected).each do |string, (valid, errors)|
        expect(native.valid?(string)).to eq(valid)
        expect(native.validate(string).errors).to eq(errors)
      end
    end
  end

  it "reports heap memory used by string and property-pattern matchers" do
    require "objspace"
    [->(pattern) { {"pattern" => pattern} }, ->(pattern) { {"patternProperties" => {pattern => true}} }].each do |schema|
      sizes = ["^a$", "^a{1024}$"].map do |pattern|
        native = Schemurai.compile(schema.call(pattern), backend: :native)
        program = native.instance_variable_get(:@evaluator).instance_variable_get(:@compiled)
        ObjectSpace.memsize_of(program)
      end
      expect(sizes.last).to be > sizes.first + 4096
    end
  end

  it "rechecks mutable strings after their cached ASCII bytes or encoding change" do # rubocop:disable RSpec/ExampleLength
    [1, 4096].each do |count|
      schema = {"pattern" => "^a{#{count}}$"}
      native = Schemurai.compile(schema, backend: :native)
      vm = Schemurai.compile(schema, backend: :vm)
      value = "a" * count
      expect(value.ascii_only?).to be(true)
      expect(native.valid?(value)).to be(true)
      value.setbyte(0, 255)
      [native, vm].each do |validator|
        expect { validator.valid?(value) }.to raise_error(ArgumentError)
        expect { validator.validate(value) }.to raise_error(ArgumentError)
      end
      value.replace("a" * count)
      expect(native.valid?(value)).to be(true)
      value.concat("é")
      expect(native.valid?(value)).to eq(vm.valid?(value))
      expect(native.validate(value).errors).to eq(vm.validate(value).errors)
      value.replace("a" * count).force_encoding(Encoding::US_ASCII)
      expect(value.ascii_only?).to be(true)
      expect(native.valid?(value)).to be(true)
      value.setbyte(0, 255)
      expect { native.valid?(value) }.to raise_error(ArgumentError)
      value.replace("a".encode(Encoding::UTF_16LE))
      [native, vm].each { |validator| expect { validator.valid?(value) }.to raise_error(Encoding::CompatibilityError) }
    end
  end

  it "retains counted pattern-property annotations and escaped diagnostic paths" do # rubocop:disable RSpec/ExampleLength
    schema = {"$schema" => "https://json-schema.org/draft/2020-12/schema", "patternProperties" => {"^p/[0-9]{2}$" => {"type" => "integer"}},
              "propertyNames" => {"pattern" => "^p/[0-9]{2}$"}, "unevaluatedProperties" => false}
    values = [{"p/01" => 1}, {"p/01" => "bad"}, {"p/1" => 1}, {"p/012" => 1}]
    vm = Schemurai.compile(schema, backend: :vm)
    expected = values.map { |value| [vm.valid?(value), vm.validate(value).errors] }
    native = Schemurai.compile(schema, backend: :native)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    values.zip(expected).each do |value, (valid, errors)|
      expect(native.valid?(value)).to eq(valid)
      expect(native.validate(value).errors).to eq(errors)
    end
  end

  it "validates overlapping patternProperties and records their evaluated locations" do # rubocop:disable RSpec/ExampleLength
    schema = {"$schema" => "https://json-schema.org/draft/2020-12/schema", "properties" => {"fixed" => true},
              "patternProperties" => {"^item[0-9]+$" => {"type" => "integer"}, "[0-9]$" => {"minimum" => 1}}, "unevaluatedProperties" => false}
    tracked = Schemurai.compile(schema, backend: :native)
    additional = Schemurai.compile(schema.except("unevaluatedProperties").merge("additionalProperties" => false), backend: :native)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    [tracked, additional].each do |validator|
      expect(validator.valid?({"fixed" => nil, "item1" => 2, "other2" => 1})).to be(true)
      expect(validator.valid?({"item1" => 0})).to be(false)
      expect(validator.valid?({"item1" => "bad"})).to be(false)
      expect(validator.valid?({"item1" => 2, "extra" => 1})).to be(false)
      expect(validator.valid?({"item1" => 2})).to be(true)
    end
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    expect(tracked.valid?({"item1" => 2})).to be(true)
  end

  it "selects a crate matcher once while preserving mixed array types and prefix diagnostics" do # rubocop:disable RSpec/ExampleLength
    arrays = [[], [nil], [nil, true, 1, 2**4096, [], {}], [nil, "record1", "record2"],
      [nil, "bad", "bad2"], [nil, "日本record1"], [nil, "a" * 21], [nil, "b" * 21]]
    arrays.concat([0, 31, 32, 63].flat_map do |position|
      ["bad", nil, {"key" => 1}].map do |entry|
        value = [nil, *Array.new(65, "record1")]
        value[position + 1] = entry
        value
      end
    end)
    cases = ["^record[0-9]+$", "record[0-9]+", "^(a|b)*a[ab]{20}$"].flat_map do |pattern|
      [true, false].flat_map do |typed|
        items = {"pattern" => pattern}
        items["type"] = "string" if typed
        schema = {"$schema" => "https://json-schema.org/draft/2020-12/schema", "prefixItems" => [true], "items" => items,
                  "contains" => {"type" => "string"}, "minContains" => 0}
        [schema, schema.merge("unevaluatedItems" => false)].map do |candidate|
          vm = Schemurai.compile(candidate, backend: :vm)
          [Schemurai.compile(candidate, backend: :native), arrays.map { |value| [vm.valid?(value), vm.validate(value).errors] }]
        end
      end
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |native, expected|
      arrays.zip(expected).each do |value, (valid, errors)|
        expect(native.valid?(value)).to eq(valid)
        expect(native.validate(value).errors).to eq(errors)
      end
    end
  end

  it "rechecks array pattern bytes after cached ASCII strings are mutated" do
    native = Schemurai.compile({"items" => {"pattern" => "^a+$"}}, backend: :native)
    value = "aa".dup
    expect(value.ascii_only?).to be(true)
    expect(native.valid?([value])).to be(true)
    expect(native.validate([value]).errors).to be_empty
    value.setbyte(0, 255)
    expect { native.valid?([value]) }.to raise_error(ArgumentError)
    expect { native.validate([value]) }.to raise_error(ArgumentError)
    value.replace("aaa")
    expect(native.valid?([value])).to be(true)
    expect(native.validate([value]).errors).to be_empty
  end

  it "preserves types and lengths in the native string array scan" do # rubocop:disable RSpec/ExampleLength
    schema = {"$schema" => "https://json-schema.org/draft/2020-12/schema", "prefixItems" => [true],
              "items" => {"type" => "string", "pattern" => "^record[0-9]+$", "minLength" => 7, "maxLength" => 8}}
    typed = Schemurai.compile(schema, backend: :native)
    untyped = Schemurai.compile({"items" => {"pattern" => "^record[0-9]+$"}}, backend: :native)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    expect(typed.valid?([nil, "record1", "record12"])).to be(true)
    expect(typed.valid?([nil, "record123"])).to be(false)
    expect(typed.valid?([nil, "record1", 2])).to be(false)
    expect(typed.valid?([nil, "record"])).to be(false)
    expect(typed.valid?([nil, "invalid1"])).to be(false)
    expect(untyped.valid?([3, "record1"])).to be(true)
    expect(untyped.valid?([3, "bad"])).to be(false)
  end

  it "keeps mixed string-array types and Unicode lengths native" do # rubocop:disable RSpec/ExampleLength
    arrays = [[], [nil, true, false, 1, 2**4096, 0.5, [], {"key" => 1}], ["é"], ["日本"], ["é日"], ["a"], ["aab"], ["é".encode(Encoding::US_ASCII, undef: :replace, replace: "a")]]
    cases = [true, false].map do |typed|
      items = {"pattern" => "^[é日a]+$", "minLength" => 1, "maxLength" => 2}
      items["type"] = "string" if typed
      schema = {"items" => items}
      vm = Schemurai.compile(schema, backend: :vm)
      [Schemurai.compile(schema, backend: :native), arrays.map { |value| [vm.valid?(value), vm.validate(value).errors] }]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |native, expected|
      arrays.zip(expected).each do |value, (valid, errors)|
        expect(native.valid?(value)).to eq(valid)
        expect(native.validate(value).errors).to eq(errors)
      end
    end
  end

  it "borrows pattern bytes in small-record fields while preserving full diagnostics" do # rubocop:disable RSpec/ExampleLength
    schema = {"type" => "object", "properties" => {"name" => {"type" => "string", "pattern" => "^[é日a]+$", "minLength" => 1, "maxLength" => 2}},
              "required" => ["name"], "additionalProperties" => false}
    values = [{"name" => "é"}, {"name" => "日本"}, {"name" => "aa"}, {"name" => "aab"}, {"name" => 1}, {}, {"name" => "b"}, {"name" => "a", "extra" => 1},
      {"name" => true}, {"name" => nil}, {"name" => []}, {"name" => {"a" => 1}}, {"name" => "aa".encode(Encoding::US_ASCII)}]
    field = schema.fetch("properties").fetch("name")
    cases = [field, field.except("minLength", "maxLength"), field.except("type", "minLength", "maxLength")].map do |rules|
      variant = schema.merge("properties" => {"name" => rules})
      vm = Schemurai.compile(variant, backend: :vm)
      [Schemurai.compile(variant, backend: :native), values.map { |value| [vm.valid?(value), vm.validate(value).errors] }]
    end
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    cases.each do |native, expected|
      values.zip(expected).each do |value, (valid, errors)|
        expect(native.valid?(value)).to eq(valid)
        expect(native.validate(value).errors).to eq(errors)
      end
    end
  end

  it "checks array string lengths before unsupported patterns or input encodings" do # rubocop:disable RSpec/ExampleLength
    invalid = "\xFF".dup.force_encoding(Encoding::UTF_8)
    incompatible = "a".encode(Encoding::UTF_16LE)
    schema = {"items" => {"pattern" => "^a+$", "minLength" => 2}}
    native = Schemurai.compile(schema, backend: :native)
    vm = Schemurai.compile(schema, backend: :vm)
    program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
    [[invalid, ArgumentError], [incompatible, Encoding::CompatibilityError]].each do |value, exception|
      expect(program.valid?([value])).to be(false)
      expect(native.valid?([value])).to eq(vm.valid?([value]))
      [native, vm].each { |validator| expect { validator.validate([value]) }.to raise_error(exception) }
    end
    malformed = Schemurai.compile({"items" => {"pattern" => "[", "minLength" => 2}}, backend: :native)
    raw = malformed.instance_variable_get(:@evaluator).instance_variable_get(:@program)
    expect(raw.valid?(["a"])).to be(false)
    expect(raw.valid?(["aa"])).to be(false)
  end

  it "uses libruby for complex patterns and invalid syntax without VM execution" do
    patterns = ["a++a", "a**", "(?=ab)ab", "(?<=a)b", "(a)\\1", "(?i:a)", "\\b日\\b", "[a-z&&[^b]]",
      "[a--b]", "[a~~b]", "[", "a{2,1}", "a{4097}", "a{100001}"]
    schemas = patterns.flat_map { |pattern| [{"pattern" => pattern}, {"items" => {"pattern" => pattern}}] }
    expect_native_policy_results(schemas, ["abcd", "aa", "b", "é", "日", "", 1, ["ab", "b", 1]])
  end

  it "preserves Ruby regexp encoding errors without VM execution" do # rubocop:disable RSpec/ExampleLength
    capture = method(:capture_validation)
    values = ["aa".b, "a".encode(Encoding::UTF_16LE), "\xFF".dup.force_encoding(Encoding::UTF_8),
      "\xFF".dup.force_encoding(Encoding::US_ASCII), "é".encode(Encoding::ISO_8859_1)]
    schemas = ["^a+$", "(?=a)a", "(?=é)é"].flat_map { |pattern| [{"pattern" => pattern}, {"items" => {"pattern" => pattern}}] }
    values += values.map { |value| [value] }
    cases = schemas.map do |schema|
      vm = Schemurai.compile(schema, backend: :vm)
      [Schemurai.compile(schema, backend: :native), values.map do |value|
        [:valid?, :validate].map { |method| capture.call(vm, method, value) }
      end]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    cases.each do |native, expected|
      values.zip(expected).each do |value, results|
        [:valid?, :validate].zip(results).each do |method, result|
          expect(capture.call(native, method, value)).to eq(result)
          expect(capture.call(native, method, value, timeout: 10)).to eq(result)
        end
      end
    end
  end

  it "replays runtime matches in input order before exposing regexp exceptions" do # rubocop:disable RSpec/ExampleLength
    capture = method(:capture_validation)
    dialect = {"$schema" => "https://json-schema.org/draft/2020-12/schema"}
    properties = {"p1" => {"pattern" => "(?=x)"}, "p2" => {"type" => "integer"}}
    rules = [{"properties" => properties},
      {"properties" => properties, "patternProperties" => {"[" => true}},
      {"properties" => properties, "propertyNames" => {"pattern" => "["}}]
    schemas = rules.flat_map { |rule| [rule, dialect.merge(rule, "unevaluatedProperties" => false)] }
    incompatible = "x".encode(Encoding::UTF_16LE)
    values = [{"p2" => "bad", "p1" => incompatible}, {"p1" => incompatible, "p2" => "bad"},
      {"p2" => "bad", "p1" => "x"}, {"p1" => "x", "p2" => 1}]
    options = [{}, {timeout: 10}, {max_errors: 0}, {max_errors: 1}]
    cases = schemas.map do |schema|
      vm = Schemurai.compile(schema, backend: :vm)
      expected = values.product([:valid?, :validate], options).map do |value, method, limits|
        capture.call(vm, method, value, **limits)
      end
      [Schemurai.compile(schema, backend: :native), expected]
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    cases.each do |native, expected|
      values.product([:valid?, :validate], options).zip(expected).each do |(value, method, limits), result|
        expect(capture.call(native, method, value, **limits)).to eq(result)
      end
    end
  end

  it "preserves pattern error scopes and skips later string assertions after invalid syntax" do
    schema = {"pattern" => "[", "format" => "date", "contentMediaType" => "application/json", "minLength" => 4, "maxLength" => 1}
    value = "bad"
    expected = Schemurai.compile(schema, backend: :vm, format: true, content: true).validate(value).errors
    native = Schemurai.compile(schema, backend: :native, format: true, content: true)
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    expect(native.validate(value).errors).to eq(expected)
    key = "x"
    scoped = Schemurai.compile({"properties" => {key => {"pattern" => "["}}, "patternProperties" => {"[" => true}}, backend: :native)
    expect(scoped.valid?({key => key})).to be(false)
    expect { scoped.validate({key => key}) }.to raise_error(RegexpError)
  end

  it "matches Ruby pattern-property routing and annotation scopes without VM execution" do
    dialect = {"$schema" => "https://json-schema.org/draft/2020-12/schema"}
    rule = {"patternProperties" => {"(?=a)a" => {"minimum" => 1}, "(a)\\1" => {"type" => "integer"}}, "additionalProperties" => false}
    schemas = [rule, dialect.merge(rule, "unevaluatedProperties" => false), {"propertyNames" => {"pattern" => "(?=a)a"}}]
    expect_native_policy_results(schemas, [{}, {"aa" => 1}, {"aa" => 0}, {"ab" => 2}, {"b" => 1}, {"aa" => "bad"}])
  end

  it "roots runtime regexp observations through GC and clears results between calls" do # rubocop:disable RSpec/ExampleLength
    schema = {"items" => {"properties" => {"value" => {"pattern" => "(?=a)a"}, "extra" => {"pattern" => "(b)\\1"}}}}
    values = Array.new(8) { |i| {"value" => "a#{i}", "extra" => (i == 0) ? +"b" : +"bb"} }
    expected = Schemurai.compile(schema, backend: :vm).validate(values).errors
    native = Schemurai.compile(schema, backend: :native)
    compiler = Schemurai.const_get(:Internal)::EcmaRegexp
    compiles = 0
    matches = 0
    allow(compiler).to receive(:compile).and_wrap_original do |original, source, budget|
      compiles += 1
      GC.verify_compaction_references(double_heap: true, toward: :empty)
      regexp = original.call(source, budget)
      match = regexp.method(:match?)
      regexp.define_singleton_method(:match?) do |value|
        matches += 1
        GC.verify_compaction_references(double_heap: true, toward: :empty) if matches <= 6
        match.call(value)
      end
      regexp
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    expect(native.valid?(values)).to be(false)
    expect(native.validate(values).errors).to eq(expected)
    expect(native.validate(values, timeout: 10).errors).to eq(expected)
    values.first["extra"].replace("bb")
    expect(native.valid?(values)).to be(true)
    # The bounded call has an invocation-local regexp cache, as in the VM.
    expect(compiles).to eq(4)
  end

  it "retains the native duration deadline across Ruby assertion retries" do
    cases = [[{"pattern" => "(?=a)a"}, Array.new(20_000) { |i| "a#{i}" }, "a", [:valid?, :validate]],
      [{"contentMediaType" => "application/json"}, Array.new(20_000) { |i| "[#{i}]".encode(Encoding::UTF_16LE) }, "[]".encode(Encoding::UTF_16LE), [:valid?, :validate]],
      [{"additionalProperties" => false}, Array.new(20_000) { {"é".encode(Encoding::ISO_8859_1) => 1} }, {}, [:validate]]]
    cases.map! { |rule, values, valid, methods| [Schemurai.compile({"items" => rule}, content: true, backend: :native), values, valid, methods] }
    allow(Process).to receive(:clock_gettime).and_call_original
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(0.0)
    allow(Schemurai.const_get(:VM)::LimitedEvaluator).to receive(:new).and_raise("VM execution")
    cases.each do |native, values, valid, methods|
      methods.each do |method|
        expect { native.public_send(method, values, timeout: 0.005) }.to raise_error(Schemurai::LimitExceeded) { |error| expect(error.limit).to eq(:timeout) }
      end
      expect(native.valid?([valid], timeout: 10)).to be(true)
      expect(native.validate([valid], timeout: 10).errors).to be_empty
    end
  end

  it "keeps libruby regexps and observation tables private to each Ractor" do
    registry = Schemurai::SchemaRegistry.new(schemas: {"urn:ruby-regexp" => {"pattern" => "(a)\\1"}}, backend: :native).make_shareable
    workers = Array.new(2) do
      Ractor.new(registry) do |shared|
        native = shared.validator_for("urn:ruby-regexp")
        program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
        GC.start
        [program.valid?("aa"), program.valid?("b"), program.diagnostics("b").map(&:first)]
      end
    end
    workers.each { |worker| expect(worker.respond_to?(:value) ? worker.value : worker.take).to eq([true, false, ["pattern"]]) }
  end

  it "shares native instruction tables while Ractors own their search caches" do # rubocop:disable RSpec/ExampleLength
    schemas = {
      "urn:patterns" => {"patternProperties" => {"record" => {"type" => "string", "pattern" => "value[0-9]+"}}},
      "urn:other" => {
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$defs" => {"positive" => {"$id" => "urn:positive", "type" => "integer", "minimum" => 1}}
      }
    }
    registry = Schemurai::SchemaRegistry.new(schemas: schemas, backend: :native).make_shareable
    native = Schemurai.const_get(:Native)
    compiled = registry.validator_for("urn:patterns").instance_variable_get(:@evaluator).instance_variable_get(:@compiled)
    expect(Ractor.shareable?(compiled)).to be(true)
    # Any native recompile in a worker would invoke this stub and fail.
    allow(native::Program).to receive(:new).and_raise("native recompilation")
    workers = Array.new(2) do
      Ractor.new(registry) do |shared|
        validator = shared.validator_for("urn:patterns")
        evaluator = validator.instance_variable_get(:@evaluator)
        runner = evaluator.instance_variable_get(:@program)
        results = Array.new(10) do
          [validator.valid?({"record1" => "value1"}), validator.valid?({"record2" => "bad"}),
            validator.validate({"record3" => "bad"}).errors.map(&:keyword)]
        end
        positive = shared.validator_for("urn:positive")
        [evaluator.instance_variable_get(:@compiled), Ractor.shareable?(runner), results,
          positive.valid?(1), positive.valid?(0)]
      end
    end
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    workers.each do |worker|
      result = worker.respond_to?(:value) ? worker.value : worker.take
      expect(result).to eq([compiled, false, Array.new(10) { [true, false, ["pattern"]] }, true, false])
    end
  end

  it "keeps shared native roots alive after their registry is collected" do # rubocop:disable RSpec/ExampleLength
    schema = {"patternProperties" => {"record" => {"pattern" => "value[0-9]+"}}, "required" => ["record1"]}
    validator = Schemurai::SchemaRegistry.new(schemas: {"urn:patterns" => schema}, backend: :native)
      .make_shareable.validator_for("urn:patterns")
    validator.instance_variable_get(:@evaluator).remove_instance_variable(:@compiled)
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(vm_class).to receive(:validate).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    expect(validator.valid?({"record1" => "value1"})).to be(true)
    expect(validator.validate({"record1" => "bad"}).errors.map(&:keyword)).to eq(["pattern"])
  end

  it "prepares all native content and format variants before sharing" do # rubocop:disable RSpec/ExampleLength
    schema = {"type" => "string", "format" => "ipv4", "contentEncoding" => "base64", "contentMediaType" => "application/json"}
    registry = Schemurai::SchemaRegistry.new(schemas: {"urn:options" => schema}, backend: :native).make_shareable
    compiled = [false, true].product([false, true]).map do |format, content|
      validator = registry.validator_for("urn:options", format: format, content: content)
      expect(validator.valid?("not an email or base64!")).to eq(!format && !content)
      validator.instance_variable_get(:@evaluator).instance_variable_get(:@compiled)
    end
    expect(compiled.uniq.length).to eq(4)
    expect(compiled.all? { |program| Ractor.shareable?(program) }).to be(true)
  end

  it "makes native tables shareable under GC stress and keeps runners private" do # rubocop:disable RSpec/ExampleLength
    previous = GC.stress
    GC.stress = true
    registry = Schemurai::SchemaRegistry.new(schemas: {"urn:gc" => {"properties" => {"id" => {"const" => {"value" => 1}}}}}, backend: :native)
      .make_shareable
    validator = registry.validator_for("urn:gc")
    GC.stress = previous
    evaluator = validator.instance_variable_get(:@evaluator)
    compiled = evaluator.instance_variable_get(:@compiled)
    runner = evaluator.instance_variable_get(:@program)
    expect { Ractor.make_shareable(runner) }.to raise_error(Ractor::Error)
    expect { compiled.send(:initialize, nil, nil, false, false) }.to raise_error(FrozenError)
    expect(validator.valid?({"id" => {"value" => 1}})).to be(true)
    expect(validator.valid?({"id" => {"value" => 2}})).to be(false)
  ensure
    GC.stress = previous
  end

  it "uses shared compiled patterns in Ractors with independent search caches" do # rubocop:disable RSpec/ExampleLength
    schema = {"$schema" => "https://json-schema.org/draft/2020-12/schema", "patternProperties" => {
      "^record[0-9]+$" => {"type" => "string", "pattern" => "^value[0-9]+$"}
    }, "unevaluatedProperties" => false}
    registry = Schemurai::SchemaRegistry.new(schemas: {"urn:patterns" => schema}, backend: :native)
    registry.make_shareable
    workers = Array.new(2) do
      Ractor.new(registry) do |shared|
        validator = shared.validator_for("urn:patterns")
        [validator.valid?({"record1" => "value1"}), validator.valid?({"record1" => "bad"}), validator.valid?({"other" => "value1"})]
      end
    end
    workers.each do |worker|
      result = worker.respond_to?(:value) ? worker.value : worker.take
      expect(result).to eq([true, false, false])
    end
  end

  it "selects recursive overrides through conditional resources without leaking scope" do # rubocop:disable RSpec/ExampleLength
    schema = JSON.parse(File.read("references/JSON-Schema-Test-Suite/tests/draft2019-09/recursiveRef.json"))[7].fetch("schema")
    schema["if"] = {"propertyNames" => {"enum" => ["alpha"]}}
    validator = Schemurai.compile(schema, backend: :native)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    expect(validator.valid?({"alpha" => 1.1})).to be(true)
    expect(validator.valid?({"november" => 1.1})).to be(false)
    expect(validator.valid?({"alpha" => 1.1})).to be(true)
  end

  it "keeps dynamic bindings and resource metadata alive through compaction" do # rubocop:disable RSpec/ExampleLength
    schema = {"$schema" => "https://json-schema.org/draft/2020-12/schema", "$id" => "urn:outer", "$ref" => "urn:list", "$defs" => {"value" => {"$dynamicAnchor" => "value", "type" => "integer"}}}
    list = {"$schema" => "https://json-schema.org/draft/2020-12/schema", "$id" => "urn:list", "type" => "array", "items" => {"$dynamicRef" => "#value"}, "$defs" => {"value" => {"$dynamicAnchor" => "value"}}}
    validator = Schemurai.compile(schema, schemas: {"urn:list" => list}, backend: :native)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    expect(validator.valid?([1, 2])).to be(true)
    expect(validator.valid?([1, "bad"])).to be(false)
  end

  it "resolves multiple dynamic names independently in the same scope" do # rubocop:disable RSpec/ExampleLength
    schema = {"$schema" => "https://json-schema.org/draft/2020-12/schema", "$id" => "urn:multi", "$ref" => "urn:lists", "$defs" => {
      "number" => {"$dynamicAnchor" => "number", "type" => "integer"}, "string" => {"$dynamicAnchor" => "string", "type" => "string"},
      "lists" => {"$id" => "urn:lists", "properties" => {
        "numbers" => {"items" => {"$dynamicRef" => "#number"}}, "strings" => {"items" => {"$dynamicRef" => "#string"}}
      }, "$defs" => {"number" => {"$dynamicAnchor" => "number"}, "string" => {"$dynamicAnchor" => "string"}}}
    }}
    validator = Schemurai.compile(schema, backend: :native)
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    expect(validator.valid?({"numbers" => [1], "strings" => ["yes"]})).to be(true)
    expect(validator.valid?({"numbers" => ["bad"], "strings" => ["yes"]})).to be(false)
    expect(validator.valid?({"numbers" => [1], "strings" => [2]})).to be(false)
  end

  it "builds dynamic binding tables from a shared registry inside a Ractor" do # rubocop:disable RSpec/ExampleLength
    schema = {"$schema" => "https://json-schema.org/draft/2020-12/schema", "$id" => "urn:outer", "$ref" => "urn:list", "$defs" => {"value" => {"$dynamicAnchor" => "value", "type" => "integer"}}}
    list = {"$schema" => "https://json-schema.org/draft/2020-12/schema", "$id" => "urn:list", "type" => "array", "items" => {"$dynamicRef" => "#value"}, "$defs" => {"value" => {"$dynamicAnchor" => "value"}}}
    registry = Schemurai::SchemaRegistry.new(schemas: {"urn:outer" => schema, "urn:list" => list}, backend: :native)
    registry.make_shareable
    worker = Ractor.new(registry) do |shared|
      validator = shared.validator_for("urn:outer")
      [validator.valid?([1, 2]), validator.valid?([1, "bad"])]
    end
    result = worker.respond_to?(:value) ? worker.value : worker.take
    expect(result).to eq([true, false])
  end

  it "returns full VM error paths for invalid instances" do
    schema = {"type" => "array", "items" => {"type" => "integer", "minimum" => 2}}
    native = Schemurai.compile(schema, backend: :native).validate([1])
    vm = Schemurai.compile(schema, backend: :vm).validate([1])
    expect(native.errors).to eq(vm.errors)
  end
end
