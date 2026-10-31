# frozen_string_literal: true

require "digest"
require "json"
require_relative "../../lib/schemurai"

SAMPLES = 5
COMPILE_ITERATIONS = 500
VALIDATE_ITERATIONS = 10_000

schema = {
  "type" => "object",
  "required" => ["id", "items"],
  "properties" => {
    "id" => {"type" => "integer", "minimum" => 1},
    "items" => {
      "type" => "array",
      "minItems" => 1,
      "items" => {"type" => "string", "minLength" => 2, "pattern" => "^[a-z]+$"}
    }
  },
  "additionalProperties" => false
}
valid_instance = {"id" => 10, "items" => %w[alpha beta gamma]}
invalid_instance = {"id" => 0, "items" => ["x", "GOOD"], "extra" => true}
validator = Schemurai.compile(schema, backend: :ruby)

correctness = [
  validator.valid?(valid_instance),
  validator.valid?(invalid_instance),
  validator.validate(invalid_instance).errors.map(&:to_h)
]

measure = lambda do |iterations, &block|
  SAMPLES.times.map do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    iterations.times(&block)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    {"seconds" => elapsed, "iterations_per_second" => iterations / elapsed}
  end
end

GC.start
before = GC.stat(:total_allocated_objects)
VALIDATE_ITERATIONS.times do |index|
  validator.valid?(index.even? ? valid_instance : invalid_instance)
end
allocated = GC.stat(:total_allocated_objects) - before

record = {
  "format_version" => 1,
  "backend" => "ruby",
  "ruby_version" => RUBY_VERSION,
  "ruby_description" => RUBY_DESCRIPTION,
  "platform" => RUBY_PLATFORM,
  "yjit" => defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?,
  "configuration" => {
    "samples" => SAMPLES,
    "compile_iterations_per_sample" => COMPILE_ITERATIONS,
    "validation_iterations_per_sample" => VALIDATE_ITERATIONS
  },
  "correctness_sha256" => Digest::SHA256.hexdigest(JSON.generate(correctness)),
  "compile_samples" => measure.call(COMPILE_ITERATIONS) { Schemurai.compile(schema, backend: :ruby) },
  "validation_samples" => measure.call(VALIDATE_ITERATIONS) do |index|
    validator.valid?(index.even? ? valid_instance : invalid_instance)
  end,
  "validation_allocations" => {
    "iterations" => VALIDATE_ITERATIONS,
    "total_allocated_objects" => allocated,
    "objects_per_iteration" => allocated.fdiv(VALIDATE_ITERATIONS)
  }
}

puts JSON.pretty_generate(record)
