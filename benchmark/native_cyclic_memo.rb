# frozen_string_literal: true

require_relative "../lib/schemurai"
require "json"

$stdout.sync = true
puts RUBY_DESCRIPTION
measure = lambda do |mode, size, schema, value|
  native = Schemurai.compile(schema, backend: :native)
  program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
  results = [:valid?, :diagnostics].to_h do |method|
    expected = (method == :valid?) ? true : []
    raise "native coverage" unless program.public_send(method, value) == expected

    samples = Array.new(7) do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      5.times { program.public_send(method, value) }
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 200_000
    end
    [method, samples.sort[3].round(3)]
  end
  puts JSON.generate(mode: mode, size: size, microseconds: results)
end
schemas = {
  "array" => {"$defs" => {"n" => {"anyOf" => [{"type" => "integer"},
    {"type" => "array", "items" => {"$ref" => "#/$defs/n"}}]}}, "$ref" => "#/$defs/n"},
  "object" => {"$defs" => {"n" => {"anyOf" => [{"type" => "integer"},
    {"type" => "object", "properties" => {"a" => {"$ref" => "#/$defs/n"}, "b" => {"$ref" => "#/$defs/n"}}}]}},
               "$ref" => "#/$defs/n"},
  "dynamic" => {"$schema" => "https://json-schema.org/draft/2020-12/schema", "$dynamicAnchor" => "n",
                "anyOf" => [{"type" => "integer"}, {"type" => "array", "items" => {"$dynamicRef" => "#n"}}]},
  "recursive" => {"$schema" => "https://json-schema.org/draft/2019-09/schema", "$recursiveAnchor" => true,
                  "anyOf" => [{"type" => "integer"}, {"type" => "array", "items" => {"$recursiveRef" => "#"}}]}
}
schemas.each do |mode, schema|
  [8, 12, 16, 20].each do |depth|
    value = 8
    depth.times { value = (mode == "object") ? {"a" => value, "b" => value} : [value, value] }
    measure.call(mode, depth, schema, value)
  end
end
[8, 12, 16, 20].each do |depth|
  definitions = {"cycle" => {"$ref" => "#/$defs/cycle"}, "n0" => {"$ref" => "#/$defs/cycle"}}
  1.upto(depth) { |i| definitions["n#{i}"] = {"allOf" => Array.new(2) { {"$ref" => "#/$defs/n#{i - 1}"} }} }
  measure.call("schema", depth, {"$defs" => definitions, "$ref" => "#/$defs/n#{depth}"}, 8)
end
measure.call("distinct-tree", 1000, schemas.fetch("array"), Array.new(1000) { |i| [i, [i]] })
linear = {"$defs" => {"n" => {"type" => "object", "properties" => {
  "value" => {"type" => "integer"}, "next" => {"$ref" => "#/$defs/n"}
}}}, "$ref" => "#/$defs/n"}
value = {"value" => 8}
32.times { value = {"value" => 8, "next" => value} }
measure.call("linear", 32, linear, value)
