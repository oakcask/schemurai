# frozen_string_literal: true

require "benchmark/ips"
require "json"

root = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(ENV.fetch("JSON_SCHEMA_VALIDATOR_LIB", File.join(root, "lib")))

require "schemurai"

suite = File.join(
  root,
  "references",
  "JSON-Schema-Test-Suite",
  "tests",
  "draft2020-12",
  "optional",
  "format"
)
formats = %w[
  date
  time
  date-time
  duration
  ipv4
  ipv6
  uuid
  json-pointer
  relative-json-pointer
]
selected_format = ENV["BENCHMARK_FORMAT"]
if selected_format
  raise "BENCHMARK_FORMAT must be one of: #{formats.join(", ")}" unless formats.include?(selected_format)

  formats = [selected_format]
end
groups = formats.flat_map do |format|
  file = File.join(suite, "#{format}.json")
  JSON.parse(File.read(file)).map do |group|
    {
      format: format,
      name: "#{format}.json: #{group.fetch("description")}",
      schema: group.fetch("schema"),
      tests: group.fetch("tests")
    }
  end
end
official_cases = groups.sum { |group| group.fetch(:tests).length }
official_cases_by_format = groups.group_by { |group| group.fetch(:format) }.transform_values do |format_groups|
  format_groups.sum { |group| group.fetch(:tests).length }
end

def build(groups)
  registry = Schemurai::SchemaRegistry.new
  groups.map do |group|
    group.merge(validator: registry.compile(group.fetch(:schema), format: true))
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

groups_by_format = groups.group_by { |group| group.fetch(:format) }
compiled_by_format = compiled.group_by { |group| group.fetch(:format) }

puts "JSON-Schema-Test-Suite Draft 2020-12 supported formats"
puts "#{groups.length} schemas, #{official_cases} validation cases"
formats.each do |format|
  format_groups = groups_by_format.fetch(format)
  format_cases = format_groups.sum { |group| group.fetch(:tests).length }
  puts "  #{format}: #{format_cases}/#{official_cases_by_format.fetch(format)} cases"
end

time = Float(ENV.fetch("BENCHMARK_TIME", "5"))
warmup = Float(ENV.fetch("BENCHMARK_WARMUP", "2"))
only = ENV["BENCHMARK_ONLY"]

if only.nil? || only == "build"
  formats.each do |format|
    Benchmark.ips do |benchmark|
      benchmark.config(time: time, warmup: warmup)
      benchmark.report("lib #{format} build") { build(groups_by_format.fetch(format)) }
    end
  end
end

if only.nil? || only == "suite"
  formats.each do |format|
    Benchmark.ips do |benchmark|
      benchmark.config(time: time, warmup: warmup)
      benchmark.report("lib #{format} suite") do
        validate_all(build(groups_by_format.fetch(format)))
      end
    end
  end
end

if only.nil? || only == "validate"
  formats.each do |format|
    Benchmark.ips do |benchmark|
      benchmark.config(time: time, warmup: warmup)
      benchmark.report("lib #{format} validate") { validate_all(compiled_by_format.fetch(format)) }
    end
  end
end
