# frozen_string_literal: true

require_relative "../lib/schemurai"
require "json"

$stdout.sync = true
puts RUBY_DESCRIPTION
measure = lambda do |mode, size, program, value|
  results = [:valid?, :diagnostics].to_h do |method|
    result = program.public_send(method, value)
    expected = (method == :valid?) ? true : []
    raise "native coverage" unless result == expected

    samples = Array.new(7) do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      5.times { program.public_send(method, value) }
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 200_000
    end
    [method, samples.sort[3].round(3)]
  end
  puts JSON.generate(mode: mode, size: size, microseconds: results)
end
%w[items additionalProperties].each do |keyword|
  [8, 12, 16, 20].each do |depth|
    definitions = {"n0" => {"type" => "integer"}}
    value = 0
    1.upto(depth) do |i|
      definitions["n#{i}"] = {keyword => {"$ref" => "#/$defs/n#{i - 1}"}}
      value = (keyword == "items") ? [value, value] : {"x" => value, "y" => value}
    end
    native = Schemurai.compile({"$defs" => definitions, "$ref" => "#/$defs/n#{depth}"}, backend: :native)
    program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
    measure.call(keyword, depth, program, value)
  end
end
# Distinct instance objects pay cache admission without finding shared values.
[false, true].each do |tracked|
  rule = {"$schema" => "https://json-schema.org/draft/2020-12/schema", "items" => {"type" => "object", "properties" => {"id" => {"type" => "integer"}}}}
  rule["unevaluatedItems"] = false if tracked
  native = Schemurai.compile(rule, backend: :native)
  program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
  measure.call("distinct-tracked-#{tracked}", 1000, program, Array.new(1000) { |i| {"id" => i} })
end
