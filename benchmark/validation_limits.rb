# frozen_string_literal: true

require_relative "../lib/schemurai"
require "json"

baseline = ENV.fetch("BASELINE", "0") == "1"
rounds = Integer(ENV.fetch("ROUNDS", "9"))
batch_seconds = Float(ENV.fetch("BATCH_SECONDS", "0.05"))
puts JSON.generate(ruby: RUBY_DESCRIPTION, yjit: RubyVM::YJIT.enabled?, baseline: baseline,
  rounds: rounds, batch_seconds: batch_seconds)
schema = {"items" => {"type" => "object", "properties" => {"id" => {"type" => "integer"}},
                      "required" => ["id"], "additionalProperties" => false}}
workloads = {
  successful: Array.new(1000) { |i| {"id" => i} },
  failing: Array.new(1000) { {"id" => "invalid"} }
}
caps = {unlimited: nil}
unless baseline
  maxima = {max_errors: 2000, max_output_bytes: 1_000_000, max_evaluations: 10_000_000, max_duration: 10}
  maxima.each { |name, maximum| caps[name] = Schemurai::Limits.new(**{name => maximum}) }
  caps[:all] = Schemurai::Limits.new(**maxima)
end
[:ruby, :vm, :native].each do |backend|
  validator = Schemurai.compile(schema, backend: backend)
  workloads.each do |workload, value|
    expected = validator.validate(value)
    raise "incorrect workload" unless expected.valid? == (workload == :successful)
    raise "incorrect error count" unless expected.errors.length == ((workload == :successful) ? 0 : 1000)
    [:valid?, :validate].each do |method|
      calls = caps.to_h do |name, limits|
        call = if baseline || limits.nil?
          -> { validator.public_send(method, value) }
        else
          -> { validator.public_send(method, value, limits: limits) }
        end
        result = call.call
        correct = (method == :valid?) ? result == expected.valid? : result.errors == expected.errors
        raise "incorrect result for #{backend}/#{workload}/#{method}/#{name}" unless correct
        [name, call]
      end
      iterations = calls.to_h do |name, call|
        10.times { call.call }
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        10.times { call.call }
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        [name, (batch_seconds * 10 / elapsed).ceil.clamp(1, 100_000)]
      end
      samples = calls.to_h { |name, _| [name, []] }
      random = Random.new(189)
      rounds.times do
        calls.keys.shuffle(random: random).each do |name|
          call = calls.fetch(name)
          count = iterations.fetch(name)
          GC.start
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          count.times { call.call }
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
          samples.fetch(name) << elapsed * 1_000_000 / count
        end
      end
      samples.each do |name, timings|
        puts JSON.generate(backend: backend, workload: workload, method: method, limits: name,
          iterations: iterations.fetch(name), microseconds: timings.sort[rounds / 2].round(3),
          samples: timings.map { |sample| sample.round(3) })
      end
    end
  end
end
