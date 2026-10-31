# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "tmpdir"

module SchemuraiBenchmark
  class Comparison
    DRAFTS = {
      "Draft 2020-12" => "draft2020_12.rb"
    }.freeze
    BACKENDS = %w[ruby vm].freeze
    WORKLOADS = %w[build suite validate].freeze

    Result = Data.define(:backend, :draft, :workload, :baseline_ips, :candidate_ips)

    def initialize(baseline_lib:, baseline_label:, candidate_label:, summary_path:, output: $stdout)
      @baseline_lib = File.expand_path(baseline_lib)
      @baseline_label = baseline_label
      @candidate_label = candidate_label
      @summary_path = summary_path
      @output = output
      @root = File.expand_path("../..", __dir__)
    end

    def run
      results = Dir.mktmpdir("schemurai-benchmark-") do |directory|
        configurations.map do |backend, draft, runner, workload|
          output.puts "Measuring #{backend} / #{draft} / #{workload}"
          output.flush
          baseline_ips = measure(runner, backend, workload, File.join(directory, "baseline.json"), baseline_lib)
          candidate_ips = measure(runner, backend, workload, File.join(directory, "candidate.json"), nil)
          Result.new(backend:, draft:, workload:, baseline_ips:, candidate_ips:)
        end
      end

      File.open(summary_path, "a") { |summary| summary.write(markdown(results)) }
    end

    def markdown(results)
      lines = [
        "## Benchmark comparison",
        "",
        "Compared `#{escape(baseline_label)}` with `#{escape(candidate_label)}`. Higher throughput is better.",
        "",
        "| Backend | Draft | Workload | Base (i/s) | Merge (i/s) | Change |",
        "| --- | --- | --- | ---: | ---: | ---: |"
      ]
      results.each do |result|
        change = (result.candidate_ips.fdiv(result.baseline_ips) - 1) * 100
        lines << "| #{result.backend} | #{result.draft} | #{result.workload} | " \
          "#{format_ips(result.baseline_ips)} | #{format_ips(result.candidate_ips)} | #{format("%+.2f%%", change)} |"
      end
      lines << ""
      lines.join("\n")
    end

    attr_reader :baseline_lib, :baseline_label, :candidate_label, :summary_path, :output, :root
    private :baseline_lib, :baseline_label, :candidate_label, :summary_path, :output, :root

    private def configurations
      BACKENDS.product(DRAFTS.to_a, WORKLOADS).map do |backend, (draft, runner), workload|
        [backend, draft, runner, workload]
      end
    end

    private def measure(runner, backend, workload, result_path, library)
      environment = {
        "BENCHMARK_JSON" => result_path,
        "BENCHMARK_ONLY" => workload,
        "JSON_SCHEMA_VALIDATOR_LIB" => library,
        "SCHEMURAI_BACKEND" => backend
      }
      stdout, stderr, status = Open3.capture3(environment, RbConfig.ruby, File.join("benchmark", "suite", runner), chdir: root)
      raise "benchmark failed:\n#{stdout}#{stderr}" unless status.success?

      JSON.parse(File.read(result_path)).fetch(0).fetch("central_tendency")
    end

    private def format_ips(value)
      integer, decimal = format("%.2f", value).split(".")
      grouped = integer.reverse.scan(/.{1,3}/).join(",").reverse
      "#{grouped}.#{decimal}"
    end

    private def escape(value)
      value.gsub("`", "\\`").gsub("|", "\\|")
    end
  end
end
