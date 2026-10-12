# frozen_string_literal: true

require "json"
require "base64"
require_relative "../lib/schemurai"
width = Integer(ENV.fetch("BENCHMARK_WIDTH", "1000"))
iterations = Integer(ENV.fetch("BENCHMARK_ITERATIONS", "21"))
batch = Integer(ENV.fetch("BENCHMARK_BATCH", "100"))
abort "benchmark settings must be positive" unless [width, iterations, batch].all?(&:positive?)
abort "benchmark width must be at least two" if width < 2
schema_base = {"$schema" => "https://json-schema.org/draft/2020-12/schema"}
workloads = {}
{
  "pattern" => [{"pattern" => "^record[0-9]+$"}, "record123", "bad"],
  "format" => [{"format" => "date"}, "2024-02-29", "2023-02-29"],
  "content" => [{"contentEncoding" => "base64", "contentMediaType" => "application/json"}, Base64.strict_encode64('{"id":1}'), "!"]
}.each do |name, (rule, valid, invalid)|
  [false, true].each do |tracked|
    schema = schema_base.merge("prefixItems" => [{"const" => "header"}], "items" => rule.merge("type" => "string"))
    schema["unevaluatedItems"] = false if tracked
    workloads["#{name}/#{tracked ? "tracked" : "plain"}/valid"] = [schema, ["header"] + Array.new(width, valid)]
    workloads["#{name}/#{tracked ? "tracked" : "plain"}/invalid"] = [schema, ["header"] + Array.new(width - 2, valid) + [invalid, invalid]]
  end
end
properties = 64.times.to_h { |i| ["p#{i}", {"type" => "integer"}] }
value = properties.keys.to_h { |key| [key, 1] }
[false, true].each do |tracked|
  schema = schema_base.merge("properties" => properties, "required" => properties.keys,
    "dependentRequired" => 32.times.to_h { |i| ["p#{i}", ["p#{i + 32}"]] })
  schema["unevaluatedProperties"] = false if tracked
  workloads["required/#{tracked ? "tracked" : "plain"}/valid"] = [schema, value]
  workloads["required/#{tracked ? "tracked" : "plain"}/invalid"] = [schema, value.except("p63")]
  workloads["dependent-required/#{tracked ? "tracked" : "plain"}/invalid"] = [schema.merge("required" => ["p0"]), value.except("p63")]
end
results = {}
workloads.each do |name, (schema, instance)|
  native = Schemurai.compile(schema, backend: :native, format: true, content: true)
  vm = Schemurai.compile(schema, backend: :vm, format: true, content: true)
  program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
  raise "native fallback #{name}" if program.valid?(instance).nil? || program.diagnostics(instance).nil?
  raise "error parity #{name}" unless native.validate(instance).errors == vm.validate(instance).errors
  raise "verdict parity #{name}" unless native.valid?(instance) == vm.valid?(instance)
  %i[valid? validate].each do |method|
    300.times { native.public_send(method, instance) }
    samples = Array.new(iterations) do
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      batch.times { native.public_send(method, instance) }
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) / batch
    end
    GC.start
    GC.stat(:total_allocated_objects)
    allocations = GC.stat(:total_allocated_objects)
    batch.times { native.public_send(method, instance) }
    allocations = (GC.stat(:total_allocated_objects) - allocations).fdiv(batch)
    results["#{name}/#{method}"] = {seconds: samples.sort[iterations / 2], allocations: allocations}
  end
end
report = {ruby: RUBY_DESCRIPTION, yjit: RubyVM::YJIT.enabled?, width: width, iterations: iterations, batch: batch, results: results}
File.write(ENV.fetch("BENCHMARK_JSON"), JSON.pretty_generate(report)) if ENV.key?("BENCHMARK_JSON")
results.each do |name, result|
  puts "%s: %.3f us, %.2f Ruby allocations" % [name, result.fetch(:seconds) * 1_000_000, result.fetch(:allocations)]
end
puts "#{results.length} cases: parity and direct native coverage passed"
