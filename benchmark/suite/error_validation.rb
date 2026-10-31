# frozen_string_literal: true

require "benchmark/ips"
require "json"
require_relative "../fixtures/large_errors"

root = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(ENV.fetch("JSON_SCHEMA_VALIDATOR_LIB", File.join(root, "lib")))

require "schemurai"

suite_root = File.join(root, "references", "JSON-Schema-Test-Suite")
remote_root = File.join(suite_root, "remotes")
remotes = Dir[File.join(remote_root, "**", "*.json")].to_h do |file|
  relative = file.delete_prefix("#{remote_root}/")
  ["http://localhost:1234/#{relative}", JSON.parse(File.read(file))]
end

required_files = Dir[File.join(suite_root, "tests", "draft2020-12", "*.json")]
optional_files = Dir[File.join(suite_root, "tests", "draft2020-12", "optional", "*.json")]
official_groups = (required_files.sort + optional_files.sort).flat_map do |file|
  content = file.include?("/optional/")
  format = File.basename(file) == "format-assertion.json"
  JSON.parse(File.read(file)).map do |group|
    group.merge("content" => content, "format" => format)
  end
end

width = Integer(ENV.fetch("BENCHMARK_WIDTH", "1000"))
raise "BENCHMARK_WIDTH must be positive" unless width.positive?

large_groups = LargeErrorFixtures.groups(width: width).map do |group|
  group.merge("content" => false, "format" => false)
end

def compile(groups, remotes)
  registry = Schemurai::SchemaRegistry.new(schemas: remotes)
  groups.map do |group|
    validator = registry.compile(
      group.fetch("schema"),
      content: group.fetch("content"),
      format: group.fetch("format")
    )
    [validator, group.fetch("tests")]
  end
end

def validate_all(compiled, detailed:)
  compiled.each do |validator, tests|
    tests.each do |test|
      detailed ? validator.validate(test.fetch("data")) : validator.valid?(test.fetch("data"))
    end
  end
end

def verify(compiled)
  wrong = compiled.sum do |validator, tests|
    tests.count do |test|
      validator.validate(test.fetch("data")).valid? != test.fetch("valid")
    end
  end
  raise "validator produced #{wrong} wrong results" unless wrong.zero?
end

def allocations(iterations)
  GC.start
  before = GC.stat(:total_allocated_objects)
  iterations.times { yield }
  (GC.stat(:total_allocated_objects) - before).fdiv(iterations)
end

official = compile(official_groups, remotes)
large = compile(large_groups, remotes)
verify(official)
verify(large)

workloads = {
  "official validate" => -> { validate_all(official, detailed: true) },
  "large valid?" => -> { validate_all(large, detailed: false) },
  "large validate" => -> { validate_all(large, detailed: true) }
}

allocation_iterations = Integer(ENV.fetch("BENCHMARK_ITERATIONS", "100"))
raise "BENCHMARK_ITERATIONS must be positive" unless allocation_iterations.positive?

puts "Detailed error validation"
puts "#{official_groups.length} official schemas, #{official_groups.sum { |group| group.fetch("tests").length }} cases"
puts "#{large_groups.length} large schemas, #{large_groups.sum { |group| group.fetch("tests").length }} cases, width #{width}"
puts "Allocated objects per workload (#{allocation_iterations} iterations)"
workloads.each do |name, workload|
  puts "%17s %10.1f" % [name, allocations(allocation_iterations, &workload)]
end

time = Float(ENV.fetch("BENCHMARK_TIME", "5"))
warmup = Float(ENV.fetch("BENCHMARK_WARMUP", "2"))

Benchmark.ips do |benchmark|
  benchmark.config(time: time, warmup: warmup)
  workloads.each { |name, workload| benchmark.report(name, &workload) }
end
