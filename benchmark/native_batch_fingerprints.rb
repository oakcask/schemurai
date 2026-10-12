# frozen_string_literal: true

require_relative "../lib/schemurai"
require "json"

$stdout.sync = true
puts RUBY_DESCRIPTION
unique = Schemurai.compile({"uniqueItems" => true}, backend: :native)
program = unique.instance_variable_get(:@evaluator).instance_variable_get(:@program)
[64, 256, 1024].each do |count|
  [64, 1024].each do |width|
    shared = Array.new(width) { |i| [i, "value#{i}"] }
    values = Array.new(count) { |i| [i, shared] }
    raise "native coverage" unless program.valid?(values)
    {"unique" => -> { program.valid?(values) }}.each do |mode, operation|
      samples = Array.new(7) do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        operation.call
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000_000
      end
      puts JSON.generate(mode: mode, count: count, width: width, microseconds: samples.sort[3].round(3))
    end
  end
end

# Unshared small records should retain the cheap shallow traversal.
[64, 1024].each do |count|
  values = Array.new(count) { |i| [i, [i, i + 1]] }
  raise "native coverage" unless program.valid?(values)
  samples = Array.new(7) do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    100.times { program.valid?(values) }
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 10_000
  end
  puts JSON.generate(mode: "unshared", count: count, microseconds: samples.sort[3].round(3))
end
