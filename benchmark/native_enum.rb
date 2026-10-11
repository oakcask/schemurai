# frozen_string_literal: true

require_relative "../lib/schemurai"
require "json"

size = Integer(ENV.fetch("BENCHMARK_SIZE", "1024"))
width = Integer(ENV.fetch("BENCHMARK_WIDTH", "256"))
iterations = Integer(ENV.fetch("BENCHMARK_ITERATIONS", "11"))
batch = Integer(ENV.fetch("BENCHMARK_BATCH", "10"))
abort "benchmark settings must be positive" unless [size, width, iterations, batch].all?(&:positive?)
$stdout.sync = true

choices = {
  "numbers" => Array.new(size) { |index| index },
  "strings" => Array.new(size) { |index| "entry#{index}" },
  "objects" => Array.new(size) { |index| {"id" => index, "nested" => [index, "entry"]} }
}
missing = {"numbers" => size, "strings" => "missing", "objects" => {"nested" => [size, "entry"], "id" => size}}
clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
results = {}
allocations = {}
choices.each do |kind, values|
  schema = {"type" => "array", "items" => {"enum" => values}}
  validators = %i[vm native].to_h { |backend| [backend, Schemurai.compile(schema, backend: backend)] }
  program = validators[:native].instance_variable_get(:@evaluator).instance_variable_get(:@program)
  {"first" => values.first, "last" => values.last, "missing" => missing.fetch(kind)}.each do |position, value|
    instance = Array.new(width, value)
    expected = position != "missing"
    abort "native coverage" unless program.valid?(instance) == expected && !program.diagnostics(instance).nil?
    abort "validity" unless validators.values.all? { |validator| validator.valid?(instance) == expected }
    abort "errors" unless validators[:native].validate(instance).errors == validators[:vm].validate(instance).errors
    %i[valid? validate].each do |method|
      validators.each_value { |validator| 10.times { validator.public_send(method, instance) } }
      samples = {vm: [], native: []}
      iterations.times do |iteration|
        order = iteration.even? ? %i[vm native] : %i[native vm]
        order.each do |backend|
          validator = validators.fetch(backend)
          start = clock.call
          batch.times { validator.public_send(method, instance) }
          samples.fetch(backend) << (clock.call - start) / batch
        end
      end
      key = "#{kind} / #{position} / #{method}"
      results[key] = samples.transform_values { |times| times.sort[iterations / 2] }
      allocations[key] = validators.transform_values do |validator|
        GC.start
        before = GC.stat(:total_allocated_objects)
        iterations.times { validator.public_send(method, instance) }
        (GC.stat(:total_allocated_objects) - before).fdiv(iterations)
      end
      puts "#{key}: #{results[key].transform_values { |seconds| (seconds * 1_000_000).round(3) }} us"
    end
  end
end
report = {ruby: RUBY_DESCRIPTION, size: size, width: width, iterations: iterations, batch: batch,
          results: results, allocations: allocations}
File.write(ENV.fetch("BENCHMARK_JSON"), JSON.pretty_generate(report)) if ENV.key?("BENCHMARK_JSON")
