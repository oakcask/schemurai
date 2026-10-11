# frozen_string_literal: true

require "uri"
require_relative "dialects/draft7"
require_relative "dialects/draft2019_09"
require_relative "dialects/draft2020_12"
require_relative "meta_schemas/draft7"
require_relative "meta_schemas/draft2019_09"
require_relative "meta_schemas/draft2020_12"
require_relative "schema_node"
require_relative "schema_domain"

module Schemurai
  module Internal
    class SchemaGraph
      class CompilationChanges
        EMPTY_HASH = {}.freeze
        EMPTY_ARRAY = [].freeze

        attr_reader :nodes
        attr_accessor :requires_dynamic_scope

        def initialize
          @nodes = []
          @requires_dynamic_scope = false
        end

        def resources = @resources || EMPTY_HASH
        def mutable_resources = (@resources ||= {})

        def resource_nodes = @resource_nodes || EMPTY_HASH
        def mutable_resource_nodes = (@resource_nodes ||= {})

        def uri_registry = @uri_registry || EMPTY_HASH
        def mutable_uri_registry = (@uri_registry ||= {})

        def dynamic_anchors = @dynamic_anchors || EMPTY_HASH
        def mutable_dynamic_anchors = (@dynamic_anchors ||= {})

        def custom_dialects = @custom_dialects || EMPTY_HASH
        def mutable_custom_dialects = (@custom_dialects ||= {})

        def document_locations
          @document_locations || EMPTY_ARRAY
        end

        def mutable_document_locations
          @document_locations ||= []
        end
      end

      private_constant :CompilationChanges

      class Resource
        attr_reader :uri, :root
        attr_accessor :dynamic_anchor_count

        def initialize(uri, root)
          @dynamic_anchor_count = 0
          @uri = uri
          @root = root
          @nodes = nil
        end

        def add(node)
          (@nodes ||= {})[node.resource_path] = node unless node.equal?(root)
          node.resource = self unless node.resource.equal?(self)
        end

        def node_at(pointer)
          return root if pointer.empty?

          @nodes&.[](pointer)
        end

        def nodes
          @nodes || EMPTY_NODES
        end

        EMPTY_NODES = {}.freeze
        private_constant :EMPTY_NODES
      end

      attr_reader :resources, :uri_registry, :nodes

      def initialize(schemas: {}, dialect: Dialect.resolve)
        SchemaDomain.validate_registry!(schemas)
        @external_schemas = schemas.dup
        @indexed_external_schemas = nil
        @compiled_roots = {}.compare_by_identity
        @meta_schema_roots = {}
        @resources = {}
        @uri_registry = {}
        @nodes = []
        @nodes_by_document_location = nil
        @resolved_refs = nil
        @dynamic_anchors = {}
        # External schemas are indexed lazily, so their references are not yet
        # available to compile_node. Track conservatively from the caller.
        # Once required, dynamic scope tracking must remain enabled because all
        # evaluators sharing this graph may reach the dynamic reference.
        @dynamic_scope = !schemas.empty?
        @default_dialect = dialect
      end

      def compile(schema, base_uri: nil, dialect: @default_dialect)
        SchemaDomain.validate!(schema)
        roots = (@compiled_roots[schema] ||= {})
        base_uri = base_uri.to_s
        cache_key = [base_uri, dialect]
        root = roots[cache_key]
        return root if root

        roots[cache_key] = compile_atomically do |changes|
          root_dialect = dialect_for(schema, dialect, changes)
          compile_document(schema, base_uri, root_dialect, changes)
        end
      end

      def meta_schema_root(schema)
        SchemaDomain.validate!(schema)
        uri = if schema.is_a?(Hash) && schema.key?("$schema")
          schema["$schema"].to_s
        else
          @default_dialect.uri
        end
        root = (@meta_schema_roots[uri] ||= compile({"$ref" => uri}))
        resolve(root, uri)
        root
      end

      def resolve(node, reference)
        if (resolved = @resolved_refs&.[](node))&.key?(reference)
          return resolved[reference]
        end

        if Ractor.shareable?(self)
          raise ResolutionError, "reference #{reference.inspect} was not resolved before sharing"
        end

        target = resolve_uncached(node, reference)
        ((@resolved_refs ||= {})[node] ||= {})[reference] = target
      end

      def dynamic_anchor(resource, name)
        @dynamic_anchors.dig(resource, name)
      end

      # Anchor tables grow in insertion order, including late external indexing.
      # Native compilation uses this snapshot to avoid absent pair lookups.
      def dynamic_anchor_names(resource)
        @dynamic_anchors[resource]&.keys || []
      end

      def dynamic_scope?
        @dynamic_scope
      end

      def make_shareable
        return self if Ractor.shareable?(self)

        @external_schemas.each_key do |uri|
          index_external(strip_fragment(uri.to_s), @default_dialect)
        end

        index = 0
        while index < nodes.length
          node = nodes[index]
          schema = node.schema
          if schema.is_a?(Hash)
            ["$ref", "$recursiveRef", "$dynamicRef"].each do |keyword|
              resolve(node, schema[keyword]) if schema.key?(keyword)
            end
          end
          index += 1
        end

        @resolved_refs ||= {}
        Ractor.make_shareable(self)
      end

      private def compilation_changes
        CompilationChanges.new
      end

      private def compile_atomically
        changes = compilation_changes
        result = yield changes
        commit(changes)
        result
      end

      private def commit(changes)
        resources.update(changes.resources)
        changes.resource_nodes.each do |resource, resource_nodes|
          resource_nodes.each_value { |node| resource.add(node) }
        end
        uri_registry.update(changes.uri_registry)
        nodes.concat(changes.nodes)
        if @nodes_by_document_location
          changes.document_locations.each do |document_key, schema_path, node|
            (@nodes_by_document_location[document_key] ||= {})[schema_path] = node
          end
        end
        changes.dynamic_anchors.each do |resource, anchors|
          merged = (@dynamic_anchors[resource] ||= {}).update(anchors)
          resource.dynamic_anchor_count = merged.size
        end
        (@custom_dialects ||= {}).update(changes.custom_dialects) unless changes.custom_dialects.empty?
        @dynamic_scope = true if changes.requires_dynamic_scope
      end

      private def resolve_uncached(node, reference)
        uri = absolute_uri(node.base_uri, reference)
        document_uri = strip_fragment(uri)
        index_external(document_uri, node.dialect)

        if (target = uri_registry[uri])
          return target
        end

        resource = if node.resource.uri == document_uri
          node.resource
        else
          resources[document_uri]
        end
        raise ResolutionError, "unresolvable reference #{reference.inspect}" unless resource

        raw_fragment = fragment(uri)
        return resource.root if raw_fragment.empty?

        decoded = URI.decode_uri_component(raw_fragment)
        unless decoded.start_with?("/")
          raise ResolutionError, "unsupported plain-name fragment ##{raw_fragment}"
        end

        pointer = canonical_pointer(decoded)
        return resource.node_at(pointer) if resource.node_at(pointer)

        schema_path = "#{resource.root.schema_path}#{pointer}"
        if (target = node_by_document_location(resource.root.document_key, schema_path))
          return target
        end

        target = pointer_target(resource.root.schema, pointer)
        compile_atomically do |changes|
          compile_node(
            target,
            resource.root.base_uri,
            resource.root.dialect,
            schema_path,
            pointer,
            resource,
            resource.root.document_key,
            changes
          )
        end
      rescue URI::Error
        raise ResolutionError, "unresolvable reference #{reference.inspect}"
      end

      def node_at(uri)
        uri_registry[uri.to_s]
      end

      private def compile_document(schema, retrieval_uri, dialect, changes)
        document_key = retrieval_uri.empty? ? Object.new : retrieval_uri
        root = compile_node(schema, retrieval_uri, dialect, "", "", nil, document_key, changes)
        document_uri = strip_fragment(retrieval_uri)
        register_resource(document_uri, root, changes) unless document_uri.empty? || resource_at(document_uri, changes)
        register_uri_unless_present(retrieval_uri, root, changes) unless retrieval_uri.empty?
        register_uri_unless_present(document_uri, root, changes) unless document_uri.empty?
        root
      end

      private def compile_node(schema, inherited_base, dialect, schema_path, resource_path, resource, document_key, changes)
        hash_schema = schema.is_a?(Hash)
        if hash_schema && (schema.key?("$recursiveRef") || schema.key?("$dynamicRef"))
          changes.requires_dynamic_scope = true
        end
        dialect = dialect_for(schema, dialect, changes) if hash_schema && schema.key?("$schema")
        if hash_schema && dialect.format_assertion? && schema.key?("format") &&
            Formats.resolve(schema["format"]).name.nil?
          raise UnsupportedFormatError,
            "unsupported format #{schema["format"].inspect} required by Format-Assertion vocabulary"
        end
        exclusive_ref = hash_schema && schema.key?("$ref") && !dialect.ref_siblings?
        base = if hash_schema && !exclusive_ref && schema.key?("$id")
          absolute_uri(inherited_base, schema["$id"])
        else
          inherited_base
        end
        base = inherited_base if base.empty?
        starts_resource = hash_schema && schema.key?("$id") && !exclusive_ref &&
          !base.empty? && fragment(base).empty?
        resource_path = "" if starts_resource

        node = SchemaNode.new(
          schema: schema,
          dialect: dialect,
          base_uri: base,
          schema_path: schema_path,
          resource_path: resource_path,
          document_key: document_key
        )
        changes.nodes << node
        if @nodes_by_document_location
          changes.mutable_document_locations << [document_key, schema_path, node]
        end

        if hash_schema && schema.key?("$id") && !exclusive_ref && !base.empty?
          changes.mutable_uri_registry[base] = node
          if starts_resource
            resource = register_resource(strip_fragment(base), node, changes)
          end
        end

        resource ||= register_resource(strip_fragment(base), node, changes)
        unless node.resource
          node.resource = resource
          (changes.mutable_resource_nodes[resource] ||= {})[node.resource_path] = node unless node.equal?(resource.root)
        end

        if hash_schema && !exclusive_ref
          register_anchor(node, resource, schema["$anchor"], changes) if schema.key?("$anchor")
          if schema.key?("$dynamicAnchor")
            register_anchor(node, resource, schema["$dynamicAnchor"], changes, dynamic: true)
          end
        end

        dialect.each_subschema(schema) do |child_schema, segments|
          child_schema_path = append_segments(schema_path, segments)
          child_resource_path = if resource_path == schema_path
            child_schema_path
          else
            append_segments(resource_path, segments)
          end
          child = compile_node(
            child_schema,
            base,
            dialect,
            child_schema_path,
            child_resource_path,
            resource,
            document_key,
            changes
          )
          node.add_child(*segments, child: child)
        end
        node.freeze
      end

      private def register_resource(uri, root, changes)
        return Resource.new(uri, root) if uri.empty?

        resource = resource_at(uri, changes)
        return resource if resource && resource.root.equal?(root)
        return resource if resource

        changes.mutable_resources[uri] = Resource.new(uri, root)
      end

      private def resource_at(uri, changes)
        changes.resources.fetch(uri) { resources[uri] }
      end

      private def register_uri_unless_present(uri, node, changes)
        return if changes.uri_registry.key?(uri) || uri_registry.key?(uri)

        changes.mutable_uri_registry[uri] = node
      end

      private def register_anchor(node, resource, name, changes, dynamic: false)
        return unless name.is_a?(String) && !name.empty?

        changes.mutable_uri_registry["#{resource.uri}##{name}"] = node
        ((changes.mutable_dynamic_anchors[resource] ||= {})[name] = node) if dynamic
      end

      private def node_by_document_location(document_key, schema_path)
        unless @nodes_by_document_location
          target = nodes.find { |node| node.document_key == document_key && node.schema_path == schema_path }
          return unless target

          @nodes_by_document_location = nodes.each_with_object({}) do |node, result|
            (result[node.document_key] ||= {})[node.schema_path] = node
          end
        end
        @nodes_by_document_location.dig(document_key, schema_path)
      end

      private def index_external(document_uri, fallback_dialect)
        return if @indexed_external_schemas&.[](document_uri)

        if (meta_schema = MetaSchemas.resolve(document_uri))
          dialect = Dialect.resolve(meta_schema["$schema"]) || fallback_dialect
          compile_atomically do |changes|
            compile_document(meta_schema, document_uri, dialect, changes)
          end
          (@indexed_external_schemas ||= {})[document_uri] = true
          return
        end
        if @external_schemas.key?(document_uri)
          external_schema = @external_schemas[document_uri]
          compile_atomically do |changes|
            dialect = dialect_for(external_schema, fallback_dialect, changes)
            compile_document(external_schema, document_uri, dialect, changes)
          end
          (@indexed_external_schemas ||= {})[document_uri] = true
          return
        end

        matches = @external_schemas.select do |external_uri, _schema|
          strip_fragment(external_uri.to_s) == document_uri
        end
        compile_atomically do |changes|
          matches.each do |external_uri, external_schema|
            external_uri = external_uri.to_s
            dialect = dialect_for(external_schema, fallback_dialect, changes)
            compile_document(external_schema, external_uri, dialect, changes)
          end
        end
        (@indexed_external_schemas ||= {})[document_uri] = true
      end

      private def dialect_for(schema, fallback, changes = nil)
        return fallback unless schema.is_a?(Hash) && schema.key?("$schema")

        uri = schema["$schema"].to_s
        Dialect.resolve(uri) || custom_dialect(uri, fallback, changes) || fallback
      end

      private def custom_dialect(uri, fallback, changes)
        meta_schema = @external_schemas[uri] || @external_schemas[uri.delete_suffix("#")]
        return unless meta_schema.is_a?(Hash) && meta_schema["$vocabulary"].is_a?(Hash)

        custom_dialects = changes ? changes.mutable_custom_dialects : (@custom_dialects ||= {})
        return custom_dialects[uri] if custom_dialects.key?(uri)
        return @custom_dialects[uri] if @custom_dialects&.key?(uri)

        custom_dialects[uri] ||= begin
          vocabulary = meta_schema["$vocabulary"]
          validation = vocabulary.any? { |name, enabled| enabled && name.end_with?("/validation") }
          format_assertion = vocabulary.any? { |name, _| name.end_with?("/format-assertion") }
          keywords = if validation
            fallback.keywords
          else
            fallback.keywords.except(*VALIDATION_KEYWORDS)
          end
          if format_assertion
            keywords = keywords.merge("format" => Dialect::Keyword.new(mask: Dialect::STRING))
          end
          Dialect.new(
            name: fallback.name,
            uri: uri,
            keywords: keywords,
            ref_siblings: fallback.ref_siblings?,
            format_assertion: format_assertion
          )
        end
      end

      VALIDATION_KEYWORDS = %w[
        type enum const multipleOf maximum exclusiveMaximum minimum exclusiveMinimum
        maxLength minLength pattern maxItems minItems uniqueItems maxContains minContains
        maxProperties minProperties required dependentRequired
      ].freeze
      private_constant :VALIDATION_KEYWORDS

      private def absolute_uri(base, identifier)
        base = base.to_s
        return base if identifier.nil?

        identifier = identifier.to_s
        return identifier if base.empty? || identifier.match?(/\A[A-Za-z][A-Za-z0-9+.-]*:/)
        return strip_fragment(base) if identifier.empty?
        return "#{strip_fragment(base)}#{identifier}" if identifier.start_with?("#")

        URI.join(base, identifier).to_s
      rescue URI::Error
        begin
          URI.join("resolve:///", base, identifier).to_s.delete_prefix("resolve:///")
        rescue URI::Error
          identifier
        end
      end

      private def strip_fragment(uri)
        index = uri.index("#")
        index ? uri[0, index] : uri
      end

      private def fragment(uri)
        index = uri.index("#")
        index ? uri[(index + 1)..] : ""
      end

      private def append_segments(path, segments)
        segments.reduce(path) do |result, segment|
          encoded = segment.to_s
          encoded = encoded.gsub("~", "~0") if encoded.include?("~")
          encoded = encoded.gsub("/", "~1") if encoded.include?("/")
          "#{result}/#{encoded}"
        end
      end

      private def canonical_pointer(pointer)
        return "" if pointer.empty?

        tokens = pointer.split("/", -1).drop(1).map do |token|
          decoded = token.gsub("~1", "/").gsub("~0", "~")
          decoded.gsub("~", "~0").gsub("/", "~1")
        end
        "/#{tokens.join("/")}"
      end

      private def pointer_target(document, pointer)
        pointer.split("/", -1).drop(1).reduce(document) do |current, token|
          key = token.gsub("~1", "/").gsub("~0", "~")
          if current.is_a?(Array)
            unless key.match?(/\A(?:0|[1-9]\d*)\z/)
              raise ResolutionError, "invalid JSON Pointer index #{key.inspect}"
            end
            current.fetch(key.to_i)
          elsif current.is_a?(Hash)
            current.fetch(key)
          else
            raise ResolutionError, "JSON Pointer traverses a scalar"
          end
        end
      rescue IndexError
        raise ResolutionError, "JSON Pointer target does not exist"
      end
    end
  end

  private_constant :Internal
end
