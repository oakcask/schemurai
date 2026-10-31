# frozen_string_literal: true

require_relative "../lib/schemurai"
require "base64"
require "json"
require "objspace"

$stdout.sync = true
width = Integer(ENV.fetch("BENCHMARK_WIDTH", "1000"))
iterations = Integer(ENV.fetch("BENCHMARK_ITERATIONS", "15"))
batch = Integer(ENV.fetch("BENCHMARK_BATCH", "30"))
lengths = ENV.fetch("BENCHMARK_LENGTHS", "128,256,257,384,385,4096,8192,8193,16384").split(",").map { |value| Integer(value) }
shape = ENV.fetch("BENCHMARK_SHAPE", "string")
cold = ENV["BENCHMARK_COLD"] == "1"
clock_name = ENV.fetch("BENCHMARK_CLOCK", "wall")
clock = case clock_name
when "wall" then Process::CLOCK_MONOTONIC
when "cpu" then Process::CLOCK_THREAD_CPUTIME_ID
else abort "BENCHMARK_CLOCK must be wall or cpu"
end
abort "benchmark settings must be positive" unless [width, iterations, batch].all?(&:positive?)
abort "decoded JSON strings need at least two bytes" unless lengths.all? { |length| length >= 2 }
rule = {"contentEncoding" => "base64", "contentMediaType" => "application/json"}
schema = {"items" => rule}
vm = Schemurai.compile(schema, content: true, backend: :vm)
native = Schemurai.compile(schema, content: true, backend: :native)
evaluator = native.instance_variable_get(:@evaluator)
program = evaluator.instance_variable_get(:@program)
factory = -> { evaluator.instance_variable_get(:@compiled).runner(evaluator.instance_variable_get(:@root)) }
results = {}
lengths.each do |length|
  json = case shape
  when "string" then '"' + "x" * (length - 2) + '"'
  when "unicode" then '"' + "日" * ((length - 2) / 3) + '"'
  when "numbers" then JSON.generate(Array.new((length - 2) / 2, 0))
  else abort "BENCHMARK_SHAPE must be string, unicode or numbers"
  end
  json += " " * (length - json.bytesize)
  encoded = Base64.strict_encode64(json)
  {"valid" => encoded, "invalid" => Base64.strict_encode64(json.rstrip[0...-1])}.each do |kind, tail|
    values = Array.new(width, encoded)
    values[-1] = tail
    abort "unsupported native content" if program.valid?(values).nil? || program.diagnostics(values).nil?
    abort "different content errors" unless native.validate(values).errors == vm.validate(values).errors
    %i[valid? validate].each do |method|
      100.times { native.public_send(method, values) }
      timed_method = (cold && method == :validate) ? :diagnostics : method
      samples = Array.new(iterations) do
        runners = cold ? Array.new(batch) { factory.call } : Array.new(batch, native)
        GC.start
        started = Process.clock_gettime(clock)
        runners.each { |runner| runner.public_send(timed_method, values) }
        (Process.clock_gettime(clock) - started) / batch
      end
      key = "#{length}/#{kind}/#{method}"
      results[key] = {seconds: samples.sort[iterations / 2], samples: samples, runner_bytes: ObjectSpace.memsize_of(program)}
      puts "#{key}: #{(results.fetch(key).fetch(:seconds) * 1_000_000).round(3)} us"
    end
  end
end
if ENV.key?("BENCHMARK_JSON")
  File.write(ENV.fetch("BENCHMARK_JSON"), JSON.pretty_generate(ruby: RUBY_DESCRIPTION, shape: shape, cold: cold, clock: clock_name, width: width, iterations: iterations, batch: batch, results: results))
end
