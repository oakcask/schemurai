# frozen_string_literal: true

require_relative "../lib/schemurai"
require "json"

duration = Float(ENV.fetch("MAX_DURATION", "0.001"))
rounds = Integer(ENV.fetch("ROUNDS", "9"))
definitions = {"n0" => false}
1.upto(24) { |i| definitions["n#{i}"] = {"allOf" => Array.new(2) { {"$ref" => "#/$defs/n#{i - 1}"} }} }
workloads = {
  successful: [{"items" => {"type" => "integer"}}, Array.new(2_000_000, 1), [:valid?, :validate]],
  diagnostics: [{"$defs" => definitions, "$ref" => "#/$defs/n24"}, nil, [:validate]]
}
puts JSON.generate(ruby: RUBY_DESCRIPTION, yjit: RubyVM::YJIT.enabled?, max_duration: duration, rounds: rounds)
[:ruby, :vm, :native].each do |backend|
  workloads.each do |workload, (schema, value, methods)|
    validator = Schemurai.compile(schema, backend: backend, limits: {max_duration: duration})
    methods.each do |method|
      samples = Array.new(rounds) do
        GC.start
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          validator.public_send(method, value)
          raise "workload completed before deadline; lower MAX_DURATION"
        rescue Schemurai::LimitExceeded => error
          raise unless error.limit == :max_duration
        end
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000_000
      end
      puts JSON.generate(backend: backend, workload: workload, method: method,
        microseconds: samples.sort[rounds / 2].round(3), max_microseconds: samples.max.round(3),
        samples: samples.map { |sample| sample.round(3) })
    end
  end
end
