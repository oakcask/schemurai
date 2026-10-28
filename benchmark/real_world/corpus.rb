# frozen_string_literal: true

require "digest"
require "json"

module SchemuraiBenchmark
  module RealWorld
    Case = Data.define(:id, :schema, :instance, :expected)

    # Immutable upstream schemas; inputs are synthetic, never harvested user data.
    class Corpus
      ROOT = __dir__

      def entries
        @entries ||= Dir[File.join(ROOT, "schemas", "*", "source.json")].sort.map do |source|
          entry = JSON.parse(File.read(source))
          directory = File.dirname(source)
          receipt_file = File.join(directory, "receipt.json")
          unless File.file?(receipt_file)
            raise "run ruby script/fetch-real-world-schemas before using the corpus"
          end
          receipt = JSON.parse(File.read(receipt_file))
          raise "stale schema: #{entry.fetch("id")}; rerun the fetch script" unless receipt.fetch("source") == entry

          bytes = File.binread(File.join(directory, "schema.json"))
          raise "schema checksum mismatch: #{entry.fetch("id")}" unless Digest::SHA256.hexdigest(bytes) == receipt.fetch("sha256")

          entry.merge("provenance" => entry.fetch("schema"), "schema" => JSON.parse(bytes), "sha256" => receipt.fetch("sha256"))
        end
      end

      def cases(seed:, size:)
        raise ArgumentError, "size must be positive" unless size.positive?

        random = Random.new(seed)
        entries.flat_map do |entry|
          name = entry.fetch("id")
          instance, failure_paths = public_send(name.tr("-", "_"), random, size)
          prefix = "#{name}/seed=#{seed}/size=#{size}"
          valid = Case.new("#{prefix}/valid", entry.fetch("schema"), instance, true)
          invalid = failure_paths.each_with_index.map do |path, index|
            value = copy(instance)
            replace(value, path, false)
            Case.new("#{prefix}/invalid-position=#{index}", entry.fetch("schema"), value, false)
          end
          representations = %w[shared copied].map do |mode|
            Case.new("#{prefix}/#{mode}", entry.fetch("schema"), representation(instance, name, mode), true)
          end
          [valid, *representations, *invalid]
        end
      end

      def github_workflow(random, size)
        steps = Array.new(size) do |index|
          if random.rand(2).zero?
            {"name" => "step #{index}", "run" => "echo #{random.rand(10_000)}", "env" => {"MODE" => "test"}}
          else
            {"uses" => "actions/checkout@v4", "with" => {"fetch-depth" => random.rand(1..10)}}
          end
        end
        instance = {"name" => "generated", "on" => ["push", "pull_request"],
                    "jobs" => {"build" => {"runs-on" => "ubuntu-latest", "steps" => steps}}}
        paths = positions(size).map do |index|
          ["jobs", "build", "steps", index, steps.fetch(index).key?("run") ? "run" : "uses"]
        end
        [instance, paths]
      end

      def taskfile(random, size)
        tasks = size.times.to_h do |index|
          command = random.rand(2).zero? ? "echo #{random.rand(10_000)}" : {"task" => "helper", "vars" => {"COUNT" => index}}
          ["task_#{index}", {"cmds" => [command], "desc" => "generated #{index}", "silent" => random.rand(2).zero?}]
        end
        [{"version" => "3", "tasks" => tasks}, positions(size).map { |index| ["tasks", "task_#{index}", "cmds", 0] }]
      end

      def geojson(random, size)
        features = Array.new(size) do |index|
          point = [random.rand(-180.0..180.0), random.rand(-90.0..90.0)]
          geometry = if random.rand(2).zero?
            {"type" => "Point", "coordinates" => point}
          else
            {"type" => "LineString", "coordinates" => [point, [point[0] + 0.01, point[1] + 0.01]]}
          end
          {"type" => "Feature", "geometry" => geometry, "properties" => {"id" => index, "label" => "地点 #{index}"}}
        end
        [{"type" => "FeatureCollection", "features" => features},
          positions(size).map { |index| ["features", index, "geometry", "coordinates", 0] }]
      end

      def copy(value)
        Marshal.load(Marshal.dump(value))
      end

      def representation(instance, name, mode)
        value = copy(instance)
        collection = case name
        when "github-workflow" then value.fetch("jobs").fetch("build").fetch("steps")
        when "taskfile" then value.fetch("tasks")
        when "geojson" then value.fetch("features")
        end
        first = collection.is_a?(Hash) ? collection.values.first : collection.first
        collection.each_with_index do |item, index|
          key = collection.is_a?(Hash) ? item.first : index
          collection[key] = (mode == "shared") ? first : copy(first)
        end
        value
      end

      def replace(value, path, replacement)
        parent = path[0...-1].reduce(value) { |node, key| node.fetch(key) }
        parent[path.last] = replacement
      end

      private def positions(size)
        [0, size / 2, size - 1].uniq
      end
    end
  end
end
