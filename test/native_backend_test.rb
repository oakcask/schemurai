# frozen_string_literal: true

require "spec_helper"
require "base64"
require "objspace"
require "open3"
require "rbconfig"
require_relative "../oracle/lib/case_catalog"

RSpec.describe "native VALUE execution" do
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

  def expect_native_policy_results(schemas, values)
    cases = schemas.map do |schema|
      vm = Schemurai.compile(schema, backend: :vm)
      [Schemurai.compile(schema, backend: :native), values.map { |value| [vm.valid?(value), vm.validate(value).errors] }]
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
    expect(program.valid?({"p2" => "bad", "p1" => "x"})).to be_nil
    expect(program.diagnostics({"p1" => "x", "p0" => "bad"})).to be_nil
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
    expect(program.diagnostics(value)).to be_nil
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
      expect(program.valid?(values + [{"special" => special}])).to be_nil
      expect(program.diagnostics(values + [{"special" => special}])).to be_nil
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

  it "delegates shared containers with custom nested equality" do # rubocop:disable RSpec/ExampleLength
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
      expect(program.valid?(values)).to be_nil
      expect(program.diagnostics(values)).to be_nil
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

  it "preserves overridden methods on singleton objects and builtin subclasses" do # rubocop:disable RSpec/ExampleLength
    string = +"abc"
    string.define_singleton_method(:length) { 0 }
    array = [1]
    array.define_singleton_method(:length) { 0 }
    object = {"id" => 1}
    object.define_singleton_method(:key?) { |_key| false }
    values = [[{"minLength" => 1}, string], [{"minItems" => 1}, array], [{"required" => ["id"]}, object],
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
      expect(program.valid?(value)).to be_nil
      expect(program.diagnostics(value)).to be_nil
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
          expect(program.valid?(prefix + [Class.new(String).new(valid)])).to be_nil
          expect(program.diagnostics(prefix + [{Object.new => 1}])).to be_nil
          if rule["contentEncoding"].nil?
            expect(program.valid?(prefix + [valid.encode(Encoding::UTF_16LE)])).to be_nil
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

  it "preserves JSON transcoding and invalid-encoding exceptions" do
    schema = {"contentMediaType" => "application/json"}
    vm = Schemurai.compile(schema, content: true, backend: :vm)
    native = Schemurai.compile(schema, content: true, backend: :native)
    value = "{\"a\":1}".encode(Encoding::UTF_16LE)
    expect(native.valid?(value)).to eq(vm.valid?(value))
    invalid = "\"\xFF\"".dup.force_encoding(Encoding::US_ASCII)
    expect { native.valid?(invalid) }.to raise_error(Encoding::InvalidByteSequenceError)
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
        expect(program.valid?(prefix + [special])).to be_nil
        expect(program.diagnostics(prefix + [special])).to be_nil
        expect(program.valid?(prefix + [{Object.new => 1}])).to be_nil
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

  it "delegates Integer multiples beyond the bounded scalar magnitude" do
    schema = {"multipleOf" => 3}
    vm = Schemurai.compile(schema, backend: :vm)
    native = Schemurai.compile(schema, backend: :native)
    program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
    [2**1024, -(2**1024), 2**4096 * 3].each do |value|
      expect(program.valid?(value)).to be_nil
      expect(program.diagnostics(value)).to be_nil
      expect(native.valid?(value)).to eq(vm.valid?(value))
      expect(native.validate(value).errors).to eq(vm.validate(value).errors)
    end
  end

  it "retains known bound failures when wide multiple diagnostics must delegate" do
    schema = {"maximum" => 0, "multipleOf" => 3}
    vm = Schemurai.compile(schema, backend: :vm)
    native = Schemurai.compile(schema, backend: :native)
    program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
    [2**1024, 2**4096 * 3].each do |value|
      expect(program.valid?(value)).to be(false)
      expect(program.diagnostics(value)).to be_nil
      expect(native.validate(value).errors).to eq(vm.validate(value).errors)
    end
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

  it "rejects coercible numeric objects before entering the Integer scalar adapter" do
    numeric = Class.new(Numeric) do
      def to_int = raise("numeric coercion")
      def to_f = raise("numeric coercion")
      def to_s = raise("numeric coercion")
    end.new
    rule = {"type" => "number", "minimum" => 0, "maximum" => 2**100}
    schemas = [rule, {"items" => rule}, {"properties" => {"value" => rule}}]
    [numeric, Rational(3, 2), Complex(1, 2), Object.new, :number].each do |value|
      schemas.each_with_index do |schema, index|
        native = Schemurai.compile(schema, backend: :native)
        program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
        instance = [value, [value], {"value" => value}].fetch(index)
        expect(program.valid?(instance)).to be_nil
        expect(program.diagnostics(instance)).to be_nil
      end
    end
  end

  it "matches Ruby decimal spelling at numeric boundaries" do # rubocop:disable RSpec/ExampleLength
    random = Random.new(1729)
    values = [723340043767187.2, 0.8455124082255701, 1e23, -1e23, 1e-20, 0.1, 0.3, -0.0]
    2000.times do
      value = [random.rand(2**64)].pack("Q").unpack1("d")
      values << value if value.finite? && value.abs.between?(1e-20, 1e20)
    end
    allow_any_instance_of(vm_class).to receive(:valid?).and_raise("VM execution") # rubocop:disable RSpec/AnyInstance
    values.each do |value|
      next if value.zero?

      validator = Schemurai.compile({"minimum" => value, "maximum" => value, "multipleOf" => value.abs}, backend: :native)
      expect(validator.valid?(value)).to be(true), value.inspect
    end
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
    values = [Class.new(Hash)["id", 1], {Object.new => 1}, {"id" => 1}.compare_by_identity]
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

  it "delegates indexed uniqueness with non-string hash keys before Ruby lookup" do
    schema = {"uniqueItems" => true}
    native = Schemurai.compile(schema, backend: :native)
    vm = Schemurai.compile(schema, backend: :vm)
    program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
    [Object.new, :key, Class.new(String).new("key")].each do |key|
      values = Array.new(20) { |i| [i] } + [{"nested" => {key => 1}}]
      expect(program.valid?(values)).to be_nil
      expect(program.diagnostics(values)).to be_nil
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

  it "preserves late reference resolution in a mutable registry" do # rubocop:disable RSpec/ExampleLength
    registry = Schemurai::SchemaRegistry.new(backend: :native)
    validator = registry.compile({"$ref" => "urn:late"})
    expect(validator.valid?(1)).to be(false)
    registry.compile({"$id" => "urn:late", "type" => "integer"})
    expect(validator.valid?(1)).to be(true)
    expect(validator.valid?("bad")).to be(false)
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
    expect(program.valid?({"id" => "x"})).to be_nil
    expect(program.diagnostics({"id" => "x"})).to be_nil
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
        program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
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
    expect(raw.valid?(["aa"])).to be_nil
  end

  it "preserves VM handling for complex patterns, invalid syntax, and other encodings" do # rubocop:disable RSpec/ExampleLength
    ["a++a", "a**", "(?=ab)ab", "(a)\\1", "(?i:a)", "\\b日\\b", "[a-z&&[^b]]", "[a--b]", "[a~~b]", "[", "a{2,1}", "a{4097}", "a{100001}"].each do |pattern|
      schema = {"pattern" => pattern}
      vm = Schemurai.compile(schema, backend: :vm)
      native = Schemurai.compile(schema, backend: :native)
      ["abcd", "b", "é", "", 1].each { |value| expect(native.valid?(value)).to eq(vm.valid?(value)) }
    end
    schema = {"pattern" => "^a+$"}
    vm = Schemurai.compile(schema, backend: :vm)
    native = Schemurai.compile(schema, backend: :native)
    expect(native.valid?("aa".b)).to eq(vm.valid?("aa".b))
    incompatible = "a".encode(Encoding::UTF_16LE)
    expect { native.valid?(incompatible) }.to raise_error(Encoding::CompatibilityError)
    expect { vm.valid?(incompatible) }.to raise_error(Encoding::CompatibilityError)
    invalid = "\xFF".dup.force_encoding(Encoding::UTF_8)
    expect { native.valid?(invalid) }.to raise_error(ArgumentError)
    expect { vm.valid?(invalid) }.to raise_error(ArgumentError)
    invalid.force_encoding(Encoding::US_ASCII)
    expect { native.valid?(invalid) }.to raise_error(ArgumentError)
    expect { vm.valid?(invalid) }.to raise_error(ArgumentError)
  end

  it "owns compiled patterns independently in Ractors using a shared registry" do # rubocop:disable RSpec/ExampleLength
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
