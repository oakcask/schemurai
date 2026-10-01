# frozen_string_literal: true

require_relative "schemurai/version"
require_relative "schemurai/backend"
require_relative "schemurai/formats"
require_relative "schemurai/schema_graph"
require_relative "schemurai/evaluator"

# Public API for compiling and evaluating JSON Schemas.
module Schemurai
  # Base class for errors raised by Schemurai.
  class Error < StandardError; end

  # Raised when a schema or URI cannot be resolved from a registry.
  class ResolutionError < Error; end

  # Raised when a schema requires a format assertion Schemurai does not support.
  class UnsupportedFormatError < Error; end

  # Raised when a schema does not conform to its declared meta-schema.
  class InvalidSchemaError < Error
    # The detailed meta-schema validation result.
    attr_reader :result

    def initialize(result)
      @result = result
      first_error = result.errors.first
      message = if first_error
        "invalid schema at #{first_error.instance_path.inspect}: #{first_error.message}"
      else
        "invalid schema"
      end
      super(message)
    end
  end

  # Public value type describing one failed JSON Schema assertion.
  #
  # +keyword+ identifies the failed keyword. +instance_path+ and +schema_path+
  # are JSON Pointers; an empty string points to the root instance or schema.
  # +message+ is a human-readable String. Its presence and type are public API,
  # but its exact wording is not. Use +keyword+ and the paths for programmatic
  # error handling.
  class ValidationError < Data.define(:keyword, :instance_path, :schema_path, :message)
    # Returns the error fields as a Hash.
    def to_h
      {keyword: keyword, instance_path: instance_path, schema_path: schema_path, message: message}
    end
  end

  # The detailed result of validating one instance.
  class Result
    # The frozen array of ValidationError objects. It is empty when validation
    # succeeds.
    attr_reader :errors

    # Creates a result from an array of ValidationError objects.
    def initialize(errors)
      @errors = errors.freeze
    end

    # Returns whether the instance passed validation.
    def valid?
      errors.empty?
    end

    alias_method :success?, :valid?
  end

  # Compiles schemas that share registered external schemas and backend state.
  #
  # Register every external schema with +schemas:+ before compiling. A registry
  # can be made shareable once registration and compilation are complete.
  class SchemaRegistry
    # The selected backend, either +:ruby+ or +:vm+.
    attr_reader :backend

    # Creates a registry.
    #
    # +schemas+ maps absolute URI strings to JSON-shaped Ruby schemas. Pass
    # +validate_schema: true+ to validate every registered and compiled schema
    # against its meta-schema. +backend+ accepts +:ruby+, +:vm+, or +:default+.
    def initialize(schemas: {}, validate_schema: false, backend: Backend.requested)
      @backend = Backend.resolve(backend)
      @validate_schema = validate_schema
      @graph = Internal::SchemaGraph.new(schemas: schemas)
      @compiler = VM::Compiler.new(@graph) if @backend == :vm
      schemas.each_value { |schema| validate_schema!(schema) } if validate_schema?
    end

    # Returns whether this registry validates every schema against its meta-schema.
    def validate_schema?
      @validate_schema
    end

    # Compiles +schema+ and returns a Validator.
    #
    # +base_uri+ supplies the schema's base URI. Pass +content: true+ or
    # +format: true+ to enable the corresponding optional assertions.
    def compile(schema, base_uri: nil, content: false, format: false)
      raise Error, "cannot compile schemas after the registry is made shareable" if shareable?

      validate_schema!(schema) if validate_schema?
      root = @graph.compile(schema, base_uri: base_uri)
      build_validator(root, content: content, format: format)
    end

    # Validates +schema+ against its declared meta-schema and returns a Result.
    # Schemas without +$schema+ are validated as Draft 7.
    def validate_schema(schema)
      raise Error, "cannot validate schemas after the registry is made shareable" if shareable?

      root = @graph.meta_schema_root(schema)
      build_validator(root, content: false, format: false).validate(schema)
    end

    # Returns whether +schema+ conforms to its declared meta-schema.
    def valid_schema?(schema)
      validate_schema(schema).valid?
    end

    # Resolves and freezes registered schemas, then makes the registry Ractor-shareable.
    #
    # Returns +self+. No more schemas can be compiled after this transition.
    def make_shareable
      return self if shareable?

      @graph.make_shareable
      @compiler&.compile_all
      Ractor.make_shareable(self)
    end

    # Returns whether this registry is Ractor-shareable.
    def shareable?
      Ractor.shareable?(self)
    end

    # Returns a Validator for the registered resource at +uri+.
    #
    # The registry must first be made shareable with #make_shareable.
    def validator_for(uri, content: false, format: false)
      raise Error, "make_shareable must be called before retrieving validators by URI" unless shareable?

      root = @graph.node_at(uri)
      raise ResolutionError, "unregistered schema URI #{uri.inspect}" unless root

      build_validator(root, content: content, format: format)
    end

    private def build_validator(root, content:, format:)
      evaluator = if @compiler
        @compiler.evaluator(root, content: content, format: format)
      else
        Internal::Evaluator.new(@graph, root, content: content, format: format)
      end
      Validator.new(evaluator)
    end

    private def validate_schema!(schema)
      result = validate_schema(schema)
      raise InvalidSchemaError, result unless result.valid?
    end
  end

  # A reusable compiled JSON Schema validator.
  #
  # Create validators through Schemurai.compile or SchemaRegistry#compile.
  # Validator instances contain mutable evaluation state and must not be used
  # concurrently or shared between Ractors.
  class Validator
    # Wraps an evaluator implementation.
    #
    # Applications should normally create validators through Schemurai.compile
    # or SchemaRegistry#compile.
    def initialize(evaluator)
      @evaluator = evaluator
    end

    # The backend reported by the evaluator, either +:ruby+ or +:vm+.
    def backend
      @evaluator.backend
    end

    # Validates +instance+ and returns a Result containing all reported errors.
    def validate(instance)
      @evaluator.validate(instance)
    end

    # Returns whether +instance+ is valid without building a detailed error list.
    def valid?(instance)
      @evaluator.valid?(instance)
    end
  end

  # Returns the backend selected by SCHEMURAI_BACKEND, either +:ruby+ or +:vm+.
  module_function def backend
    Backend.resolve
  end

  # Compiles +schema+ and returns a reusable Validator.
  #
  # +schemas+ maps external URI strings to schemas. +base_uri+ supplies the
  # schema's base URI. Optional content and format assertions are disabled by
  # default. +backend+ accepts +:ruby+, +:vm+, or +:default+.
  module_function def compile(schema, schemas: {}, base_uri: nil, content: false, format: false, validate_schema: false, backend: Backend.requested)
    SchemaRegistry.new(schemas: schemas, validate_schema: validate_schema, backend: backend).compile(
      schema,
      base_uri: base_uri,
      content: content,
      format: format
    )
  end

  # Validates +schema+ against its declared meta-schema and returns a Result.
  # Schemas without +$schema+ are validated as Draft 7.
  module_function def validate_schema(schema, schemas: {}, backend: Backend.requested)
    SchemaRegistry.new(schemas: schemas, backend: backend).validate_schema(schema)
  end

  # Returns whether +schema+ conforms to its declared meta-schema.
  module_function def valid_schema?(schema, schemas: {}, backend: Backend.requested)
    validate_schema(schema, schemas: schemas, backend: backend).valid?
  end

  # Validates +instance+ against +schema+ and returns a Result.
  #
  # This convenience method compiles the schema for each call. Use .compile
  # when validating multiple instances against the same schema.
  module_function def validate(schema, instance, schemas: {}, base_uri: nil, content: false, format: false, validate_schema: false, backend: Backend.requested)
    compile(
      schema,
      schemas: schemas,
      base_uri: base_uri,
      content: content,
      format: format,
      validate_schema: validate_schema,
      backend: backend
    ).validate(instance)
  end

  # Returns whether +instance+ is valid against +schema+.
  #
  # This convenience method compiles the schema for each call. Use .compile
  # when validating multiple instances against the same schema.
  module_function def valid?(schema, instance, schemas: {}, base_uri: nil, content: false, format: false, validate_schema: false, backend: Backend.requested)
    compile(
      schema,
      schemas: schemas,
      base_uri: base_uri,
      content: content,
      format: format,
      validate_schema: validate_schema,
      backend: backend
    ).valid?(instance)
  end

  private_constant :Backend
end
