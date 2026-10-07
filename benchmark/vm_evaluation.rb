# frozen_string_literal: true

require "json"

$LOAD_PATH.unshift(ENV.fetch("JSON_SCHEMA_VALIDATOR_LIB", File.expand_path("../lib", __dir__)))
require "schemurai"

width = Integer(ENV.fetch("BENCHMARK_WIDTH", "1000"))
iterations = Integer(ENV.fetch("BENCHMARK_ITERATIONS", "31"))
raise "width and iterations must be positive" unless width.positive? && iterations.positive?

properties = width.times.to_h { |index| ["p#{index}", {"type" => "integer"}] }
object = width.times.to_h { |index| ["p#{index}", index] }
array = Array.new(width) { |index| index }
fixtures = {
  "object" => [
    {"anyOf" => [{"properties" => properties}, {"properties" => properties}],
     "unevaluatedProperties" => false},
    object, object.merge("extra" => nil)
  ],
  "array" => [
    {"contains" => {"type" => "integer"}, "unevaluatedItems" => false},
    array, array + [nil]
  ]
}

results = {}
fixtures.each do |name, (schema, valid, invalid)|
  schema = schema.merge("$schema" => "https://json-schema.org/draft/2020-12/schema")
  validator = Schemurai.compile(schema, backend: :vm)
  %i[valid? validate].each do |method|
    [["valid", valid, true], ["invalid", invalid, false]].each do |label, instance, expected|
      result = validator.public_send(method, instance)
      actual = (method == :validate) ? result.valid? : result
      raise "incorrect #{name}/#{method}/#{label}" unless actual == expected

      if method == :validate && !expected
        keyword = (name == "object") ? "unevaluatedProperties" : "unevaluatedItems"
        path = (name == "object") ? "/extra" : "/#{width}"
        errors = result.errors.map { |error| [error.keyword, error.instance_path, error.schema_path] }
        raise "incorrect errors: #{errors.inspect}" unless errors == [["falseSchema", path, "/#{keyword}"]]
      end

      5.times { validator.public_send(method, instance) }
      samples = Array.new(iterations) do
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        validator.public_send(method, instance)
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      end
      GC.start
      before = GC.stat(:total_allocated_objects)
      iterations.times { validator.public_send(method, instance) }
      allocated = (GC.stat(:total_allocated_objects) - before).fdiv(iterations)
      key = "#{name}/#{method}/#{label}"
      results[key] = {seconds: samples.sort.fetch(iterations / 2), allocations: allocated}
      puts "%24s %9.3f ms %9.1f objects" % [key, results[key][:seconds] * 1000, allocated]
    end
  end
end

if (output = ENV["BENCHMARK_JSON"])
  File.write(output, JSON.pretty_generate(ruby: RUBY_DESCRIPTION, width: width, iterations: iterations, results: results))
end
