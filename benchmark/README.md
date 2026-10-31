# Performance benchmarks

Run commands from the repository root. Choose a runner by the question being
measured, then keep its protocol and inputs identical across revisions.

| Directory | Purpose |
| --- | --- |
| [`suite/`](suite/) | Official JSON Schema cases: dialects, assertions and detailed errors |
| [`features/`](features/) | Synthetic workloads for public API features and VM behavior |
| [`native/compile/`](native/compile/) | Native construction costs and compilation growth |
| [`native/runtime/`](native/runtime/) | Native evaluation, memoization, equality and backend comparisons |
| [`profile/`](profile/) | Sustained execution for external CPU sampling |
| [`baseline/`](baseline/) | Ruby oracle baseline capture |
| [`real_world/`](real_world/README.md) | Pinned external schemas, generated inputs, correctness checks and mutation fuzzing |
| [`support/`](support/) | Shared runners, measurement protocols and comparison orchestration |
| [`fixtures/`](fixtures/) | Synthetic input builders |
| [`history/`](history/performance.md) | Historical measurements, optimization decisions and reproduction details |
| [`results/`](results/) | Deliberately retained measurement artifacts |

## Start here

```sh
bundle exec ruby benchmark/suite/draft2020_12.rb
SCHEMURAI_BACKEND=vm BENCHMARK_ONLY=validate bundle exec ruby benchmark/suite/draft7.rb
bundle exec ruby benchmark/suite/allocations.rb
bundle exec ruby --yjit -Iext/schemurai_native benchmark/native/runtime/comparison.rb
```

Build the native extension before running native workloads (`ruby extconf.rb`
and `make` from `ext/schemurai_native`). The real-world runner also needs the
pinned schema downloads; see its [setup and correctness guide](real_world/README.md).

## Official suites and API features

| Runner | Question / measured operations |
| --- | --- |
| `suite/draft7.rb`, `suite/draft2019_09.rb`, `suite/draft2020_12.rb` | Dialect throughput: `build`, `suite` (build + validation), `validate` (already compiled) |
| `suite/allocations.rb` | Ruby allocations for those three operations; dialect and all/content/format selection |
| `suite/formats.rb` | Supported Draft 2020-12 format assertions, grouped by format |
| `suite/content.rb` | Opt-in Base64/JSON assertions; expected validity derived independently of the backend |
| `suite/error_validation.rb` | Detailed errors for official cases and large synthetic object/`anyOf` cases; time and allocations |
| `features/repeated_validation.rb` | One compiled schema with a cycle of valid and invalid documents |
| `features/unique_items.rb` | Ruby/VM equality for unique numbers and objects, including duplicates at the end |
| `features/vm_evaluation.rb` | VM evaluated-property/item tracking, including exact failure paths |
| `features/validation_limits.rb` | Overhead of enabling error caps and deadlines without reaching them |
| `features/validation_deadlines.rb` | Time until a timeout interrupts large successful scans or diagnostic expansion |
| `baseline/oracle.rb` | Fixed Ruby-backend baseline: correctness digest, compilation, validation and allocations |
| `real_world/run.rb` | Compilation and validation by schema, size, failure position and shared/copied representation |

The suite runners use `BENCHMARK_TIME` and `BENCHMARK_WARMUP` where they use
`benchmark-ips`. Dialect, content and format runners accept `BENCHMARK_ONLY`
(`build`, `suite`, `validate`). Dialect runners accept `BENCHMARK_JSON` for one
selected operation. `JSON_SCHEMA_VALIDATOR_LIB` selects another checkout's
library in the suite runners and the repeated-validation, unique-items and VM
evaluation runners. Other runners load the library in their own checkout.

Allocation measurement is a separate protocol. In particular,
`suite/allocations.rb` enables format assertions only in `BENCHMARK_MODE=format`,
whereas the Draft 2020-12 throughput runner also enables the official
`format-assertion.json` cases. Do not assume these aggregates are identical.

## Native construction

| Runner under `native/compile/` | Measured region |
| --- | --- |
| `memo.rb` | Native construction from cached VM programs; plain, closed, reference, nested, shared and cyclic/dependency graphs; CPU and wall time, program bytes |
| `scope.rb` | Native construction from cached VM programs with single-name or sparse dynamic bindings; wall time and program bytes |
| `required.rb` | Native construction from a cached VM program with many properties/required names |
| `operand.rb` | Full native compilation of a deeply shared `const` value |
| `enum_batch.rb` | Full native compilation of enum choices sharing nested containers |

Cached-VM construction excludes schema discovery and VM compilation. Full
`Schemurai.compile` includes them. These are intentionally different protocols.
`operand.rb` and `enum_batch.rb` are construction probes without the validation
parity checks used by the cached-VM runners.

## Native evaluation

| Runner under `native/runtime/` | Workload / purpose |
| --- | --- |
| `comparison.rb` | VM/native public API comparison with YJIT, valid/invalid controls, complete error parity, native coverage and allocations |
| `policies.rb` | VM/native comparison of sparse/dense properties and nested applicators/references |
| `enum.rb` | VM/native enum lookup, first/last/missing choices and scalar/object values |
| `unique_large.rb` | VM/native uniqueness of large shuffled integer arrays; requires YJIT |
| `algorithms.rb` | Direct native algorithm growth: branches, property IDs, shared references, patterns and contains |
| `shared_scans.rb` | Public API scans with/without annotation tracking: patterns, formats, content and required fields |
| `runner_reuse.rb` | Repeated direct runner calls; thread CPU time, optional invalid inputs |
| `callback_setup.rb` | Direct runner calls with Hash/String subclasses and ordinary-container controls; CPU time and runner bytes |
| `content_scratch.rb` | Public API decoded-content scans by byte length; optional fresh runners using direct calls; wall or CPU time |
| `pointer_names.rb` | Public diagnostics with long ASCII/Unicode/escaped property names |
| `cyclic_memo.rb` | Direct evaluation of shared recursive instance/schema graphs plus distinct-tree/linear controls |
| `dynamic_memo.rb` | Direct evaluation of repeated references to an invariant dynamic binding |
| `contextual_memo.rb` | Direct evaluation with scope-dependent dynamic bindings and scalar/object annotations |
| `memo_turnover.rb` | Direct evaluation crossing invocation-cache limits before later shared-reference reuse |
| `repeated_positions.rb` | Direct evaluation of repeated instance positions plus distinct-container controls |
| `scope_projection.rb` | Direct evaluation of dynamic scopes with many irrelevant names |
| `shared_containers.rb` | Direct uniqueness/equality for deeply shared containers plus ordinary-tree controls |
| `batch_fingerprints.rb` | Direct uniqueness with shared subcontainers plus unshared controls |
| `wide_fingerprints.rb` | Direct uniqueness with mixed/nested wide integers |
| `unique_collisions.rb` | Direct uniqueness with deliberately colliding fingerprint low bits |

Public `valid?`/`validate` and direct native `valid?`/`diagnostics` measure
different layers. Preserve that distinction, including first-call versus reused
runner behavior. Most native runners check coverage; VM parity and invalid-input
coverage vary by runner. Timing is informational, not a CI performance gate.

For external sampling, use `profile/native.rb` with `-Ilib -Iext/schemurai_native`.
`PROFILE_WORKLOAD` selects pattern/content/unique/record and `PROFILE_SECONDS`
sets the duration. It uses direct native validity after compilation and warmup.

## Measurement and maintenance

Runner settings remain local: `BENCHMARK_ITERATIONS`, `BENCHMARK_BATCH`, size,
width, depth and filter variables have runner-specific defaults. Some older
probes use `MODE`, `WIDTH`, `FILTER`, `ROUNDS` or `TIMEOUT`. See each runner and
the [historical reproduction notes](history/performance.md) for exact settings.
`BENCHMARK_JSON` is supported only by runners that explicitly write it; its
existing JSON/JSONL schemas and units differ by runner.

`support/measurement.rb` shares alternating backend order, repeated CPU samples
and the existing upper-middle median convention. Warmup, GC policy, timed API,
clock selection, correctness checks and output remain explicit at each call
site. Single-call probes, dual-clock construction and adaptive deadline batches
retain their own protocols. Ruby allocation counts do not measure native heaps.

Add new cases to the matching runner when they share its measurement protocol.
Create a new runner when the measured layer or protocol differs, and list it
here. Preserve independent expected results and backend comparisons; do not
share production validation rules with correctness oracles. Suite-loading and
specialized input builders still have some duplication; consolidating their
assertion policies requires a separate review of the measured case sets.

The `benchmark / pull request` and `benchmark / native backends` workflows run
when `workflow:enable-benchmark` is added to a PR. Remove and re-add the label
to measure later commits. The former compares Draft 2020-12 build/suite/validate
for Ruby and VM using `script/benchmark-compare`. The latter uses
`native/runtime/comparison.rb`, copying that runner and its measurement helper
into the base checkout for same-harness comparisons. Real-world CI runs
`real_world/run.rb` alongside correctness and fuzz checks.

Runner paths changed during this organization; previous commands should use
the catalog above. Historical results keep their original meaning and are not
new performance claims. Use the same current harness on both revisions for
comparisons involving the shared measurement helper.
