# frozen_string_literal: true

require "json"
require File.expand_path("schemurai", ENV.fetch("JSON_SCHEMA_VALIDATOR_LIB", File.expand_path("../lib", __dir__)))

size = Integer(ENV.fetch("BENCHMARK_SIZE", "2000"))
iterations = Integer(ENV.fetch("BENCHMARK_ITERATIONS", "5"))
raise ArgumentError, "size must be at least 2 and iterations positive" unless size >= 2 && iterations.positive?

numbers = Array.new(size) { |index| index }
objects = numbers.map { |index| {"id" => index, "nested" => [index, {"active" => true}]} }
cases = {
  "numbers/unique" => [numbers, true],
  "numbers/duplicate-at-end" => [numbers + [numbers.last.to_f], false],
  "objects/unique" => [objects, true],
  "objects/duplicate-at-end" => [objects + [{"nested" => [numbers.last.to_f, {"active" => true}], "id" => numbers.last.to_f}], false]
}
results = {}
puts "Ruby #{RUBY_VERSION}; size=#{size}; iterations=#{iterations} (median seconds/call)"
[:ruby, :vm].each do |backend|
  validator = Schemurai.compile({"uniqueItems" => true}, backend: backend)
  [:valid?, :validate].each do |method|
    cases.each do |name, (instance, expected)|
      run = -> { (method == :validate) ? validator.validate(instance).valid? : validator.valid?(instance) }
      raise "incorrect result: #{backend}/#{method}/#{name}" unless run.call == expected

      samples = Array.new(iterations) do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        run.call
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      end.sort
      seconds = samples.fetch(iterations / 2)
      key = "#{backend}/#{method}/#{name}"
      results[key] = seconds
      puts "%s: %.6f" % [key, seconds]
    end
  end
end
File.write(ENV.fetch("BENCHMARK_JSON"), JSON.pretty_generate({size: size, iterations: iterations, results: results})) if ENV["BENCHMARK_JSON"]
