# frozen_string_literal: true

module SchemuraiBenchmark
  module RealWorld
    # Reviewed contracts for these builders, independent of backend verdicts.
    # Every selected field excludes null and booleans. Public diagnostics can
    # collapse the leaf failure into the enclosing applicator's error.
    class DestructiveMutator
      def initialize(source, seed:)
        @source = source
        @random = Random.new(seed)
      end

      def mutate(index)
        at(@random.rand(@source.faults.length), replacement: [nil, false, true].fetch(@random.rand(3)),
          id: "#{@source.id}/destruction=#{index}")
      end

      def at(position, replacement:, id:)
        raise ArgumentError, "destructive replacements must be null or boolean" unless [nil, false, true].include?(replacement)

        corpus = Corpus.new
        path = @source.faults.fetch(position)
        before = path.reduce(@source.instance) { |value, key| value.fetch(key) }
        value = corpus.copy(@source.instance)
        corpus.replace(value, path, replacement)
        name = @source.id.split("/").first
        expected_error, allowed_types = contract(name, path, before)
        mutation = {"operation" => "replace", "path" => path, "instance_path" => pointer(path),
                    "before" => corpus.copy(before), "after" => replacement,
                    "rule" => {"keyword" => "type", "allowed_types" => allowed_types}}
        Case.new(id, @source.schema, value, false, [], mutation, [expected_error])
      end

      private def pointer(path)
        path.map { |token| "/#{token.to_s.gsub("~", "~0").gsub("/", "~1")}" }.join
      end

      private def contract(name, path, before)
        instance_path, schema_path, keyword, allowed_types = case name
        when "github-workflow"
          [pointer(path.first(2)), "/properties/jobs/patternProperties/^[_a-zA-Z][a-zA-Z0-9_-]*$/oneOf", "oneOf", ["string"]]
        when "taskfile"
          [pointer(path.first(2)), "/allOf/0/properties/tasks/$ref/patternProperties/^.*$/anyOf", "anyOf", %w[string object]]
        when "geojson"
          ["", "/oneOf", "oneOf", [before.is_a?(Array) ? "array" : "number"]]
        else
          raise "no destruction contract for #{name}"
        end
        [{"instance_path" => instance_path, "schema_path" => schema_path, "keyword" => keyword}, allowed_types]
      end
    end
  end
end
