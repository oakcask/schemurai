# frozen_string_literal: true

require_relative "../lib/schemurai"
require "json"

$stdout.sync = true
puts RUBY_DESCRIPTION
[64, 256, 1024].each do |count|
  [64, 1024].each do |width|
    shared = Array.new(width) { |i| [i, "value#{i}"] }
    schema = {"enum" => Array.new(count) { |i| [i, shared] }}
    samples = Array.new(7) do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Schemurai.compile(schema, backend: :native)
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000_000
    end
    puts JSON.generate(count: count, width: width, microseconds: samples.sort[3].round(3))
  end
end
