# frozen_string_literal: true

# A sustained, native-only run for external CPU sampling. Compilation and the
# initial coverage check finish before the timed validation loop starts.
require "schemurai"
require "base64"

duration = Float(ENV.fetch("PROFILE_SECONDS", "12"))
abort "PROFILE_SECONDS must be positive and finite" unless duration.positive? && duration.finite?
schema, values = case ENV.fetch("PROFILE_WORKLOAD", "pattern")
when "pattern"
  [{"type" => "array", "items" => {
    "type" => "object", "properties" => {
      "name" => {"type" => "string", "pattern" => "^record[0-9]+$"}
    }, "required" => ["name"], "additionalProperties" => false
  }}, Array.new(1000) { |i| {"name" => "record#{i}"} }]
when "content"
  encoded = Base64.strict_encode64('{"name":"' + "x" * 4096 + '"}')
  [{"type" => "array", "items" => {"type" => "string", "contentEncoding" => "base64", "contentMediaType" => "application/json"}}, Array.new(1000, encoded)]
when "unique"
  values = Array.new(1000) { |i| 2**200 + i }.shuffle(random: Random.new(9571))
  [{"type" => "array", "uniqueItems" => true}, values]
when "record"
  [{"type" => "array", "items" => {
    "type" => "object", "properties" => {"id" => {"type" => "integer", "minimum" => 1}, "name" => {"type" => "string", "minLength" => 1}},
    "required" => %w[id name], "additionalProperties" => false
  }}, Array.new(1000) { |i| {"id" => i + 1, "name" => "record"} }]
else
  abort "PROFILE_WORKLOAD must be pattern, content, unique or record"
end
validator = Schemurai.compile(schema, backend: :native, content: true)
program = validator.instance_variable_get(:@evaluator).instance_variable_get(:@program)
abort "unsupported native workload" unless program.valid?(values) == true
1000.times { program.valid?(values) }
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
count = 0
while Process.clock_gettime(Process::CLOCK_MONOTONIC) - started < duration
  1000.times { raise "unexpected native verdict" unless program.valid?(values) == true }
  count += 1000
end
puts "#{count} native validations"
