# frozen_string_literal: true

require_relative "../../../lib/schemurai"
require "json"
require_relative "../../support/measurement"

$stdout.sync = true
width = Integer(ENV.fetch("BENCHMARK_WIDTH", "128"))
iterations = Integer(ENV.fetch("BENCHMARK_ITERATIONS", "21"))
batch = Integer(ENV.fetch("BENCHMARK_BATCH", "1000"))
abort "benchmark settings must be positive" unless [width, iterations, batch].all?(&:positive?)
bounds = {"type" => "integer", "minimum" => 0, "maximum" => 10000, "exclusiveMinimum" => 1, "exclusiveMaximum" => 9000}
record = {"properties" => {"id" => bounds, "name" => {"type" => "string", "minLength" => 1}},
          "required" => %w[id name], "additionalProperties" => false}
workloads = {
  "boolean" => [true, 42, 42],
  "integer" => [{"type" => "integer"}, 42, "bad"],
  "bounds" => [bounds, 42, 0],
  "array" => [{"items" => bounds}, Array.new(width, 42), [0]],
  "record" => [{"items" => record}, Array.new(width) { {"id" => 42, "name" => "record"} }, [{"id" => 0, "name" => "record"}]],
  "pattern" => [{"pattern" => "^record[0-9]+$"}, "record42", "bad"]
}
if ENV.key?("BENCHMARK_WORKLOAD")
  workloads.select! { |name, _| name == ENV.fetch("BENCHMARK_WORKLOAD") }
  abort "unknown runner workload" if workloads.empty?
end
results = {}
workloads.each do |name, (schema, valid, invalid)|
  native = Schemurai.compile(schema, backend: :native)
  vm = Schemurai.compile(schema, backend: :vm)
  runner = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
  [valid, invalid].each do |value|
    abort "unsupported or incorrect native verdict" unless runner.valid?(value) == vm.valid?(value)
    abort "unsupported native diagnostics" if runner.diagnostics(value).nil?
    abort "different errors" unless native.validate(value).errors == vm.validate(value).errors
  end
  value = ENV.key?("BENCHMARK_INVALID") ? invalid : valid
  results[name] = {}
  %i[valid? diagnostics].each do |method|
    1000.times { runner.public_send(method, value) }
    samples = SchemuraiBenchmark::Measurement.samples(iterations: iterations, batch: batch,
      clock: Process::CLOCK_THREAD_CPUTIME_ID, gc: true) do
      runner.public_send(method, value)
    end
    seconds = SchemuraiBenchmark::Measurement.median(samples)
    results[name][method] = {seconds: seconds, samples: samples}
    puts JSON.generate(workload: name, operation: method, microseconds: seconds * 1_000_000)
  end
end
if ENV.key?("BENCHMARK_JSON")
  File.write(ENV.fetch("BENCHMARK_JSON"), JSON.pretty_generate(ruby: RUBY_DESCRIPTION, width: width,
    iterations: iterations, batch: batch, invalid: ENV.key?("BENCHMARK_INVALID"), results: results))
end
