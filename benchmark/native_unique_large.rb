# frozen_string_literal: true

require_relative "../lib/schemurai"
require "json"

abort "YJIT required" unless RubyVM::YJIT.enabled?
width = Integer(ENV.fetch("BENCHMARK_WIDTH", "65536"))
iterations = Integer(ENV.fetch("BENCHMARK_ITERATIONS", "31"))
batch = Integer(ENV.fetch("BENCHMARK_BATCH", "5"))
abort "benchmark settings must be positive" unless [width, iterations, batch].all?(&:positive?)
values = Array.new(width) { |index| 2**200 + index }.shuffle(random: Random.new(9571))
schema = {"uniqueItems" => true}
validators = %i[vm native].to_h { |backend| [backend, Schemurai.compile(schema, backend: backend)] }
program = validators[:native].instance_variable_get(:@evaluator).instance_variable_get(:@program)
clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
results = {}
{"valid" => values, "invalid" => values + [values.last]}.each do |name, instance|
  expected = name == "valid"
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
    results["#{name} / #{method}"] = samples.transform_values { |times| times.sort[iterations / 2] }
  end
end
report = {ruby: RUBY_DESCRIPTION, width: width, iterations: iterations, batch: batch, results: results}
puts JSON.pretty_generate(report)
File.write(ENV.fetch("BENCHMARK_JSON"), JSON.pretty_generate(report)) if ENV.key?("BENCHMARK_JSON")
