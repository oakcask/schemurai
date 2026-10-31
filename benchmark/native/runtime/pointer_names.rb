# frozen_string_literal: true

require_relative "../../../lib/schemurai"
require "json"

$stdout.sync = true
batch = Integer(ENV.fetch("BENCHMARK_BATCH", "100"))
iterations = Integer(ENV.fetch("BENCHMARK_ITERATIONS", "15"))
abort "benchmark settings must be positive" unless batch.positive? && iterations.positive?
results = {}
[8, 64, 1024, 16384].each do |length|
  {"ascii" => "a" * length, "unicode" => "日" * length, "escaped" => "a~/" * length,
   "leading escape" => "~/" + "日" * length, "trailing escape" => "日" * length + "~/"}.each do |kind, key|
    schema = {"items" => {"additionalProperties" => false}}
    value = Array.new(16) { {key => 1} }
    native = Schemurai.compile(schema, backend: :native)
    expected = Schemurai.compile(schema, backend: :vm).validate(value).errors
    program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
    abort "unsupported native diagnostics" if program.diagnostics(value).nil?
    abort "different diagnostic paths" unless native.validate(value).errors == expected
    100.times { native.validate(value) }
    samples = Array.new(iterations) do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      batch.times { native.validate(value) }
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / batch
    end
    results["#{kind}/#{length}"] = samples.sort[iterations / 2]
    puts "#{kind}/#{length}: #{(results.fetch("#{kind}/#{length}") * 1_000_000).round(3)} us"
  end
end
if ENV.key?("BENCHMARK_JSON")
  File.write(ENV.fetch("BENCHMARK_JSON"), JSON.pretty_generate(ruby: RUBY_DESCRIPTION, batch: batch, iterations: iterations, seconds: results))
end
