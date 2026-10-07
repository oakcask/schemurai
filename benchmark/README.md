# Performance Benchmark

The benchmark suite measures Schemurai performance for regression detection and
performance development. Each runner verifies correctness before measuring.

## VM evaluation tracking

`vm_evaluation.rb` measures `valid?` and detailed `validate` on large objects
and arrays whose schemas need evaluated locations. The object combines two
overlapping `anyOf` branches with `unevaluatedProperties`; the array combines
`contains` with `unevaluatedItems`. Each has a valid instance and an invalid
instance with one trailing unevaluated location. The runner checks validity
and the exact error keyword and paths before measuring, and excludes compilation.

```sh
bundle exec ruby benchmark/vm_evaluation.rb
JSON_SCHEMA_VALIDATOR_LIB=../baseline/lib bundle exec ruby benchmark/vm_evaluation.rb
BENCHMARK_WIDTH=2000 BENCHMARK_ITERATIONS=31 BENCHMARK_JSON=vm-results.json \
  bundle exec ruby benchmark/vm_evaluation.rb
```

The backend is explicitly VM. `BENCHMARK_WIDTH` defaults to 1000 and
`BENCHMARK_ITERATIONS` to 31. Results are median elapsed time per call after
five warmup calls, plus average allocated objects per call measured separately
after `GC.start`. JSON output includes Ruby version, width, and iterations.

Compared with `e767a05` on Ruby 4.0.6, x86_64-linux, without YJIT,
using 1000 locations and 31 iterations:

| VM workload | Before (ms) | After (ms) | Speedup |
| --- | ---: | ---: | ---: |
| Object / `valid?` / valid | 15.676 | 0.767 | 20.4x |
| Object / `validate` / invalid | 15.248 | 0.782 | 19.5x |
| Array / `valid?` / valid | 4.003 | 0.556 | 7.2x |
| Array / `validate` / invalid | 4.126 | 0.600 | 6.9x |

All eight method/validity combinations improved by 6.9–20.4x. At 2000
locations, the range was 12.8–33.1x; at 16 locations, it was 1.09–1.30x.
Warmed allocation counts were unchanged (1–15 objects per call).

VM evaluation buffers now use sets for recording, merging, and looking up
evaluated locations, avoiding repeated linear scans. This changes annotation
collection and membership checks from quadratic to expected linear work.
Sets require linear hash storage and are reused between validations.
Speculative branches retain annotations but skip error path maintenance;
paths are restored before reporting errors outside the branch.

The existing workloads were also compared with 5 seconds of measurement,
2 seconds of warmup, `SCHEMURAI_BACKEND=vm`, and `BENCHMARK_ONLY=validate`:

| Workload | Before | After | Speedup |
| --- | ---: | ---: | ---: |
| Draft 7 / `valid?`, full suite | 0.944 ms | 0.942 ms | 1.00x |
| Draft 2019-09 / `valid?`, full suite | 2.08 ms | 2.10 ms | 0.99x |
| Draft 2020-12 / `valid?`, full suite | 2.17 ms | 2.20 ms | 0.99x |
| Repeated document / `valid?` | 3.20 μs | 3.21 μs | 1.00x |
| Official suite / `validate` | 5.83 ms | 5.89 ms | 0.99x |
| Large fixtures / `valid?` | 0.601 ms | 0.618 ms | 0.97x |
| Large fixtures / `validate` | 9.88 ms | 2.52 ms | 3.93x |

The last three rows use `error_validation.rb` with width 1000 and 20 allocation
iterations. These times are inverse mean throughput from `benchmark-ips`;
unlike the tracking table above, they are not medians.

The 2x target is exceeded for large annotation workloads and the existing
large detailed-validation workload, not for every VM operation. Small official
cases and ordinary repeated validation remain close to baseline, with measured
differences of up to about 3%. These are local measurements, not portable
performance guarantees.

Validation: the default RSpec suite passes (6522 examples, 1287 pending), as do
the complete-catalog Ruby/VM differential and Ractor tests, and RuboCop.
Forcing VM globally with `SCHEMURAI_BACKEND=vm bundle exec rspec` leaves two
pre-existing failures, both reproduced against the baseline: invalid schema
types in `spec/schemurai_spec.rb` and out-of-domain numeric coercion in
`spec/compatibility_domain_spec.rb`. No new failures were introduced.

## Unique items

`unique_items.rb` reproduces the quadratic `uniqueItems` workload using distinct
numbers and nested objects, plus duplicates at the end. It measures both Ruby
and VM backends through `valid?` and `validate`, excluding schema compilation.
Each result is the median elapsed time per call after a correctness/warmup call.
It also reports average allocated objects per call using
`GC.stat(:total_allocated_objects)` in a separate measurement after `GC.start`.

```sh
bundle exec ruby benchmark/unique_items.rb
JSON_SCHEMA_VALIDATOR_LIB=../baseline/lib bundle exec ruby benchmark/unique_items.rb
```

`BENCHMARK_SIZE` (default 2000) and `BENCHMARK_ITERATIONS` (default 5) control
the workload. Set `BENCHMARK_JSON` to save the size, iterations, and timings as
JSON for comparison, including an `allocations` map alongside the timing
`results` map. Use the same Ruby version and settings for both runs.

Measured on Ruby 4.0.6, x86_64-linux, with 2000 elements and 5 iterations,
comparing the original pairwise implementation with fingerprint buckets:

| Backend / `valid?` workload | Before (ms) | After (ms) | Speedup |
| --- | ---: | ---: | ---: |
| Ruby / distinct numbers | 392.484 | 0.351 | 1117x |
| Ruby / distinct nested objects | 1685.353 | 3.635 | 464x |
| VM / distinct numbers | 222.572 | 0.308 | 722x |
| VM / distinct nested objects | 826.228 | 3.414 | 242x |

Across all 16 combinations (including duplicates at the end and detailed
`validate` calls), speedups ranged from 228x to 1290x. At 10000 elements,
the new implementation took 1.5–1.9 ms for numbers and 17–19 ms for nested
objects. These are local measurements, not portable performance guarantees.

The index takes linear additional space and avoids pairwise comparisons when
fingerprints differ. Matching fingerprints still use JSON equality, preserving
numeric equality and object key order independence. Heavy hash collisions can
still cause quadratic comparisons. Arrays of at most 16 items use direct
comparisons to avoid indexing overhead.

The allocation optimization stores a single index per fingerprint and creates
a bucket array only for collisions. Structural fingerprints combine integer
hashes directly instead of allocating intermediate arrays.

Compared with the initial fingerprint implementation (`d8edff2`), on Ruby 4.0.6,
x86_64-linux, with 2000 elements and 101 iterations:

| Ruby / `valid?` workload | Before objects/call | After objects/call | Before (ms) | After (ms) |
| --- | ---: | ---: | ---: | ---: |
| Distinct numbers | 2001 | 1 | 0.302 | 0.268 |
| Numbers, duplicate at end | 2002 | 1 | 0.287 | 0.269 |
| Distinct nested objects | 18001 | 1 | 3.343 | 1.910 |
| Nested objects, duplicate at end | 18017 | 8 | 3.441 | 1.905 |

Across all 16 backend/method/workload combinations, allocations fell by
99.06–99.99% and elapsed time fell by 6–45%. At 10000 elements and 31
iterations, allocations fell by at least 99.81% and elapsed time fell by
10–44%. At 17 elements (just above the indexing threshold), all 16 timings
also improved; fixed validation/error overhead limited allocation reduction
for Ruby `validate` with duplicate numbers to 49%. Arrays of at most 16 items
still use the unchanged direct comparison path. These are local measurements.

`draft7.rb`, `draft2019_09.rb`, and `draft2020_12.rb` measure all supported
required and top-level optional cases from the corresponding official suite.
They report validator construction, end-to-end suite execution, and validation
with constructed validators.

Run the current implementation with:

```sh
bundle exec ruby benchmark/draft7.rb
```

Set `BENCHMARK_ONLY` to `build`, `suite`, or `validate` to isolate one workload.

Use the validation-only workload and allocation runner to measure the VM
backend against another checkout:

```sh
SCHEMURAI_BACKEND=vm BENCHMARK_ONLY=validate bundle exec ruby benchmark/draft7.rb
SCHEMURAI_BACKEND=vm bundle exec ruby benchmark/allocations.rb
JSON_SCHEMA_VALIDATOR_LIB=../baseline/lib SCHEMURAI_BACKEND=vm \
  BENCHMARK_ONLY=validate bundle exec ruby benchmark/draft7.rb
```

Measure allocated objects for the same build, end-to-end suite, and validation
workloads with:

```sh
bundle exec ruby benchmark/allocations.rb
```

Set `BENCHMARK_ITERATIONS` to control the number of measured iterations. The
default is 20. The script warms constructed validators before measuring and
uses `GC.stat(:total_allocated_objects)`, so it requires no profiler gem.

Set `BENCHMARK_DRAFT` to `draft7`, `draft2019-09`, or `draft2020-12`. Set
`BENCHMARK_MODE` to `content` or `format` to isolate opt-in content assertions
or the supported formats; the default mode is the complete dialect suite.

To reproduce a regression comparison, set `JSON_SCHEMA_VALIDATOR_LIB` to the
`lib` directory of a checkout at the baseline revision and run the same command.

## Dialect workloads

```sh
bundle exec ruby benchmark/draft7.rb
bundle exec ruby benchmark/draft2019_09.rb
bundle exec ruby benchmark/draft2020_12.rb
```

`formats.rb` measures assertion performance for every format listed as supported
in the project README: `date`, `time`, `date-time`, `duration`, `ipv4`, `ipv6`,
`uuid`, `json-pointer`, and `relative-json-pointer`. It runs every case from the
corresponding Draft 2020-12 official format files with format validation enabled.
Results are reported separately for each format.

```sh
bundle exec ruby benchmark/formats.rb
```

Set `BENCHMARK_FORMAT` to any one of those formats to measure it alone while
retaining the same correctness checks and workloads.

```sh
BENCHMARK_FORMAT=date bundle exec ruby benchmark/formats.rb
```

`content.rb` measures opt-in Base64 and JSON content assertions against the
official content cases. Newer drafts specify these keywords as annotations, so
the runner derives the expected opt-in assertion result independently. Select a
dialect with `BENCHMARK_DRAFT`:

```sh
SCHEMURAI_BACKEND=vm BENCHMARK_DRAFT=draft2020-12 \
  bundle exec ruby benchmark/content.rb
```

`repeated_validation.rb` measures repeated validation throughput after compiling
one Draft 2020-12 schema once:

```sh
bundle exec ruby benchmark/repeated_validation.rb
```

`BENCHMARK_DOCUMENTS` controls the number of valid and invalid documents cycled
through the compiled validators. Schema compilation is outside the measured
section.

`error_validation.rb` measures detailed validation over the Draft 2020-12
official suite together with official-suite-shaped fixtures for a large object
and a large `anyOf`. It reports both allocated objects and throughput. The large
fixtures include valid and invalid cases so their expected results are checked
before measurement.

```sh
bundle exec ruby benchmark/error_validation.rb
```

`BENCHMARK_WIDTH` controls the number of object properties and `anyOf`
alternatives. `BENCHMARK_ITERATIONS` controls the allocation measurement.

Set `BENCHMARK_ONLY` to `build`, `suite`, or `validate` to run one workload.
This is useful for longer, lower-variance measurements:

```sh
BENCHMARK_ONLY=suite BENCHMARK_TIME=15 BENCHMARK_WARMUP=3 \
  bundle exec ruby benchmark/draft2020_12.rb
```

`BENCHMARK_TIME` and `BENCHMARK_WARMUP` control the measurement and warmup
durations for the benchmark scripts that use time-based measurement.

To compare another checkout, point `JSON_SCHEMA_VALIDATOR_LIB` at its `lib`
directory while running the same script and settings:

```sh
JSON_SCHEMA_VALIDATOR_LIB=../baseline/lib BENCHMARK_ONLY=suite \
  BENCHMARK_TIME=15 BENCHMARK_WARMUP=3 \
  bundle exec ruby benchmark/draft2020_12.rb
```
