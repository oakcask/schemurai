# Schemurai

[![Gem Version](https://badge.fury.io/rb/schemurai.svg?icon=si%3Arubygems)](https://badge.fury.io/rb/schemurai)
[![test / rspec](https://github.com/oakcask/schemurai/actions/workflows/test--rspec.yaml/badge.svg)](https://github.com/oakcask/schemurai/actions/workflows/test--rspec.yaml)
[![lint / c](https://github.com/oakcask/schemurai/actions/workflows/lint--c.yaml/badge.svg)](https://github.com/oakcask/schemurai/actions/workflows/lint--c.yaml)
[![lint / rubocop](https://github.com/oakcask/schemurai/actions/workflows/lint--rubocop.yaml/badge.svg)](https://github.com/oakcask/schemurai/actions/workflows/lint--rubocop.yaml)
[![lint / rbs](https://github.com/oakcask/schemurai/actions/workflows/lint--rbs.yaml/badge.svg)](https://github.com/oakcask/schemurai/actions/workflows/lint--rbs.yaml)

A small, light-weight-dependency JSON Schema validator for Ruby supporting Draft 7,
Draft 2019-09, and Draft 2020-12. It covers the required cases in the official
JSON-Schema-Test-Suite, as well as the applicable optional tests for numeric
precision, ECMA-262 regular expressions, content validation, anchors, and dynamic
references. The dialect is selected from the schema's `$schema` URI; schemas that
omit `$schema` use Draft 7 for compatibility.

Schemurai ships RBS declarations for its public API in `sig/schemurai.rbs`.

```ruby
require "schemurai"

schema = {
  "$schema" => "https://json-schema.org/draft/2020-12/schema",
  "type" => "object",
  "properties" => {
    "order_id" => { "type" => "string", "pattern" => "^ord_[0-9]{6}$" },
    "customer" => { "$ref" => "#/$defs/customer" },
    "items" => {
      "type" => "array",
      "minItems" => 1,
      "items" => { "$ref" => "#/$defs/line_item" }
    },
    "created_at" => { "type" => "string", "format" => "date-time" }
  },
  "required" => %w[order_id customer items created_at],
  "additionalProperties" => false,
  "$defs" => {
    "customer" => {
      "type" => "object",
      "properties" => {
        "id" => { "type" => "integer", "minimum" => 1 },
        "name" => { "type" => "string", "minLength" => 1 },
        "tier" => { "enum" => %w[standard premium] }
      },
      "required" => %w[id name],
      "additionalProperties" => false
    },
    "line_item" => {
      "type" => "object",
      "properties" => {
        "sku" => { "type" => "string", "pattern" => "^SKU-[A-Z0-9]{8}$" },
        "quantity" => { "type" => "integer", "minimum" => 1 },
        "unit_price" => { "type" => "number", "minimum" => 0 }
      },
      "required" => %w[sku quantity unit_price],
      "additionalProperties" => false
    }
  }
}

order = {
  "order_id" => "ord_123456",
  "customer" => { "id" => 42, "name" => "Ada Lovelace", "tier" => "premium" },
  "items" => [
    { "sku" => "SKU-ABC12345", "quantity" => 2, "unit_price" => 19.95 }
  ],
  "created_at" => "2026-08-31T10:15:00+09:00"
}

validator = Schemurai.compile(schema, format: true)
validator.valid?(order) # => true

invalid_order = order.merge(
  "items" => [order.fetch("items").first.merge("quantity" => 0)]
)
result = validator.validate(invalid_order)
result.valid? # => false
result.errors.each do |error|
  puts "#{error.instance_path}: #{error.message}"
end
```

For repeated validation, compile the schema once and reuse the validator. A
schema registry owns the compiled resource graph, so schemas compiled by the
same registry also share their compiled external references.

```ruby
registry = Schemurai::SchemaRegistry.new(
  schemas: {
    "https://example.test/positive" => { "type" => "integer", "minimum" => 1 }
  }
)
validator = registry.compile({"$ref" => "https://example.test/positive"})

validator.valid?(1) # => true
validator.valid?(0) # => false
validator.validate(0).errors # detailed errors, without recompiling the schema
```

`Schemurai.compile` is a convenience for compiling a standalone
validator. Repeatedly compiling the same schema object with one registry reuses
its compiled schema graph. `Schemurai.validate` and `.valid?` continue
to accept raw JSON-like schemas and perform compilation internally.

Schema inputs are checked recursively before compilation. They must use the
built-in JSON-shaped Ruby classes described in
[`docs/compatibility-domain.md`](docs/compatibility-domain.md); rejected values
are never retained by a registry.

To resolve external references, pass a mapping of URIs to schemas using
`schemas:`.

```ruby
Schemurai.valid?(
  { "$ref" => "https://example.test/positive" },
  3,
  schemas: { "https://example.test/positive" => { "type" => "integer", "minimum" => 1 } }
)
```

Draft 2019-09 and Draft 2020-12 support their dialect-specific keywords, including
`$recursiveRef` / `$dynamicRef`, `$defs`, `dependentSchemas`, `dependentRequired`,
`minContains`, `maxContains`, and the `unevaluated*` applicators. Enable optional
validation for `contentEncoding` and `contentMediaType` with `content: true`.
Enable optional format assertions with `format: true`; support for each format is
listed separately below.

### Validation errors

```ruby
result = Schemurai.validate(
  { "$ref" => "https://example.test/positive" },
  -1,
  schemas: { "https://example.test/positive" => { "type" => "integer", "minimum" => 1 } }
)

validation_error = result.errors[0]
p validation_error.keyword # => "minimum"
p validation_error.instance_path # => ""
p validation_error.schema_path # => "/$ref/minimum"
p validation_error.message # => "number must be greater than or equal to 1"
```

`Result#errors` contains `Schemurai::ValidationError` objects.
Check the following attributes to investigate schema errors:

- `keyword` identifies the failed JSON Schema keyword. Schemurai uses
  `falseSchema` for a boolean `false` schema, which has no keyword of its own.
- `instance_path` is a JSON Pointer to the value that failed validation.
- `schema_path` is a JSON Pointer to the schema location that produced the
  error.
- `message` is a human-readable `String` describing the failure.

An empty path points to the instance or schema root. Error order is stable.
The presence and type of `message` are part of the public API, but its exact
wording is not. Use `keyword`, `instance_path`, and `schema_path`, rather than
matching `message`, when handling errors programmatically. `ValidationError#to_h`
returns these four attributes as a Hash.

### Thread / Ractor support

To share a registry between threads or Ractors, finish registering schemas and
make the registry shareable first. This eagerly compiles every registered
schema, resolves all references, and makes the registry deeply immutable.

```ruby
registry = Schemurai::SchemaRegistry.new(
  schemas: {
    "https://example.test/positive" => { "type" => "integer", "minimum" => 1 },
    "https://example.test/value" => { "$ref" => "https://example.test/positive" }
  },
  # enable virtual machine backend that is faster for iterative validation.
  backend: :vm
)
registry.make_shareable

# Each thread or Ractor creates and owns its validator.
validator = registry.validator_for("https://example.test/value")
```

`make_shareable` calls `Ractor.make_shareable` internally. It raises a
`ResolutionError` if a reference cannot be resolved. After it returns,
`validator_for` is read-only and may be called concurrently, while `compile` is
no longer available. A `Validator` contains per-validation mutable state and
must not be shared between threads or Ractors. With the VM backend, the registry
compiles and shares its bytecode before this transition, so those validators do
not compile separate instruction streams in each Ractor.

### Meta-schema validation

Meta-schema validation is opt-in so ordinary compilation does not pay its
additional time and memory cost. Set `validate_schema: true` when creating a
`SchemaRegistry` to validate every schema registered through `schemas:` and
every schema passed to `compile`. The convenience `compile`, `validate`, and
`valid?` methods accept the same option and apply it to their internal registry.
Schemas without `$schema` use the Draft 7 meta-schema. An invalid schema raises
`Schemurai::InvalidSchemaError`, whose `result` contains the detailed validation
errors.

```ruby
Schemurai.compile(schema, validate_schema: true)

registry = Schemurai::SchemaRegistry.new(
  schemas: external_schemas,
  validate_schema: true
)
validator = registry.compile(schema)

result = Schemurai.validate_schema(schema)
result.valid? # whether the schema itself is valid
```

`SchemaRegistry#validate_schema` and `#valid_schema?` perform explicit checks
regardless of the registry option and reuse meta-schema graph data within that
registry. The stateful validator used for a check is temporary; no global
validator is retained.

### Backend selection

`Schemurai.backend`, `SchemaRegistry#backend`, and `Validator#backend` expose
the actual backend. Pass `backend: :ruby` to force the Ruby oracle or
`backend: :vm` to ahead-of-time compile schemas into the native validator virtual
machine. Its compiler, immutable programs, rule structures, and evaluator are
implemented in C; schema graph construction and public result objects remain
shared Ruby infrastructure. Environment-based selection is documented in
[`docs/backend-selection.md`](docs/backend-selection.md).

## JSON Schema conformance

| Capability | Draft 7 | Draft 2019-09 | Draft 2020-12 |
| --- | --- | --- | --- |
| Required JSON-Schema-Test-Suite cases | Supported | Supported | Supported |
| Dialect-specific references | `$ref` | `$ref`, `$recursiveRef` | `$ref`, `$dynamicRef` |
| `unevaluatedItems` / `unevaluatedProperties` | Not applicable | Supported | Supported |
| `contentEncoding` / `contentMediaType` assertions | Opt-in[^content] | Opt-in[^content] | Opt-in[^content] |

The required-suite row covers every required case for the listed dialect in the
[official JSON Schema Test Suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite).
The applicable top-level optional cases are also tested, including arbitrary
precision numbers, ECMA-262 regular expressions, anchors, cross-draft references,
and dynamic references.

### Format assertion support

Formats are annotations by default in each standard dialect. Pass `format: true`
to enable the supported assertions below.[^format]

| Format | Assertion support |
| --- | --- |
| `date` | Supported |
| `time` | Supported |
| `date-time` | Supported |
| `duration` | Supported |
| `email` | Not supported |
| `idn-email` | Not supported |
| `hostname` | Not supported |
| `idn-hostname` | Not supported |
| `ipv4` | Supported |
| `ipv6` | Supported |
| `uri` | Not supported |
| `uri-reference` | Not supported |
| `iri` | Not supported |
| `iri-reference` | Not supported |
| `uuid` | Supported |
| `uri-template` | Not supported |
| `json-pointer` | Supported |
| `relative-json-pointer` | Supported |
| `regex` | Not supported |

Unsupported and unknown formats remain annotations when assertion is enabled by
the caller.

[^content]: Pass `content: true` to assert Base64 `contentEncoding` and JSON
    `contentMediaType`. Other encodings and media types remain annotations.
[^format]: A custom Draft 2020-12 meta-schema that declares the Format-Assertion
    vocabulary can assert supported formats without the option and rejects
    unsupported formats during schema compilation.

## Development

Run the test suite with:

```sh
bundle exec rspec
```

Verify the reviewed official-suite classifications with:

```sh
ruby script/oracle-cases --summary
```

The serialized oracle tools are `script/oracle-runner` and
`script/oracle-compare`.

Run the linter with:

```sh
bundle exec rubocop
```

The native extension uses LLVM 18 for formatting and linting:

```sh
bundle exec rake c:format
bundle exec rake c:format:check
bundle exec rake c:lint
```

## AI Disclosure

Large part of this work is generated by OpenAI Codex.
