# Performance Benchmark

The benchmark suite measures Schemurai performance for regression detection and
performance development. Each runner verifies correctness before measuring.

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

`memory_retention.rb` repeatedly uses one native validator and prints a CSV row
after each full GC. It reports RSS on Linux, Ruby heap state, native evaluator
size, and the containers retained directly by the evaluator. The default run
performs one million successful `valid?` calls in 20 batches:

```sh
bundle exec ruby benchmark/memory_retention.rb
```

Use `BENCHMARK_OPERATION` (`valid?` or `validate`), `BENCHMARK_INSTANCE`
(`valid` or `invalid`), and `BENCHMARK_SCHEMA` (`recursive` or `dynamic`) to
select the path. Set `BENCHMARK_FRESH=1` to allocate a new instance for every
call. `BENCHMARK_BATCH_SIZE`, `BENCHMARK_BATCHES`, and `BENCHMARK_WARMUP`
control the run length. For example, the long detailed-validation run used for
the native-backend memory investigation can be reproduced with:

```sh
BENCHMARK_OPERATION=validate BENCHMARK_INSTANCE=invalid \
  BENCHMARK_BATCH_SIZE=20000 BENCHMARK_BATCHES=100 \
  bundle exec ruby benchmark/memory_retention.rb
```

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
