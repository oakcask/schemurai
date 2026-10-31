# frozen_string_literal: true

module SchemuraiBenchmark
  def self.configure(benchmark, time:, warmup:)
    benchmark.config(time: time, warmup: warmup)

    output = ENV["BENCHMARK_JSON"]
    return unless output

    benchmark.quiet = true
    benchmark.json!(output)
  end
end
