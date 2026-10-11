# frozen_string_literal: true

require_relative "../lib/schemurai"
require "json"

$stdout.sync = true
puts RUBY_DESCRIPTION
[:scalar, :object].each do |shape|
  [1, 2].each do |names|
    [8, 12, 16].each do |depth|
      dialect = {"$schema" => "https://json-schema.org/draft/2020-12/schema"}
      definitions = names.times.to_h { |i| ["target#{i}", {"$dynamicAnchor" => "target#{i}", "type" => "integer", "minimum" => 1}] }
      definitions["d0"] = {"allOf" => names.times.map { |i| {"$dynamicRef" => "#target#{i}"} }}
      1.upto(depth) { |i| definitions["d#{i}"] = {"allOf" => Array.new(2) { {"$ref" => "#/$defs/d#{i - 1}"} }} }
      resources = {"urn:body" => dialect.merge("$id" => "urn:body", "$defs" => definitions, "$ref" => "#/$defs/d#{depth}")}
      value = (shape == :scalar) ? 0 : {}
      %w[a b].each_with_index do |name, branch|
        targets = names.times.to_h do |i|
          leaf = if shape == :scalar
            {"type" => "integer", "minimum" => -branch}
          else
            value["#{name}#{i}"] = 0
            {"properties" => {"#{name}#{i}" => {"type" => "integer"}}}
          end
          ["target#{i}", leaf.merge("$dynamicAnchor" => "target#{i}")]
        end
        resources["urn:#{name}"] = dialect.merge("$id" => "urn:#{name}", "$defs" => targets, "$ref" => "urn:body")
      end
      root = dialect.merge("allOf" => [{"$ref" => "urn:a"}, {"$ref" => "urn:b"}])
      root["unevaluatedProperties"] = false if shape == :object
      native = Schemurai.compile(root, schemas: resources, backend: :native)
      vm = Schemurai.compile(root, schemas: resources, backend: :vm)
      runner = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
      raise "VM parity" unless vm.valid?(value) && native.validate(value).errors == vm.validate(value).errors

      results = [:valid?, :diagnostics].to_h do |method|
        samples = Array.new(7) do
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          result = runner.public_send(method, value)
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
          raise "native coverage" unless (method == :valid?) ? result == true : result&.empty?

          elapsed * 1_000_000
        end
        [method, samples.sort[3].round(3)]
      end
      puts JSON.generate(shape: shape, names: names, depth: depth, microseconds: results)
    end
  end
end
