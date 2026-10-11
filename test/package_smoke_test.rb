# frozen_string_literal: true

require "schemurai"
require "base64"

signature_path = File.join(Gem.loaded_specs.fetch("schemurai").full_gem_path, "sig/schemurai.rbs")
abort "expected the installed gem to include its RBS signature" unless File.file?(signature_path)

schema = {
  "$schema" => "https://json-schema.org/draft/2020-12/schema",
  "type" => "object",
  "properties" => {
    "order_id" => {"type" => "string", "pattern" => "^ord_[0-9]{6}$"},
    "customer" => {"$ref" => "#/$defs/customer"},
    "items" => {
      "type" => "array",
      "minItems" => 1,
      "items" => {"$ref" => "#/$defs/line_item"}
    },
    "created_at" => {"type" => "string", "format" => "date-time"}
  },
  "required" => %w[order_id customer items created_at],
  "additionalProperties" => false,
  "$defs" => {
    "customer" => {
      "type" => "object",
      "properties" => {
        "id" => {"type" => "integer", "minimum" => 1},
        "name" => {"type" => "string", "minLength" => 1},
        "tier" => {"enum" => %w[standard premium]}
      },
      "required" => %w[id name],
      "additionalProperties" => false
    },
    "line_item" => {
      "type" => "object",
      "properties" => {
        "sku" => {"type" => "string", "pattern" => "^SKU-[A-Z0-9]{8}$"},
        "quantity" => {"type" => "integer", "minimum" => 1},
        "unit_price" => {"type" => "number", "minimum" => 0}
      },
      "required" => %w[sku quantity unit_price],
      "additionalProperties" => false
    }
  }
}

order = {
  "order_id" => "ord_123456",
  "customer" => {"id" => 42, "name" => "Ada Lovelace", "tier" => "premium"},
  "items" => [
    {"sku" => "SKU-ABC12345", "quantity" => 2, "unit_price" => 19.95}
  ],
  "created_at" => "2026-08-31T10:15:00+09:00"
}

invalid_order = order.merge(
  "items" => [order.fetch("items").first.merge("quantity" => 0)]
)
backends = %i[ruby vm native]
if ENV["SCHEMURAI_EXPECT_NO_NATIVE"] == "1"
  begin
    Schemurai.compile(true, backend: :native)
  rescue LoadError => error
    raise unless error.path == "schemurai_native"
  else
    abort "expected the optional native extension to be absent"
  end
  backends.delete(:native)
end
backends.each do |backend|
  if backend == :native
    vm = Schemurai.const_get(:VM)::Evaluator
    %i[valid? validate].each do |method|
      vm.define_method(method) { |_instance| raise "unexpected VM execution in installed native backend" }
    end
  end
  validator = Schemurai.compile(schema, format: true, backend: backend)
  abort "expected the order to be valid with #{backend}" unless validator.valid?(order)

  result = validator.validate(invalid_order)
  quantity_error = result.errors.any? do |error|
    error.keyword == "minimum" && error.instance_path == "/items/0/quantity"
  end
  abort "expected an invalid quantity error with #{backend}" unless quantity_error

  prices = Schemurai.compile({"type" => "array", "items" => {"type" => "number", "multipleOf" => 0.01, "minimum" => 0}}, backend: backend)
  abort "expected decimal prices to be valid with #{backend}" unless prices.valid?([0.3, 19.95, 2**100])
  abort "expected fractional cents to be invalid with #{backend}" if prices.valid?([19.951])

  dates = Schemurai.compile({"type" => "array", "items" => {"type" => "string", "format" => "date"}}, format: true, backend: backend)
  abort "expected a leap date to be valid with #{backend}" unless dates.valid?(["2024-02-29"])
  abort "expected an invalid leap date with #{backend}" if dates.valid?(["2023-02-29"])

  pointer_text = "/" + "a" * 128 + "~0/" + "b" * 128 + "~1"
  %w[json-pointer relative-json-pointer].each do |format|
    pointer = Schemurai.compile({"type" => "array", "items" => {"type" => "string", "format" => format}}, format: true, backend: backend)
    value = (format == "json-pointer") ? pointer_text : "123" + pointer_text
    abort "expected a long pointer with #{backend}" unless pointer.valid?([value])
    abort "expected long pointer diagnostics with #{backend}" unless pointer.validate([value]).valid?
    abort "expected an invalid pointer escape with #{backend}" if pointer.valid?([value + "~2"])
    error = pointer.validate([value + "~2"]).errors.first
    abort "expected a pointer format error with #{backend}" unless error.keyword == "format" && error.instance_path == "/0"
  end

  plain_content = Schemurai.compile({"type" => "array", "items" => {"contentMediaType" => "application/json"}}, content: true, backend: backend)
  plain_values = ["{}", "[]".b, "true".encode(Encoding::US_ASCII), nil, 7]
  abort "expected plain JSON views with #{backend}" unless plain_content.valid?(plain_values)
  abort "expected plain JSON diagnostics with #{backend}" unless plain_content.validate(plain_values).valid?
  plain_error = plain_content.validate(["{}", "{:}"]).errors.first
  unless plain_error&.keyword == "contentMediaType" && plain_error.instance_path == "/1"
    abort "expected plain JSON content error with #{backend}"
  end

  content = Schemurai.compile({"type" => "array", "items" => {"contentEncoding" => "base64", "contentMediaType" => "application/json"}}, content: true, backend: backend)
  abort "expected encoded JSON to be valid with #{backend}" unless content.valid?(["e30=", "W10="])
  abort "expected malformed encoded JSON with #{backend}" if content.valid?(["ezp9"])
  medium_content = Base64.strict_encode64('"' + "x" * 4096 + '"')
  abort "expected directly decoded JSON with #{backend}" unless content.valid?([medium_content])
  abort "expected directly decoded diagnostics with #{backend}" unless content.validate([medium_content]).valid?
  long_content = Base64.strict_encode64('"' + "x" * 8193 + '"')
  abort "expected streamed encoded JSON with #{backend}" unless content.valid?([long_content])
  abort "expected valid streamed diagnostics with #{backend}" unless content.validate([long_content]).valid?
  [1024, 2048].each do |boundary|
    padded_chunk = long_content[0...boundary - 4] + "TQ==" + long_content[boundary..]
    abort "expected intermediate padding to be invalid with #{backend}" if content.valid?([padded_chunk])
    abort "expected invalid padding diagnostics with #{backend}" if content.validate([padded_chunk]).valid?
  end
  prefixed_content = Schemurai.compile({"$schema" => "https://json-schema.org/draft/2020-12/schema",
    "prefixItems" => [{"const" => "header"}], "items" => {"type" => "string", "contentEncoding" => "base64"},
    "unevaluatedItems" => false}, content: true, backend: backend)
  content_paths = prefixed_content.validate(["header", "!", "!"]).errors
    .select { |error| error.keyword == "contentEncoding" }.map(&:instance_path)
  abort "expected both content item paths with #{backend}" unless content_paths == %w[/1 /2]

  large = Schemurai.compile({"const" => 2**4096}, backend: backend)
  abort "expected a large integer constant with #{backend}" unless large.valid?(2**4096)
  unique = Schemurai.compile({"uniqueItems" => true}, backend: backend)
  wide_bounds = Schemurai.compile({"items" => {"type" => "integer", "minimum" => 2**200}}, backend: backend)
  wide_values = Array.new(25) { |i| 2**256 + i }
  abort "expected wide integer bounds with #{backend}" unless wide_bounds.valid?(wide_values)
  abort "expected wide integer bound failure with #{backend}" if wide_bounds.valid?(wide_values + [2**200 - 1])
  bounded_limits = Schemurai.compile({"items" => {"type" => "integer", "minimum" => 2**100}}, backend: backend)
  abort "expected oversized positive integers with #{backend}" unless bounded_limits.valid?(wide_values)
  abort "expected oversized negative failure with #{backend}" if bounded_limits.valid?([-(2**200)])
  abort "expected oversized bound diagnostics with #{backend}" if bounded_limits.validate([-(2**200)]).valid?

  annotation_properties = 65.times.to_h { |index| ["p#{index}", {"type" => "integer"}] }
  annotations = Schemurai.compile({"$schema" => "https://json-schema.org/draft/2020-12/schema", "anyOf" => [
    {"properties" => annotation_properties}, {"patternProperties" => {"^dynamic" => true}},
    {"allOf" => [{"properties" => {"extra" => true}}, false]}
  ], "unevaluatedProperties" => false}, backend: backend)
  annotated_value = annotation_properties.keys.to_h { |key| [key, 1] }.merge("dynamic/key" => nil)
  abort "expected merged property annotations with #{backend}" unless annotations.valid?(annotated_value)
  abort "expected merged annotation diagnostics with #{backend}" unless annotations.validate(annotated_value).valid?
  abort "expected failed branch annotations to be discarded with #{backend}" if annotations.valid?(annotated_value.merge("extra" => nil))

  record_fields = 8.times.to_h { |index| ["p#{index}", {"type" => "integer", "minimum" => 0}] }
  record_rule = {"properties" => record_fields, "required" => %w[p7 p0 p7 p3], "additionalProperties" => false}
  ordered_records = Schemurai.compile({"items" => record_rule}, backend: backend)
  frozen_records = Array.new(3) { |index| 8.times.to_h { |field| ["p#{field}".freeze, index] } }
  abort "expected frozen-key records with #{backend}" unless ordered_records.valid?(frozen_records)
  abort "expected frozen-key diagnostics with #{backend}" unless ordered_records.validate(frozen_records).valid?
  frozen_records.last.delete("p3")
  abort "expected changed frozen-key records with #{backend}" if ordered_records.valid?(frozen_records)
  abort "expected changed frozen-key diagnostics with #{backend}" if ordered_records.validate(frozen_records).valid?
  short_keys = ["é", "日日", "a\u0000b", "abcdefgh"]
  short_fields = short_keys.each_with_index.to_h { |key, index| [key, {"const" => index}] }
  short_records = Schemurai.compile({"items" => {"properties" => short_fields, "required" => short_keys}}, backend: backend)
  short_value = short_keys.each_with_index.to_h { |key, index| [String.new(key).freeze, index] }
  abort "expected exact short Unicode keys with #{backend}" unless short_records.valid?([short_value])
  abort "expected exact short key diagnostics with #{backend}" unless short_records.validate([short_value]).valid?
  binary_keys = short_value.transform_keys { |key| String.new(key).force_encoding(Encoding::ASCII_8BIT).freeze }
  abort "expected incompatible non-ASCII keys with #{backend}" if short_records.valid?([binary_keys])
  abort "expected incompatible key diagnostics with #{backend}" if short_records.validate([binary_keys]).valid?
  sparse_keys = 8.times.map { |offset| ("\u0000" * 8).tap { |key| key.setbyte(offset, 1) } }
  sparse_fields = sparse_keys.each_with_index.to_h { |key, index| [key, {"const" => index}] }
  sparse_records = Schemurai.compile({"items" => {"properties" => sparse_fields, "required" => sparse_keys}}, backend: backend)
  sparse_value = sparse_keys.each_with_index.to_h { |key, index| [String.new(key).freeze, index] }
  abort "expected sparse short key fallback with #{backend}" unless sparse_records.valid?([sparse_value])
  abort "expected sparse key diagnostics with #{backend}" unless sparse_records.validate([sparse_value]).valid?
  sparse_value.delete(sparse_keys.last)
  abort "expected missing sparse key with #{backend}" if sparse_records.valid?([sparse_value])
  abort "expected missing sparse key diagnostics with #{backend}" if sparse_records.validate([sparse_value]).valid?
  decimal_bounds = Schemurai.compile({"minimum" => 2**200, "multipleOf" => 3}, backend: backend)
  decimal_errors = decimal_bounds.validate(0.5).errors.map(&:keyword)
  abort "expected wide decimal bound diagnostics with #{backend}" unless decimal_errors == %w[minimum multipleOf]
  integers = Array.new(25) { |i| 2**200 + i }
  abort "expected unique large integers with #{backend}" unless unique.valid?(integers)
  unordered = integers.shuffle(random: Random.new(9571))
  abort "expected unique unordered integers with #{backend}" unless unique.valid?(unordered)
  abort "expected unordered integer duplicate with #{backend}" if unique.valid?(unordered + [integers[17] + 0])
  abort "expected unordered duplicate diagnostics with #{backend}" if unique.validate(unordered + [integers[17] + 0]).valid?
  collision_values = Array.new(40) { |index| 2**200 + (index << 64) }.shuffle(random: Random.new(9571))
  abort "expected full integer hashing after collisions with #{backend}" unless unique.valid?(collision_values)
  abort "expected collision diagnostics with #{backend}" unless unique.validate(collision_values).valid?
  collision_duplicate = collision_values + [collision_values[17] + 0]
  abort "expected collision duplicate with #{backend}" if unique.valid?(collision_duplicate)
  abort "expected collision duplicate diagnostics with #{backend}" if unique.validate(collision_duplicate).valid?
  abort "expected mixed Float equality after collisions with #{backend}" if unique.valid?(collision_values + [(2**200).to_f])
  [65_535, 65_536].each do |length|
    boundary = Array.new(length, &:itself).shuffle(random: Random.new(9571))
    abort "expected unique boundary values with #{backend}" unless unique.valid?(boundary)
    boundary[-1] = boundary[0]
    abort "expected boundary duplicate with #{backend}" if unique.valid?(boundary)
    abort "expected boundary duplicate diagnostics with #{backend}" if unique.validate(boundary).valid?
  end
  objects = Array.new(25) { |i| {"id" => i, "nested" => [nil, true, false, [], {}, "日", "x" * 128, i + 0.5]} }
  abort "expected unique nested objects with #{backend}" unless unique.valid?(objects)
  abort "expected nested object duplicate with #{backend}" if unique.valid?(objects + [objects[17].dup])
  abort "expected nested object diagnostics with #{backend}" if unique.validate(objects + [objects[17].dup]).valid?
  abort "expected a mixed numeric duplicate with #{backend}" if unique.valid?(integers + [(2**200).to_f])
  shared = [Float::NAN]
  abort "expected recursive NaN equality with #{backend}" unless unique.valid?([shared, shared])
  abort "expected valid NaN diagnostics with #{backend}" unless unique.validate([shared, shared]).valid?

  labels = Schemurai.compile({"properties" => {"label" => {"type" => "string", "minLength" => 2, "maxLength" => 2}}}, backend: backend)
  label = +"ab"
  abort "expected two ASCII characters with #{backend}" unless labels.valid?({"label" => label})
  label.replace("é")
  abort "expected one Unicode character with #{backend}" if labels.valid?({"label" => label})
  label.replace("ab").force_encoding(Encoding::UTF_16LE)
  abort "expected one UTF-16 character with #{backend}" if labels.valid?({"label" => label})
  label.force_encoding(Encoding::ASCII_8BIT)
  abort "expected two binary characters with #{backend}" unless labels.valid?({"label" => label})

  pattern = Schemurai.compile({"pattern" => "^(?:ord|sku)-[0-9]{2,8}:[A-Z]+$"}, backend: backend)
  abort "expected grouped repetitions with #{backend}" unless pattern.valid?("ord-12:OK")
  abort "expected an invalid grouped pattern with #{backend}" if pattern.valid?("ord-12:bad")

  combined = Schemurai.compile({"type" => "array", "items" => {
    "type" => "string", "minLength" => 1, "pattern" => "^[0-9]+$",
    "format" => "relative-json-pointer", "contentMediaType" => "application/json"
  }}, format: true, content: true, backend: backend)
  abort "expected combined string assertions with #{backend}" unless combined.valid?(["1", "123"])
  abort "expected combined string diagnostics with #{backend}" unless combined.validate(["1", "123"]).valid?
  abort "expected invalid combined string assertions with #{backend}" if combined.valid?(["1", "bad"])
  combined_errors = combined.validate(["1", "bad"]).errors
  unless combined_errors.map(&:keyword) == %w[pattern format contentMediaType] && combined_errors.all? { |error| error.instance_path == "/1" }
    abort "expected combined string errors at the second item with #{backend}"
  end

  alternative = Schemurai.compile({"type" => "array", "items" => {"pattern" => "^(?:a|ab)$"}}, backend: backend)
  abort "expected the longer alternative with #{backend}" unless alternative.valid?(["a", "ab"])
  abort "expected alternative diagnostics with #{backend}" unless alternative.validate(["a", "ab"]).valid?
  abort "expected an invalid alternative with #{backend}" if alternative.valid?(["a", "abc"])
  alternative_errors = alternative.validate(["a", "abc"]).errors
  unless alternative_errors.length == 1 && alternative_errors.first.keyword == "pattern" && alternative_errors.first.instance_path == "/1"
    abort "expected an alternative error at the second item with #{backend}"
  end

  [["^a{4096}$", "a" * 4096, "a" * 4095], ["^(a|b)*a[ab]{20}$", "a" * 21, "b" * 21]].each do |source, valid, invalid|
    bounded = Schemurai.compile({"pattern" => source}, backend: backend)
    abort "expected bounded matcher fallback with #{backend}" unless bounded.valid?(valid)
    abort "expected an invalid bounded matcher with #{backend}" if bounded.valid?(invalid)
  end
end

puts "Installed gem validated the sample order"
