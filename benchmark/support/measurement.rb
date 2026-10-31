# frozen_string_literal: true

module SchemuraiBenchmark
  module Measurement
    # Keep clocks, GC policy and warmup at the call site when protocols differ.
    # Each block measures one batch and returns seconds per call. The timed
    # workload stays in the runner, without extra per-call dispatch here.
    def self.alternating(iterations:, backends: %i[vm native])
      samples = backends.to_h { |backend| [backend, []] }
      iterations.times do |iteration|
        order = iteration.even? ? backends : backends.reverse
        order.each { |backend| samples.fetch(backend) << yield(backend) }
      end
      samples
    end

    def self.samples(iterations:, batch:, clock:, gc: false, &operation)
      Array.new(iterations) do
        GC.start if gc
        started = Process.clock_gettime(clock)
        batch.times(&operation)
        (Process.clock_gettime(clock) - started) / batch
      end
    end

    # Preserve the existing upper-middle convention for even sample counts.
    def self.median(samples)
      samples.sort.fetch(samples.length / 2)
    end
  end
end
