# frozen_string_literal: true

# Native construction from cached VM programs, excluding schema graph work.
require_relative "../lib/schemurai"
require "json"
require "objspace"

$stdout.sync = true
widths = ENV.fetch("BENCHMARK_WIDTHS", "8,128,2048,8192").split(",").map { |value| Integer(value) }
iterations = Integer(ENV.fetch("BENCHMARK_ITERATIONS", "21"))
batch = Integer(ENV.fetch("BENCHMARK_BATCH", "5"))
mode = ENV.fetch("BENCHMARK_MODE", "plain")
abort "benchmark settings must be positive" unless [*widths, iterations, batch].all?(&:positive?)
Schemurai.compile(true, backend: :native)
program_class = Schemurai.const_get(:Native)::Program
results = {}
widths.each do |width|
  definitions = {}
  properties = width.times.to_h do |index|
    leaf = {"type" => "integer", "minimum" => index}
    rule = case mode
    when "plain", "closed" then leaf
    when "references"
      definitions["v#{index}"] = leaf
      {"$ref" => "#/$defs/v#{index}"}
    when "nested" then {"items" => leaf}
    when "cyclic", "dependencies"
      reference = {"$ref" => "#/$defs/v#{index}"}
      definitions["v#{index}"] = if mode == "cyclic"
        {"allOf" => [reference, reference], "minimum" => index}
      else
        {"properties" => {"next" => reference}, "dependentSchemas" => {"next" => reference}, "minimum" => index}
      end
      reference
    when "shared"
      definitions["value"] = {"type" => "integer", "minimum" => 0}
      {"$ref" => "#/$defs/value"}
    else abort "BENCHMARK_MODE must be plain, closed, references, nested, cyclic, dependencies or shared"
    end
    ["p#{index}", rule]
  end
  schema = {"properties" => properties, "$defs" => definitions}
  schema["$schema"] = "https://json-schema.org/draft/2020-12/schema" if mode == "dependencies"
  schema["additionalProperties"] = false if mode == "closed"
  vm = Schemurai.compile(schema, backend: :vm)
  evaluator = vm.instance_variable_get(:@evaluator)
  root = evaluator.instance_variable_get(:@root)
  compiler = evaluator.instance_variable_get(:@compiler)
  factory = -> { program_class.new(root, compiler, false, false) }
  program = factory.call
  runner = program.runner(root)
  value = properties.keys.to_h { |key| [key, (mode == "nested") ? [width] : width] }
  abort "unsupported native program" unless runner.valid?(value) == true && runner.diagnostics(value) == []
  invalid = value.merge("p0" => ((mode == "nested") ? [-1] : -1))
  abort "incorrect native failure" unless runner.valid?(invalid) == false
  native = Schemurai.compile(schema, backend: :native)
  abort "different errors" unless native.validate(invalid).errors == vm.validate(invalid).errors
  5.times { factory.call }
  samples = Array.new(iterations) do
    GC.start
    cpu = Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID)
    wall = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    batch.times { factory.call }
    {cpu: (Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID) - cpu) / batch,
     wall: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - wall) / batch}
  end
  medians = %i[cpu wall].to_h { |clock| [clock, samples.map { |sample| sample.fetch(clock) }.sort[iterations / 2]] }
  results[width] = {seconds: medians, samples: samples, program_bytes: ObjectSpace.memsize_of(program)}
  puts JSON.generate(mode: mode, width: width, milliseconds: medians.transform_values { |time| time * 1000 }, program_bytes: ObjectSpace.memsize_of(program))
end
if ENV.key?("BENCHMARK_JSON")
  File.write(ENV.fetch("BENCHMARK_JSON"), JSON.pretty_generate(ruby: RUBY_DESCRIPTION, mode: mode, iterations: iterations, batch: batch, results: results))
end
