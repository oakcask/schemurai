# frozen_string_literal: true

# Time native construction from a cached VM program, excluding schema graph work.
require_relative "../lib/schemurai"
require "json"

Schemurai.compile(true, backend: :native)
program_class = Schemurai.const_get(:Native)::Program
[8, 128, 512, 2048, 4096].each do |width|
  properties = Array.new(width) { |i| ["p#{i}", true] }.to_h
  validator = Schemurai.compile({"properties" => properties, "required" => properties.keys.reverse}, backend: :vm)
  evaluator = validator.instance_variable_get(:@evaluator)
  root = evaluator.instance_variable_get(:@root)
  compiler = evaluator.instance_variable_get(:@compiler)
  factory = -> { program_class.new(root, compiler, false, false) }
  program = factory.call
  instance = properties.keys.to_h { |name| [name, 1] }
  runner = program.runner(root)
  raise "native coverage" unless runner.valid?(instance) && runner.diagnostics(instance)&.empty?
  missing = instance.except(properties.keys.first)
  raise "validity parity" unless runner.valid?(missing) == validator.valid?(missing)
  native = Schemurai.compile({"properties" => properties, "required" => properties.keys.reverse}, backend: :native)
  raise "error parity" unless native.validate(missing).errors == validator.validate(missing).errors
  samples = Array.new(7) do
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    factory.call
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
  end
  puts JSON.generate(label: "native compile properties=required=#{width}", milliseconds: samples.sort[3].round(3))
end
