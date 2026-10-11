# frozen_string_literal: true

require "json"
require "base64"
require_relative "../lib/schemurai"

$stdout.sync = true
abort "Run Ruby with --yjit to compare native against the requested YJIT baseline" unless RubyVM::YJIT.enabled?
width = Integer(ENV.fetch("BENCHMARK_WIDTH", "1000"))
iterations = Integer(ENV.fetch("BENCHMARK_ITERATIONS", "31"))
batch = Integer(ENV.fetch("BENCHMARK_BATCH", "100"))
content_bytes = Integer(ENV.fetch("BENCHMARK_CONTENT_BYTES", "4096"))
unique_shift = Integer(ENV.fetch("BENCHMARK_UNIQUE_SHIFT", "0"))
abort "benchmark settings must be positive" unless [width, iterations, batch, content_bytes].all?(&:positive?)
abort "uniqueness shift must be nonnegative" if unique_shift.negative?
clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

workloads = {
  "integer array" => [{"type" => "array", "items" => {"type" => "integer", "minimum" => 0}}, Array.new(width) { |i| i }],
  "object records" => [{"type" => "array", "items" => {
    "type" => "object", "properties" => {"id" => {"type" => "integer", "minimum" => 1}, "name" => {"type" => "string", "minLength" => 1}},
    "required" => %w[id name], "additionalProperties" => false
  }}, Array.new(width) { |i| {"id" => i + 1, "name" => "record"} }],
  "contains and unevaluated" => [{"$schema" => "https://json-schema.org/draft/2020-12/schema", "type" => "array",
                                  "contains" => {"type" => "integer"}, "unevaluatedItems" => false}, Array.new(width) { |i| i }],
  "static references" => [{"type" => "array", "items" => {"$ref" => "#/$defs/value"}, "$defs" => {"value" => {"type" => "integer", "minimum" => 0}}}, Array.new(width) { |i| i }],
  "unique numbers" => [{"type" => "array", "uniqueItems" => true}, Array.new(width) { |i| i }],
  "unique objects" => [{"type" => "array", "uniqueItems" => true}, Array.new(width) { |i| {"id" => i, "nested" => [i, "entry"]} }],
  "pattern strings" => [{"type" => "array", "items" => {"type" => "string", "pattern" => "^record[0-9]+$"}}, Array.new(width) { |i| "record#{i}" }],
  "overlapping property annotations" => [{"$schema" => "https://json-schema.org/draft/2020-12/schema",
                                          "anyOf" => Array.new(2) { {"properties" => width.times.to_h { |i| ["p#{i}", {"type" => "integer"}] }} },
                                          "unevaluatedProperties" => false}, width.times.to_h { |i| ["p#{i}", i] }]
}
dynamic_list = {"$schema" => "https://json-schema.org/draft/2020-12/schema", "$id" => "urn:dynamic-root", "$ref" => "urn:dynamic-list",
                "$defs" => {"value" => {"$dynamicAnchor" => "value", "type" => "integer", "minimum" => 0},
                            "list" => {"$id" => "urn:dynamic-list", "type" => "array", "items" => {"$dynamicRef" => "#value"}, "$defs" => {"value" => {"$dynamicAnchor" => "value"}}}}}
workloads["dynamic references"] = [dynamic_list, Array.new(width) { |i| i }]
workloads["fractional bounds"] = [{"type" => "array", "items" => {"type" => "number", "minimum" => 0.5, "maximum" => width + 0.5}}, Array.new(width) { |i| i + 0.5 }]
workloads["integer multiples"] = [{"type" => "array", "items" => {"type" => "integer", "multipleOf" => 3}}, Array.new(width) { |i| i * 3 }]
workloads["decimal multiples"] = [{"type" => "array", "items" => {"type" => "number", "multipleOf" => 0.01, "minimum" => 0, "maximum" => width + 1}}, Array.new(width) { |i| i + 0.25 }]
workloads["unique large integers"] = [{"type" => "array", "uniqueItems" => true}, Array.new(width) { |i| 2**200 + i }]
workloads["counted pattern strings"] = [{"type" => "array", "items" => {"type" => "string", "pattern" => "^SKU-[A-Z0-9]{8}$"}}, Array.new(width) { |i| "SKU-#{i.to_s.rjust(8, "0")}" }]
workloads["grouped pattern strings"] = [{"type" => "array", "items" => {"type" => "string", "pattern" => "^(?:ord|sku)-[0-9]{2,8}:[A-Z]+$"}}, Array.new(width) { |i| "ord-#{i.to_s.rjust(2, "0")}:OK" }]
workloads["long unanchored pattern strings"] = [{"type" => "array", "items" => {"type" => "string", "pattern" => "record[0-9]+"}}, Array.new(width) { "r" * 4096 + "ecord123" }]
workloads["pattern object records"] = [{"type" => "array", "items" => {"type" => "object", "properties" => {"name" => {"type" => "string", "pattern" => "^record[0-9]+$"}},
                                                                       "required" => ["name"], "additionalProperties" => false}}, Array.new(width) { |i| {"name" => "record#{i}"} }]
format_samples = {
  "date" => ["2024-02-29", "2023-02-29"],
  "time" => ["01:29:60.125+01:30", "01:29:60.125+01:00"],
  "date-time" => ["2024-02-29T12:34:56.125+09:00", "2023-02-29T12:34:56.125+09:00"],
  "duration" => ["P3Y6M4DT12H30M5S", "P3Y6M4DT12H30M5"],
  "ipv4" => ["192.168.123.234", "192.168.123.256"],
  "ipv6" => ["2001:db8:1234:5678:90ab:cdef:1234:5678", "2001:db8:1234:5678:90ab:cdef:1234:56789"],
  "uuid" => ["123e4567-e89b-12d3-a456-426614174000", "123e4567-e89b-12d3-a456-42661417400z"],
  "json-pointer" => ["/items/0/a~1b/~0value", "/items/0/a~1b/~2value"],
  "relative-json-pointer" => ["123/items/0/a~1b/~0value", "123/items/0/a~1b/~2value"]
}
format_samples.each do |name, (valid, _invalid)|
  workloads["format #{name}"] = [{"type" => "array", "items" => {"type" => "string", "format" => name}}, Array.new(width) { valid.dup }]
end
invalid_tails = [-1, {"id" => 0, "name" => "record"}, false, -1, 0.0, {"nested" => [0.0, "entry"], "id" => 0.0}, "bad", nil, -1, 0.25, 1, 0.001]
invalid_tails << 2**200
invalid_tails << "SKU-ABC123456"
invalid_tails << "ord-12:bad"
invalid_tails << "r" * 4096 + "ecord"
invalid_tails << {"name" => "bad"}
invalid_tails.concat(format_samples.values.map(&:last))
content_samples = {
  "base64" => [Base64.strict_encode64("native content payload"), "bmF0aXZlIGNvbnRlbnQgcGF5bG9hZB=="],
  "json" => ['{"id":1,"flags":[true,false,null],"name":"record"}', '{"id":1,"flags":[true,false,null],"name":"record",}'],
  "base64 json" => [Base64.strict_encode64('{"id":1,"flags":[true,false,null],"name":"record"}'), Base64.strict_encode64('{"id":1,"flags":[true,false,null],"name":"record",}')],
  "base64 json long" => [Base64.strict_encode64('{"name":"' + "x" * 256 + '"}'), Base64.strict_encode64('{"name":"' + "x" * 256 + '",}')],
  "base64 json large" => [Base64.strict_encode64('{"name":"' + "x" * content_bytes + '"}'), Base64.strict_encode64('{"name":"' + "x" * content_bytes + '",}')]
}
content_samples.each do |name, (valid, _invalid)|
  items = {"type" => "string"}
  items["contentEncoding"] = "base64" if name.include?("base64")
  items["contentMediaType"] = "application/json" if name.include?("json")
  workloads["content #{name}"] = [{"type" => "array", "items" => items}, Array.new(width) { valid.dup }]
end
invalid_tails.concat(content_samples.values.map(&:last))
workloads["large integer bounds"] = [{"type" => "array", "items" => {"type" => "integer", "minimum" => 2**100}},
  Array.new(width) { |i| 2**200 + i }]
invalid_tails << 0
workloads["large integer multiples"] = [{"type" => "array", "items" => {"type" => "integer", "multipleOf" => 3, "minimum" => 2**100}},
  Array.new(width) { |i| (2**200 + i) * 3 }]
invalid_tails << 2**200 * 3 + 1
workloads["wide schema integer bounds"] = [{"type" => "array", "items" => {"type" => "integer", "minimum" => 2**200}},
  Array.new(width) { |i| 2**256 + i }]
invalid_tails << 2**200 - 1
workloads["wide schema float bounds"] = [{"type" => "array", "items" => {"type" => "number", "minimum" => 2**200 + 1}},
  Array.new(width) { (2**200).to_f.next_float }]
invalid_tails << (2**200).to_f
workloads["unique high word integers"] = [{"type" => "array", "uniqueItems" => true},
  Array.new(width) { |i| 2**200 + (i << 64) + 1 }]
invalid_tails << 2**200 + 1
workloads["combined string assertions"] = [{"type" => "array", "items" => {
  "type" => "string", "minLength" => 1, "pattern" => "^[0-9]+$", "format" => "relative-json-pointer", "contentMediaType" => "application/json"
}}, Array.new(width) { |i| (i + 1).to_s }]
invalid_tails << "bad"
workloads["unique shuffled large integers"] = [{"type" => "array", "uniqueItems" => true},
  Array.new(width) { |i| 2**200 + (i << unique_shift) }.shuffle(random: Random.new(9571))]
invalid_tails << 2**200
late_unordered = Array.new(width) { |i| 2**200 + i }
late_unordered[-2], late_unordered[-1] = late_unordered[-1], late_unordered[-2] if width > 1
workloads["unique late unordered integers"] = [{"type" => "array", "uniqueItems" => true}, late_unordered]
invalid_tails << 2**200
record_names = Array.new(8) { |i| "field#{i}" }
workloads["object records dynamic keys"] = [{"type" => "array", "items" => {
  "type" => "object", "properties" => record_names.to_h { |name| [name, {"type" => "integer", "minimum" => 0}] },
  "required" => record_names, "additionalProperties" => false
}}, Array.new(width) { |i| 8.times.to_h { |field| ["field#{field}", i] } }]
invalid_tails << 8.times.to_h { |field| ["field#{field}", field.zero? ? -1 : 0] }
workloads["object records frozen keys"] = [workloads.fetch("object records dynamic keys").first,
  Array.new(width) { |i| 8.times.to_h { |field| ["field#{field}".freeze, i] } }]
invalid_tails << 8.times.to_h { |field| ["field#{field}".freeze, field.zero? ? -1 : 0] }
long_pointer = "/" + "a" * 128 + "~0/" + "b" * 128 + "~1"
workloads["format json-pointer long"] = [{"type" => "array", "items" => {"type" => "string", "format" => "json-pointer"}},
  Array.new(width) { long_pointer.dup }]
invalid_tails << long_pointer + "~2"
workloads = workloads.each_with_index.flat_map do |(name, (schema, instance)), index|
  invalid = if instance.is_a?(Hash)
    instance.merge("extra" => nil)
  else
    (name.start_with?("unique") ? instance : instance[0...-1]) + [invalid_tails.fetch(index)]
  end
  [["#{name} / valid", [schema, instance, true]], ["#{name} / invalid", [schema, invalid, false]]]
end.to_h
if ENV.key?("BENCHMARK_WORKLOAD")
  filter = ENV.fetch("BENCHMARK_WORKLOAD")
  workloads.select! { |name, _| name.start_with?("#{filter} / ") }
  abort "unknown benchmark workload #{filter.inspect}" if workloads.empty?
end
if ENV.key?("BENCHMARK_GROUP")
  group = ENV.fetch("BENCHMARK_GROUP")
  workloads.select! { |name, _| name.start_with?("#{group} ") }
  abort "unknown benchmark group #{group.inspect}" if workloads.empty?
end
results = {}
workloads.each do |name, (schema, instance, expected)|
  validators = %i[vm native].to_h { |backend| [backend, Schemurai.compile(schema, backend: backend, format: true, content: true)] }
  program = validators.fetch(:native).instance_variable_get(:@evaluator).instance_variable_get(:@program)
  abort "unsupported native validity for #{name}" if program.valid?(instance).nil?
  abort "unsupported native diagnostics for #{name}" if program.diagnostics(instance).nil?
  errors = validators.transform_values { |validator| validator.validate(instance).errors }
  abort "different detailed errors for #{name}" unless errors.fetch(:vm) == errors.fetch(:native)
  %i[valid? validate].each do |method|
    validators.each_value do |validator|
      result = validator.public_send(method, instance)
      actual = (method == :valid?) ? result : result.valid?
      abort "incorrect result for #{name}" unless actual == expected
      1000.times { validator.public_send(method, instance) }
    end
    samples = {vm: [], native: []}
    iterations.times do |iteration|
      # Alternate measurement order to reduce temperature/order bias.
      order = iteration.even? ? %i[vm native] : %i[native vm]
      order.each do |backend|
        start = clock.call
        batch.times { validators.fetch(backend).public_send(method, instance) }
        samples.fetch(backend) << (clock.call - start) / batch
      end
    end
    timings = samples.transform_values { |times| times.sort[times.length / 2] }
    allocations = validators.transform_values do |validator|
      GC.start
      before = GC.stat(:total_allocated_objects)
      batch.times { validator.public_send(method, instance) }
      (GC.stat(:total_allocated_objects) - before).fdiv(batch)
    end
    speedup = timings.fetch(:vm) / timings.fetch(:native)
    key = "#{name} / #{method}"
    results[key] = {seconds: timings, speedup: speedup, allocations: allocations}
    puts "%s: VM %.3f ms, native %.3f ms, %.2fx" % [key, timings.fetch(:vm) * 1000, timings.fetch(:native) * 1000, speedup]
  end
end
report = {ruby: RUBY_DESCRIPTION, yjit: RubyVM::YJIT.enabled?, width: width, iterations: iterations, batch: batch,
          content_bytes: content_bytes, unique_shift: unique_shift, results: results}
File.write(ENV.fetch("BENCHMARK_JSON"), JSON.pretty_generate(report)) if ENV.key?("BENCHMARK_JSON")
