# frozen_string_literal: true

# Native traversal only: reuse compiled validators and retain shared Ruby inputs.
require_relative "../../../lib/schemurai"
require "json"

$stdout.sync = true
puts RUBY_DESCRIPTION
native = Schemurai.compile({"uniqueItems" => true}, backend: :native)
program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
measure = lambda do |label, size, validator, values, expected|
  raise "native coverage" unless validator.valid?(values) == expected
  samples = Array.new(7) do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    5.times { validator.valid?(values) }
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 200_000
  end
  puts JSON.generate(mode: label, size: size, microseconds: samples.sort[3].round(3))
end
["array", "object"].each do |shape|
  [8, 12, 16, 20].each do |depth|
    left = right = 0
    depth.times do
      left = (shape == "array") ? [left, 1, left] : {"a" => left, "b" => 1, "c" => left}
      right = (shape == "array") ? [right, 1, right] : {"a" => right, "b" => 1, "c" => right}
    end
    [2, 17].each do |count|
      padding = Array.new(count - 2) { |i| "padding#{i}" }
      values = [*padding, left, right]
      measure.call("#{shape}-#{count}", depth, program, values, false)
    end
  end
end
# Ordinary trees pay cache bookkeeping without sharing. Report this control.
[1, 32, 256].each do |width|
  left = Array.new(width) { |i| [i, {"value" => i}] }
  right = Array.new(width) { |i| [i, {"value" => i}] }
  measure.call("tree", width, program, [left, right], false)
end
