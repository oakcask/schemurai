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
