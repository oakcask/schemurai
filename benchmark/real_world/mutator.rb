# frozen_string_literal: true

require_relative "corpus"

module SchemuraiBenchmark
  module RealWorld
    # Mutate nested positions in successful inputs, using upstream enum/const
    # values and numeric/length boundaries as well as JSON type changes.
    # Mutants deliberately have no assumed verdict: another branch may accept.
    class Mutator
      def initialize(schema, seed:)
        @random = Random.new(seed)
        @values = [nil, true, false, 0, 1, -1, "", "日", [], {}]
        collect(schema)
        @values.uniq!
      end

      def mutate(instance)
        value = Corpus.new.copy(instance)
        paths = []
        visit(value, [], paths)
        path = paths.fetch(@random.rand(paths.length))
        node = path.reduce(value) { |parent, key| parent.fetch(key) }
        case @random.rand(3)
        when 0
          if node.is_a?(Hash) && !node.empty?
            node.delete(node.keys.fetch(@random.rand(node.length)))
            return value
          elsif node.is_a?(Array) && !node.empty?
            node.delete_at(@random.rand(node.length))
            return value
          end
        when 1
          if node.is_a?(Hash)
            node["unexpected_#{@random.rand(100)}"] = false
            return value
          elsif node.is_a?(Array)
            node.insert(@random.rand(node.length + 1), nil)
            return value
          end
        end
        replacement = Corpus.new.copy(@values.fetch(@random.rand(@values.length)))
        return replacement if path.empty?

        Corpus.new.replace(value, path, replacement)
        value
      end

      private def visit(value, path, paths)
        paths << path
        case value
        when Hash
          value.each { |key, child| visit(child, [*path, key], paths) }
        when Array
          value.each_with_index { |child, index| visit(child, [*path, index], paths) }
        end
      end

      private def collect(node)
        case node
        when Hash
          @values.concat(node["enum"]) if node["enum"].is_a?(Array)
          @values << node.fetch("const") if node.key?("const")
          %w[minimum maximum exclusiveMinimum exclusiveMaximum].each do |keyword|
            bound = node[keyword]
            @values.concat([bound - 1, bound, bound + 1]) if bound.is_a?(Numeric)
          end
          %w[minLength maxLength minItems maxItems].each do |keyword|
            bound = node[keyword]
            next unless bound.is_a?(Integer) && bound.between?(0, 256)

            [bound - 1, bound, bound + 1].select { |length| length >= 0 }.each do |length|
              @values << (keyword.end_with?("Length") ? "x" * length : Array.new(length, 0))
            end
          end
          node.each_value { |child| collect(child) }
        when Array
          node.each { |child| collect(child) }
        end
      end
    end
  end
end
