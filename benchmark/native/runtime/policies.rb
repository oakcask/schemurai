# frozen_string_literal: true

require "json"
require_relative "../../support/measurement"
require_relative "../../../lib/schemurai"

$stdout.sync = true
width = Integer(ENV.fetch("BENCHMARK_WIDTH", "1000"))
depth = Integer(ENV.fetch("BENCHMARK_DEPTH", "8"))
iterations = Integer(ENV.fetch("BENCHMARK_ITERATIONS", "11"))
batch = Integer(ENV.fetch("BENCHMARK_BATCH", "50"))
abort "benchmark settings must be positive" unless [width, depth, iterations, batch].all?(&:positive?)
clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
dialect = {"$schema" => "https://json-schema.org/draft/2020-12/schema"}
properties = width.times.to_h { |index| ["p#{index}", {"type" => "integer"}] }
full = width.times.to_h { |index| ["p#{index}", index] }
leaf = {"properties" => properties, "unevaluatedProperties" => true}
all = conditional = leaf
depth.times do
  all = {"allOf" => [all], "unevaluatedProperties" => true}
  conditional = {"if" => {"type" => "object"}, "then" => conditional, "unevaluatedProperties" => true}
end
definitions = {"node0" => leaf}
depth.times do |index|
  definitions["node#{index + 1}"] = {"$ref" => "#/$defs/node#{index}", "unevaluatedProperties" => true}
end
reference = {"$ref" => "#/$defs/node#{depth}", "$defs" => definitions, "unevaluatedProperties" => true}
workloads = {
  "sparse properties" => [{"properties" => properties}, {"p0" => 0}, {"p0" => "bad"}],
  "sparse tracked properties" => [{"properties" => properties, "unevaluatedProperties" => false}, {"p0" => 0}, {"extra" => nil}],
  "dense properties" => [{"properties" => properties}, full, full.merge("p#{width - 1}" => "bad")],
  "nested allOf" => [all, full, full.merge("p#{width - 1}" => "bad")],
  "nested conditional" => [conditional, full, full.merge("p#{width - 1}" => "bad")],
  "nested references" => [reference, full, full.merge("p#{width - 1}" => "bad")]
}
results = {}
workloads.each do |name, (schema, valid, invalid)|
  validators = %i[vm native].to_h { |backend| [backend, Schemurai.compile(dialect.merge(schema), backend: backend)] }
  program = validators.fetch(:native).instance_variable_get(:@evaluator).instance_variable_get(:@program)
  {"valid" => valid, "invalid" => invalid}.each do |state, instance|
    expected = state == "valid"
    abort "native coverage: #{name}" unless program.valid?(instance) == expected && !program.diagnostics(instance).nil?
    abort "validity: #{name}" unless validators.values.all? { |validator| validator.valid?(instance) == expected }
    abort "errors: #{name}" unless validators[:native].validate(instance).errors == validators[:vm].validate(instance).errors
    %i[valid? validate].each do |method|
      validators.each_value { |validator| 20.times { validator.public_send(method, instance) } }
      samples = SchemuraiBenchmark::Measurement.alternating(iterations: iterations) do |backend|
        validator = validators.fetch(backend)
        start = clock.call
        batch.times { validator.public_send(method, instance) }
        (clock.call - start) / batch
      end
      timings = samples.transform_values { |times| SchemuraiBenchmark::Measurement.median(times) }
      allocations = validators.transform_values do |validator|
        GC.start
        start = GC.stat(:total_allocated_objects)
        batch.times { validator.public_send(method, instance) }
        (GC.stat(:total_allocated_objects) - start).fdiv(batch)
      end
      key = "#{name} / #{state} / #{method}"
      results[key] = {seconds: timings, allocations: allocations}
      puts "%s: VM %.3f ms, native %.3f ms" % [key, timings.fetch(:vm) * 1000, timings.fetch(:native) * 1000]
    end
  end
end
report = {ruby: RUBY_DESCRIPTION, width: width, depth: depth, iterations: iterations, batch: batch, results: results}
File.write(ENV.fetch("BENCHMARK_JSON"), JSON.pretty_generate(report)) if ENV.key?("BENCHMARK_JSON")
