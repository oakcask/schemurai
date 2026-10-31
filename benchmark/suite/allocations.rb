# frozen_string_literal: true

require "base64"
require "json"

root = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(ENV.fetch("JSON_SCHEMA_VALIDATOR_LIB", File.join(root, "lib")))

require "schemurai"

suite_root = File.join(root, "references", "JSON-Schema-Test-Suite")
remote_root = File.join(suite_root, "remotes")
remotes = Dir[File.join(remote_root, "**", "*.json")].to_h do |file|
  relative = file.delete_prefix("#{remote_root}/")
  ["http://localhost:1234/#{relative}", JSON.parse(File.read(file))]
end

draft = ENV.fetch("BENCHMARK_DRAFT", "draft7")
drafts = %w[draft7 draft2019-09 draft2020-12]
raise "BENCHMARK_DRAFT must be one of: #{drafts.join(", ")}" unless drafts.include?(draft)

mode = ENV.fetch("BENCHMARK_MODE", "all")
modes = %w[all content format]
raise "BENCHMARK_MODE must be one of: #{modes.join(", ")}" unless modes.include?(mode)

test_root = File.join(suite_root, "tests", draft)
files = case mode
when "all"
  Dir[File.join(test_root, "*.json")] + Dir[File.join(test_root, "optional", "*.json")]
when "content"
  candidates = [File.join(test_root, "content.json"), File.join(test_root, "optional", "content.json")]
  [candidates.find { |file| File.file?(file) } || raise("content tests unavailable for #{draft}")]
when "format"
  formats = %w[date time date-time duration ipv4 ipv6 uuid json-pointer relative-json-pointer]
  formats.map { |format| File.join(test_root, "optional", "format", "#{format}.json") }.select do |file|
    File.file?(file)
  end
end

groups = files.sort.flat_map do |file|
  content = mode == "content" || (mode == "all" && file.include?("/optional/"))
  JSON.parse(File.read(file)).map do |group|
    schema = group.fetch("schema")
    tests = if mode == "content"
      group.fetch("tests").map do |test|
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
    else
      group.fetch("tests")
    end
    {
      schema: schema,
      tests: tests,
      content: content,
      format: mode == "format"
    }
  end
end

def build(groups, remotes)
  registry = Schemurai::SchemaRegistry.new(schemas: remotes)
  groups.map do |group|
    group.merge(
      validator: registry.compile(
        group.fetch(:schema),
        content: group.fetch(:content),
        format: group.fetch(:format)
      )
    )
  end
end

def validate_all(compiled)
  compiled.each do |group|
    validator = group.fetch(:validator)
    group.fetch(:tests).each { |test| validator.valid?(test.fetch("data")) }
  end
end

def allocations(iterations)
  GC.start
  before = GC.stat(:total_allocated_objects)
  iterations.times { yield }
  GC.stat(:total_allocated_objects) - before
end

iterations = Integer(ENV.fetch("BENCHMARK_ITERATIONS", "20"))
compiled = build(groups, remotes)
wrong = compiled.sum do |group|
  group.fetch(:tests).count do |test|
    group.fetch(:validator).valid?(test.fetch("data")) != test.fetch("valid")
  end
end
raise "validator produced #{wrong} wrong results" unless wrong.zero?

validate_all(compiled)

measurements = {
  "lib build" => allocations(iterations) { build(groups, remotes) },
  "lib suite" => allocations(iterations) { validate_all(build(groups, remotes)) },
  "lib validate" => allocations(iterations) { validate_all(compiled) }
}

puts "JSON-Schema-Test-Suite #{draft} #{mode} allocations"
puts "#{groups.length} schemas, #{groups.sum { |group| group.fetch(:tests).length }} validation cases"
puts "#{iterations} iterations"
measurements.each do |name, total|
  puts "%12s %10.1f objects/iteration (%d total)" % [name, total.fdiv(iterations), total]
end
