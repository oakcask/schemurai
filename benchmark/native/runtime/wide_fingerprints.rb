# frozen_string_literal: true

require_relative "../../../lib/schemurai"
require "json"

$stdout.sync = true
puts RUBY_DESCRIPTION
[128, 1024, 4096].each do |width|
  numbers = Array.new(width) { |i| 2**4096 + (i << 1100) + 1 }
  # Scalars mixed with Bignums bypass the Big-only adaptive fingerprint path.
  [numbers + ["other"], numbers.map { |number| {"n" => number} }].each_with_index do |value, shape|
    schema = {"uniqueItems" => true}
    native = Schemurai.compile(schema, backend: :native)
    runner = native.instance_variable_get(:@evaluator).instance_variable_get(:@program)
    vm = Schemurai.compile(schema, backend: :vm)
    sample = value.first(32)
    raise "VM parity" unless native.valid?(sample) == vm.valid?(sample) &&
      native.validate(sample).errors == vm.validate(sample).errors

    results = [:valid?, :diagnostics].to_h do |method|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = runner.public_send(method, value)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      raise "native coverage" unless (method == :valid?) ? result == true : result&.empty?

      [method, (elapsed * 1000).round(3)]
    end
    puts JSON.generate(width: width, shape: shape.zero? ? "mixed" : "nested", milliseconds: results)
  end
end
