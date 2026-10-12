# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "the compatibility domain" do
  compatibility_cases = JSON.parse(File.read(File.expand_path("../oracle/compatibility_cases.json", __dir__)))
  recorded_cases = (compatibility_cases.fetch("supported_domain") + compatibility_cases.fetch("out_of_domain"))
    .to_h { |record| [record.fetch("id"), record.fetch("expected")] }

  define_method(:recorded) { |id| recorded_cases.fetch(id) }

  let(:internal) { Schemurai.const_get(:Internal) }
  let(:graph_class) { internal.const_get(:SchemaGraph) }

  describe "schema inputs" do
    it "accepts exact recursively JSON-shaped values", :aggregate_failures do
      schema = {"enum" => [nil, true, false, "text", 1, 1.5, [], {}]}
      instance = {"values" => [nil, true, false, "text", 1, 1.5, [], {}]}

      expect { Schemurai.compile(schema) }.not_to raise_error
      expect(Schemurai.valid?(true, instance))
        .to eq(recorded("exact-json-containers-and-scalars").fetch("valid"))
    end

    it "rejects a non-object schema root before graph mutation", :aggregate_failures do
      graph = graph_class.new

      expect { graph.compile("schema") }
        .to raise_error(Schemurai::Error, "invalid JSON-shaped schema: must be a boolean or an object")
      expect(graph.nodes).to be_empty
    end

    it "rejects nested Ruby-only values before graph mutation", :aggregate_failures do
      graph = graph_class.new

      expect { graph.compile({"extension" => Object.new}) }
        .to raise_error(Schemurai::Error, /invalid JSON-shaped schema\/extension: contains unsupported Object/)
      expect(graph.nodes).to be_empty
    end

    it "rechecks shared containers on each call and reports the first invalid path", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
      shared = ["valid"]
      schema = {"first" => shared, "second" => shared}
      expect { Schemurai.compile(schema) }.not_to raise_error
      shared << Object.new
      expect { Schemurai.compile(schema) }
        .to raise_error(Schemurai::Error, /schema\/first\/1: contains unsupported Object/)
      shared[-1] = shared
      expect { Schemurai.compile(schema) }
        .to raise_error(Schemurai::Error, /schema\/first\/1: contains a recursive container/)
    end

    it "reports escaped paths for invalid nested values" do
      schema = {"a/b" => [{"c~d" => Object.new}]}

      expect { Schemurai.compile(schema) }
        .to raise_error(Schemurai::Error, /invalid JSON-shaped schema\/a~1b\/0\/c~0d:/)
    end

    it "rejects invalid external schemas before retaining any registry input" do
      expect { Schemurai::SchemaRegistry.new(schemas: {"urn:bad" => {"value" => Rational(1, 2)}}) }
        .to raise_error(Schemurai::Error, /schemas\["urn:bad"\]\/value: contains unsupported Rational/)
    end

    it "rejects non-finite numbers, subclasses, non-string keys, and cycles" do # rubocop:disable RSpec/ExampleLength
      string_subclass = Class.new(String).new("value")
      recursive = []
      recursive << recursive
      invalid = [
        {"value" => Float::NAN},
        {"value" => Float::INFINITY},
        {"value" => string_subclass},
        {1 => true},
        {"value" => recursive}
      ]

      invalid.each { |schema| expect { Schemurai.compile(schema) }.to raise_error(Schemurai::Error) }
    end
  end

  describe "explicit out-of-domain instance behavior" do
    it "records inherited behavior for a core subclass" do
      value = Class.new(String).new("text")
      expect(Schemurai.valid?({"type" => "string", "minLength" => 4}, value))
        .to eq(recorded("string-subclass").fetch("valid"))
    end

    it "records singleton overrides" do
      value = +"x"
      value.define_singleton_method(:length) { 2 }
      expect(Schemurai.valid?({"type" => "string", "minLength" => 2}, value))
        .to eq(recorded("singleton-string-length").fetch("valid"))
    end

    it "records numeric coercion" do
      numeric_class = Class.new(Numeric) do
        def to_s = "2.5"
      end
      expect(Schemurai.valid?({"type" => "number", "minimum" => 2}, numeric_class.new))
        .to eq(recorded("coercible-numeric-subclass").fetch("valid"))
    end

    it "records mutation during iteration" do # rubocop:disable RSpec/ExampleLength
      hash_class = Class.new(Hash) do
        def each
          first = true
          super do |key, value|
            if first
              first = false
              delete("second")
            end
            yield key, value
          end
        end
      end
      value = hash_class["first", 1, "second", "bad"]
      schema = {"properties" => {"first" => {"type" => "integer"}, "second" => {"type" => "integer"}}}

      expect(Schemurai.valid?(schema, value)).to eq(recorded("mutating-hash-iteration").fetch("valid"))
    end

    it "records exceptions from numeric methods" do # rubocop:disable RSpec/ExampleLength
      numeric_class = Class.new(Numeric) do
        def finite? = raise("finite failed")
      end

      expected = recorded("exceptional-numeric-method")
      expect { Schemurai.valid?({"type" => "integer"}, numeric_class.new) }
        .to raise_error(Object.const_get(expected.fetch("exception_class")), expected.fetch("message"))
    end
  end
end
