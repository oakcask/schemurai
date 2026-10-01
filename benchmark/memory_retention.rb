# frozen_string_literal: true

require "objspace"

root = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(ENV.fetch("JSON_SCHEMA_VALIDATOR_LIB", File.join(root, "lib")))

require "schemurai"

operation = ENV.fetch("BENCHMARK_OPERATION", "valid?")
operations = %w[valid? validate]
raise "BENCHMARK_OPERATION must be one of: #{operations.join(", ")}" unless operations.include?(operation)

instance_kind = ENV.fetch("BENCHMARK_INSTANCE", "valid")
instance_kinds = %w[valid invalid]
unless instance_kinds.include?(instance_kind)
  raise "BENCHMARK_INSTANCE must be one of: #{instance_kinds.join(", ")}"
end

schema_kind = ENV.fetch("BENCHMARK_SCHEMA", "recursive")
schema_kinds = %w[recursive dynamic]
raise "BENCHMARK_SCHEMA must be one of: #{schema_kinds.join(", ")}" unless schema_kinds.include?(schema_kind)

fresh = ENV["BENCHMARK_FRESH"] == "1"
batch_size = Integer(ENV.fetch("BENCHMARK_BATCH_SIZE", "50000"))
batches = Integer(ENV.fetch("BENCHMARK_BATCHES", "20"))
warmup = Integer(ENV.fetch("BENCHMARK_WARMUP", "2000"))
raise "BENCHMARK_BATCH_SIZE must be positive" unless batch_size.positive?
raise "BENCHMARK_BATCHES must be positive" unless batches.positive?
raise "BENCHMARK_WARMUP must not be negative" if warmup.negative?

schemas = {
  "recursive" => {
    "$schema" => "https://json-schema.org/draft/2020-12/schema",
    "$id" => "urn:memory-retention-node",
    "type" => "object",
    "required" => %w[name values next],
    "properties" => {
      "name" => {"type" => "string", "pattern" => "\\Aitem-[0-9]+\\z", "minLength" => 6},
      "values" => {
        "type" => "array",
        "uniqueItems" => true,
        "contains" => {"type" => "integer", "minimum" => 0},
        "unevaluatedItems" => false
      },
      "next" => {"anyOf" => [{"type" => "null"}, {"$ref" => "urn:memory-retention-node"}]}
    },
    "additionalProperties" => false,
    "unevaluatedProperties" => false
  },
  "dynamic" => {
    "$schema" => "https://json-schema.org/draft/2020-12/schema",
    "$id" => "urn:memory-retention-dynamic-node",
    "$dynamicAnchor" => "node",
    "type" => "object",
    "properties" => {"next" => {"$dynamicRef" => "#node"}}
  }
}.freeze

def build_instance(schema_kind, instance_kind, index)
  if schema_kind == "dynamic"
    return {"next" => {"next" => {}}} if instance_kind == "valid"

    return {"next" => nil}
  end

  return {"name" => "item-#{index}", "values" => [index, index + 1, index + 2], "next" => nil} if instance_kind == "valid"

  {"name" => "x-#{index}", "values" => [index, index], "next" => nil, "extra-#{index}" => true}
end

def rss_kib
  status_path = File.join(File::SEPARATOR, "proc", "self", "status")
  status = File.read(status_path)
  match = status.match(/^VmRSS:\s+(\d+)/)
  raise "VmRSS is unavailable in #{status_path}" unless match

  Integer(match[1])
end

def sample(batch, evaluator)
  GC.start(full_mark: true, immediate_sweep: true)
  stat = GC.stat
  reachable = ObjectSpace.reachable_objects_from(evaluator)
  hashes = reachable.grep(Hash)
  arrays = reachable.grep(Array)
  values = [
    batch,
    rss_kib,
    stat.fetch(:heap_live_slots),
    stat.fetch(:heap_allocated_pages),
    stat.fetch(:old_objects),
    ObjectSpace.memsize_of(evaluator),
    hashes.length,
    hashes.sum(&:size),
    arrays.length,
    arrays.sum(&:size)
  ]
  puts values.join(",")
end

validator = Schemurai.compile(schemas.fetch(schema_kind), backend: :vm)
evaluator = validator.instance_variable_get(:@evaluator)
fixed_instance = build_instance(schema_kind, instance_kind, 0)
expected = instance_kind == "valid"
actual = validator.valid?(fixed_instance)
raise "validator returned #{actual.inspect}, expected #{expected.inspect}" unless actual == expected

iteration = 0
run = lambda do
  instance = fresh ? build_instance(schema_kind, instance_kind, iteration += 1) : fixed_instance
  validator.public_send(operation, instance)
end

puts "operation=#{operation} instance=#{instance_kind} schema=#{schema_kind} fresh=#{fresh}"
puts "batch_size=#{batch_size} batches=#{batches} warmup=#{warmup}"
puts "batch,rss_kib,live_slots,heap_pages,old_objects,evaluator_bytes," \
  "reachable_hashes,hash_entries,reachable_arrays,array_entries"

warmup.times { run.call }
sample(0, evaluator)

1.upto(batches) do |batch|
  batch_size.times { run.call }
  sample(batch, evaluator)
end
