# frozen_string_literal: true

require "benchmark/ips"

root = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(ENV.fetch("JSON_SCHEMA_VALIDATOR_LIB", File.join(root, "lib")))

require "schemurai"

schema = {
  "$schema" => "https://json-schema.org/draft/2020-12/schema",
  "type" => "object",
  "required" => %w[id name status scores profile],
  "properties" => {
    "id" => {"type" => "integer", "minimum" => 1},
    "name" => {
      "type" => "string",
      "minLength" => 3,
      "maxLength" => 64,
      "pattern" => "^[A-Za-z][A-Za-z0-9_-]+$"
    },
    "status" => {"enum" => %w[active disabled pending]},
    "scores" => {
      "type" => "array",
      "minItems" => 2,
      "maxItems" => 8,
      "items" => {"type" => "number", "minimum" => 0, "maximum" => 100}
    },
    "profile" => {
      "type" => "object",
      "required" => %w[email age],
      "properties" => {
        "email" => {"type" => "string", "minLength" => 3},
        "age" => {"type" => "integer", "minimum" => 0, "maximum" => 150}
      },
      "additionalProperties" => false
    }
  },
  "additionalProperties" => false
}

document_count = Integer(ENV.fetch("BENCHMARK_DOCUMENTS", "1000"))
raise "BENCHMARK_DOCUMENTS must be positive" unless document_count.positive?

documents_with_expected = Array.new(document_count) do |index|
  document = {
    "id" => index + 1,
    "name" => "user_#{index}",
    "status" => %w[active disabled pending][index % 3],
    "scores" => [index % 101, (index + 1) % 101],
    "profile" => {"email" => "user#{index}@example.test", "age" => index % 151}
  }

  valid = case index % 4
  when 1
    document["name"] = "x"
    false
  when 2
    document["scores"][1] = 101
    false
  when 3
    document["unexpected"] = true
    false
  else
    true
  end
  [document, valid]
end
documents = documents_with_expected.map(&:first)
expected = documents_with_expected.map(&:last)

registry = Schemurai::SchemaRegistry.new
validator = registry.compile(schema)
actual = documents.map { |document| validator.valid?(document) }
wrong = actual.zip(expected).count { |result, expected_result| result != expected_result }
raise "validator produced #{wrong} wrong results" unless wrong.zero?

puts "Repeated validation with one compiled Draft 2020-12 schema"
puts "#{document_count} documents (#{expected.count(true)} valid, #{expected.count(false)} invalid)"

time = Float(ENV.fetch("BENCHMARK_TIME", "5"))
warmup = Float(ENV.fetch("BENCHMARK_WARMUP", "2"))

Benchmark.ips do |benchmark|
  benchmark.config(time: time, warmup: warmup)

  index = 0
  benchmark.report("lib validate") do
    validator.valid?(documents[index])
    index += 1
    index = 0 if index == document_count
  end
end
