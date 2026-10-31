# frozen_string_literal: true

require_relative "../lib/schemurai"
require "json"
require "objspace"

$stdout.sync = true
width = Integer(ENV.fetch("BENCHMARK_WIDTH", "128"))
iterations = Integer(ENV.fetch("BENCHMARK_ITERATIONS", "21"))
batch = Integer(ENV.fetch("BENCHMARK_BATCH", "20"))
modes = ENV.fetch("BENCHMARK_MODES", "record,types,boolean,string,plain").split(",")
abort "benchmark settings must be positive" unless [width, iterations, batch].all?(&:positive?)
results = {}
modes.each do |mode|
  leaf = {"type" => "object", "properties" => {"id" => {"type" => "integer"}, "name" => {"type" => "string"}},
          "required" => %w[id name], "additionalProperties" => false}
  klass = (mode == "plain") ? Hash : Class.new(Hash)
  values = Array.new(width) { |index| klass["id", index + 1, "name", "record"] }
  invalid = [klass["id", "bad", "name", "record"]]
  case mode
  when "record", "plain"
    leaf["properties"]["id"]["minimum"] = 1
    leaf["properties"]["name"]["minLength"] = 1
  when "types" # Boolean/type callbacks do not enter the native evaluator.
  when "boolean"
    leaf = {"properties" => {"value" => true, "bad" => false}}
    values = Array.new(width) { klass["value", 1] }
    invalid = [klass["bad", 1]]
  when "string"
    leaf = {"type" => "string", "minLength" => 1}
    strings = Class.new(String)
    values = Array.new(width) { strings.new("record") }
    invalid = [strings.new("")]
  else abort "unknown callback mode #{mode}"
  end
  schema = {"items" => leaf}
  native = Schemurai.compile(schema, backend: :native)
  vm = Schemurai.compile(schema, backend: :vm)
  runner = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
  cold_bytes = ObjectSpace.memsize_of(runner)
  abort "unsupported native program" unless runner.valid?(values) == true && runner.diagnostics(values) == []
  abort "incorrect native failure" unless runner.valid?(invalid) == false
  abort "different errors" unless native.validate(invalid).errors == vm.validate(invalid).errors
  results[mode] = {runner_bytes_before: cold_bytes, operations: {}}
  %i[valid? diagnostics].each do |method|
    100.times { runner.public_send(method, values) }
    samples = Array.new(iterations) do
      GC.start
      started = Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID)
      batch.times { runner.public_send(method, values) }
      (Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID) - started) / batch
    end
    seconds = samples.sort[iterations / 2]
    results[mode][:operations][method] = {seconds: seconds, samples: samples}
    puts JSON.generate(mode: mode, operation: method, microseconds: seconds * 1_000_000)
  end
  results[mode][:runner_bytes_after] = ObjectSpace.memsize_of(runner)
end
if ENV.key?("BENCHMARK_JSON")
  File.write(ENV.fetch("BENCHMARK_JSON"), JSON.pretty_generate(ruby: RUBY_DESCRIPTION, width: width,
    iterations: iterations, batch: batch, results: results))
end
