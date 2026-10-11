# frozen_string_literal: true

require_relative "../lib/schemurai"
require "json"

$stdout.sync = true
puts RUBY_DESCRIPTION
[8, 12, 16].each do |depth|
  definitions = {"target" => {"$dynamicAnchor" => "target", "type" => "integer"},
                 "d0" => {"$dynamicRef" => "#target"}}
  1.upto(depth) { |i| definitions["d#{i}"] = {"allOf" => Array.new(2) { {"$ref" => "#/$defs/d#{i - 1}"} }} }
  schema = {"$schema" => "https://json-schema.org/draft/2020-12/schema", "$defs" => definitions,
            "$ref" => "#/$defs/d#{depth}"}
  native = Schemurai.compile(schema, backend: :native)
  runner = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
  vm = Schemurai.compile(schema, backend: :vm)
  raise "VM parity" unless native.valid?(1) == vm.valid?(1) && native.validate(1).errors == vm.validate(1).errors

  results = [:valid?, :diagnostics].to_h do |method|
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = runner.public_send(method, 1)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    raise "native coverage" unless (method == :valid?) ? result == true : result&.empty?

    [method, (elapsed * 1_000_000).round(3)]
  end
  puts JSON.generate(depth: depth, microseconds: results)
end
