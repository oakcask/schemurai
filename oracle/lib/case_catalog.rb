# frozen_string_literal: true

require "json"

module SchemuraiOracle
  CaseRecord = Data.define(
    :id,
    :dialect,
    :feature,
    :classification,
    :description,
    :schema,
    :instance,
    :expected,
    :options
  )

  class CaseCatalog
    CLASSIFICATIONS = %w[selected skipped pending].freeze

    attr_reader :configuration, :repository_root

    def initialize(repository_root: File.expand_path("../..", __dir__))
      @repository_root = repository_root
      @configuration = JSON.parse(File.read(File.join(repository_root, "oracle/case_catalog.json")))
    end

    def each_case(dialect = nil, &block)
      return enum_for(__method__, dialect) unless block

      dialects = dialect ? {dialect => configuration.fetch("dialects").fetch(dialect)} : configuration.fetch("dialects")
      dialects.each do |name, settings|
        each_group(name, "core", "*.json", "selected", {}) { |record| yield record }
        each_group(name, "content", "optional/*.json", "selected", {"content" => true}) { |record| yield record }
        each_format_group(name, settings) { |record| yield record }
      end
    end

    def fetch(case_id)
      case_index.fetch(case_id) { raise KeyError, "unknown oracle case #{case_id.inspect}" }
    end

    def counts(dialect = nil)
      records = each_case(dialect)
      initial = CLASSIFICATIONS.to_h { |classification| [classification, 0] }
      records.each_with_object(initial) { |record, result| result[record.classification] += 1 }
    end

    def verify_counts!
      configuration.fetch("dialects").each do |dialect, settings|
        actual = counts(dialect).transform_keys(&:to_s)
        expected = settings.fetch("expected_counts")
        next if expected == {"selected" => actual.fetch("selected", 0), "skipped" => actual.fetch("skipped", 0), "pending" => actual.fetch("pending", 0)}

        raise "oracle case count changed for #{dialect}: expected #{expected.inspect}, got #{actual.inspect}"
      end
      true
    end

    def update_counts!
      updated = JSON.parse(JSON.generate(configuration))
      updated.fetch("dialects").each do |dialect, settings|
        actual = counts(dialect)
        raise "official suite is empty for #{dialect}" if actual.fetch("selected").zero?

        settings["expected_counts"] = actual
      end

      path = File.join(repository_root, "oracle/case_catalog.json")
      source = File.read(path)
      counts = updated.fetch("dialects").each_value.map { |settings| settings.fetch("expected_counts") }.each
      # Preserve the catalog's compact arrays and objects; only counts are generated.
      result = source.gsub(/("expected_counts"\s*:\s*)\{[^{}]*\}/) do
        "#{$1}{#{counts.next.map { |key, value| "#{key.to_json}: #{value}" }.join(", ")}}"
      end
      raise "could not update only expected_counts" unless JSON.parse(result) == updated

      File.write(path, result) unless result == source
      configuration.replace(updated)
    end

    def remotes
      return @remotes if defined?(@remotes)

      remote_root = File.join(suite_root, "remotes")
      @remotes = Dir[File.join(remote_root, "**", "*.json")].to_h do |file|
        relative = file.delete_prefix("#{remote_root}/")
        ["http://localhost:1234/#{relative}", JSON.parse(File.read(file))]
      end
    end

    private def each_format_group(dialect, settings)
      pattern = File.join(suite_root, "tests", dialect, "optional", "format", "*.json")
      Dir[pattern].sort.each do |file|
        format = File.basename(file, ".json")
        classification = settings.fetch("enabled_formats").include?(format) ? "selected" : "pending"
        emit_file(dialect, "format", file, classification, {"format" => true}) { |record| yield record }
      end
    end

    private def each_group(dialect, feature, pattern, classification, options)
      files = Dir[File.join(suite_root, "tests", dialect, pattern)].sort
      files.each { |file| emit_file(dialect, feature, file, classification, options) { |record| yield record } }
    end

    private def emit_file(dialect, feature, file, classification, options)
      relative = file.delete_prefix("#{File.join(suite_root, "tests", dialect)}/")
      JSON.parse(File.read(file)).each_with_index do |group, group_index|
        group.fetch("tests").each_with_index do |test, test_index|
          yield CaseRecord.new(
            id: "official:#{dialect}:#{relative}:#{group_index}:#{test_index}",
            dialect: dialect,
            feature: feature,
            classification: classification,
            description: "#{relative}: #{group.fetch("description")} / #{test.fetch("description")}",
            schema: group.fetch("schema"),
            instance: test.fetch("data"),
            expected: test.fetch("valid"),
            options: options
          )
        end
      end
    end

    private def suite_root
      File.join(repository_root, configuration.fetch("suite_root"))
    end

    private def case_index
      @case_index ||= each_case.to_h { |record| [record.id, record] }
    end
  end
end
