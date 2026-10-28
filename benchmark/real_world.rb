# frozen_string_literal: true

require_relative "real_world/checker"

# Keep these cases separate from the official-suite aggregate. Run the same
# script and pinned corpus against each checkout for before/after comparisons.
seed = Integer(ENV.fetch("BENCHMARK_SEED", "9571"))
sizes = ENV.fetch("BENCHMARK_SIZES", "1,8,32").split(",").map { |value| Integer(value) }
iterations = Integer(ENV.fetch("BENCHMARK_ITERATIONS", "5"))
batch = Integer(ENV.fetch("BENCHMARK_BATCH", "3"))
backends = ENV.fetch("BENCHMARK_BACKENDS", "ruby,vm").split(",").map(&:to_sym)
abort "sizes, iterations and batch must be positive" unless [*sizes, iterations, batch].all?(&:positive?)
checker = SchemuraiBenchmark::RealWorld::Checker.new(backends: ([:ruby] + backends).uniq)
corpus = SchemuraiBenchmark::RealWorld::Corpus.new
clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
output = ENV["BENCHMARK_JSON"] ? File.open(ENV.fetch("BENCHMARK_JSON"), "w") : $stdout
output.sync = true
output.puts JSON.generate(kind: "metadata", ruby: RUBY_DESCRIPTION, seed: seed, sizes: sizes,
  iterations: iterations, batch: batch, backends: backends, yjit: RubyVM::YJIT.enabled?,
  schemas: corpus.entries.map { |entry| entry.except("schema") })

measure = lambda do |&work|
  2.times(&work)
  samples = Array.new(iterations) do
    GC.start
    allocations = GC.stat(:total_allocated_objects)
    started = clock.call
    batch.times(&work)
    elapsed = clock.call - started
    {microseconds: elapsed * 1_000_000 / batch,
     ruby_allocations: (GC.stat(:total_allocated_objects) - allocations).fdiv(batch)}
  end
  {microseconds: samples.map { |sample| sample.fetch(:microseconds) }.sort.fetch(iterations / 2), samples: samples}
end

sizes.each do |size|
  cases = corpus.cases(seed: seed, size: size)
  # Verify every expected result and ordered diagnostic before measuring.
  cases.each { |test_case| checker.check(test_case) }
  cases.group_by(&:schema).each_value do |group|
    schema = group.first.schema
    name = group.first.id.split("/").first
    backends.each do |backend|
      output.puts JSON.generate(kind: "compile", corpus: name, size: size, backend: backend,
        **measure.call { Schemurai.compile(schema, backend: backend) })
    end
  end
  cases.shuffle(random: Random.new(seed + size)).each do |test_case|
    checker.validators(test_case.schema).slice(*backends).to_a.shuffle(random: Random.new(seed + size)).each do |backend, validator|
      support = if backend == :native
        program = validator.instance_variable_get(:@evaluator).instance_variable_get(:@program)
        {valid: !program.valid?(test_case.instance).nil?, diagnostics: !program.diagnostics(test_case.instance).nil?}
      end
      errors = validator.validate(test_case.instance).errors.length
      %i[valid? validate].each do |operation|
        result = measure.call { validator.public_send(operation, test_case.instance) }
        output.puts JSON.generate(kind: "validation", id: test_case.id, size: size, backend: backend,
          operation: operation, expected: test_case.expected, errors: errors, native_support: support,
          input_bytes: JSON.generate(test_case.instance).bytesize, **result)
      end
    end
  end
end
output.close unless output.equal?($stdout)
