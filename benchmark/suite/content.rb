# frozen_string_literal: true

require "base64"
require "benchmark/ips"
require "json"

root = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(ENV.fetch("JSON_SCHEMA_VALIDATOR_LIB", File.join(root, "lib")))

require "schemurai"

draft = ENV.fetch("BENCHMARK_DRAFT", "draft2020-12")
drafts = %w[draft7 draft2019-09 draft2020-12]
raise "BENCHMARK_DRAFT must be one of: #{drafts.join(", ")}" unless drafts.include?(draft)

test_root = File.join(root, "references", "JSON-Schema-Test-Suite", "tests", draft)
candidates = [File.join(test_root, "content.json"), File.join(test_root, "optional", "content.json")]
file = candidates.find { |candidate| File.file?(candidate) }
raise "content tests unavailable for #{draft}" unless file

groups = JSON.parse(File.read(file)).map do |group|
  schema = group.fetch("schema")
  tests = group.fetch("tests").map do |test|
    data = test.fetch("data")
    valid = true
    if data.is_a?(String)
      begin
        decoded = (schema["contentEncoding"] == "base64") ? Base64.strict_decode64(data) : data
        JSON.parse(decoded) if schema["contentMediaType"] == "application/json"
      rescue ArgumentError, JSON::ParserError
        valid = false
      end
    end
    test.merge("valid" => valid)
  end
  {schema: schema, tests: tests}
end

def build(groups)
  registry = Schemurai::SchemaRegistry.new
  groups.map do |group|
    group.merge(validator: registry.compile(group.fetch(:schema), content: true))
  end
end

def validate_all(compiled)
  compiled.each do |group|
    validator = group.fetch(:validator)
    group.fetch(:tests).each { |test| validator.valid?(test.fetch("data")) }
  end
end

compiled = build(groups)
wrong = compiled.sum do |group|
  group.fetch(:tests).count do |test|
    group.fetch(:validator).valid?(test.fetch("data")) != test.fetch("valid")
  end
end
raise "validator produced #{wrong} wrong results" unless wrong.zero?

puts "JSON-Schema-Test-Suite #{draft} opt-in content assertions"
puts "#{groups.length} schemas, #{groups.sum { |group| group.fetch(:tests).length }} validation cases"

time = Float(ENV.fetch("BENCHMARK_TIME", "5"))
warmup = Float(ENV.fetch("BENCHMARK_WARMUP", "2"))
only = ENV["BENCHMARK_ONLY"]

Benchmark.ips do |benchmark|
  benchmark.config(time: time, warmup: warmup)
  benchmark.report("lib build") { build(groups) } if only.nil? || only == "build"
  benchmark.report("lib suite") { validate_all(build(groups)) } if only.nil? || only == "suite"
  benchmark.report("lib validate") { validate_all(compiled) } if only.nil? || only == "validate"
end
