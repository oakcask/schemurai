# frozen_string_literal: true

require_relative "../lib/schemurai"
require "json"

$stdout.sync = true
puts RUBY_DESCRIPTION
[4, 8, 12, 16, 24, 32].each do |depth|
  definitions = {"base" => {"$id" => "urn:base", "$dynamicAnchor" => "n", "type" => "integer"},
                 "other" => {"$id" => "urn:other", "$dynamicAnchor" => "n", "minimum" => 0},
                 "d0" => {"$id" => "urn:d0", "$dynamicRef" => "urn:base#n"}}
  1.upto(depth) do |i|
    %w[a b].each do |branch|
      definitions["#{branch}#{i}"] = {"$id" => "urn:#{branch}#{i}", "$dynamicAnchor" => "x#{i}", "$ref" => "urn:d#{i - 1}"}
    end
    definitions["d#{i}"] = {"$id" => "urn:d#{i}", "allOf" => [{"$ref" => "urn:a#{i}"}, {"$ref" => "urn:b#{i}"}]}
  end
  # These siblings register names that the diamond's leaf never references.
  refs = [{"$ref" => "urn:d#{depth}"}, {"$ref" => "urn:other"}] + (1..depth).map { |i| {"$dynamicRef" => "urn:a#{i}#x#{i}"} }
  schema = {"$schema" => "https://json-schema.org/draft/2020-12/schema", "$defs" => definitions, "allOf" => refs}
  native = Schemurai.compile(schema, backend: :native)
  program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
  results = [:valid?, :diagnostics].to_h do |method|
    expected = (method == :valid?) ? true : []
    raise "native coverage" unless program.public_send(method, 8) == expected

    samples = Array.new(7) do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      5.times { program.public_send(method, 8) }
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 200_000
    end
    [method, samples.sort[3].round(3)]
  end
  puts JSON.generate(depth: depth, microseconds: results)
end
