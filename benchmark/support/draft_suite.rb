# frozen_string_literal: true

require "benchmark/ips"
require "json"
require_relative "ips"

root = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(ENV.fetch("JSON_SCHEMA_VALIDATOR_LIB", File.join(root, "lib")))

require "schemurai"

module SchemuraiBenchmark
  # Shared loading, correctness checks and measurement for the official suites.
  class DraftSuite
    def initialize(draft:, label:)
      @draft = draft
      @label = label
      suite_root = File.expand_path("../../references/JSON-Schema-Test-Suite", __dir__)
      remote_root = File.join(suite_root, "remotes")
      @remotes = Dir[File.join(remote_root, "**", "*.json")].to_h do |file|
        relative = file.delete_prefix("#{remote_root}/")
        ["http://localhost:1234/#{relative}", JSON.parse(File.read(file))]
      end
      @groups = load_groups(suite_root)
    end

    def run
      compiled = build
      wrong = compiled.sum do |group|
        group.fetch(:tests).count do |test|
          group.fetch(:validator).valid?(test.fetch("data")) != test.fetch("valid")
        end
      end
      raise "validator produced #{wrong} wrong results" unless wrong.zero?

      puts "JSON-Schema-Test-Suite #{@label}"
      puts "#{@groups.length} schemas, #{@groups.sum { |group| group.fetch(:tests).length }} validation cases"

      @time = Float(ENV.fetch("BENCHMARK_TIME", "5"))
      @warmup = Float(ENV.fetch("BENCHMARK_WARMUP", "2"))
      @only = ENV["BENCHMARK_ONLY"]

      measure("build") { build }
      measure("suite") { validate_all(build) }
      measure("validate") { validate_all(compiled) }
    end

    private def load_groups(suite_root)
      required_files = Dir[File.join(suite_root, "tests", @draft, "*.json")]
      optional_files = Dir[File.join(suite_root, "tests", @draft, "optional", "*.json")]
      (required_files.sort + optional_files.sort).flat_map do |file|
        content = file.include?("/optional/")
        format = @draft == "draft2020-12" && File.basename(file) == "format-assertion.json"
        JSON.parse(File.read(file)).map do |group|
          {
            name: "#{File.basename(file)}: #{group.fetch("description")}",
            schema: group.fetch("schema"),
            tests: group.fetch("tests"),
            content: content,
            format: format
          }
        end
      end
    end

    private def build
      registry = Schemurai::SchemaRegistry.new(schemas: @remotes)
      @groups.map do |group|
        group.merge(
          validator: registry.compile(
            group.fetch(:schema),
            content: group.fetch(:content),
            format: group.fetch(:format)
          )
        )
      end
    end

    private def validate_all(compiled)
      compiled.each do |group|
        validator = group.fetch(:validator)
        group.fetch(:tests).each { |test| validator.valid?(test.fetch("data")) }
      end
    end

    private def measure(mode, &workload)
      return unless @only.nil? || @only == mode

      Benchmark.ips do |benchmark|
        SchemuraiBenchmark.configure(benchmark, time: @time, warmup: @warmup)
        benchmark.report("lib #{mode}", &workload)
      end
    end
  end
end
