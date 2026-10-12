# frozen_string_literal: true

module Schemurai
  module Internal
    module SchemaDomain
      module_function def validate!(schema, label: "schema")
        unless schema.equal?(true) || schema.equal?(false) || schema.instance_of?(Hash)
          invalid!(label, "must be a boolean or an object")
        end

        validate_value!(schema, label, [], {}, {})
        schema
      end

      module_function def validate_registry!(schemas)
        invalid!("schemas", "must be an object") unless schemas.instance_of?(Hash)

        schemas.each do |uri, schema|
          invalid!("schemas", "contains a non-string URI key") unless uri.instance_of?(String)

          validate!(schema, label: "schemas[#{uri.inspect}]")
        end
        schemas
      end

      module_function def validate_value!(value, label, path, ancestors, completed)
        case value
        when nil, true, false
          nil
        when String, Integer
          invalid_at!(label, path, "uses a subclass of #{value.class.superclass}") unless supported_exact_scalar?(value)
        when Float
          invalid_at!(label, path, "must contain only finite numbers") unless value.finite?
          invalid_at!(label, path, "uses a Float subclass") unless value.instance_of?(Float)
        when Array
          invalid_at!(label, path, "uses an Array subclass") unless value.instance_of?(Array)
          descend!(value, label, path, ancestors, completed) do
            value.each_with_index do |item, index|
              path << index
              validate_value!(item, label, path, ancestors, completed)
              path.pop
            end
          end
        when Hash
          invalid_at!(label, path, "uses a Hash subclass") unless value.instance_of?(Hash)
          descend!(value, label, path, ancestors, completed) do
            value.each do |key, item|
              invalid_at!(label, path, "contains a non-string object key") unless key.instance_of?(String)

              path << key
              validate_value!(item, label, path, ancestors, completed)
              path.pop
            end
          end
        else
          invalid_at!(label, path, "contains unsupported #{value.class}")
        end
      end
      private_class_method :validate_value!

      module_function def supported_exact_scalar?(value)
        value.instance_of?(String) || value.instance_of?(Integer)
      end
      private_class_method :supported_exact_scalar?

      module_function def descend!(value, label, path, ancestors, completed)
        # A completed subtree cannot contain a cycle back to this path. Only
        # publish after the entire subtree passes, preserving first-error paths.
        return if completed.key?(value.object_id)

        invalid_at!(label, path, "contains a recursive container") if ancestors.key?(value.object_id)

        ancestors[value.object_id] = true
        yield
        completed[value.object_id] = true
      ensure
        ancestors.delete(value.object_id)
      end
      private_class_method :descend!

      module_function def invalid_at!(label, path, reason)
        location = path.reduce(label.dup) do |result, segment|
          result << "/" << segment.to_s.gsub("~", "~0").gsub("/", "~1")
        end
        invalid!(location, reason)
      end
      private_class_method :invalid_at!

      module_function def invalid!(path, reason)
        raise Error, "invalid JSON-shaped #{path}: #{reason}"
      end
      private_class_method :invalid!
    end
  end
end
