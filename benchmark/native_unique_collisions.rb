# frozen_string_literal: true

require_relative "../lib/schemurai"
require "json"

# Invert the native scalar mixer to produce distinct fingerprints sharing
# their low 16 bits. Every generated input fits CRuby's signed immediate range.
mask = (1 << 64) - 1
unshift = lambda do |word, shift|
  result = word
  shift.step(63, shift) { |at| result ^= word >> at }
  result
end
values = []
candidate = 1
while values.length < 8192
  word = unshift.call(candidate << 16, 31)
  word = unshift.call((word * 0x319642b2d24d8ec3) & mask, 27)
  word = unshift.call((word * 0x96de1b173f119089) & mask, 30) ^ 16
  word -= 1 << 64 if word >= 1 << 63
  values << word if word.between?(-(1 << 62), (1 << 62) - 1)
  candidate += 1
end
native = Schemurai.compile({"uniqueItems" => true}, backend: :native)
program = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
puts RUBY_DESCRIPTION
[1024, 2048, 4096, 8192].each do |size|
  input = values.first(size)
  raise "native coverage" unless program.valid?(input) == true && program.diagnostics(input) == []

  samples = Array.new(7) do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    5.times { program.valid?(input) }
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 200_000
  end
  puts JSON.generate(size: size, microseconds: samples.sort[3].round(3))
end
