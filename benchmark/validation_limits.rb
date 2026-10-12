# frozen_string_literal: true

require_relative "../lib/schemurai"
require "json"

puts RUBY_DESCRIPTION
schema = {"items" => {"type" => "object", "properties" => {"id" => {"type" => "integer"}},
                      "required" => ["id"], "additionalProperties" => false}}
value = Array.new(1000) { |i| {"id" => i} }
limits = Schemurai::Limits.new(max_errors: 100, max_output_bytes: 65536, max_evaluations: 1_000_000)
[:ruby, :vm, :native].each do |backend|
  validator = Schemurai.compile(schema, backend: backend)
  [:valid?, :validate].each do |method|
    [nil, limits].each do |caps|
      result = validator.public_send(method, value, limits: caps)
      raise "incorrect result" unless (method == :valid?) ? result : result.valid?

      samples = Array.new(7) do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        5.times { validator.public_send(method, value, limits: caps) }
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 200_000
      end
      puts JSON.generate(backend: backend, method: method, limited: !caps.nil?, microseconds: samples.sort[3].round(3))
    end
  end
end
