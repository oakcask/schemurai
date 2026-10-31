# frozen_string_literal: true

# Cross the invocation cache limits with distinct values, then exercise a
# shared-reference chain for every later record. Compile outside measurement.
require_relative "../../../lib/schemurai"
require "json"

$stdout.sync = true
puts RUBY_DESCRIPTION
[8, 12, 16].each do |depth|
  definitions = {"d0" => {"properties" => {"x" => {"type" => "integer"}}}}
  1.upto(depth) { |i| definitions["d#{i}"] = {"allOf" => Array.new(2) { {"$ref" => "#/$defs/d#{i - 1}"} }} }
  schema = {"$schema" => "https://json-schema.org/draft/2020-12/schema", "$defs" => definitions,
            "items" => {"$ref" => "#/$defs/d#{depth}", "unevaluatedProperties" => false}}
  native = Schemurai.compile(schema, backend: :native)
  runner = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
  vm = Schemurai.compile(schema, backend: :vm)
  sample = [{"x" => 1}]
  raise "VM parity" unless vm.valid?(sample) && native.validate(sample).errors == vm.validate(sample).errors

  [128, 1024].each do |width|
    value = Array.new(width) { |i| {"x" => i} }
    results = [:valid?, :diagnostics].to_h do |method|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = runner.public_send(method, value)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      raise "native coverage" unless (method == :valid?) ? result == true : result&.empty?

      [method, (elapsed * 1000).round(3)]
    end
    puts JSON.generate(depth: depth, width: width, milliseconds: results)
  end
end
