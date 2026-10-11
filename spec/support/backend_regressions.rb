# frozen_string_literal: true

require "base64"

# Public behavior shared by the ordinary suite and the backend CI matrix.
# Native-only checks for fallback, allocation and GC remain in test/.
RSpec.shared_examples "backend regressions" do |backend|
  def expect_equivalent_results(schema, values, backend:, **options)
    reference = Schemurai.compile(schema, backend: :ruby, **options)
    candidate = Schemurai.compile(schema, backend: backend, **options)
    values.each do |value|
      expect(candidate.valid?(value)).to eq(reference.valid?(value)), value.inspect
      expected = reference.validate(value)
      actual = candidate.validate(value)
      expect(actual.valid?).to eq(expected.valid?), value.inspect
      expect(actual.errors.map(&:to_h)).to eq(expected.errors.map(&:to_h)), value.inspect
    end
  end

  it "distinguishes required-property flags in otherwise identical oneOf branches", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    property = {"properties" => {"id" => {"type" => "integer"}}}
    schema = {"$schema" => "https://json-schema.org/draft/2020-12/schema",
              "oneOf" => [property, property.merge("required" => ["id"])], "unevaluatedProperties" => false}
    validator = Schemurai.compile(schema, backend: backend)
    expect(validator.valid?({})).to be(true)
    expect(validator.valid?({"id" => 1})).to be(false)
    expect_equivalent_results(schema, [{}, {"id" => 1}, {"id" => "bad"}], backend: backend)
  end

  it "retains repeated branch counts, count bounds and unsupported middle branches", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    dialect = {"$schema" => "https://json-schema.org/draft/2020-12/schema"}
    property = {"properties" => {"id" => {"type" => "integer"}}}
    branches = [Array.new(20, property), [property, property.merge("minProperties" => 2)],
      [property, property.merge("maxProperties" => 0)],
      [{"properties" => {"id" => true}}, {"properties" => {"id" => {"pattern" => "(?=x)"}}}, {"properties" => {"id" => true}}]]
    branches.each do |children|
      %w[anyOf oneOf].each do |keyword|
        schema = dialect.merge(keyword => children, "unevaluatedProperties" => false)
        expect_equivalent_results(schema, [{}, {"id" => 1}, {"id" => "x"}, {"id" => 1, "extra" => nil}], backend: backend)
      end
    end
  end

  it "rejects padding inside Base64 chunks instead of parsing stale decoded bytes", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    schema = {"contentEncoding" => "base64", "contentMediaType" => "application/json"}
    validator = Schemurai.compile(schema, content: true, backend: backend)
    [256, 4096, 8193, 9216].each do |length|
      encoded = Base64.strict_encode64('"' + "x" * length + '"')
      expect(validator.valid?(encoded)).to be(true)
      [128, 512, 1024, 2048].select { |boundary| boundary < encoded.length - 4 }.each do |boundary|
        invalid = encoded[0...boundary - 4] + "TQ==" + encoded[boundary..]
        expect(validator.valid?(invalid)).to be(false)
        expect_equivalent_results(schema, [invalid], backend: backend, content: true)
      end
    end
  end

  it "matches JSON and Base64 syntax after seeded byte mutations", :aggregate_failures, :fuzz do # rubocop:disable RSpec/ExampleLength
    random = Random.new(42)
    seeds = ['{"a":[1,-2.5e+20,true,false,null,"a\\n\\u1234"]}', '"日本"', "[{},[],0]", " 123.456e-7 "]
    values = seeds + Array.new(150) do
      bytes = seeds.sample(random: random).bytes
      at = random.rand(bytes.length)
      case random.rand(3)
      when 0 then bytes[at] = random.rand(128)
      when 1 then bytes.insert(at, random.rand(128))
      else bytes.delete_at(at)
      end
      bytes.pack("C*")
    end
    expect_equivalent_results({"contentMediaType" => "application/json"}, values, backend: backend, content: true)
    encoded = values.map { |value| Base64.strict_encode64(value) }
    expect_equivalent_results({"contentEncoding" => "base64", "contentMediaType" => "application/json"}, encoded, backend: backend, content: true)
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/= \n"
    mutated = Array.new(150) { Array.new(random.rand(32)) { alphabet[random.rand(alphabet.length)] }.join }
    expect_equivalent_results({"contentEncoding" => "base64"}, mutated, backend: backend, content: true)
  end

  it "preserves pattern match existence across empty and priority alternatives", :aggregate_failures, :fuzz do # rubocop:disable RSpec/ExampleLength
    patterns = ["a|ab", "ab|a", "(?:|a)b", "(?:a?|b)*", "^a|b$", "^(?:a|ab)+$", "\\A[a-z]+\\z"]
    random = Random.new(9571)
    strings = ["", "a", "ab", "b", "aba", "x\nab", "ab\nx"] + Array.new(80) { Array.new(random.rand(12)) { "abx\n"[random.rand(4)] }.join }
    patterns.each do |pattern|
      expect_equivalent_results({"pattern" => pattern}, strings, backend: backend)
    end
  end

  it "resolves large-integer fingerprint collisions and mixed Float equality", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    random = Random.new(9571)
    schema = {"uniqueItems" => true}
    [0, 11, 32, 33, 64].each do |shift|
      values = Array.new(40) { |index| 2**200 + (index << shift) }.shuffle(random: random)
      expect_equivalent_results(schema, [values, values + [values.first], values + [(2**200).to_f]], backend: backend)
    end
    collisions = Array.new(40) { |index| 2**200 + ((index << 11) ^ index) }.shuffle(random: random)
    expect_equivalent_results(schema, [collisions, collisions + [collisions.last]], backend: backend)
    boundary = [2**53, 2**53 + 1, 2**100, (2**100).to_f]
    expect_equivalent_results(schema, [boundary, boundary[0...-1], [0, -0.0]], backend: backend)
  end

  it "retains exact uniqueness at compact index size boundaries", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    schema = {"uniqueItems" => true}
    validator = Schemurai.compile(schema, backend: backend)
    [65_534, 65_535, 65_536].each do |length|
      values = Array.new(length) { |index| 2**200 + index }.shuffle(random: Random.new(9571))
      expect(validator.valid?(values)).to be(true)
      expect(validator.valid?(values + [values.last])).to be(false)
      expect_equivalent_results(schema, [values, values + [values.last]], backend: backend)
    end
  end

  it "retains exclusive numeric endpoints and oversized Integer signs", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    [2**62, 2**63, 2**100, 2**200].each do |bound|
      %w[minimum maximum exclusiveMinimum exclusiveMaximum].each do |keyword|
        schema = {"items" => {"type" => "integer", keyword => bound}}
        values = [bound - 1, bound, bound + 1, -bound, 2**256, -(2**256)]
        expect_equivalent_results(schema, values.map { |value| [value] }, backend: backend)
      end
    end
  end

  it "compares shared containers recursively even when nested numbers are non-finite", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    [Float::NAN, Float::INFINITY, -Float::INFINITY, 0.0, -0.0].each do |number|
      [[number], {"number" => number}, [{"nested" => [number]}]].each do |container|
        padding = Array.new(17) { |index| "padding#{index}" }
        expect_equivalent_results({"uniqueItems" => true}, [[container, container], padding + [container, container]], backend: backend)
      end
    end
  end

  it "retains the selected backend's Float comparison semantics at an exact Integer tie", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    # Ruby compares decimal spelling; VM (and its native implementation) use
    # ordinary Float/Integer comparison. Keep this existing distinction explicit.
    bound = 2**62
    validator = Schemurai.compile({"maximum" => bound}, backend: backend)
    expected = backend != :ruby
    expect(validator.valid?(bound.to_f)).to eq(expected)
    result = validator.validate(bound.to_f)
    expect(result.valid?).to eq(expected)
    expect(result.errors.map(&:keyword)).to eq(expected ? [] : ["maximum"])
  end

  it "checks every short-key byte and preserves key encoding compatibility", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    key_sets = (1..9).map { |length| 4.times.map { |index| (65 + index).chr + "x" * (length - 1) } }
    key_sets.concat([["", "a", "aa", "aaa"], ["é", "日", "ééé", "日日"]])
    key_sets.each do |keys|
      schema = {"items" => {"properties" => keys.each_with_index.to_h { |key, index| [key, {"const" => index}] },
                            "required" => keys, "additionalProperties" => true}}
      record = keys.each_with_index.to_h { |key, index| [String.new(key).freeze, index] }
      changed = keys.flat_map do |key|
        key.bytesize.times.map do |offset|
          other = String.new(key)
          other.setbyte(offset, other.getbyte(offset) ^ 1)
          record.except(key).merge(other.freeze => record.fetch(key))
        end
      end
      encodings = [Encoding::ASCII_8BIT, Encoding::US_ASCII, Encoding::UTF_16LE].map do |encoding|
        record.transform_keys { |key| String.new(key).force_encoding(encoding).freeze }
      end
      expect_equivalent_results(schema, [record, record.to_a.reverse.to_h, *changed, *encodings].map { |value| [value] }, backend: backend)
    end
  end

  it "keeps failed applicator annotations separate from local diagnostic coverage", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    dialect = {"$schema" => "https://json-schema.org/draft/2020-12/schema"}
    cases = [
      [{"allOf" => [{"properties" => {"x" => true}}, {"type" => "string"}],
        "properties" => {"local" => {"type" => "integer"}}, "unevaluatedProperties" => false}, {"x" => 1, "local" => "bad", "extra" => 9}],
      [{"prefixItems" => [{"minimum" => 5}], "contains" => {"type" => "integer"}, "minContains" => 3, "unevaluatedItems" => false}, [0, "bad"]],
      [{"oneOf" => [{"prefixItems" => [true]}, {"items" => true}], "unevaluatedItems" => false}, [1, 2]],
      [{"dependentSchemas" => {"flag" => {"properties" => {"value" => {"type" => "integer"}}}},
        "properties" => {"flag" => true}, "unevaluatedProperties" => false}, {"flag" => nil, "value" => "bad"}]
    ]
    cases.each { |schema, value| expect_equivalent_results(dialect.merge(schema), [value], backend: backend) }
  end

  it "rechecks borrowed strings, nested values and record layouts after mutation", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    string = +"record123"
    validator = Schemurai.compile({"items" => {"pattern" => "^record[0-9]+$", "minLength" => 9}}, backend: backend)
    expect(validator.valid?([string])).to be(true)
    string.replace("record日")
    expect(validator.valid?([string])).to be(false)
    expect(validator.validate([string])).not_to be_valid
    unique = Schemurai.compile({"uniqueItems" => true}, backend: backend)
    values = Array.new(20) { |index| {"id" => [index]} }
    expect(unique.valid?(values)).to be(true)
    values.last["id"].replace([0.0])
    expect(unique.valid?(values)).to be(false)
    expect(unique.validate(values)).not_to be_valid
    schema = {"properties" => {"id" => {"type" => "integer"}}, "required" => %w[id id], "additionalProperties" => false}
    record = {"id" => 1}
    records = Schemurai.compile(schema, backend: backend)
    expect(records.valid?(record)).to be(true)
    record["extra"] = nil
    expect(records.valid?(record)).to be(false)
    expect_equivalent_results(schema, [record, record.dup.freeze, {}, 1], backend: backend)
  end

  it "restores recursive resource scope between conditional branches and calls", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    schema = {"$schema" => "https://json-schema.org/draft/2019-09/schema", "$id" => "urn:regression:outer",
              "$defs" => {"inner" => {"$id" => "urn:regression:inner", "$recursiveAnchor" => true,
                                      "additionalProperties" => {"$recursiveRef" => "#"}}},
              "if" => {"propertyNames" => {"enum" => ["alpha"]}},
              "then" => {"$id" => "urn:regression:any", "$recursiveAnchor" => true, "$ref" => "urn:regression:inner"},
              "else" => {"$id" => "urn:regression:integer", "$recursiveAnchor" => true,
                         "type" => %w[object integer], "$ref" => "urn:regression:inner"}}
    values = [{"alpha" => 1.1}, {"november" => 1.1}, {"alpha" => 1.1}, {"november" => 1}, {"alpha" => {"november" => 1.1}}]
    expect_equivalent_results(schema, values, backend: backend)
  end
end
