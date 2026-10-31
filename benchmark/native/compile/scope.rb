# frozen_string_literal: true

# Time native construction from cached VM programs. GC is outside timing.
require_relative "../../../lib/schemurai"
require "json"
require "objspace"

Schemurai.compile(true, backend: :native)
program_class = Schemurai.const_get(:Native)::Program
$stdout.sync = true
puts RUBY_DESCRIPTION
{"single" => [128, 512, 2048, 8192], "sparse" => [32, 128, 512, 1024, 2048]}.each do |mode, widths|
  next if ENV["MODE"] && ENV.fetch("MODE") != mode

  widths.each do |width|
    next if ENV["WIDTH"] && Integer(ENV.fetch("WIDTH")) != width

    dialect = {"$schema" => "https://json-schema.org/draft/2020-12/schema"}
    resources = if mode == "single"
      {"urn:body" => dialect.merge("$id" => "urn:body", "$defs" => {"value" => {"$dynamicAnchor" => "value", "type" => "integer"}},
        "$dynamicRef" => "#value")}
    else
      {}
    end
    width.times do |i|
      name = (mode == "single") ? "value" : "value#{i}"
      leaf = {"$dynamicAnchor" => name, "type" => "integer", "minimum" => i}
      ref = (mode == "single") ? {"$ref" => "urn:body"} : {"$dynamicRef" => "##{name}"}
      resources["urn:r#{i}"] = dialect.merge("$id" => "urn:r#{i}", "$defs" => {name => leaf}).merge(ref)
    end
    schema = dialect.merge("allOf" => width.times.map { |i| {"$ref" => "urn:r#{i}"} })
    vm = Schemurai.compile(schema, schemas: resources, backend: :vm)
    evaluator = vm.instance_variable_get(:@evaluator)
    root = evaluator.instance_variable_get(:@root)
    compiler = evaluator.instance_variable_get(:@compiler)
    factory = -> { program_class.new(root, compiler, false, false) }
    program = factory.call
    runner = program.runner(root)
    raise "native coverage" unless runner.valid?(width) == true && runner.diagnostics(width)&.empty?
    native = Schemurai.compile(schema, schemas: resources, backend: :native)
    raise "VM parity" unless runner.valid?(width - 2) == vm.valid?(width - 2) &&
      native.validate(width - 2).errors == vm.validate(width - 2).errors

    samples = Array.new(7) do
      GC.start
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      factory.call
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
    end
    puts JSON.generate(mode: mode, width: width, milliseconds: samples.sort[3].round(3),
      reported_program_bytes: ObjectSpace.memsize_of(program))
  end
end
