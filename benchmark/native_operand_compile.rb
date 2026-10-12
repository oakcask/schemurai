# frozen_string_literal: true

require_relative "../lib/schemurai"
require "json"

$stdout.sync = true
puts RUBY_DESCRIPTION
[8, 12, 16, 20].each do |depth|
  value = ["fixed"]
  depth.times { value = [value, value] }
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  Schemurai.compile({"const" => value}, backend: :native)
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  puts JSON.generate(depth: depth, milliseconds: (elapsed * 1000).round(3))
end
