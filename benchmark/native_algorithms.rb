# frozen_string_literal: true

# Compile outside the measured region and check native coverage and VM parity.
require_relative "../lib/schemurai"
require "json"

def measure(label, schema, value, calls: 50)
  schema = {"$schema" => "https://json-schema.org/draft/2020-12/schema"}.merge(schema)
  validator = Schemurai.compile(schema, backend: :native)
  runner = validator.instance_variable_get(:@evaluator).instance_variable_get(:@program)
  raise "native coverage: #{label}" unless runner.valid?(value) == true && runner.diagnostics(value)&.empty?
  vm = Schemurai.compile(schema, backend: :vm)
  raise "VM parity: #{label}" unless vm.valid?(value) && vm.validate(value).errors == validator.validate(value).errors
  results = {}
  [:valid?, :diagnostics].each do |method|
    10.times { runner.public_send(method, value) }
    samples = Array.new(7) do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      calls.times { runner.public_send(method, value) }
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000_000 / calls
    end
    results[method] = samples.sort[3].round(3)
  end
  puts JSON.generate(label: label, microseconds: results)
end

$stdout.sync = true
puts RUBY_DESCRIPTION
[128, 1024].each do |width|
  [8, 32, 128].each do |branches|
    schema = {"anyOf" => Array.new(branches) { |i| {"type" => "integer", "minimum" => i} } + [true]}
    measure("key-guard width=#{width} branches=#{branches}", schema, Array.new(width) { |i| ["f#{i}", i] }.to_h)
  end
end
[0, 4096, 65536].each do |padding|
  schema = {"allOf" => [
    {"properties" => Array.new(padding) { |i| ["unused#{i}", true] }.to_h},
    {"properties" => {"records" => {"items" => {"properties" => {"x" => true}, "unevaluatedProperties" => false}}}}
  ]}
  measure("global-property-ids padding=#{padding} records=1000", schema, {"records" => Array.new(1000) { {"x" => 1} }}, calls: 10)
end
[4, 8, 12, 16].each do |depth|
  definitions = {"d0" => {"type" => "integer", "minimum" => 1}}
  1.upto(depth) do |i|
    definitions["d#{i}"] = {"allOf" => Array.new(2) { {"$ref" => "#/$defs/d#{i - 1}"} }}
  end
  measure("shared-reference depth=#{depth}", {"$defs" => definitions, "$ref" => "#/$defs/d#{depth}"}, 1, calls: 5)
end
[1, 8, 32, 64].each do |patterns|
  schema = {"patternProperties" => Array.new(patterns) { |i| ["^f#{i}_", {"type" => "integer"}] }.to_h}
  measure("patterns=#{patterns} width=1024", schema, Array.new(1024) { |i| ["f0_#{i}", i] }.to_h, calls: 10)
end
