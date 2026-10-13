# Performance Benchmark

The benchmark suite measures Schemurai performance for regression detection and
performance development. Each runner verifies correctness before measuring.

The `benchmark / pull request` and `benchmark / native backends` workflows run
only when `workflow:enable-benchmark` is added to a pull request. Commits pushed
afterward do not start another run; remove and re-add the label to benchmark
the updated PR. Other labels do not run benchmarks.

## Shared native scans

`native_shared_scans.rb` checks direct native coverage and exact VM verdict/error
parity before timing native `valid?` and `validate`. It covers pattern, format and
content arrays with a prefix offset, ordinary and tracked evaluation, valid and
invalid inputs, and required/dependent-required objects. Compilation is excluded;
Ruby allocation counts are reported separately. Use `native_scope_compile.rb`
for DFS-related constructor time and reported native program memory.

```sh
BENCHMARK_JSON=shared-scans.json bundle exec ruby --yjit -Iext/schemurai_native benchmark/native_shared_scans.rb
```

Run the same settings against base and candidate release builds without other
CPU-heavy work. Compare repeated runs before attributing small changes to the
refactoring. Width, batch size and sample count can be set with
`BENCHMARK_WIDTH`, `BENCHMARK_BATCH` and `BENCHMARK_ITERATIONS`.

## Opt-in error cap and timeout (draft)

`validation_limits.rb` measures ordinary calls, `max_errors:` alone, `timeout:`
alone and both together on 1,000 successful/failing records. It verifies full
results, warms each configuration, calibrates batches and shuffles their order.
GC stays enabled and runs before each batch. `BASELINE=1` measures only ordinary
calls and works with the pre-change version. Compilation is outside timing.

```sh
ruby -Ilib -Iext/schemurai_native benchmark/validation_limits.rb
BASELINE=1 ruby -Ilib -Iext/schemurai_native benchmark/validation_limits.rb
ruby -Ilib -Iext/schemurai_native benchmark/validation_deadlines.rb
```

The deadline runner measures observed latency for 1 ms cooperative timeouts.
No individual scalar operation is preempted; timings are machine/workload
specific and do not establish a hard return-time guarantee.

Measured on Ruby 4.0.6, Linux x86_64, Ryzen 9 7900X, YJIT disabled, native
release build. The baseline is main at `1bc9ef2`. Each cell is the median of
nine calibrated batches (target 50 ms); candidate modes run in shuffled order.
Baseline and candidate runs are sequential. All values are microseconds per
invocation. Raw samples and runtime metadata are in
[`validation_limits_results.jsonl`](validation_limits_results.jsonl).

| Backend / workload / method | Before change | Disabled | Errors only | Timeout only | Both |
| --- | ---: | ---: | ---: | ---: | ---: |
| ruby / successful / valid? | 1735.854 | 1691.042 | 1697.417 | 2007.888 | 2011.816 |
| ruby / successful / validate | 3550.498 | 3569.701 | 3813.327 | 3951.962 | 3949.182 |
| ruby / failing / valid? | 2.658 | 2.707 | 2.832 | 3.955 | 3.946 |
| ruby / failing / validate | 7025.369 | 7094.050 | 8005.643 | 8195.014 | 8251.810 |
| vm / successful / valid? | 542.981 | 523.380 | 522.263 | 849.743 | 849.672 |
| vm / successful / validate | 1907.601 | 1991.931 | 2303.349 | 2505.602 | 2512.107 |
| vm / failing / valid? | 1.080 | 1.175 | 1.333 | 2.599 | 2.602 |
| vm / failing / validate | 5266.614 | 5431.795 | 6049.753 | 6267.285 | 6277.114 |
| native / successful / valid? | 16.196 | 16.956 | 17.133 | 20.369 | 20.378 |
| native / successful / validate | 114.605 | 114.841 | 116.431 | 119.792 | 119.850 |
| native / failing / valid? | 0.170 | 0.260 | 0.362 | 1.141 | 1.167 |
| native / failing / validate | 1926.314 | 1880.135 | 1973.794 | 2015.484 | 2029.537 |

Disabled calls still pay keyword dispatch and lightweight polling branches;
these measurements do not prove zero overhead. Longer workloads ranged from
0.96x to 1.05x the baseline. Native early failure increased from 0.170 to
0.260 us; explicit errors-only kwargs add a small validation cost even though
`valid?` uses the ordinary evaluator. Ratios on such tiny calls exaggerate
absolute costs. Negative differences and a few-percent changes may be noise.

Compared with the candidate's disabled calls, successful `validate` costs about
1.07x / 1.16x / 1.01x for errors only and 1.11x / 1.26x / 1.04x for timeout only
(Ruby / VM / native). Failing `validate` costs about 1.13x / 1.11x / 1.05x for
errors only and 1.16x / 1.15x / 1.07x for timeout only. These workloads do not
exercise expensive regexps, custom callbacks or timed bulk fast-path changes.

Observed medians with a 1 ms timeout on a 2,000,000-integer successful array
were 1.033 / 1.025 / 1.020 ms for `valid?` and 1.102 / 1.065 / 1.022 ms for
`validate` (Ruby / VM / native). Expanding failing shared-reference diagnostics
stopped in 1.761 / 1.677 / 1.105 ms. Nine samples per case and their maxima are
in the same artifact. This measures cooperative responsiveness for these
workloads; it is not a guaranteed return time.

## Shared native reference annotations

`native_algorithms.rb` includes chains with two references to the preceding
definition at every level. The object leaf evaluates property `x`, the array
leaf evaluates index zero, and the root rejects unevaluated locations. Before
annotation memoization, successful traversal expanded to O(2^D) evaluations
for depth D even though the compiled graph has O(D) nodes. With invocation-local
coverage reuse, these equal-depth chains take O(D) evaluations plus annotation
copying and merging. The runner checks native coverage and exact VM parity
before timing, with compilation excluded.

```sh
FILTER='shared-reference annotations=' ruby --yjit -Ilib -Iext/schemurai_native benchmark/native_algorithms.rb
```

Local medians on Ruby 4.0.6/YJIT, x86_64-linux, compared with `2439118`:

| Kind / depth | Before validity (µs) | After validity (µs) | Before diagnostics (µs) | After diagnostics (µs) |
| --- | ---: | ---: | ---: | ---: |
| Object / 4 | 1.349 | 0.895 | 4.422 | 1.847 |
| Object / 8 | 20.410 | 1.622 | 70.842 | 3.194 |
| Object / 12 | 363.548 | 2.215 | 1,148.681 | 4.730 |
| Object / 16 | 6,168.412 | 3.187 | 18,547.277 | 6.617 |
| Array / 4 | 1.351 | 0.820 | 4.825 | 2.083 |
| Array / 8 | 21.344 | 1.594 | 76.069 | 3.176 |
| Array / 12 | 389.558 | 2.372 | 1,260.346 | 5.012 |
| Array / 16 | 6,485.829 | 3.646 | 20,249.494 | 6.859 |

Verdicts retain up to 4,096 results; tracked validity and diagnostic successes
share up to 8,192 results and a 65,536-slot annotation budget. FIFO admission
replaces old results when a limit is reached. Scope-dependent results additionally
key their effective dynamic bindings; selected cyclic and recursive candidates
include exact guard contexts as described below. Failing diagnostics retain
distinct schema-path errors and can require exponential output size. These
measurements establish improvement for the successful static-reference workload,
not a complexity bound for arbitrary schemas or an all-suite speedup.

### Shared cyclic and recursive references

`native_cyclic_memo.rb` constructs O(D) shared array/object containers under
cyclic static, dynamic and recursive schemas, plus a doubled definition chain
ending in a self-reference. Cycles previously excluded every reachable target
from memoization, producing O(2^D) successful evaluation work. Exact guard
membership and effective bindings now permit reuse. A bounded proof of input
acyclicity removes irrelevant ancestor guards; inconclusive proofs preserve the
full guard context. Tests compare shallow failures and cyclic Ruby containers
with the VM, and check deep successful evaluations through the raw native API.

```sh
ruby -Ilib -Iext/schemurai_native benchmark/native_cyclic_memo.rb
```

Local medians on Ruby 4.0.6 without YJIT, x86_64-linux, compared with `c1c9fe2`
(the affected paths were unchanged through `bc7407e`), excluding compilation:

| Workload / size | Before validity (µs) | After validity (µs) | Before diagnostics (µs) | After diagnostics (µs) |
| --- | ---: | ---: | ---: | ---: |
| Shared array / 8 | 21.634 | 4.430 | 22.463 | 4.893 |
| Shared array / 12 | 397.423 | 7.662 | 390.458 | 8.321 |
| Shared array / 16 | 6,632.687 | 11.213 | 6,732.360 | 12.524 |
| Shared array / 20 | 112,919.428 | 15.359 | 112,085.795 | 16.483 |
| Shared object / 20 | 209,187.498 | 19.370 | 209,740.377 | 19.361 |
| Dynamic array / 20 | 110,802.723 | 16.750 | 108,920.193 | 17.583 |
| Recursive array / 20 | 131,607.929 | 16.553 | 132,096.786 | 17.636 |
| Definition chain / 20 | 104,435.704 | 8.671 | 290,733.770 | 17.497 |
| Distinct recursive trees / 1,000 | 164.877 | 177.863 | 163.124 | 178.904 |
| Linear recursive object / 32 | 2.859 | 2.574 | 3.205 | 2.828 |

The distinct-tree control incurs approximately 8–10% overhead. A repeat detector
limits heavy context construction to revisited positions, with safe false
positives. Cache and proof budgets bound retained memory; eviction, genuinely
different guard contexts and failed diagnostic output still prevent a universal
polynomial-time guarantee.

### Invocation cache turnover

`native_memo_turnover.rb` uses distinct annotated objects in an array, exceeding
the invocation entry limit. Before FIFO eviction, saturation stopped all new
admissions and later objects expanded their shared definition chain to O(2^D)
work. When the per-object working set fits the cache, replacement keeps this
workload at O(ND), plus annotation copying, for N objects and depth D.

```sh
ruby -Ilib -Iext/schemurai_native benchmark/native_memo_turnover.rb
```

Local single-call observations on Ruby 4.0.6, x86_64-linux, without YJIT,
compared with `9f69db3`; compilation is excluded:

| Depth / objects | Before validity (ms) | After validity (ms) | Before diagnostics (ms) | After diagnostics (ms) |
| --- | ---: | ---: | ---: | ---: |
| 8 / 1,024 | 18.131 | 4.058 | 18.663 | 3.420 |
| 12 / 1,024 | 370.609 | 5.136 | 380.261 | 4.992 |
| 16 / 1,024 | 6,850.908 | 5.902 | 6,944.446 | 5.823 |
| 16 / 128 | 0.968 | 1.082 | 0.464 | 0.512 |

FIFO adds a bounded queue with one key per retained result and slot accounting
per entry. It also adds admission work, visible in the small control above.
Eviction releases annotation allocations before copying the admitted result;
oversized single results are skipped. Workloads larger than the cache working
set can still thrash, so this is not a universal polynomial-time guarantee.
The runner checks VM parity on a one-object sample and direct native coverage
for each measured array. Regression tests compare full ordered VM errors after
turnover, including mutation of the final object. Rust tests check entry and
slot limits, eviction across coverage policies, and oversized-result rejection.

### Invariant dynamic references

A dynamic reference can have only one possible target in the compiled engine.
Previously its presence disabled memoization for the entire reachable shared
subgraph, making the two-reference definition chain exponential even without
any scope-dependent behavior. After anchor binding reaches its fixed point,
the compiler proves that every binding equals the fallback target and uses
static resolution internally. Diagnostic paths keep `$dynamicRef`. Binding
overrides, fallback mismatches and recursive references keep their scope rules.

```sh
ruby -Ilib -Iext/schemurai_native benchmark/native_dynamic_memo.rb
```

For the scalar-leaf depth-16 workload, local single-call observations on Ruby
4.0.6/x86_64-linux without YJIT dropped from about 4,060 µs to 32 µs for
validity and 14,161 µs to 32 µs for diagnostics. These are indicative samples;
the structural change reduces this equal-depth successful chain from O(2^D)
to O(D) evaluation work, within the invocation cache limits. Compilation adds
O(A + E) work and O(K) temporary slots for compiled anchor bindings A,
instructions E and anchor names K. The benchmark checks direct native coverage
and VM parity outside timing. Regressions include annotation propagation,
invalid source paths, GC compaction, and existing dynamic override cases.

### Scope-dependent dynamic references

`native_contextual_memo.rb` evaluates a shared definition chain twice under
different outer resources. It exercises one and two dynamic names, both scalar
leaves and object leaves exporting annotations. Compile and VM parity checks
are outside timing, and every measured call checks direct native coverage.
Results are medians of seven native calls on Ruby 4.0.6/x86_64-linux without
YJIT, compared with `7307b40`:

```sh
ruby -Ilib -Iext/schemurai_native benchmark/native_contextual_memo.rb
```

| Shape / names / depth | Before validity (µs) | After validity (µs) | Before diagnostics (µs) | After diagnostics (µs) |
| --- | ---: | ---: | ---: | ---: |
| Scalar / 1 / 12 | 605.254 | 4.624 | 2,143.336 | 11.707 |
| Scalar / 1 / 16 | 10,864.251 | 6.722 | 37,280.972 | 14.604 |
| Scalar / 2 / 12 | 1,340.445 | 10.888 | 3,500.203 | 18.933 |
| Scalar / 2 / 16 | 23,066.467 | 15.227 | 59,947.403 | 24.760 |
| Object / 2 / 12 | 2,298.173 | 14.484 | 5,734.457 | 23.557 |
| Object / 2 / 16 | 38,259.172 | 19.303 | 93,983.905 | 31.202 |

The previous O(2^D) successful chain becomes O(D) node evaluation work per
effective scope, plus annotation copying and O(KS) key construction for K
dynamic names and S scope frames. Single-name keys use the existing effective
binding without allocation or scope traversal. Scope-independent nodes keep
their scope-independent reuse and original three-word cache keys. The static
scalar depth-16 control in `native_algorithms.rb` measured 2.458 → 2.700 µs for
validity and 6.591 → 6.928 µs for diagnostics, indicating a small additional
eligibility-check cost in these local samples. This does not guarantee linear work when scope
counts, annotations or schema working sets grow beyond the cache budgets.

Cycle analysis includes every possible binding through one shared dispatch
vertex per anchor name, taking O(N + E + A + K) work/storage instead of
materializing reference-count × binding-count edges. The engine retains one
extra boolean per node indicating scope dependence. Scope IDs map into disjoint blocks of native node IDs with checked arithmetic,
retaining the existing three-word cache keys. For multiple names, exact signatures are
interned with FIFO limits of 4,096 entries and 65,536 binding slots (up to
1 MiB of binding payload on 64-bit builds), plus bounded table/queue metadata.
The table and queue share each signature buffer. Monotonic IDs prevent old
evaluation results from aliasing newly admitted scopes after eviction.

Native regressions check changing bindings at the same instance and depth,
including both dynamic names, complete branch counts, exported annotations,
ordered failure paths and GC compaction without VM fallback. Rust tests check
outermost-binding equivalence, interner entry/slot turnover and ID uniqueness,
oversized-signature rejection, and cycles introduced only by override targets.

### Dynamic binding compilation

`native_scope_compile.rb` times native construction from cached VM programs.
The single-name case varies resources sharing a dynamic body; the sparse case
gives each resource one distinct anchor name. Both verify direct native coverage
and exact ordered VM failures. GC runs before each of seven construction
samples, outside timing. Local medians on Ruby 4.0.6/x86_64-linux without YJIT,
compared with `c1c9fe2`:

```sh
ruby -Ilib -Iext/schemurai_native benchmark/native_scope_compile.rb
MODE=sparse WIDTH=512 ruby -Ilib -Iext/schemurai_native benchmark/native_scope_compile.rb
```

| Mode / resources | Before construction (ms) | After construction (ms) | Before reported program bytes | After reported program bytes |
| --- | ---: | ---: | ---: | ---: |
| Single / 128 | 0.445 | 0.501 | 177,707 | 177,707 |
| Single / 2,048 | 12.144 | 10.354 | 2,825,387 | 2,825,387 |
| Single / 8,192 | 90.115 | 51.092 | 11,297,963 | 11,297,963 |
| Sparse / 32 | 0.320 | 0.272 | 61,257 | 44,873 |
| Sparse / 128 | 3.391 | 2.258 | 373,865 | 177,257 |
| Sparse / 512 | 73.179 | 30.759 | 4,638,953 | 706,793 |

Single-name metadata previously scanned the complete binding table for every
compiled node, taking O(NA) work for N nodes and A bindings. It now uses the
existing index in O(N) expected work. A resolved-name prefix per resource replaces
the Cartesian pending-pair buffer and absent-binding map entries. Only positive
bindings and their programs are stored; missing lookups no longer append `nil`
GC roots. Binding-related discovery storage is O(R + K + A) for R resources,
K names and A actual bindings, instead of O(RK) negative entries and roots.
The Ruby lookup interface still probes all resource/name pairs, so lookup work
remains O(RK), plus compilation and scans for later discovery passes.

The prefix map adds O(R) temporary counters, which can add cost to small
single-name cases, as the 128-resource control shows. Reported bytes come from
approximate `ObjectSpace.memsize_of` and omit some native index buffers. Separate
`MODE=sparse WIDTH=512` runs measured process peak RSS of 131,156 KiB before and
27,016 KiB after with `/usr/bin/time -f %M`; these include Ruby, schema/VM data,
retained programs and constructor scratch, rather than isolating native buffers.
Regression coverage includes new names and resources discovered while compiling
overrides, missing-binding fallback, ordered diagnostics and GC compaction.

### Indexed dynamic binding discovery

The earlier sparse-storage change still performed O(RK) resource/name queries.
Multi-name discovery now snapshots actual declaration names and maintains a
reverse index from names to reached resources. New registered names join that
index; newly added declarations join already registered names. Counts/prefixes
also cover external documents adding anchors to an existing resource. The
single-name path keeps direct queries to avoid enumerating unused declarations.
Dynamic name registration uses an exact hash index instead of O(K) scans.

The same cached-VM constructor protocol now includes 1,024 and 2,048 sparse
resources. Release builds, Ruby 4.0.6, Rust 1.99.0, seven samples, YJIT disabled:

| Sparse resources/names | Before indexed discovery (ms) | After (ms) |
| --- | ---: | ---: |
| 512 | 44.691 | 1.976 |
| 1,024 | 174.284 | 4.269 |
| 2,048 | 664.779 | 9.444 |

Expected join work is O(RP + B + K + A + T), excluding name bytes and child
compilation: P passes scan R reached resource counts, B actual declarations are
indexed once, K names join A bindings, and T counts names copied into Ruby
snapshot arrays. Stable tables are copied once; repeated growth can recopy older
keys. Temporary storage is O(R + B + K + A), including unused declarations B.
Name handles have temporary GC roots across allocating compilation callbacks.
These roots and the compiler-only name-ID table are released at the fixed point;
runtime binding tables remain O(K + A). Multi-name resources with many unused
anchors can pay more enumeration work. This is a sparse join improvement, not a
claim that complete compilation is universally linear.

Single-name controls retained direct queries: 8,192 resources measured 48.696 ms
in the after run (previous sparse-storage measurement 51.092 ms). Approximate
reported program sizes stayed close, with additional struct headers; temporary
index allocations are absent from the completed program. Regressions force GC
compaction in compiler callbacks and check late new resources/names and late
anchors appended to existing resources, including an already registered name.
The old implementation missed the latter override and omitted its `minimum`
error; validity and full ordered errors now match the resolved VM graph.

## Repeated instance positions

`native_repeated_positions.rb` has one `$ref` inside each `items` or
`additionalProperties` rule. Its depth-D schema and shared Ruby instance each
have O(D) nodes, but evaluation previously took O(2^D) work: memo eligibility
counted schema reference edges and missed repeated calls from one position loop.
It now admits acyclic loop children whose reachable graph contains another
position loop. The existing scope-aware keys, cycle exclusions, success-only
diagnostic results and FIFO entry/annotation budgets apply unchanged. Graph
analysis adds two temporary bit vectors and propagates iteration reachability
in the existing DFS, retaining O(N + E + A + K) analysis work/storage.
Position-only scalar/simple-record children skip caching so ordinary arrays
avoid extra admissions. Candidates with nested loops but distinct instance
values can still pay lookup, admission and annotation-copy work without reuse.

```sh
ruby -Ilib -Iext/schemurai_native benchmark/native_repeated_positions.rb
```

Release build, Ruby 4.0.6, Rust 1.99.0, YJIT disabled. Seven batches of five
native calls per case, compilation excluded, median microseconds:

| Input | Before validity | After validity | Before diagnostics | After diagnostics |
| --- | ---: | ---: | ---: | ---: |
| Shared array depth 20 | 73,264.546 | 3.016 | 73,143.010 | 3.228 |
| Shared object depth 20 | 91,735.036 | 3.749 | 91,394.098 | 4.036 |
| 1,000 distinct records | 17.100 | 16.475 | 27.222 | 26.252 |
| 1,000 distinct records, tracked | 26.937 | 26.600 | 27.951 | 27.646 |

The binary chain's working set fits the caches, giving O(D) traversal, plus
annotation copying when needed. Cache bounds do not guarantee polynomial work
for every input graph. Failing diagnostics retain each required instance/schema
path and can require exponential output. Regression coverage exercises depth-24
shared arrays/objects through items, contains, unevaluated items/properties and
pattern/additional properties, plus full shallow failing VM error parity.

## Shared container equality and fingerprints

`native_shared_containers.rb` keeps shared Ruby input graphs intact and reuses a
native program for `uniqueItems`. Each level repeats a child nonadjacently, so
D levels have O(D) containers but previously required O(2^D) equality/hash work.
Two separately constructed graphs test structural equality rather than object
identity. Two entries use equality directly; seventeen entries exercise the
fingerprint index and collision comparison. Measurements use seven batches of
five native validity calls, with compilation outside timing.

```sh
ruby -Ilib -Iext/schemurai_native benchmark/native_shared_containers.rb
```

Ruby 4.0.6, Rust 1.99.0, release build, YJIT disabled, median microseconds:

| Input | Before | After |
| --- | ---: | ---: |
| Shared array depth 20, 2 entries | 49,493.226 | 2.779 |
| Shared array depth 20, 17 entries | 72,105.756 | 6.072 |
| Shared object depth 20, 2 entries | 126,566.698 | 6.255 |
| Shared object depth 20, 17 entries | 230,391.754 | 12.887 |
| Ordinary tree width 32 | 3.152 | 3.126 |
| Ordinary tree width 256 | 24.945 | 24.210 |

One comparison/hash owns a FIFO cache of at most 4,096 completed container
results. Equality keys retain both ordered identities and depth; hash keys retain
identity and depth. Caches skip the first four relative levels to avoid
bookkeeping for shallow ordinary trees. Deeper trees incur extra lookup/storage
work even without sharing. Reuse preserves full checks of NaN and unsupported
children, depth limits and exact collision equality. It never persists across
calls or Ruby callbacks, so mutation and GC compaction need no invalidation.
The binary chain's reusable working set fits, giving O(D) traversal after a
constant prefix. Eviction bounds memory without guaranteeing polynomial time
for every shared graph. Regressions use depth 32, nonadjacent repeated arrays
and objects, separately built equal graphs, mutation, non-finite numbers and
compaction. Native `const`/`enum` share the same primitives; this benchmark avoids
schema processing that can expand a shared schema value before native execution.

## Wide integer fingerprints

`native_wide_fingerprints.rb` exercises 4,097-bit integers whose low 1,024 bits
and magnitude sizes are identical. Mixed arrays and nested containers use the
canonical structural fingerprint path, bypassing the Bignum-only adaptive
index. Low-word sampling put every such integer into one bucket, causing
O(N²) equality checks in `uniqueItems`; it also collapsed compiled enum
candidate indexes. The canonical oversized-integer path now uses CRuby's full
digit hash without Ruby dispatch or allocation. No finite Float can equal
these magnitudes, so this preserves Integer/Float fingerprint compatibility.

```sh
ruby -Ilib -Iext/schemurai_native benchmark/native_wide_fingerprints.rb
```

Local single-call observations on Ruby 4.0.6, x86_64-linux, without YJIT,
compared with `3e2da08`; compilation is excluded:

| Shape / integers | Before validity (ms) | After validity (ms) | Before diagnostics (ms) | After diagnostics (ms) |
| --- | ---: | ---: | ---: | ---: |
| Mixed / 1,024 | 8.290 | 0.814 | 8.235 | 0.293 |
| Mixed / 4,096 | 136.823 | 1.707 | 136.287 | 1.234 |
| Nested / 1,024 | 31.895 | 0.161 | 31.876 | 0.148 |
| Nested / 4,096 | 518.120 | 0.650 | 528.672 | 0.629 |

Hashing now reads all Bignum digits, taking O(B) work for B digit bytes instead
of a bounded sample. Expected uniqueness work is O(NB), excluding other
container bytes and exact collision comparisons, with the existing O(N)
index storage. Arbitrary full hash collisions can still require quadratic
comparisons. The homogeneous Bignum path retains its bounded sampling and
adaptive retry behavior. Regression cases cover mixed values, nested arrays
and objects, separately allocated equal integers, enum hits and misses,
negative integers, and Integer/Float equality at the 1,024-bit boundary.

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

## Native evaluation policies

`native_policies.rb` measures sparse and dense property lookup and deeply nested
`allOf`, conditionals and references whose annotations are consumed by
`unevaluatedProperties`. Each case includes valid and invalid inputs and both
`valid?` and `validate`. Compilation is excluded. Before measuring, the runner
requires native validity/diagnostic coverage and compares validity and complete
ordered errors with the VM.

```sh
BENCHMARK_JSON=policy-results.json \
  bundle exec ruby --yjit -Ilib -Iext/schemurai_native benchmark/native_policies.rb
```

`BENCHMARK_WIDTH` defaults to 1000, `BENCHMARK_DEPTH` to 8,
`BENCHMARK_ITERATIONS` to 11 and `BENCHMARK_BATCH` to 50. The runner alternates
VM/native measurement order, reports median elapsed time and measures Ruby
allocations separately. Native allocation overhead is included in elapsed time;
allocation counts describe Ruby objects only. For comparisons, use the same
script and settings with each extension on the Ruby load path.

Comparing the preceding native implementation with shared branch/property scans
and combined diagnostic/annotation collection, on Ruby 4.0.6 with YJIT,
x86_64 Linux, width 1000, depth 8, 11 samples and batches of 50:

| Native workload | Before (µs) | After (µs) | Speedup |
| --- | ---: | ---: | ---: |
| Sparse properties / valid / `valid?` | 14.395 | 0.145 | 99.04x |
| Sparse tracked properties / valid / `valid?` | 13.600 | 0.144 | 94.12x |
| Nested `allOf` / valid / `validate` | 188.860 | 40.168 | 4.70x |
| Nested conditional / valid / `validate` | 190.184 | 40.978 | 4.64x |
| Nested references / valid / `validate` | 207.255 | 41.956 | 4.94x |
| Nested `allOf` / invalid / `validate` | 407.294 | 242.951 | 1.68x |

Invalid nested conditional/reference diagnostics improved by 1.68–1.71x.
Ruby allocation counts were unchanged in all 24 method/validity combinations:
zero for `valid?`, three for successful `validate`, and 11 or 17 for invalid
results. Sparse lookup uses temporary native candidate storage and compiled
property/required indices; those are not reflected in Ruby allocation counts.
The early-invalid sparse case increased from 0.078 to 0.112 µs because candidate
discovery precedes the first property check. Dense-object diagnostics increased
by about 3–4% in this comparison; nested validity remained within about 4%.
These local results do not establish a speedup for every input. The artifacts
are `schemurai-policies-before.json` and `schemurai-policies-after.json`.

## Native enum lookup

`native_enum.rb` measures arrays whose items use a number, string or nested-object
enum. It includes first-candidate matches, last-candidate matches and misses,
through both `valid?` and detailed `validate`. Compilation is excluded. Before
measurement, the runner checks native coverage and exact validity/error parity
with the VM, then alternates backend order and reports batched-call medians.
Ruby allocations are measured separately after warmup; they do not describe
native index storage.

```sh
BENCHMARK_JSON=enum-results.json bundle exec ruby --yjit \
  -Iext/schemurai_native benchmark/native_enum.rb
```

`BENCHMARK_SIZE` controls enum candidates (default 1024), `BENCHMARK_WIDTH`
controls array elements (256), `BENCHMARK_ITERATIONS` controls samples (11)
and `BENCHMARK_BATCH` controls calls per sample (10). Run sizes 16, 17 and 64
to check the linear/indexed boundary. Compare builds using the same script and
settings with the appropriate extension directory on the Ruby load path.

Compared with `15d2858`, on Ruby 4.0.6 with YJIT, x86_64 Linux, 1024 candidates,
256 elements, 11 samples and batches of five:

| Native last-candidate workload | Before (µs) | After (µs) | Speedup |
| --- | ---: | ---: | ---: |
| Numbers / `valid?` | 3216.526 | 11.011 | 292.11x |
| Strings / `valid?` | 3599.939 | 15.784 | 228.07x |
| Nested objects / `valid?` | 14008.137 | 64.050 | 218.71x |
| Numbers / `validate` | 3176.900 | 10.907 | 291.28x |
| Strings / `validate` | 3636.570 | 15.711 | 231.46x |
| Nested objects / `validate` | 14267.697 | 63.859 | 223.42x |

First-candidate speed ratios ranged from 0.94x to 1.03x in the same run.
At size 16, non-first cases remained within about 5%; at size 17 they improved
by 1.61–6.48x, and at size 64 by 3.41–22.95x (seven samples, batches of five).
All native validity cases allocated zero Ruby objects; successful diagnostics
allocated three. The artifacts are `schemurai-enum-before.json` and
`schemurai-enum-after.json`, with size-suffixed artifacts for the smaller runs.
These are local measurements, not portable speed guarantees.

Enums with more than 16 candidates compile canonical fingerprints into a
sorted flat index. Lookup fingerprints the input once and uses binary search
to select candidates, then retains full JSON equality and original candidate
order within each collision group. The first candidate is compared directly,
and disjoint root types avoid input fingerprinting. Index storage is linear
(16 bytes per candidate on 64-bit platforms), capped at 64 MiB per enum;
sorting takes O(E log E) work in addition to schema fingerprinting. Lookup takes
O(log E) index work plus input fingerprinting and exact collision comparisons.
Heavy fingerprint collisions can still require a full candidate scan.
Small enums, unavailable schema/input fingerprints and unavailable index
storage keep linear comparisons, preserving depth and unsupported-value
fallback. Native memory reporting includes enum values and index buffers.

## Rust native backend versus YJIT

Build the extension as described in `docs/backend-selection.md`, then run:

```sh
BENCHMARK_JSON=native-results.json bundle exec ruby --yjit \
  -Iext/schemurai_native benchmark/native.rb
```

The runner requires YJIT, verifies validity and full detailed errors before
measurement, excludes compilation, warms both validators, and alternates
measurement order. It reports medians of batched calls and a separate warmed
allocation measurement. Defaults: 1000 elements, 31 samples, 100 calls per
sample. `BENCHMARK_WIDTH`, `BENCHMARK_ITERATIONS`, and `BENCHMARK_BATCH` override
these settings. `BENCHMARK_CONTENT_BYTES` changes the repeated string length in
the large Base64 JSON workload (default 4096); use 9216 to exercise streaming
above the 8192-byte direct-decode limit. The JSON report records this setting.
`BENCHMARK_UNIQUE_SHIFT` changes the bit position of varying digits in the
shuffled large-integer workload (default 0); use 64 to give every input the
same low 64 bits. Its value is also recorded in the JSON report.
`BENCHMARK_WORKLOAD` selects one workload by its name; omit it
for the complete comparison. Workload order can affect YJIT specialization, so
filtered and complete runs should be reported separately. JSON output records Ruby version, YJIT, settings, and results.
`BENCHMARK_GROUP=content` selects all five content workloads. The runner enables
both format and content assertions; unsupported encodings still use the VM's
compatibility behavior.

### Public-API Bignum sampling

The `benchmark / native backends` GitHub Actions workflow runs `native.rb`
with YJIT on Ubuntu 24.04 x64 and arm64. Workflow Summary contains each
case's VM/native timings, speedup and native Ruby allocation count, along
with the number reaching the 10× target. The full JSON is retained as an
artifact per runner. Correctness and native-coverage checks fail the job;
timing differences on hosted runners are informational.

The extension reads low-word collision metadata through public integer packing.
Exact comparison and wider retries still determine uniqueness; Ruby objects and
digit pointers are not cached or marshalled. This avoids depending on CRuby's
private Bignum layout across patch-level runtime updates.

A historical sequential comparison of the removed private-layout optimization
against the preceding installed compact-slot build
used Ruby 4.0.6/YJIT, Rust 1.99, width 1,000, 31 samples and 100-call batches.
Native coverage, validity and full-error gates passed. Artifacts are
`schemurai-big-sample-{before,after}.json`.

| Shuffled Bignums | Before (µs) | After (µs) | VM / native |
| --- | ---: | ---: | ---: |
| Valid / `valid?` | 10.55 | 4.19 | 15.67× |
| Valid / `validate` | 10.83 | 4.41 | 13.12× |
| Invalid / `valid?` | 10.51 | 4.11 | 14.22× |
| Invalid / `validate` | 11.98 | 5.47 | 11.06× |

These filtered measurements were followed by a complete packaged-extension
audit (`schemurai-big-sample-full-audit.json`). All 168 cases reached at least
10× VM throughput: minimum 10.039×, maximum 145.908×, median 25.136× and
geometric mean 26.771×. The minimum was ordered large integers / invalid /
`validate`. Shuffled Bignums reached 17.69–22.32×; late-unordered Bignums reached
10.16–11.06×. The environment was Ruby 4.0.6/YJIT on x86_64 Linux, Rust 1.99,
width 1,000, 31 samples and 100-call batches, with 4,096-byte content fixtures.
The extension was rebuilt from the gem, its loaded path was asserted, and
all 13 packaged Rust/C/build sources matched the checkout. Compilation was
excluded; measurement order alternated after warm-up. Direct native coverage,
validity and complete diagnostic errors matched VM for every workload. All
84 native `valid?` cases allocated zero Ruby objects.

The default RSpec suite passed 6,550 examples with no failures and 1,287
pending. Native and independently packaged portable builds each passed 132
focused examples; VM differential checks passed 17. The installed-gem smoke
test, Clippy, rustfmt and changed Ruby files' RuboCop checks also passed.
This is the measured result in this environment, not a cross-platform or
arbitrary-workload throughput guarantee; the narrowest margin is 0.039×.

### Compact slots for the short Bignum index

The low-32-bit index now uses four-byte slots for at most 65,535 elements and
eight-byte slots above that through the 32-bit index limit. Slots retain a
truncated filter and an index into the original Ruby array. Exact comparison
and wider retries still decide uniqueness. The canonical and low-64-bit
indexes keep their preceding formats. Short-index slot storage is halved;
at width 1,000 its 2,048 slots occupy 8 KiB instead of 16 KiB.

A final sequential comparison against the installed preceding extension used
Ruby 4.0.6/YJIT, Rust 1.99.0, width 1,000, 31 samples and 100-call batches.
All native-coverage, validity and full-error gates passed, and native `valid?`
allocated zero Ruby objects. Artifacts are
`schemurai-short-unique-slot-final-{before,after}.json`.

| Shuffled Bignums | Before (µs) | After (µs) | Reduction |
| --- | ---: | ---: | ---: |
| Valid / `valid?` | 10.48 | 10.45 | 0.29% |
| Valid / `validate` | 10.87 | 10.66 | 1.87% |
| Invalid / `valid?` | 10.56 | 10.44 | 1.13% |
| Invalid / `validate` | 12.06 | 11.93 | 1.09% |

The initial candidate skipped the short pass above the 16-bit index limit;
its two filtered runs improved 1.74–4.21%. That size policy was replaced with
the eight-byte wider short slot to retain the fast sample for larger arrays.
The final 24-case uniqueness control used 15 samples and 50-call batches
(`schemurai-short-unique-slot-control-{before,after}.json`). Numbers ranged
from 3.21% faster to 4.27% slower, objects from 2.77% faster to 0.40% slower,
ordered Bignums improved 0.01–2.40%, high-word Bignums 0.02–3.44%, and
late-unordered Bignums 0.13–2.65%. Grouped shuffled cases ranged from 1.40%
faster to 0.60% slower. Small differences are reported without claiming a
universal speedup.

`native_unique_large.rb` focuses on large Bignum arrays without constructing
all the unrelated fixtures in `native.rb`. It checks direct native coverage,
validity and full errors against VM, excludes compilation, warms both methods
and alternates measurement order. With 65,536 elements, 31 samples and
five-call batches, native calls improved 5.73–9.47%:

| Case | Before (ms) | After (ms) |
| --- | ---: | ---: |
| Valid / `valid?` | 0.953 | 0.891 |
| Valid / `validate` | 0.938 | 0.884 |
| Invalid / `valid?` | 1.017 | 0.921 |
| Invalid / `validate` | 1.016 | 0.941 |

Artifacts are `schemurai-short-unique-slot-large-{before,after}.json`. This
focused size measured 5.32–6.16× VM, so it also remains below the 10× target.
The preceding 162/168 full audit predates both short sampling and compact
slots and does not establish the current complete-run result.

```sh
BENCHMARK_JSON=native-unique-large-results.json bundle exec ruby --yjit \
  -Iext/schemurai_native benchmark/native_unique_large.rb
```

Shared regressions now check shuffled Big arrays at 65,534, 65,535 and 65,536
elements, including duplicates that cross the slot-format boundary and full
diagnostics. The default suite passed 6,550 examples with zero failures and
1,287 pending; native/differential tests passed 132 examples in both default
and portable builds; VM differential tests passed 17. Clippy with warnings
denied, formatting and Ruby lint passed. The rebuilt installed gem passed the
package smoke test; both package builds had extension locations asserted,
and all 12 default-package Rust/build/glue files matched the working tree.

### Short Bignum samples with a wider retry

Unordered Bignum uniqueness now starts with a low 32-bit magnitude sample and
sign, returned as register-sized metadata from the guarded public packing API.
The short sample folds its bits without multiplication. Equal sample filters
still compare original integers; an unequal pair immediately restarts with the
preceding bounded 64-bit index. The existing full-hash and mixed-value retries
remain. No sampled bits decide equality and no instance tree is copied.

A sequential comparison against the installed preceding extension used Ruby
4.0.6/YJIT, Rust 1.99.0, width 1,000, 31 samples and 100-call batches. Coverage,
validity and complete errors matched VM before timing; native `valid?` allocated
zero Ruby objects. Artifacts are `schemurai-big-low32-final-{before,after}.json`.

| Shuffled large integers | Before (µs) | After (µs) | Reduction |
| --- | ---: | ---: | ---: |
| Valid / `valid?` | 12.15 | 10.71 | 11.89% |
| Valid / `validate` | 12.51 | 10.95 | 12.49% |
| Invalid / `valid?` | 11.97 | 10.69 | 10.75% |
| Invalid / `validate` | 13.75 | 12.10 | 11.97% |

Controls varied digits at shifts 11, 32 and 64, using 15 samples and 50-call
batches. Shift 11 improved 12.03–14.72%. Shift 32 ranged from 1.13% faster to
2.75% slower; shift 64 was 0.46–4.43% slower. Artifacts are
`schemurai-big-low32-shift{11,32,64}-before.json` and
`schemurai-big-low32-retry-shift{11,32,64}-after.json`. The small wider-retry
overhead is a measured tradeoff. The 162/168 full audit below predates this
change; the complete 10× target remains unmet.

An initial short-sample candidate skipped the wider retry and regressed shift
32 by 15.76–17.57%, so it was replaced. A separate ordered-scan candidate
omitted rechecking its already validated left operand. It did not improve the
two below-target diagnostic cases and slowed late-unordered cases by
0.92–4.45%, so it was removed. Artifacts for the latter are
`schemurai-big-order-guard-{ordered,late}-{before,after}.json`.

The final native/differential suite passed 131 examples; the default suite passed
6,548 examples with zero failures and 1,287 pending. Shared regression coverage
now includes shifts 32 and 33 alongside 0, 11 and 64, checking distinct values,
duplicates and equal mixed Floats with full diagnostics. Clippy with warnings
denied, formatting, Ruby lint and whitespace checks passed. The rebuilt
installed gem passed the package smoke test and explicit short-sample retry
checks with gem/extension locations asserted. All 12 packaged Rust/build/glue
files matched the working tree byte for byte.

An installed-package comparison of all 24 uniqueness cases used 15 samples
and 50-call batches (`schemurai-big-low32-control-{before,after}.json`). Numbers
and objects ranged from 0.28–4.64% faster; shuffled Bignums were 12.18–14.49%
faster. Ordered invalid cases initially slowed 7.07–8.64%; an isolated
31-sample/100-call repeat narrowed the ordered differences to 2.09–4.01%
slower (`schemurai-big-low32-ordered-repeat-{before,after}.json`). High-word
inputs slowed 3.00–5.90%, and late-unordered cases ranged from 0.66% faster to
4.24% slower. These remain measured tradeoffs, not an all-case speedup claim.
Moving the ordered scan into a non-inlined function did not consistently
remove them: valid diagnostics slowed 5.25% relative to the original extension,
while invalid diagnostics improved 1.43%. That attribute was removed; its
artifact is `schemurai-big-order-isolated-after.json`.

### Adjacent equivalent applicator branches

The compiler groups adjacent equivalent simple object branches in `anyOf` and
`oneOf`, retaining multiplicity for match counts and merging successful
annotations once. Equality includes ordered key handles, required-property
flags and remaining required keys, type requirements, count bounds, and exact
type/boolean leaves. Complex rules keep separate evaluations. Nonadjacent
branches retain their order so an unsupported middle branch still reaches the
compatibility path. Instance VALUEs remain borrowed without copying or caching.

A sequential comparison against the installed preceding AR-proof extension
used Ruby 4.0.6/YJIT, Rust 1.99.0, width 1,000, 31 samples and 100-call batches.
All native-coverage, validity and complete-error checks passed before timing.

| Overlapping annotation case | Before (µs) | After (µs) | Reduction |
| --- | ---: | ---: | ---: |
| Valid / `valid?` | 41.03 | 21.42 | 47.79% |
| Valid / `validate` | 40.41 | 21.62 | 46.50% |
| Invalid / `valid?` | 41.17 | 21.35 | 48.14% |
| Invalid / `validate` | 57.25 | 36.42 | 36.38% |

Artifacts are `schemurai-branch-groups-final-{before,after}.json`. Native
`valid?` allocated zero Ruby objects. Filtered YJIT speedups were 12.98–13.27×
for the first three cases and 7.80× for invalid diagnostics; these are separate
from the full audit. Native/differential tests passed 118 examples, covering
different required/count/type rules, matching multiplicity through 20 branches,
failed branch annotations and an unsupported middle branch. The default suite
passed 6,522 examples with no failures and 1,287 pending. Clippy with warnings
denied and Rust formatting passed. The rebuilt installed gem passed the package
smoke test plus required-property and 20-branch multiplicity checks, with both
gem and extension locations asserted. All 12 packaged Rust/build/glue files
matched the working tree byte for byte.

Two property-key equality candidates were also rejected: cached short-key
length/encoding expanded each set entry and regressed three cases by 1.20–4.05%;
a full-fingerprint equality filter retained the entry size but regressed three
cases by 0.05–4.38%. Both were removed before the retained branch comparison.

### Full audit after small-record proofs and branch grouping

The installed `schemurai-branch-groups.gem` extension completed all 168 cases
with Ruby 4.0.6/YJIT, Rust 1.99.0, width 1,000, 31 samples and 100-call batches.
The extension location was asserted; packaged native sources matched the working
tree. Native coverage, validity and full diagnostics matched VM before timing,
and every native `valid?` case allocated zero Ruby objects. The report is
`schemurai-branch-groups-full-audit.json`.

162/168 cases reached 10×, compared with 158/168 in the preceding full audit.
The range was 7.33–145.11×, median 24.50× and geometric mean 25.91×. Ordinary
record validity reached 17.11×, pattern-record validity 12.27–12.30×, and invalid
overlapping-property diagnostics 14.08×. The remaining cases are:

| Case | VM/native speedup | Native time (µs) |
| --- | ---: | ---: |
| Ordered large integers / invalid / `validate` | 9.76× | 9.55 |
| Shuffled large integers / valid / `valid?` | 7.62× | 11.95 |
| Shuffled large integers / valid / `validate` | 7.63× | 12.29 |
| Shuffled large integers / invalid / `valid?` | 7.73× | 12.20 |
| Shuffled large integers / invalid / `validate` | 7.33× | 13.44 |
| Late unordered large integers / invalid / `validate` | 9.71× | 9.69 |

Shuffled-integer native times remain close to the previous full audit's
11.98–13.55 µs; their VM times were lower in this run. Full-run YJIT
specialization and filtered results are reported separately. The overall
10× target remains unmet.

### Verified AR-table proof for small records

The default build can now prove ordinary semantics for small CRuby Hashes
without a separate key lookup. It enables this only for Ruby API 3.4/4.0 after
an embedded-interpreter build check verifies the internal storage flag against
ordinary, frozen and identity Hashes of sizes zero through eight. Cross builds,
other API versions, failed checks and `--enable-portable-hash-walk` keep the
original proof. C reads the public object flags, tags the proof separately from
the initialized pair count, and never dereferences a private Hash table. Rust
skips collecting or looking up a distinct schema key only for proven ordinary
Hashes. Identity Hashes and ordinary ST tables retain the existing lookup.
This introduces a version-limited dependency on CRuby's internal storage flag;
the build check and portable path are part of the implementation.

Sequential comparisons against the installed preceding extension used Ruby
4.0.6/YJIT and Rust 1.99.0 at width 1,000. Pattern-record measurements used
31 samples and 100-call batches; ordinary/dynamic/frozen controls used 15
samples and 50-call batches. All native-coverage, validity and complete-error
checks passed before timing, with zero native `valid?` Ruby allocations.

| Record family | Native time reduction |
| --- | ---: |
| Pattern records, `valid?` | 33.23–33.41% |
| Pattern records, diagnostics | 19.80–21.21% |
| Ordinary records | 40.88–50.84% |
| Dynamic-key records | 32.26–36.08% |
| Frozen-key records | 15.55–17.61% |

Pattern-record `valid?` dropped from 47.47–47.78 µs to 31.61–31.90 µs.
Artifacts are `schemurai-ar-proof-pattern-before.json`,
`schemurai-ar-proof-pattern-final.json` and
`schemurai-ar-proof-record-{before,after}.json`. These filtered comparisons
are separate from the 162/168 full audit above, which includes this change.

Both default and portable builds passed 117 native/differential examples.
Expanded cases cover property-count boundaries, large backing tables with
deleted entries, and identity conversion before/after population, duplication,
freezing and clearing. The default suite passed 6,522 examples with no failures
and 1,287 pending. Clippy with warnings denied, Rust formatting, RuboCop on the
build script and tests, and whitespace checks passed. Ruby 3.4 is covered by
the existing CI matrix; these local results are for Ruby 4.0.6. The rebuilt
installed gem enabled the verified hint and passed the package smoke test with
gem/extension locations asserted. Rust sources, C glue, the build script and
the lockfile matched the working tree byte for byte.

### Full audit after hoisted array bounds and folded Big-only fingerprints

The installed `schemurai-big-fold.gem` extension completed all 168 cases with
Ruby 4.0.6/YJIT, Rust 1.99.0, width 1,000, 31 samples and 100-call batches.
Its extension location was asserted, and Rust sources, C glue and the lockfile
matched the working tree before timing. Native validity and diagnostic coverage
passed throughout, including complete-error comparisons with the VM. Every
native `valid?` allocation measurement was zero.

158 of 168 cases reached 10x. Minimum: 8.06x; maximum: 134.25x; median: 23.87x;
geometric mean: 25.77x. This is the current full-run audit, superseding the
156/168 audit below. The all-case 10x target remains unmet. Changes in YJIT
specialization affect full-run ratios; the paired filtered comparisons below
measure the native-time improvements separately.

| Cases below 10x | Count | Speedup | Native time (µs) |
| --- | ---: | ---: | ---: |
| Ordinary object records, `valid?` | 2 | 9.37–9.38x | 35.98–36.58 |
| Overlapping annotations, invalid diagnostics | 1 | 9.28x | 55.84 |
| Pattern object records, `valid?` | 2 | 8.06–8.07x | 46.63–46.81 |
| Large integer bounds, invalid `valid?` | 1 | 9.96x | 8.97 |
| Shuffled large-integer uniqueness | 4 | 9.23–9.83x | 11.98–13.55 |

Artifact: `schemurai-folded-index-full-audit.json`. The largest remaining gap
is now pattern-record validity. An earlier ordinary-record CPU profile showed
41.77% of inclusive CPU time in the distinct-key Hash lookup; the corresponding
pattern-record profile showed 19.07% in that lookup. These motivate investigating
a cheaper proof of ordinary Hash semantics while retaining identity-Hash
delegation. The existing lookup remains in this audited implementation.

CRuby's tagged sources show that identity Hashes use ST tables on
[Ruby 3.4.7](https://github.com/ruby/ruby/blob/v3_4_7/hash.c) and
[Ruby 4.0.6](https://github.com/ruby/ruby/blob/v4.0.6/hash.c). The representation
flags are internal details, so a future optimization using them must explicitly
limit supported versions and preserve the portable path; the current audit does
not claim such an optimization is implemented.

### Bounded Big-only probing with folded fingerprints

The Big-only low-word mixer now folds six 11-bit groups before its odd
multiplication. It keeps adjacent low words distributed across table positions
without feeding multiplication's high bits back into the table index. This is
only a fingerprint: exact integer comparisons still decide every potential
duplicate, and mixed numeric types restart with canonical fingerprints.

The sampled index now also bounds occupied-slot probes to twice the number
of input values, in addition to its existing limit of 16 equal-fingerprint
comparisons that find unequal integers. Either guard restarts with full hashes. This keeps
poor table-position distributions from causing an unbounded sampled-index
scan. Generic indexes retain their original probing path.

Two sequential filtered comparisons against the installed preceding extension
used Ruby 4.0.6/YJIT, Rust 1.99.0, width 1,000, 31 samples and 100-call batches.
Shuffled large-integer native times improved 5.40–8.32% in the first run and
5.30–7.54% in the repeat. Shifting the varying digits by 11 improved 1.72–4.64%.
The full-hash-restart control with shift 64 ranged from 1.76% faster to 2.79%
slower. Every run matched VM validity and complete errors before measurement,
with zero Ruby allocations in native `valid?`. These are filtered comparisons,
not a replacement for the 168-case audit below.

Artifacts are `schemurai-big-fold-after.json`,
`schemurai-big-capacity-before.json`, `schemurai-big-fold-repeat-{before,after}.json`,
`schemurai-big-fold-stride-{before,after}.json` and
`schemurai-big-fold-shift-{before,after}.json`. A separate candidate doubled
sampled-index capacity, but improved the primary `valid?` case only 0.01%
while doubling slot storage; it was removed before testing the mixer.

The 24-case uniqueness-group comparison matched validity and complete errors
throughout: all Big-integer cases improved 0.81–7.82%, while object cases ranged
from 0.80% faster to 1.31% slower. Ordinary numeric cases initially slowed
2.57–5.79%; an isolated repeat ranged from 0.21% faster to 0.61% slower, so the
larger difference did not reproduce. Artifacts are
`schemurai-big-fold-controls-{before,after}.json` and
`schemurai-big-fold-numeric-{before,after}.json`.

Differential coverage adds deliberately identical bucket positions with distinct
fingerprints, duplicates after that probe budget, mixed Float cases after the
restart, and random 64-bit low words with both signs. Existing coverage varies
each bit position from 0 through 64. VM execution is forbidden after expected
results are collected. Verification passed 117 native/differential examples,
6,522 default-suite examples with no failures and 1,287 pending, Clippy with
warnings denied, Rust formatting, and RuboCop on the expanded test. The rebuilt
installed gem passed its smoke test with gem/extension locations asserted;
packaged Rust sources and the lockfile matched the working tree byte for byte.

### Hoisted integer-array bounds

The homogeneous array path now folds exact integer limits into an inclusive
interval once before traversal. Immediate Ruby integers then use two comparisons
instead of interpreting each limit for each item. Big integers, Floats and
non-numeric values retain the existing guarded evaluation; fractional limits
and multiples retain their original paths. Original array handles are borrowed
directly, without copying or converting instance values.

Sequential filtered comparisons used the installed preceding extension,
Ruby 4.0.6/YJIT, Rust 1.99.0 and the default benchmark settings. The initial
implementation reduced native `valid?` from 2.36–2.38 µs to 0.58–0.60 µs.
Moving integer traversal into a separate function further reduced it to
0.506–0.516 µs: 78.20–78.74% faster than the baseline, at 44.69–45.62x VM.
Final diagnostic calls improved 2.86–4.40%. All coverage, validity and
complete-error gates passed; native `valid?` allocated no Ruby objects.
Artifacts are `schemurai-array-bounds-{before,after}.json` and
`schemurai-array-bounds-repeat-{before,after}.json`. These filtered runs do not
replace the 168-case audit below, which predates this change.

The initial implementation also slowed dynamic-key records by 4.54–13.30% in
an isolated control. With the separate integer function, a same-worktree rebuild
of the preceding source reduced that difference to 1.60–4.41% (15 samples,
50-call batches). This small regression remains a measured tradeoff; the integer
array gain is retained, and a new full audit is still needed. Final artifacts
are `schemurai-array-bounds-isolated-after.json`,
`schemurai-array-bounds-isolated-dynamic-after.json` and
`schemurai-array-bounds-dynamic-main-before.json`.

Native/differential tests passed 117 examples with no failures, including exact
inclusive/exclusive endpoints around immediate-integer and signed-64-bit limits,
contradictory limits, prefix items, empty arrays and mixed Integer/Float/other
values with VM execution forbidden after expectations were collected. The
default suite passed 6,522 examples with no failures and 1,287 pending. Clippy
with warnings denied, Rust formatting and RuboCop checks passed. The final
separate-function implementation passed both suites again and the rebuilt
installed-gem smoke test, with installed gem/extension paths asserted and Rust
sources plus the lockfile matching the working tree byte for byte.

### Rejected forced inlining of record dispatch

Forcing the record child dispatcher to inline improved pattern-record cases
only 0.11–1.99%, while sequential controls showed dynamic-key records becoming
5.84–8.09% slower. Ordinary invalid records slowed 1.02–2.24%, and frozen-key
records slowed 0.72–4.61%. The candidate was removed. Pattern measurements used
31 samples of 100 calls; controls used 15 samples of 50 calls, all at width
1,000. Artifacts are `schemurai-record-inline-pattern-{before,after}.json` and
`schemurai-record-inline-clean-controls-{before,after}.json`. The earlier
overlapping control runs were discarded and are not evidence for this decision.

The restored ordinary-record profile (`PROFILE_WORKLOAD=record`) attributed
41.77% of inclusive CPU time to Hash lookup, needed to distinguish identity
Hash semantics, and 23.52% exclusive time to native object evaluation. This
points to key handling rather than child dispatch as the larger remaining cost.

### Full audit after crate-backed decoding and the lighter Big-only mixer

With Ruby 4.0.6/YJIT, Rust 1.99.0, and the default 1,000-element, 31-sample,
100-call settings, all 168 cases passed native validity, diagnostic coverage,
and complete-error comparisons against the VM. Every native `valid?` allocation
measurement was zero. The report is `schemurai-turbo-big-mix-full-audit.json`.

156 of 168 cases reached 10x: minimum 6.69x, maximum 148.44x, median 23.55x,
and geometric mean 24.46x. This full audit replaces the older 149/168 result
for the current implementation. Benchmark order and YJIT specialization affect
VM-relative ratios; the paired filtered measurements below assess individual
changes separately. The all-case 10x target remains unmet.

The rebuilt gem passed the installed-package smoke test with both gem and
extension locations asserted. Its Rust sources and lockfile matched the
working tree byte for byte.

| Cases below 10x | Count | Speedup |
| --- | ---: | ---: |
| Integer array, invalid `valid?` | 1 | 9.60x |
| Object records, `valid?` | 2 | 9.18x |
| Overlapping annotations, invalid diagnostics | 1 | 8.49x |
| Ordered large integers, invalid diagnostics | 1 | 9.78x |
| Pattern object records, `valid?` | 2 | 7.75–7.98x |
| Shuffled large integers | 4 | 6.69–7.24x |
| Late unordered integers, invalid diagnostics | 1 | 9.81x |

### Large-integer uniqueness sampling and fingerprint mixing

`PROFILE_WORKLOAD=unique` selects the shuffled 1,000-element large-integer
workload in `native_profile.rb`. CPU sampling attributed 54.55% of inclusive
CPU time to `rb_integer_pack`, with 36.60% exclusive time in the native
uniqueness loop. Batching eight low-word reads made all four filtered benchmark
cases 1.79–4.74% slower, so that candidate was removed.

The retained change reduces the Big-only low-word fingerprint mixer to one
multiplication with high/low-bit folding on both sides. Each mixing step is
reversible; full integer comparisons and the bounded-collision restart still
decide uniqueness. Canonical fingerprints for mixed numeric types are unchanged.
Two filtered comparisons against the installed previous extension measured
1.15–3.63% and 3.67–7.25% reductions in native time across all four cases.
These are local timings, not a new full-suite speedup audit. A control with
`BENCHMARK_UNIQUE_SHIFT=64`, which forces the full-hash restart, ranged from
0.74% faster to 0.42% slower. Both validators agreed on validity and complete
errors before measurement, and native `valid?` allocated no Ruby objects.

Differential coverage exercises positive and negative integers varying at each
bit position from 0 through 64, including duplicates, with VM execution forbidden
after expected results are collected. Verification passed: 116 native/differential
examples; 6,522 default-suite examples with zero failures and 1,287 pending;
Clippy with warnings denied; Rust formatting; and RuboCop on the changed tests
and profiling helper.

### Crate-backed Base64 decoding for medium and large JSON content

CPU sampling of the old 4,096-character Base64 JSON workload attributed
79.88% of exclusive samples to `base64-simd`'s AVX2 decoder and 13.75% of
inclusive samples to JSON string scanning. The helper completed 27,000 native
validations during its sustained phase. Artifact:
`schemurai-content-large-clock-functions.txt`. Reproduce with
`PROFILE_WORKLOAD=content` using the profiling command below; `pattern` remains
the helper's default. Inspection found no duplicate UTF-8 scan in JSON, and
the existing decoded-length calculation examines length and padding metadata.

On this AMD Ryzen 9 7900X with AVX-512 VBMI available, an isolated comparison
of `base64-turbo 0.5.0` and `base64-simd 0.8.0` decoded 4,107 bytes in about
68 versus 379 ns, and 9,227 bytes in about 148 versus 832 ns. Three rounds
alternated order and verified the written bytes; padding and trailing-bit
rejection probes matched. At 32 bytes the new crate was slower, so the native
backend retains `base64-simd` for standalone checks and decoded JSON shorter
than 128 bytes. Larger encoded JSON now uses
[`base64-turbo`](https://docs.rs/crate/base64-turbo/0.5.0)'s strict caller-buffer
decoder. Its runtime dispatch also supplies other CPU paths; the numbers here
establish performance only on this CPU. Rust 1.93 is now required, with local
builds and tests using 1.99.0.

The new decoder needs an initialized conservative output buffer, including
up to two extra bytes for padding. Separate bounded frames serve medium,
direct and streaming decoding. Parsing reads only the exact successful
written prefix, with the expected length checked. No Ruby allocation or
instance conversion is introduced, and the original encoded String is borrowed.

Paired 20-case content runs used Ruby 4.0.6/YJIT, 1,000 items, 31 samples,
and batches of 100 after builds had finished. All native coverage, VM validity
and detailed-error gates passed. Every native `valid?` allocated zero Ruby
objects. The final candidate orders the shortest-content branch first.

| Content workload, four cases | Native before (µs) | Native after (µs) | VM ratio after |
| --- | ---: | ---: | ---: |
| Base64 JSON, 256-character string | 57.13–60.48 | 35.96–52.47 | 12.07–12.65x |
| Base64 JSON, 4,096-character string | 451.76–459.17 | 205.83–224.25 | 18.80–19.07x |

Native time fell 13.24–37.26% for the medium workload and 51.16–54.56%
for the large workload. Plain JSON controls improved 6.21–7.27%; short encoded
JSON ranged from 0.31% slower to 1.54% faster. One standalone Base64 validity
case initially measured 5.97% slower; independent paired controls measured
0.29% slower for that case, with all four ranging from 3.69% faster to 1.34%
slower. Artifacts: `schemurai-turbo-content-before.json`,
`schemurai-turbo-content-final.json` and
`schemurai-turbo-base64-controls-{before,after}.json`.

A separate streaming comparison used 9,216-character strings, 15 samples
and batches of 30. The baseline loaded the preceding installed gem with its
extension path verified. All four cases passed the coverage and error gates.
Native times fell from 1,099.54–1,117.18 µs to 405.64–441.66 µs, a
60.05–63.69% reduction; VM ratios were 17.49–18.94x. Artifacts are
`schemurai-turbo-stream-before.json` and `schemurai-turbo-stream-after.json`.
These filtered results do not update the 168-case full-run counts below.

Native/differential tests passed 116 examples, including the new 126–131-byte
boundary, existing short/direct/streaming boundaries, all byte positions,
strict padding and trailing bits, invalid content, detailed errors and Ractors.
The default suite passed 6,522 examples with 1,287 pending. Clippy and
RuboCop passed.
An independently built and installed `schemurai-native-turbo.gem` passed
package smoke tests with native VM fallback forbidden and verified gem and
extension paths. Its complete Rust sources and Cargo lockfile matched the
worktree byte for byte. Formatting and whitespace checks passed.

### Full audit after the internal Hash walks and bounded Bignum index

The default runner completed all 168 method/validity cases using the installed
`schemurai-native-key-guard.gem` extension. Before timing, its complete Rust
source directory, C glue and build configuration matched the worktree byte for
byte. The loaded extension path was checked when the process exited. Settings
were Ruby 4.0.6/YJIT on x86_64-linux, Rust 1.99.0, 1,000 elements, 31 samples,
batches of 100, 4,096-character large-content strings and `unique_shift=0`.
Every case passed native validity/diagnostic coverage and VM validity/full
error comparison before measurement. Native `valid?` allocated zero Ruby
objects in all cases.

149/168 cases reached at least 10x, compared with 144/168 in the preceding
compiled-short-key-index snapshot. The minimum was 6.42x, maximum 153.69x,
median 22.70x and geometric mean 23.71x. These aggregates do not establish
10x in every case. Frozen-key and dynamic-key record validity now exceeded
10x in this full run. Pattern-record validity measured 7.77–7.80x, compared
with 6.33–6.53x in the preceding snapshot. The earlier paired controls
establish the direct effects of the Hash-walk changes; full-run ratios also
depend on VM specialization and timing variation.

| Workload still below 10x | Cases below target | Speedup of those cases |
| --- | ---: | ---: |
| Unique shuffled large integers | 4 | 6.42–7.13x |
| Pattern object records | 2 | 7.77–7.80x |
| Overlapping property annotations | 1 | 8.93x |
| Content Base64 JSON large | 4 | 9.10–9.86x |
| Object records | 2 | 9.14–9.72x |
| Content Base64 JSON long | 2 | 9.50–9.57x |
| Unique late unordered integers | 1 | 9.59x |
| Unique large integers | 1 | 9.73x |
| Content JSON | 2 | 9.76–9.99x |

Artifact: `schemurai-key-guard-full-audit.json`. The remaining bottlenecks are
unordered Bignum uniqueness, ordinary/pattern record validity, and content
scanning; near-threshold cases still need repeatable improvement. This is the
current full-run baseline. The per-change correctness checks and both
Hash-walk build modes are recorded in the sections below.

### Rejected compiled record-pattern check

A candidate added a compile-time `RecordCheck::StringPattern` for fields with
only a pattern assertion. The required-type flag was selected once; evaluation
borrowed the original field's String bytes and called the existing crate
matcher directly. Length, format and content combinations kept their original
path. This introduced no instance conversion, raw pointer cache or copied
automaton. Clippy and 116 native/differential examples passed.

Paired pattern-record measurements used Ruby 4.0.6/YJIT, Rust 1.99.0,
1,000 records, 31 samples and batches of 100 after builds had finished.
All native-coverage, validity and full-diagnostic gates passed.

| Pattern-record case | Existing (µs) | Candidate (µs) |
| --- | ---: | ---: |
| valid? valid | 46.58 | 45.38 |
| validate valid | 54.50 | 53.25 |
| valid? invalid | 46.52 | 45.89 |
| validate invalid | 57.69 | 56.98 |

Although these four cases improved 1.23–2.59%, the 12-case ordinary-record
controls were worse overall. Ordinary keys ranged from 0.23% faster to 2.49%
slower; dynamic keys slowed 5.35–6.97%, and frozen keys slowed 2.76–5.01%.
The baseline controls used the preceding installed extension with its path
verified and its Rust source matching the saved baseline byte for byte.
The runtime edit was removed. Artifacts are
`schemurai-record-pattern-check-before.json`,
`schemurai-record-pattern-check-after.json`,
`schemurai-record-pattern-check-controls-before.json` and
`schemurai-record-pattern-check-controls-after.json`.

The expanded record-pattern test remains: it compares typed and untyped pure
patterns and length combinations against VM validity and detailed errors,
including numeric and other non-string fields, Unicode and US-ASCII inputs,
and GC compaction. VM execution is forbidden for these native cases.
RuboCop passed. This experiment does not update the full-run counts below.
After restoring and rebuilding, the expanded native/differential suite passed
116 examples with no failures. Both restored Rust files matched their saved
baseline versions byte for byte; formatting and whitespace checks passed.

### Read-only key-classification walk

A second CPU sample of the retained small-record optimization completed
243,000 native validations during the helper's approximately 12-second
sustained phase. `sn_small_hash` accounted for 6.18% of inclusive CPU samples,
compared with 24.37% in the preceding sample; `rb_hash_lookup2` accounted for
19.07%, and DFA search accounted for 33.31% of exclusive samples. These
relative shares identify remaining costs; paired benchmarks below quantify
speed. Artifact: `schemurai-pattern-stlike-clock-functions.txt`.

The optional internal Hash walker now also serves the general `sn_kind`
key-classification guard. Its C-only callback checks every encountered key's
exact String class and stops on unsupported keys, without invoking Ruby or
Rust, allocating or mutating. Rust-callback walks keep their existing APIs.
The same build-time detection and public-API fallback apply to both C-only
walks. No instance conversion or additional retained state is introduced.

Paired overlapping-annotation runs used Ruby 4.0.6/YJIT, Rust 1.99.0,
1,000 items, 31 samples and batches of 100, after builds had finished.
Native coverage, validity and full error details matched the VM before timing.

| Overlapping-annotation case | Before (µs) | After (µs) | Time change |
| --- | ---: | ---: | ---: |
| valid? valid | 42.97 | 41.13 | 4.28% faster |
| validate valid | 41.74 | 41.98 | 0.57% slower |
| valid? invalid | 42.62 | 41.02 | 3.77% faster |
| validate invalid | 60.20 | 58.07 | 3.53% faster |

Four unique-object controls measured 0.11–2.78% faster. Their baseline used
the preceding installed `schemurai-native-stlike.gem` extension with its path
verified. All gates passed, and every native validity case in both workloads
allocated zero Ruby objects. Artifacts are `schemurai-key-guard-before.json`,
`schemurai-key-guard-after.json`, `schemurai-key-guard-unique-before.json` and
`schemurai-key-guard-unique-after.json`. These filtered comparisons do not
update the full-run counts or establish the overall 10x target.

The internal-walk build passed 116 native/differential examples and the
default full suite passed 6,522 examples with 1,287 pending. The unsupported
key test now exercises both small-record and general-object paths, including
deleted table entries and frozen Hashes, and verifies that native delegation
does not call the custom key's `hash` or `eql?` methods. RuboCop passed.
The public-API fallback independently passed the same 116 examples. A fresh
`schemurai-native-key-guard.gem` installation detected the optional walker
and passed package smoke tests with verified gem/extension paths and VM
execution forbidden for native cases. The checkout was rebuilt in automatic
detection mode afterward. Whitespace checks passed.

A separate mkmf linkage check could not link `rb_hash_compare_by_id_p` on
this Ruby 4.0.6 installation. The distinct schema-key lookup remains necessary
to distinguish identity-key Hash semantics; this change does not bypass it.

### Guarded internal Hash walk for small records

CPU sampling below identified substantial `rb_hash_foreach` bookkeeping in
the small-record stack-buffer walk. The build now detects CRuby's exported
internal `rb_hash_stlike_foreach` symbol and uses it only for that walk.
The C callback reads handles and exact String classes under the GVL; it never
allocates, mutates, invokes Ruby, or calls Rust. That permits omission of the
iteration-level and exception-cleanup machinery in
[CRuby's implementation](https://docs.ruby-lang.org/capi/en/master/d1/d04/hash_8c_source.html).
Key matching, the distinct schema-key lookup that detects identity Hashes,
required bits and Rust field validation are unchanged. Instances are never
converted or copied. Missing symbols use public `rb_hash_foreach`, and
`--enable-portable-hash-walk` explicitly selects that fallback. This internal
symbol has a less stable ABI than the public extension API; the native CI
matrix now exercises both build modes on Ruby 3.4 and 4.0.

Paired controls used Ruby 4.0.6/YJIT, Rust 1.99.0, 1,000 records, 31 samples
and batches of 100. The object baseline loaded the preceding installed gem's
extension with its path checked; its C source matched the saved worktree
baseline byte for byte. All coverage, validity and full-error gates passed.
Every native `valid?` case allocated zero Ruby objects.

| Record family | Native before, four cases (µs) | Native after, four cases (µs) | Time reduction |
| --- | ---: | ---: | ---: |
| Pattern field | 58.43–68.89 | 46.68–57.44 | 14.75–20.11% |
| Ordinary keys | 49.52–64.39 | 36.91–46.66 | 25.21–28.23% |
| Dynamic keys | 102.23–121.22 | 68.21–80.27 | 32.26–34.10% |
| Frozen keys | 124.39–145.71 | 88.71–100.29 | 27.59–31.17% |

Artifacts are `schemurai-stlike-before.json`, `schemurai-stlike-after.json`,
`schemurai-stlike-controls-before.json` and
`schemurai-stlike-controls-after.json`. These filtered results do not update
the 168-case full-run counts below or establish the overall 10x target.
Native/differential tests passed 116 examples in each build mode, including
large backing tables reduced to zero, one and eight entries by deletion,
frozen inputs, unsupported keys, identity Hashes and GC compaction.
The default full suite passed 6,522 examples with 1,287 pending. RuboCop
passed, and the workflow's matrix was parsed and checked locally.
A fresh `schemurai-native-stlike.gem` installation detected the internal
symbol, rebuilt the packaged extension, and passed isolated package smoke
tests with VM execution forbidden for native cases. Its gem and extension
paths were verified, and its C source matched the worktree byte for byte.
The final checkout build again detected the symbol. Whitespace checks passed.

### CPU sampling of pattern records and rejected meta-engine selection

The retained implementation was sampled with GNU gprofng at a requested
1 ms clock interval during a sustained, native-only pattern-record run.
Compilation and a coverage check preceded the repeated calls. The process
completed 201,000 validations of 1,000 records over about 12 seconds.
The report attributed 26.77% of exclusive CPU samples to
`regex_automata::dfa::search::find_fwd`, 10.02% to `Engine::object`,
8.44% to `Engine::record_value`, and 3.12% to UTF-8 validation. Inclusive
shares were 24.37% for `sn_small_hash` and 15.70% for `rb_hash_lookup2`.
Inclusive shares overlap and must not be added to exclusive shares.
Artifact: `schemurai-pattern-clock-functions.txt`.

To reproduce sampling after building the extension:

```sh
gprofng collect app -p 1 -o pattern-profile.er \
  ruby --yjit -Ilib -Iext/schemurai_native benchmark/native_profile.rb
gprofng display text -limit 35 -functions pattern-profile.er
```

`PROFILE_SECONDS` controls the sustained phase, defaulting to 12 seconds.
The helper calls the native program directly and aborts on unsupported or
unexpected verdicts; it does not time VM fallback. Sampling includes startup
and warmup, so use the paired benchmark runner for performance comparisons.

The dominant regex samples motivated an independent candidate using the
crate's meta engine for anchored patterns too, retaining its literal
prefilters instead of selecting the immutable dense DFA. Paired runs used
Ruby 4.0.6/YJIT, Rust 1.99.0, 1,000 records, 31 samples and batches of 100.
Builds finished before timing, and all native-coverage, validity and detailed
error gates passed.

| Pattern-record case | Existing DFA (µs) | Meta engine (µs) |
| --- | ---: | ---: |
| valid? valid | 58.09 | 63.22 |
| validate valid | 65.71 | 69.42 |
| valid? invalid | 58.28 | 62.16 |
| validate invalid | 68.15 | 71.23 |

Every case slowed, by 4.52–8.83%, so the candidate was removed. Artifacts
are `schemurai-pattern-meta-before.json` and
`schemurai-pattern-meta-after.json`. Hash traversal and lookup remain sizable
measured costs to investigate. This filtered experiment does not update the
full-run counts below.
After restoring and rebuilding, native/differential tests passed 116 examples
with no failures. The restored pattern source matched its preceding version
byte for byte. The profiling helper passed RuboCop, and whitespace checks
passed.

### Rejected one-field record shortcut and DFA minimization

Two further pattern-record candidates were measured with Ruby 4.0.6/YJIT,
Rust 1.99.0, 1,000 records, 31 samples and batches of 100. Builds finished
before timing. Every run passed native-coverage, validity and full-diagnostic
gates. The first candidate directly checked a matched one-field record after
the existing C String-key guard and distinct schema-key Hash lookup, skipping
the generic visited-bit context. The second independently enabled
`regex-automata`'s `dense::Config::minimize(true)` with the original record
path. Both still borrowed original Ruby handles and string bytes.

| Pattern-record case | Existing (µs) | One-field shortcut (µs) | Minimal DFA (µs) |
| --- | ---: | ---: | ---: |
| valid? valid | 58.30 | 57.71 | 58.74 |
| validate valid | 65.56 | 64.81 | 64.49 |
| valid? invalid | 59.53 | 66.43 | 57.23 |
| validate invalid | 67.88 | 78.54 | 67.89 |

The record shortcut improved valid cases only 1.00–1.13%, while invalid
cases slowed 11.59–15.71%. DFA minimization ranged from 3.87% faster to
0.75% slower; it did not establish a consistent runtime gain to justify
the crate's additional compilation work. Both edits were removed.
Artifacts are `schemurai-single-record-before.json`,
`schemurai-single-record-after.json` and `schemurai-dfa-minimize-after.json`.
These filtered experiments do not update the full-run counts below.
After restoring and rebuilding, native/differential tests passed 116 examples
with no failures. Both restored Rust files matched their preceding versions
byte for byte, and the whitespace check passed.

### Rejected short-key comparison for small field sets

A candidate extended the existing exact short-key comparison to record
schemas with fewer than four fields. Identity matches still bypassed it;
distinct input keys borrowed their original bytes and encoding before exact
comparison. On the one-field pattern-record workload this added work instead
of reducing it. Paired runs used Ruby 4.0.6/YJIT, Rust 1.99.0, 1,000 records,
31 samples and batches of 100, after each build had finished. Both runs passed
the runner's native-coverage, validity and full-diagnostic gates.

| Pattern-record case | Existing (µs) | Candidate (µs) |
| --- | ---: | ---: |
| valid? valid | 57.42 | 58.71 |
| validate valid | 64.87 | 66.26 |
| valid? invalid | 57.69 | 61.78 |
| validate invalid | 67.26 | 69.66 |

All four native times increased, by 2.14–7.09%. The runtime edit was removed;
the retained implementation continues using the original small-field
comparison. Artifacts are `schemurai-single-short-before.json` and
`schemurai-single-short-after.json`. This experiment does not change the
full-run performance counts below. After restoring and rebuilding, the
native/differential suite passed 116 examples with no failures. The restored
Rust source matched the preceding implementation byte for byte, and the
whitespace check passed.

### Bounded low-word indexing for unordered Bignums

Unordered Bignum arrays now first index sign and the low magnitude word,
borrowed through guarded public `rb_integer_pack`. Matching fingerprints
always compare the original integer handles exactly. Sixteen unequal matches
restart the entire array with the existing public `rb_hash` index; encountering
another numeric kind restarts canonical mixed-number comparison. The bounded
path lives in a separate non-inlined function, keeping its retry state out of
ordinary scalar indexing. No instance tree or integer value is converted.

Paired 24-case uniqueness controls used Ruby 4.0.6/YJIT, Rust 1.99.0,
1,000 elements, 31 samples and batches of 100. The preceding installed
extension's loaded path was verified. All cases matched VM validity and full
diagnostics before timing; native `valid?` allocated zero Ruby objects.

| Shuffled Bignum case | Before (µs) | After (µs) | Native time reduction |
| --- | ---: | ---: | ---: |
| valid? valid | 13.89 | 13.17 | 5.17% |
| validate valid | 14.06 | 13.79 | 1.94% |
| valid? invalid | 13.85 | 13.26 | 4.26% |
| validate invalid | 15.17 | 14.83 | 2.23% |

Ordinary integer controls improved 0.39–5.38%; object controls improved
0.36–2.36%. Ordered Bignum controls ranged from 1.01% slower to 2.39% faster.
An initial inline candidate slowed ordinary integers by up to 7.8%; isolating
the bounded path removed that observed regression. With
`BENCHMARK_UNIQUE_SHIFT=64`, every input shares its low word and triggers the
full-hash retry. Those four cases cost 1.25–3.33% more than the preceding
implementation. Artifacts are `schemurai-big-low-controls-before.json`,
`schemurai-big-low-outlined-controls.json`,
`schemurai-big-low-high-before.json` and
`schemurai-big-low-outlined-high.json`.

Native/differential tests passed 116 examples, including negative values,
unequal integers with identical low words, exact duplicates, mixed Float
duplicates, and forbidden Ruby `hash`/`to_int` callbacks. The default full
suite passed 6,522 examples with 1,287 pending. Clippy, formatting and RuboCop
passed. A freshly built and installed `schemurai-native-big-low.gem` passed
isolated package smoke tests with verified gem/extension paths and VM
execution forbidden for native cases. The full audit below predates this
change; these filtered controls do not establish the overall 10x target.

### Rejected constant specialization of record lookup

The full audit below identified pattern object records as its lowest ratio.
A candidate selected separate Rust loops once per record depending on whether
a compiled short-key index existed. A const-generic field lookup removed the
index-strategy branches from the no-index loop; both loops retained identical
validation and Hash-key checks. Native/differential tests passed 116 examples
and Clippy passed.

An isolated pattern-record comparison on Ruby 4.0.6/YJIT, Rust 1.99.0,
1,000 records, 31 samples and batches of 100 did not show a consistent gain:

| Pattern-record case | Existing (µs) | Constant specialization (µs) |
| --- | ---: | ---: |
| valid? valid | 58.43 | 60.78 |
| validate valid | 64.43 | 66.35 |
| valid? invalid | 61.05 | 58.18 |
| validate invalid | 66.78 | 67.07 |

Valid validity slowed 4.03%, valid diagnostics slowed 2.98%, invalid validity
improved 4.70% and invalid diagnostics slowed 0.44%. The runtime change was
removed. Artifacts are `schemurai-record-index-const-pattern-before.json` and
`schemurai-record-index-const-pattern-after.json`. The retained implementation
is the packaged compiled-index implementation used by the full audit below.
After restoring and rebuilding, native/differential tests passed 116 examples
and the default full suite passed 6,522 examples with 1,287 pending. The
restored Rust source matches the audited package byte for byte. Formatting
and whitespace checks passed.

### Full audit with the compiled short-key index

The default 168-case runner completed using the freshly installed
`schemurai-native-short-index.gem` extension. Its loaded path was checked after
the run, and the packaged Rust/C/content sources matched the worktree before
measurement. Settings were Ruby 4.0.6/YJIT, Rust 1.99.0, 1,000 elements,
31 samples, batches of 100 and the default 4,096-character large-content
string. Native validity and diagnostics were supported for every case, and
validity plus full error details matched the VM before timing.

144/168 cases reached at least 10x; the minimum was 6.33x, median 20.60x and
geometric mean 23.22x. Every native `valid?` case allocated zero Ruby objects.
Frozen-key validity reached 7.95–7.96x, compared with 6.49–6.54x in the
preceding full snapshot. Its native times fell from about 149–150 µs to
123 µs. The paired controls below establish the index's direct effects.

| Workload | Cases below 10x | Speedup range |
| --- | ---: | ---: |
| pattern object records | 2 | 6.33–6.53x |
| unique shuffled large integers | 4 | 6.39–6.86x |
| object records | 2 | 6.93–6.95x |
| object records frozen keys | 2 | 7.95–7.96x |
| object records dynamic keys | 2 | 8.55–8.62x |
| overlapping property annotations | 1 | 8.89x |
| content base64 json large | 4 | 8.94–9.94x |
| unique late unordered integers | 1 | 9.43x |
| content base64 json long | 2 | 9.50–9.63x |
| large integer bounds | 2 | 9.66–9.67x |
| unique large integers | 1 | 9.77x |
| content json | 1 | 9.92x |

The preceding full snapshot reached 145/168 cases. `valid?` for valid plain JSON
now measured 9.92x, adding one case below the threshold despite a native time
of 35.92 µs. Threshold crossings in unrelated cases do not establish a causal
effect from this index. The lowest ratio now belongs to pattern object records;
shuffled large integers remain close behind. The all-case 10x target is unmet.
The artifact is `schemurai-short-index-full-audit.json`. Earlier full-audit
sections below are historical snapshots of their respective implementations.

### Collision-free compiled index for short record keys

Records with four to eight short schema names can now use a compiled sixteen-
slot index. The compiler searches four-bit windows of exact byte/length
metadata and uses the index only if every schema key has a distinct slot.
Encoding is excluded from slot selection; candidate bytes, length and encoding
compatibility are still checked exactly. Unknown input keys sharing a slot
cannot be accepted through the index alone. Long names and sets that cannot
be separated retain the existing scan. No instance data is cached or rebuilt.

An initial version indexed every eligible key and reduced isolated frozen-key
latency 23.83–25.61%, but slowed dynamic keys that share schema identities.
The retained version chooses a strategy per record from its first actual
key: shared identities keep the identity scan first, while distinct identities
can go straight to the compiled index. An immutable first-schema-property
handle makes the common identity check cheap. Both strategies inspect every
actual key, and no choice or input pointer survives the record.

Paired object-group controls used Ruby 4.0.6/YJIT, Rust 1.99.0, 1,000 records,
31 samples and batches of 100. The preceding installed extension's loaded
path was checked; both runners verified native support, validity and full
error details before timing.

| Record family | Case | Existing (µs) | Compiled index (µs) |
| --- | --- | ---: | ---: |
| ordinary | valid? valid | 48.84 | 50.29 |
| ordinary | validate valid | 58.23 | 56.06 |
| ordinary | valid? invalid | 50.65 | 49.82 |
| ordinary | validate invalid | 61.15 | 60.25 |
| dynamic keys | valid? valid | 104.20 | 106.68 |
| dynamic keys | validate valid | 112.39 | 112.55 |
| dynamic keys | valid? invalid | 105.90 | 106.30 |
| dynamic keys | validate invalid | 121.29 | 122.77 |
| frozen keys | valid? valid | 156.87 | 123.14 |
| frozen keys | validate valid | 163.57 | 130.52 |
| frozen keys | valid? invalid | 156.09 | 124.77 |
| frozen keys | validate invalid | 172.42 | 138.73 |

Frozen-key latency fell 19.54–21.50%. Dynamic keys measured 0.14–2.38% slower;
ordinary cases ranged from 2.97% slower to 3.73% faster. The frozen-key benefit
is retained with those measured tradeoffs. These filtered results do not update
the full-audit case count below, which predates this index. The 10x target is
still unmet.

Artifacts are `schemurai-record-short-index-before.json`,
`schemurai-record-short-index-after.json`,
`schemurai-record-short-index-controls-before.json`,
`schemurai-record-short-index-controls-after.json`,
`schemurai-record-short-index-adaptive-controls.json` and
`schemurai-record-short-index-final-controls.json`. The final artifact measures
the retained version.

Native/differential tests passed 116 examples and the default full suite passed
6,522 examples with 1,287 pending. Coverage includes every short-key byte,
unknown keys sharing index windows, Unicode/encoding differences, GC
compaction, mixed identity layouts and reversed order. Eight keys with a single
nonzero byte at different positions cannot be separated by one four-bit
window; their validity and full errors exercise the original scan. Clippy,
formatting and Ruby lint passed.
A newly built `schemurai-native-short-index.gem` compiled from its packaged
sources and passed isolated package smoke tests, including both indexed
short keys and the inseparable sparse-key set, with native VM fallback
forbidden. Loaded gem and extension paths were checked.

### Rejected contiguous schema-key identity scan

A candidate retained the compiled record's existing schema-key handles in a
fixed eight-word array and searched that array for identity matches before
accessing the larger field metadata. The array contained immutable schema
handles only, excluded its unused tail, and retained the original field order,
required bits and exact byte/encoding comparison after identity misses.
No instance data or key bytes were copied. Native/differential tests passed
116 examples, including GC compaction, and Clippy passed.

On Ruby 4.0.6/YJIT, Rust 1.99.0, 1,000 records, 31 samples and batches of
100, an isolated frozen-key run reduced latency 3.74–6.27%. Paired controls
using the preceding installed extension and the same object-group runner
did not reproduce a consistent benefit:

| Record family | Case | Existing (µs) | Contiguous identity scan (µs) |
| --- | --- | ---: | ---: |
| ordinary | valid? valid | 49.88 | 50.06 |
| ordinary | validate valid | 59.41 | 59.30 |
| ordinary | valid? invalid | 49.16 | 50.10 |
| ordinary | validate invalid | 61.87 | 61.49 |
| dynamic keys | valid? valid | 102.92 | 108.14 |
| dynamic keys | validate valid | 112.62 | 116.55 |
| dynamic keys | valid? invalid | 102.66 | 109.09 |
| dynamic keys | validate invalid | 122.78 | 123.17 |
| frozen keys | valid? valid | 151.72 | 150.09 |
| frozen keys | validate valid | 159.11 | 158.87 |
| frozen keys | valid? invalid | 149.59 | 150.68 |
| frozen keys | validate invalid | 172.77 | 165.19 |

Dynamic-key latency increased 0.32–6.26%; frozen-key changes ranged from a
0.73% increase to a 4.38% reduction. The runtime change was removed. Artifacts
are `schemurai-record-identity-array-before.json`,
`schemurai-record-identity-array-after.json`,
`schemurai-record-identity-array-controls-before.json` and
`schemurai-record-identity-array-controls-after.json`. The baseline extension's
loaded path was checked. The retained full-audit results below remain unchanged.
After restoring and rebuilding, native/differential tests passed 116 examples
and the default full suite passed 6,522 examples with 1,287 pending. The
restored Rust source matches the preceding verified package byte for byte;
formatting and whitespace checks passed.

### Rejected batched record key descriptors

A candidate collected each small record's key pointer, length and encoding
during the existing C Hash walk, alongside the borrowed key/value handles.
Only records with at least four compiled fields used the descriptor adapter.
The descriptors borrowed key storage under the GVL; no key bytes, instance
tree or Ruby objects were copied or allocated. Rust retained field selection,
encoding compatibility comparisons, required/duplicate bits and ordinary-Hash
lookup verification. Negative or oversized views never read partial outputs.

The candidate passed 116 native/differential examples and Clippy, but increased
frozen-key latency on Ruby 4.0.6/YJIT and Rust 1.99.0, with 1,000 records,
31 samples and batches of 100:

| Frozen-key case | Existing (µs) | Batched descriptors (µs) | Latency increase |
| --- | ---: | ---: | ---: |
| valid? valid | 156.47 | 159.86 | 2.17% |
| validate valid | 162.89 | 168.41 | 3.39% |
| valid? invalid | 155.26 | 162.28 | 4.52% |
| validate invalid | 172.96 | 179.95 | 4.04% |

The runtime changes were removed. Reducing the C call count did not improve
overall latency in this implementation.
Artifacts are `schemurai-record-key-views-before.json` and
`schemurai-record-key-views-after.json`. The retained implementation and its
full-audit results below remain unchanged.
After restoration and rebuilding, native/differential tests passed 116
examples and the default full suite passed 6,522 examples with 1,287 pending.
The restored Rust/C sources match the preceding verified package byte for
byte. Formatting and whitespace checks passed.

### Exact scalar comparison for short record keys

Small records with at least four compiled fields now compare short key bytes,
length and encoding as exact scalar metadata after the key-identity scan.
The original fingerprint filter mixed those bytes and then called CRuby's
string comparison for every surviving candidate. Keys of at most eight bytes
fit in overlapping first/last words covering every byte; a separate length tag
prevents ambiguity. Equal bytes, length and encoding establish exact equality.
Encoding differences still use CRuby's compatibility comparison. Longer keys
and smaller records retain the existing C string comparisons.

Compiled schema names come from immutable VM snapshots. Input metadata is
reacquired under the GVL in one pointer/length/encoding C call on each lookup;
no instance pointer is cached and no Ruby object is allocated. Required and
duplicate field bits, ordinary-Hash lookup verification and GC roots remain.

With Ruby 4.0.6/YJIT, Rust 1.99.0, 1,000 frozen-key records, 31 samples and
batches of 100, the isolated comparison measured:

| Frozen-key case | Existing (µs) | Exact scalar comparison (µs) | Latency reduction |
| --- | ---: | ---: | ---: |
| valid? valid | 178.71 | 154.73 | 13.42% |
| validate valid | 188.10 | 163.04 | 13.32% |
| valid? invalid | 180.74 | 155.16 | 14.15% |
| validate invalid | 195.24 | 172.28 | 11.76% |

Artifacts are `schemurai-record-short-exact-before.json` and
`schemurai-record-short-exact-after.json`. Filtered timings and VM ratios must
be kept separate from full-audit measurements because of YJIT workload order.
Paired object-group controls compared the preceding installed extension with
the current extension using the same runner and settings. Frozen keys improved
13.25–17.41%, dynamic keys improved 0.43–4.15%, and ordinary two-field records
measured 4.64–10.66% faster. The two-field lookup still uses C comparisons, so
its measured change cannot be attributed to the new scalar equality path.
Artifacts are `schemurai-short-key-record-controls-before.json` and
`schemurai-short-key-record-controls-after.json`; the old extension's loaded
path was checked after the run.

Native/differential tests passed 116 examples, including each byte position
for key lengths one through eight, longer keys, Unicode, embedded NULs,
different encodings and GC compaction. Full error details match the VM while
native VM execution is forbidden. The default full suite passed 6,522 examples
with 1,287 pending; Clippy, formatting and Ruby lint passed. A newly built
`schemurai-native-short-key.gem` compiled and passed isolated package smoke
tests, including Unicode/NUL keys and encoding differences, with native VM
fallback forbidden and loaded gem/extension paths checked.

### Full audit after exact short record key comparison

The complete default runner passed all 168 cases on Ruby 4.0.6/YJIT and
Rust 1.99.0, with 1,000 elements, 31 samples and batches of 100. The large
content setting was the default 4,096 characters. Before timing, both native
entry points were supported and validity plus full error details matched the
VM. Every native `valid?` case allocated zero Ruby objects.

145/168 cases reached at least 10x. The minimum was 6.30x, the median 20.95x
and the geometric mean 23.00x. The preceding full snapshot also reached
145/168, with a 5.62x minimum. Frozen-key validity now reached 6.49–6.54x;
shuffled large-integer diagnostics became the slowest VM-relative case.
Threshold crossings in unrelated cases do not establish a causal change from
this optimization; the paired record controls above show its direct effects.

| Workload | Cases below 10x | Speedup range |
| --- | ---: | ---: |
| object records | 2 | 6.87–7.03x |
| overlapping property annotations | 1 | 8.40x |
| unique large integers | 1 | 9.65x |
| pattern object records | 2 | 6.77–6.80x |
| content base64 json long | 2 | 9.15–9.24x |
| content base64 json large | 4 | 9.09–9.80x |
| large integer bounds | 2 | 9.25–9.50x |
| unique shuffled large integers | 4 | 6.30–6.86x |
| unique late unordered integers | 1 | 9.38x |
| object records dynamic keys | 2 | 8.76–8.85x |
| object records frozen keys | 2 | 6.49–6.54x |

The artifact is `schemurai-short-key-full-audit.json`. The 23 remaining cases
keep the all-case 10x target unmet. The earlier audit sections below remain
historical measurements of their respective implementations.

### Larger Base64 JSON streaming refills

Inputs above the 8,192-byte direct-decode limit now refill a fixed 1,536-byte
buffer instead of 384 bytes. The separate non-inlined helper keeps this frame
out of the short and medium input paths. Each full refill ends on a Base64
group boundary, and the crate still verifies the exact decoded output length,
alphabet, padding and unused trailing bits. No instance conversion or dynamic
decode buffer is introduced.

The default large workload contains only 4,096 repeated characters and uses
direct decoding. Initial attempts to compare streaming changes with that
workload did not exercise the changed path. The runner now accepts
`BENCHMARK_CONTENT_BYTES`, defaults to the same 4,096 characters, and records
the setting in its JSON output. A 9,216-character string exercises streaming.

With Ruby 4.0.6/YJIT, Rust 1.99.0, 1,000 elements, 31 samples and batches of
20, the streaming comparison measured:

| 9 KiB string case | 384-byte refill (ms) | 1,536-byte refill (ms) | Latency reduction |
| --- | ---: | ---: | ---: |
| valid? valid | 1.388 | 1.107 | 20.18% |
| validate valid | 1.392 | 1.116 | 19.83% |
| valid? invalid | 1.379 | 1.109 | 19.61% |
| validate invalid | 1.402 | 1.119 | 20.14% |

VM-relative speedups increased from 5.65–5.81x to 7.08–7.25x. Validity still
allocates zero Ruby objects. These filtered measurements are separate from
the default 168-case full audit below; the 10x target remains unmet.
Artifacts are `schemurai-stream-9216-existing.json` and
`schemurai-stream-9216-candidate.json`. A confirmation run measured
1.111–1.127 ms, preserving an 18.79–20.24% latency reduction and 7.03–7.30x
VM speedups; its artifact is `schemurai-stream-9216-confirm.json`.
A default-size control measured
0.454–0.460 ms with the candidate versus 0.454–0.460 ms with the existing
implementation; it does not establish a streaming improvement.

Boundary coverage includes invalid bytes and intermediate padding around the
2,048-byte encoded refill boundary, literal prefixes and escapes crossing the
9,216-byte decoded boundary, and VM comparisons of full error details.
The earlier experiment using uninitialized streaming storage was removed;
its original 4 KiB measurement likewise did not exercise streaming.
Native/differential tests passed 115 examples; the default full suite passed
6,522 examples with 1,287 pending. Clippy, formatting and Ruby lint passed.
A freshly built `schemurai-native-stream.gem` compiled from its packaged
sources and passed isolated package smoke tests, including the new refill
boundary, with native VM fallback forbidden. Loaded gem and extension paths
were checked against the isolated installation.

### Rejected record fingerprint lookup indexes

Two candidates tried to shorten field lookup after key-identity misses in
small records. A compiled sixteen-slot table retained candidate field bit masks,
checking full fingerprints and CRuby string equality for every surviving
candidate. A second candidate sorted the existing field vector by fingerprint
and located equal fingerprints with a partition search; it retained each field's
required/duplicate bit and exact string equality. Neither cached instance keys
or copied instance values. Both passed 115 native/differential examples.

With Ruby 4.0.6/YJIT, Rust 1.99.0, 1000 frozen-key records, 31 samples and
batches of 100, both candidates increased latency:

| Frozen-key case | Existing (µs) | Candidate masks (µs) | Sorted lookup (µs) |
| --- | ---: | ---: | ---: |
| valid? valid | 176.61 | 190.72 | 214.75 |
| validate valid | 183.54 | 195.47 | 218.72 |
| valid? invalid | 176.38 | 190.88 | 213.08 |
| validate invalid | 193.50 | 208.56 | 227.69 |

Both changes were removed. The existing small-vector scan and compiled schema
fingerprints remain. The current string-byte adapter already obtains pointer
and length in one C call, so another adapter fusion was unnecessary.
Artifacts are `schemurai-record-buckets-before.json`,
`schemurai-record-buckets-after.json` and `schemurai-record-sorted-after.json`.
These rejected candidates do not change the full-audit results below.

### Full audit after JSON value dispatch inlining

The JSON scanner now inlines value-kind dispatch into its callers. This retains
the same syntax/depth checks and borrowed input storage. Plain JSON improved
about 4–8% in isolated before/after measurements; a paired control improved
about 5–6%. Long Base64 JSON diagnostics improved about 6–7%, while combined
string-assertion validity was about 7–10% slower in isolated controls. The
combined workload still reached about 20–24x VM speed in the full audit, so the
change is retained to improve cases that previously missed the 10x target.

The complete 168-case runner passed with Ruby 4.0.6/YJIT, Rust 1.99.0, 1000
elements, 31 samples and batches of 100. All native validity/diagnostic support
gates passed; VM validity and full errors matched, and every native `valid?`
case allocated zero Ruby objects. 145/168 cases reached at least 10x; the
minimum was 5.62x, median 20.86x and geometric mean 23.08x. Plain JSON reached
10.38–10.43x for validity and 16.64–16.88x for diagnostics, meeting 10x in all
four cases. This snapshot includes the preceding container specialization and
combined JSON byte/encoding view as well as value dispatch inlining.

The 23 cases below 10x remain explicit:

| Workload | Cases below 10x | VM/native speedup |
| --- | ---: | ---: |
| object records frozen keys | 2 | 5.62–5.65x |
| unique shuffled large integers | 4 | 6.31–6.76x |
| pattern object records | 2 | 6.81x |
| object records | 2 | 7.08–7.10x |
| overlapping property annotations | 1 | 8.44x |
| unique late unordered integers | 2 | 9.09–9.98x |
| content base64 json large | 4 | 9.14–9.89x |
| unique large integers | 1 | 9.29x |
| object records dynamic keys | 2 | 9.40–9.42x |
| content base64 json long | 2 | 9.62–9.75x |
| unique high word integers | 1 | 9.85x |

Compared with the preceding complete 168-case snapshot, plain JSON's two
validity cases crossed 10x, while one high-word integer diagnostic case moved
from 10.04x to 9.85x. The aggregate count therefore increased from 144 to 145;
the all-case 10x target remains unmet. Audit artifacts are
`schemurai-json-value-full-audit.json` and
`schemurai-json-value-full-audit.log`. Paired controls use
`schemurai-json-value-control-`.

A candidate that compared fixed JSON literals in bulk did not improve plain
JSON and was removed. Restricting inlining to container entries also failed
to improve plain JSON and slowed combined validity by about 5%, so it was
removed. The added truncation/mutation and Base64 refill-boundary tests remain.
Artifacts use `schemurai-json-literal-` and `schemurai-json-value-scoped-`.

### Combined JSON String guard and encoding view

Plain JSON content arrays now obtain the ordinary String guard, borrowed byte
pointer/length and encoding metadata in one C call. The metadata query uses
CRuby's public inline encoding adapter, with its extended-index fallback.
Rust enters the JSON syntax scan directly after that guard. Unsupported String
encodings and nonordinary values retain VM fallback; non-String results never
read the unwritten byte-view outputs. US-ASCII inputs still require ASCII bytes,
and UTF-8/ASCII-8BIT behavior remains unchanged. Base64 retains its independent
raw String view. No instance conversion or new C parsing is introduced.

With Ruby 4.0.6/YJIT, Rust 1.99.0, 1000 strings, 31 samples and batches of 100,
the final direct-scan variant improved plain JSON content by about 5–8% over
the container-specialized baseline:

| Plain JSON case | Before (µs) | Combined view (µs) |
| --- | ---: | ---: |
| valid? valid | 40.39 | 37.54 |
| validate valid | 40.23 | 38.03 |
| valid? invalid | 39.90 | 37.55 |
| validate invalid | 41.37 | 39.31 |

Combined string-assertion controls ranged from about 1–3% faster, and Base64
JSON controls about 1–2% slower. An intermediate variant routed the metadata
through the general content evaluator and slowed combined validity by about
2–4%; direct scanning removed that slowdown. All benchmark native support
gates and VM validity/full-error comparisons passed, and native validity
allocated no Ruby objects. Artifacts use `schemurai-json-view-` for the initial
and paired/reverse-order controls, and `schemurai-json-view-direct-` for the
final plain, Base64 and combined controls. The full audit below predates both
this change and container specialization; no new aggregate count is claimed.

### JSON container specialization

The JSON content scanner now selects its array or object loop at compile time.
Array entries avoid the repeated object-key branch; object entries retain key
and colon checks. Both modes retain the same delimiters, depth limit, syntax
checks and bounded Base64 streaming. No JSON tree is constructed.

On Ruby 4.0.6/YJIT, Rust 1.99.0, 1000 strings, 31 samples and batches of 100,
two measurements improved plain JSON content by about 14–17%. Grouped controls
showed the following native times:

| Content case | Before (µs) | Specialized (µs) |
| --- | ---: | ---: |
| JSON / valid? valid | 45.92 | 39.17 |
| JSON / validate valid | 45.61 | 40.03 |
| JSON / valid? invalid | 45.39 | 39.71 |
| JSON / validate invalid | 47.48 | 41.30 |
| Base64 JSON / valid? valid | 51.29 | 48.10 |
| long Base64 JSON / validate valid | 57.63 | 60.83 |
| large Base64 JSON / valid? valid | 449.45 | 452.43 |

Short Base64 JSON validity improved about 5–7%. Its diagnostics were about 5%
slower in the grouped run, but 3–4% faster in a reverse-order isolated control.
Long Base64 JSON diagnostics remained about 5–6% slower in the reverse-order
control; its validity and the large streaming input stayed close to baseline.
The plain-JSON improvement is retained with this diagnostic tradeoff. Native
validity still allocated no Ruby objects, and all content benchmark support
gates and full VM error comparisons passed.

A separate attempt to remove redundant whitespace checks in array entries
did not improve plain JSON and was removed. Artifacts use the prefixes
`schemurai-content-container-` (plain/grouped and reverse-order short/long
controls) and `schemurai-content-whitespace-` (the rejected attempt).
The 168-case audit below predates this change; no new overall case count or
aggregate speedup is claimed from these filtered runs. The all-case 10x target
remains unmet.

### Full audit after packed uniqueness slots

The 168-case runner, before JSON container specialization, completed with
Ruby 4.0.6/YJIT, Rust 1.99.0,
1000 elements, 31 samples and batches of 100. Every workload passed native
validity/diagnostic support gates and matched VM validity and full errors.
Every native `valid?` case allocated zero Ruby objects.

144/168 cases reached at least 10x. The minimum was 5.64x, the median 20.69x,
and the geometric mean 22.77x. These measurements include the four frozen-key
record cases added after the earlier 164-case audit, so aggregate figures are
not a before/after comparison of identical suites. The 24 cases below 10x are:

| Workload | Cases below 10x | VM/native speedup |
| --- | ---: | ---: |
| object records frozen keys | 2 | 5.64–5.65x |
| unique shuffled large integers | 4 | 6.45–6.82x |
| pattern object records | 2 | 6.66–6.67x |
| object records | 2 | 6.98–7.07x |
| content json | 2 | 7.95–8.06x |
| overlapping property annotations | 1 | 8.53x |
| unique late unordered integers | 2 | 9.07–9.96x |
| content base64 json large | 4 | 9.17–9.96x |
| object records dynamic keys | 2 | 9.25–9.32x |
| unique large integers | 1 | 9.27x |
| content base64 json long | 2 | 9.40–9.59x |

The all-case 10x target remains unmet. This audit supersedes older snapshots
and predates the JSON change described above. The implementation also passed
115 native/differential
examples, 6522 default-backend examples (1287 pending), Clippy, formatting,
RuboCop and an installed-gem smoke test with both packed/full-table boundaries.
Audit artifacts are `schemurai-unique-packed-full-audit.json` and
`schemurai-unique-packed-full-audit.log`.

### Frozen-key record coverage and rejected order hints

The runner now includes `object records frozen keys`: eight fields whose keys
are separately created frozen Strings. A local Ruby identity check found all
eight corresponding keys shared between two ordinary dynamic-key records,
and none shared between two frozen-key records. Both workloads retain the
same logical key/value content. The new workload adds four method/input cases,
bringing the runner to 168 cases; the earlier complete audit below covers
164 cases and predates this addition.

The existing backend, measured with Ruby 4.0.6/YJIT, Rust 1.99.0, 1000 records,
31 samples, and 100 calls per sample, matched VM validity and full errors:

| Frozen-key method/input | Native (µs) | VM speedup |
| --- | ---: | ---: |
| valid? valid | 179.22 | 5.14x |
| validate valid | 182.62 | 10.32x |
| valid? invalid | 178.19 | 5.13x |
| validate invalid | 193.18 | 10.35x |

Temporary schema-index order hints improved this workload by about 1.26–1.30x
when both validity and diagnostics shared the scan, but slowed existing
dynamic-key validity by roughly 8–13%. A diagnostics-only shared scan reduced
dynamic-key diagnostics by about 5–6%, but ordinary-record validity still
regressed in a reverse-order control. Both implementation changes were removed;
the restored Rust sources matched the previously verified installed gem.
Artifacts include `schemurai-record-order-frozen-before.json`,
`schemurai-record-order-diag-after.json`,
`schemurai-record-order-dynamic-before-control.json`,
`schemurai-record-order-dynamic-after-control.json`,
`schemurai-record-visit-final-simple.json`, and
`schemurai-record-visit-simple-before-repeat.json`.

The added tests retain frozen/non-frozen key mixtures, reordered and sparse
records, overflow records, several invalid items, prefix offsets, dynamic
resource scopes, compaction, and mutations between validations. Restored
native/differential tests and installed-gem checks cover the implementation
without retaining the unsuccessful optimization.

### Rejected packed ASCII record-key comparison

A candidate packed every byte of keys up to eight bytes, retained their length,
and accepted identical ASCII bytes directly for UTF-8, US-ASCII and ASCII-8BIT.
Other encodings still used CRuby string equality. Schema metadata held the
packed keys; instance bytes remained borrowed under the GVL. The candidate
passed 114 native/differential examples, all 6522 default-backend examples
(1287 pending), and an installed-gem smoke check.

With Ruby 4.0.6/YJIT, Rust 1.99.0, 1000 records, 31 samples and batches of 100,
two runs improved frozen-key validity by 1.16–1.18x and diagnostics by
1.10–1.13x. Existing ordinary-record diagnostics were about 6% slower, and
dynamic-key diagnostics about 4% slower in the reverse-order control:

| Reverse-order control | Existing native (µs) | Candidate (µs) |
| --- | ---: | ---: |
| ordinary / validate valid | 55.03 | 58.35 |
| ordinary / validate invalid | 58.17 | 61.78 |
| dynamic keys / validate valid | 105.75 | 109.59 |
| dynamic keys / validate invalid | 114.09 | 118.74 |
| frozen keys / valid? valid | 175.14 | 151.68 |
| frozen keys / valid? invalid | 174.48 | 149.23 |

The candidate was removed after this regression reproduced. The restored
implementation retains the new short-key/encoding compatibility test, including
empty and control-byte names, short keys, a longer name, reordered keys,
missing required keys, wrong values, and UTF-16 encoding fallback.
Validity allocated no Ruby objects in either implementation. Artifacts are
`schemurai-record-ascii-packed-controls-before.json`,
`schemurai-record-ascii-packed-controls-after.json`,
`schemurai-record-ascii-packed-controls-before-repeat.json`, and
`schemurai-record-ascii-packed-controls-after-repeat.json`.
The all-case 10x target remains unmet.

### Packed uniqueness slots

Uniqueness arrays of at most 65,535 elements now use eight-byte slots instead
of sixteen-byte slots. A slot retains 48 fingerprint bits and a one-based
16-bit index into the original Ruby array; zero marks an empty slot. Larger
arrays retain the full fingerprint and machine-sized index. The table remains
at most half full, and every matching fingerprint requires exact JSON equality.
Discarded fingerprint bits can cause extra comparisons but cannot make unequal
values duplicates. No instance values, strings or integer digits are copied.

On Ruby 4.0.6/YJIT, Rust 1.99.0, 1000 elements, 31 samples and batches of 100,
two runs improved shuffled large-integer uniqueness by about 4–6%. A grouped
control improved ordinary integers by about 8–11%, while ordered integer
paths and object uniqueness remained close to the existing implementation:

| Grouped control | Existing native (µs) | Packed slots (µs) |
| --- | ---: | ---: |
| numbers / valid? valid | 3.52 | 3.25 |
| numbers / validate invalid | 4.86 | 4.50 |
| shuffled large integers / valid? valid | 14.06 | 13.43 |
| shuffled large integers / validate invalid | 15.47 | 14.81 |
| objects / valid? valid | 51.03 | 49.57 |
| ordered large integers / valid? valid | 8.76 | 8.81 |

The grouped ordered/late-unordered controls ranged from about 1% faster to
2% slower. Validity allocated no Ruby objects. Boundary coverage compares
65,534, 65,535 and 65,536-element arrays, including duplicates, against VM
validity and full errors while prohibiting native fallback to VM execution.
Artifacts are `schemurai-unique-packed-before.json`,
`schemurai-unique-packed-after.json`,
`schemurai-unique-packed-controls-before.json`, and
`schemurai-unique-packed-controls-after.json`. These filtered runs do not replace
the full audit below; the all-case 10x target remains unmet.

### Rejected combined record view

A candidate combined the ordinary-kind guard and the fixed eight-pair Hash
handle walk in one C adapter, keeping validation in Rust. A second version
inlined the Rust processing of those handles into the record-array loop.
Both versions passed 115 native/differential examples, including scalar items,
empty and overflowing Hashes, unusual key semantics and full error comparison.
The borrowed buffer was read only for successful Hash views.

On Ruby 4.0.6/YJIT, Rust 1.99.0, 1000 records, 31 samples and batches of 100,
combining the guard showed no speed improvement. Explicit inlining made
dynamic-key cases about 8–12% slower:

| Dynamic-key case | Existing native (µs) | Combined view (µs) | Inlined view (µs) |
| --- | ---: | ---: | ---: |
| valid? valid | 97.88 | 100.70 | 109.38 |
| validate valid | 105.93 | 105.93 | 115.41 |
| valid? invalid | 98.62 | 98.89 | 108.16 |
| validate invalid | 114.22 | 115.76 | 123.07 |

Both implementation changes were removed. The scalar/overflow compatibility
test remains. Artifacts are `schemurai-record-view-before.json`,
`schemurai-record-view-after.json`, and
`schemurai-record-view-inline-after.json`. The all-case 10x target remains unmet.

### Record-array loop and required-field bits

Small-record array items select a dedicated Rust loop before visiting items.
The loop retains the existing shallow kind guard, fixed borrowed-handle
buffer, resource scope, and general path for overflowing records. Compilation
maps required names to the field bits already used to detect duplicate equal
keys. Runtime keeps one visited-field mask, eliminating the separate required
mask update and per-field required metadata. Required-name duplicates and
diagnostic order are preserved. The C adapters are unchanged.

Controlled runs used Ruby 4.0.6 with YJIT, Rust 1.99.0, and the default
settings above. Every measured case matched VM validity and full errors.

| Workload/method/input | Native before (µs) | Native after (µs) |
| --- | ---: | ---: |
| object records / valid? valid | 50.36 | 48.51 |
| object records / validate valid | 56.61 | 55.76 |
| object records / valid? invalid | 50.26 | 48.43 |
| object records / validate invalid | 59.85 | 59.56 |
| dynamic keys / valid? valid | 101.31 | 99.41 |
| dynamic keys / validate valid | 103.24 | 107.38 |
| dynamic keys / valid? invalid | 99.92 | 98.87 |
| dynamic keys / validate invalid | 116.16 | 115.51 |

Ordinary record validity improved by 3.8%; dynamic-key validity by 1.1–1.9%.
Diagnostics were mixed, including dynamic-key valid diagnostics measuring
4% slower. Pattern-record control timings were initially up to 5.7% slower;
a repeat was near baseline. These are small improvements and measurement
variations, and do not establish the all-cases 10x target. Artifacts:
`schemurai-record-walk-before.json`, `schemurai-record-loop-after.json`,
`schemurai-record-mask-dynamic-before.json`,
`schemurai-record-loop-dynamic-after.json`, and the
`schemurai-record-loop-pattern-*.json` controls.

Focused native/differential tests passed (112 examples). Required-field
coverage now includes reordered and repeated names, optional fields, eight
fields, each missing-required case, compaction, and full VM errors with VM
execution forbidden. The default full suite passed (6522 examples, 1287
pending). Clippy, RuboCop, and formatting passed.
The freshly installed gem passed the package smoke test with Ruby/extension
paths verified and VM execution forbidden for native cases. Whitespace
checks passed.

### Object guard consolidation measurements

Combining the small-Hash view with its preceding kind guard did not produce
a consistent improvement. Ordinary record validity measured about 2% faster,
but dynamic eight-field records measured roughly 8–10% slower when the view
returned kind through an additional output argument. Encoding kind in the
return value still regressed; a Rust inline hint brought those cases near
baseline with mixed diagnostics timings. A separate unequal-length shortcut
in string comparison was also nearly unchanged. These changes were removed,
and both C/Rust sources matched the previously verified installed gem after
restoration. Subsequent work should address the record scan itself rather
than infer throughput from the number of FFI calls. Controlled artifact pairs:
`schemurai-record-key-before.json` / `schemurai-record-view-after.json`, and
`schemurai-record-dynamic-before.json` / `schemurai-record-dynamic-after.json`.

### Selecting content specializations before array scans

Content-only array scans select their Base64/JSON combination once, then use
a Rust specialization throughout the item loop. Their byte-view adapter outputs
use `MaybeUninit`; only successful String views read the initialized pointer
and length. Encoding checks, bounded decode scratch, JSON syntax, invalid-item
diagnostics, and fallback behavior are unchanged. No C parsing or instance
conversion was added.

Controlled `BENCHMARK_GROUP=content` runs used Ruby 4.0.6 with YJIT, Rust
1.99.0, and the default settings above. All 20 cases matched VM validity and
full errors. Native `valid?` allocated zero Ruby objects in every case.
Ranges cover valid/invalid inputs and both public methods.

| Workload | Native before (µs) | Native after (µs) | VM speedup after |
| --- | ---: | ---: | ---: |
| content base64 | 8.93–10.47 | 7.94–9.22 | 10.17–23.91x |
| content json | 46.11–48.03 | 45.67–47.28 | 6.56–10.60x |
| content base64 json | 53.61–56.42 | 50.02–51.88 | 8.59–12.62x |
| content base64 json long | 57.14–62.66 | 57.37–58.76 | 7.42–10.83x |
| content base64 json large | 447.62–462.89 | 449.62–455.32 | 8.71–9.40x |

Base64-only native time improved by 1.11–1.14x and short Base64/JSON by
1.07–1.09x. Plain JSON was nearly unchanged. Long and large content had mixed
results, including up to 1.2% slower timings; this change does not establish
their 10x target. Filtered VM ratios differ from the full audit below and
should not replace its overall counts. Artifacts:
`schemurai-content-specialized-before.json` and
`schemurai-content-specialized-after.json`.

Focused native/differential tests passed (112 examples), including encoding,
compaction, malformed content, scratch/refill boundaries, prefix offsets,
and full diagnostics with VM execution forbidden. The default full suite
passed (6522 examples, 1287 pending). Clippy and formatting passed.
The freshly installed gem passed its package smoke test with installed Ruby
and extension paths verified and VM execution forbidden for native cases.
Whitespace checks passed.

### Full audit after annotation-buffer reuse

A complete run including the numeric-bound, content-array, and annotation
optimizations used Ruby 4.0.6 with YJIT and Rust 1.99.0: 1000 elements, 31
samples, and 100 calls per sample. Compilation was excluded. No builds,
tests, or other benchmarks ran alongside it. All 164 cases passed the native
validity/diagnostics support gates and matched VM validity and full detailed
errors before measurement. Native `valid?` allocated zero Ruby objects in
every case.

142 of 164 cases reached 10x. The median ratio was 21.26x, the geometric
mean 23.23x, and the minimum 6.10x. The remaining 22 cases are below; counts
refer to method/input combinations, and ranges contain only those below 10x.
These results leave the all-cases performance target unmet.

| Workload | Cases below 10x | VM speedup |
| --- | ---: | ---: |
| unique shuffled large integers | 4 | 6.10–6.45x |
| pattern object records | 2 | 6.47–6.56x |
| object records | 2 | 6.67–6.68x |
| overlapping property annotations | 1 | 8.30x |
| content json | 2 | 8.32–8.33x |
| object records dynamic keys | 2 | 8.92–8.98x |
| content base64 json large | 3 | 9.12–9.86x |
| content base64 json long | 2 | 9.43–9.63x |
| unique late unordered integers | 1 | 9.48x |
| unique large integers | 1 | 9.62x |
| content base64 json | 2 | 9.71–9.79x |

The large instance-Integer bounds and wide schema-Integer bounds each reached
10x in all four combinations. Three of the four overlapping-property
annotation combinations also reached 10x. Filtered and full-run ratios differ
because workload order affects the YJIT baseline; absolute native timings and
the full-run results should both inform subsequent optimization. The remaining
work concentrates on unordered Bignum uniqueness, object validity, and JSON
content scanning. Artifacts: `schemurai-native-tracking-full-audit.json` and
`schemurai-native-tracking-full-audit.log`.

### Reusing annotation buffers and instance guards

Successful applicator branches transfer native annotation buffers into empty
accumulators instead of allocating copies. Later branches still union the
bitsets and borrowed key sets. Tracked property assertions reuse direct leaf
checks; branches evaluating the same instance reuse its guarded kind while
entering their own resource scopes. Ruby instances are neither converted nor
cached between calls, and the C adapters are unchanged.

Controlled `BENCHMARK_WORKLOAD='overlapping property annotations'` runs used
Ruby 4.0.6 with YJIT, Rust 1.99.0, and the default settings above. All four
cases matched VM validity and full detailed errors.

| Method and input | Native before (µs) | Native after (µs) | VM speedup after |
| --- | ---: | ---: | ---: |
| valid? valid | 58.23 | 42.85 | 6.49x |
| validate valid | 59.20 | 42.35 | 6.61x |
| valid? invalid | 60.07 | 42.35 | 6.57x |
| validate invalid | 76.56 | 59.37 | 4.80x |

Native time improved by 1.29–1.42x. This workload still falls below the 10x
target. Artifacts: `schemurai-inline-tracking-before.json` and
`schemurai-tracking-final-after.json`.

Focused native and differential tests passed (112 examples). New cases cover
empty and overlapping annotation sets, known and pattern-matched keys,
failed-branch discard, and array/property boundaries at 63, 64, 65, and 129
locations, comparing full VM errors with VM execution forbidden for native
checks. The default full suite passed; forcing VM retained its two known
failures (6522 examples, 1287 pending). Clippy, RuboCop, and formatting passed.
The freshly installed gem also passed the package smoke test, including
65 known properties, a pattern-matched key, and failed-branch discard. The
test verified installed Ruby/extension paths and forbade VM execution for
native cases. Whitespace checks passed.

### Bounded Integer sign results

Numeric bounds now combine Bignum classification and public size/sign metadata
without repeated classification calls. Rust reads only fields initialized for
the returned kind and sign, avoiding unused scalar-output initialization.
When all Integer limits fit i128 and no multipleOf assertion is present,
compilation combines their result for each sign outside i128. Runtime scans
select that result without revisiting each limit. Near-boundary magnitudes
still use exact words; Float and wide schema-bound rules retain their exact
comparisons. No instance conversion or Ruby allocation is added.

Controlled `BENCHMARK_WORKLOAD='large integer bounds'` before/after runs used
Rust 1.99.0, Ruby 4.0.6 with YJIT, and the settings above. All four cases
matched VM validity and detailed errors.

| Method and input | Native before (µs) | Native after (µs) | VM speedup after |
| --- | ---: | ---: | ---: |
| valid? valid | 12.95 | 8.88 | 12.31x |
| validate valid | 13.45 | 9.46 | 28.77x |
| valid? invalid | 12.96 | 8.95 | 12.40x |
| validate invalid | 15.99 | 11.97 | 22.99x |

Native time improved by 1.34–1.46x and native `valid?` allocated zero Ruby
objects. VM timings also varied between runs; the ratio change should not all
be attributed to the native implementation. Artifacts:
`schemurai-bounds-outputs-before.json` and `schemurai-bounds-signs-after.json`.
The wide Float control measured 10.74–13.41 µs before and 10.93–13.50 µs after,
up to 2.2% slower, with unchanged results and detailed errors. Its artifacts
are `schemurai-bounds-signs-float-before.json` and
`schemurai-bounds-signs-float-after.json`. These filtered runs do not establish
the overall 10x target.

Focused tests passed (111 examples). Oversized-bound checks were additionally
expanded to arrays and object properties, covering both signs, all four
comparison operators, contradictory limits, i128 boundaries, magnitudes around
2^127 through 2^4096, and ordered diagnostics. The expanded test passed with
VM execution forbidden. The full suite retained the two known VM failures
(6522 examples, 1287 pending). Clippy, RuboCop, formatting, and whitespace
checks passed.

The freshly built and installed gem passed the package smoke test, including
positive and negative oversized Integer bounds in arrays. The test verified
that both Ruby code and the native extension came from the installed gem and
forbade VM execution for native cases.

### Content array scans

Arrays with only a content assertion now select the content scan before
visiting items. One existing C guard classifies each ordinary String and
returns its borrowed pointer and byte length; JSON retains its encoding check.
Diagnostics scan the same input and collect full errors only for invalid items.
Required types, prefix offsets, attempted-item coverage, special-value fallback,
and sibling assertions retain their existing semantics. No C parser or instance
conversion is added.

Controlled `BENCHMARK_GROUP=content` runs used Rust 1.99.0, Ruby 4.0.6 with
YJIT, and the settings above. The baseline used the preceding installed native
extension; builds and tests had finished before both runs. All 20 cases matched
VM validity and detailed errors. Native `valid?` allocated zero Ruby objects.
Times span all four method/validity cases for each workload.

| Content assertion | Native before (µs) | Native after (µs) | VM speedup after |
| --- | ---: | ---: | ---: |
| Strict Base64 | 13.40–17.61 | 8.99–10.38 | 9.13–20.98x |
| JSON syntax | 49.75–53.74 | 45.95–47.29 | 6.31–10.27x |
| Base64 + JSON syntax | 55.91–60.12 | 52.56–55.99 | 7.44–11.81x |
| Base64 + JSON, 256-byte string | 59.89–65.57 | 57.33–59.41 | 7.42–11.12x |
| Base64 + JSON, 4,096-byte string | 453.46–461.77 | 458.70–461.19 | 8.72–9.56x |

Strict Base64 improved native time by 1.49–1.75x and JSON syntax by 1.08–1.14x.
Encoded JSON diagnostics improved by 1.11–1.13x for the shorter workloads;
their validity scans changed less. Large encoded JSON measured up to 1.4%
slower. The overall 10x target remains unmet. Artifacts:
`schemurai-content-scan-controlled-before.json` and
`schemurai-content-scan-controlled-after.json`.

Focused tests passed (111 examples), including all three content combinations,
typed and untyped items, binary and ASCII strings, unsupported encodings and
subclasses, multiple errors, prefixItems, allOf, unevaluatedItems, sibling length
assertions, and GC compaction. The full suite retained the two known VM failures
(6522 examples, 1287 pending). Clippy, RuboCop, formatting, and whitespace checks
passed. An independently built and installed gem passed smoke tests with VM
execution forbidden for native cases, including both invalid content paths
after prefixItems.

### Full-run audit before the single wide-bound shortcut

The complete run on 2026-10-11 used Rust 1.99.0, Ruby 4.0.6 with YJIT on
x86_64-linux, 1000 elements, 31 samples, and batches of 100. All 164
method/validity cases matched VM validity and detailed errors. Native coverage
was checked before timing, and native `valid?` allocated zero Ruby objects in
every case. Of these cases, 136 reached 10x; the range was 5.60–144.16x, the
median 20.85x, and the geometric mean 22.59x. These aggregate figures do not
establish 10x in every case. Artifact: `schemurai-native-current-full-audit.json`.

| Workload with cases below 10x | Cases below target | Speedup of those cases |
| --- | ---: | ---: |
| wide schema integer bounds | 2 | 5.60–6.27x |
| unique shuffled large integers | 4 | 6.23–6.61x |
| overlapping property annotations | 4 | 6.46–8.16x |
| pattern object records | 2 | 6.72–6.81x |
| object records | 2 | 7.01–7.03x |
| content JSON | 2 | 7.67–7.78x |
| large integer bounds | 2 | 7.78–8.81x |
| content Base64 JSON long | 2 | 8.86–8.98x |
| content Base64 JSON large | 4 | 8.97–9.41x |
| content Base64 JSON | 2 | 9.17–9.33x |
| unique large integers | 1 | 9.52x |
| unique late unordered integers | 1 | 9.54x |

### Single wide Integer bound

A single Integer bound outside i128 now compares original Bignum handles
through the existing checked Big/Big comparator, skipping magnitude metadata
and scalar word reads. Rust applies the type mask and inclusive/exclusive
comparison. Other kinds retain the existing classification and Float tie rules.
Bounded decimal Float fractions can also combine `multipleOf` with a wider
Integer schema bound: the fraction cannot reach that magnitude, so the bound's
sign determines ordering without an allocating mixed comparison.

Controlled `BENCHMARK_WORKLOAD='wide schema integer bounds'` before/after runs
used the settings above. All four cases matched VM validity and detailed errors.

| Method and input | Native before (µs) | Native after (µs) | VM speedup after |
| --- | ---: | ---: | ---: |
| valid? valid | 16.57 | 7.84 | 11.10x |
| validate valid | 17.47 | 8.44 | 32.07x |
| valid? invalid | 16.40 | 7.92 | 10.89x |
| validate invalid | 20.13 | 11.00 | 24.85x |

Native time improved by 1.83–2.11x. Native `valid?` allocated zero Ruby objects.
Artifacts: `schemurai-wide-single-before.json` and
`schemurai-wide-single-after.json`. These filtered results do not update the
164-case full-run counts above. Focused tests passed (110 examples), including
positive and negative bounds around 2^127 through 2^4096, all four comparison operators,
typed and untyped rules, mixed values, decimal multiples, full diagnostics,
and GC compaction. The test VM loader now explicitly loads the VM before
obtaining its evaluator class, avoiding dependence on randomized test order.
The full suite retained the two known VM failures (6522 examples, 1287 pending).
Clippy, RuboCop, formatting, and whitespace checks passed. An independently
built and installed gem passed smoke tests for wide integer bounds and the
combined decimal diagnostics with VM execution forbidden for native cases.

### Full-run audit before ordered integer scans

The complete run on 2026-10-11 used Ruby 4.0.6 with YJIT on x86_64-linux,
1000 elements, 31 samples, and batches of 100. All 148 method/validity cases
matched VM validity and detailed errors, and the runner confirmed native
coverage before measuring. Native `valid?` allocated zero Ruby objects in
every case. Of the 148 cases, 116 reached 10x; the overall range was
3.46–142.17x. The 10x target remains unmet across the full workload set.
The result artifact is `schemurai-native-current-audit.json`.

| Workload with cases below 10x | Cases below target | Speedup of those cases |
| --- | ---: | ---: |
| object records | 2 | 6.32–6.33x |
| overlapping property annotations | 4 | 6.30–8.35x |
| unique large integers | 4 | 3.51–3.81x |
| pattern object records | 2 | 6.17–6.18x |
| format json-pointer | 2 | 7.85–7.90x |
| content json | 2 | 7.06–7.13x |
| content base64 json | 2 | 9.00–9.19x |
| content base64 json long | 2 | 7.28–7.40x |
| content base64 json large | 4 | 4.64–5.12x |
| large integer bounds | 2 | 7.03–7.04x |
| wide schema integer bounds | 2 | 5.15–5.17x |
| unique high word integers | 4 | 3.46–3.62x |

This full-run result includes the shared string views, bounded Base64 decode
scratch, and regex-automata boolean DFA changes. Filtered measurements later
in this document describe their separate runs and can differ because of YJIT
specialization. Timings are local observations, not portable guarantees.
The same source was built as `schemurai-native-current-audit.gem` and installed
into a fresh gem directory. The package smoke test passed with VM evaluation
disabled for its native cases, including combined string assertions and
priority alternatives; the loaded gem and extension paths were verified.

### Ordered large-integer uniqueness

Native uniqueness now recognizes strictly ascending or descending Bignum
arrays by comparing original operands through a guarded public CRuby adapter.
It needs no magnitude export or fingerprint table for these arrays. An unordered
tail of at most sixteen elements uses binary search in the proven ordered
prefix and exact comparisons within the tail. Other inputs use the existing
fingerprint index, including mixed Integer/Float equality.

Filtered runs with the full-run audit's settings measured consecutive large
integers at 0.008–0.010 ms instead of 0.025–0.026 ms. Their VM speedup remains
6.02–7.61x in the final filtered run. High-word integers measured
0.008–0.009 ms, or 6.54–8.57x VM. Shuffled integers stayed at
0.025–0.027 ms. The late-unordered benchmark swaps the last two elements;
it measured 0.009–0.010 ms instead of 0.025–0.027 ms. The initial ordered
scan without the short-tail search regressed this workload to 0.033–0.035 ms;
that intermediate version was replaced. Larger unordered tails after long
ordered prefixes still require a second scan for the fingerprint index.
These results improve ordered inputs but do not establish the 10x target.

Artifacts: `schemurai-unique-ordered-before.json` and the final
`schemurai-unique-large-integers-final.json`,
`schemurai-unique-high-word-integers-final.json`,
`schemurai-unique-shuffled-large-integers-final.json`, and
`schemurai-unique-late-unordered-integers-final.json`. Shuffled and late-unordered
before runs used the extension from the preceding packaged source. The runner
now includes both workloads in its complete comparison (156 method/validity
cases); the 148-case audit above predates them and this optimization.
Focused differential tests passed (103 examples); the full suite retained only
the two documented VM failures (6522 examples, 1287 pending).
The extension was subsequently rebuilt and relinked with Rust/Cargo 1.99.0.
Clippy, formatting, and both test runs passed with the same known full-suite
failures. Repeating the four filtered workloads under that build measured
ordered and late-unordered inputs at 0.007–0.010 ms (6.19–8.75x VM) and
shuffled inputs at 0.024–0.026 ms (2.29–2.72x VM). The corresponding artifact
names replace the `-final.json` suffix above with `-rust199.json`.

### Structural fingerprint views

Structural fingerprints now obtain an ordinary-kind check and its borrowed
storage metadata in one C call. Array and String views retain original storage;
Hash views provide size, Float views a scalar, and Boolean views their truth
value. Rust reads only outputs initialized for that kind. Hash iteration still
checks every key, unsupported subclasses still delegate, and exact equality
still resolves collisions. No instance conversion is introduced.

Controlled `BENCHMARK_GROUP=unique` runs used Rust 1.99.0, Ruby 4.0.6 with
YJIT, and the settings above. All 24 cases matched VM validity and detailed
errors, with zero Ruby allocations for native `valid?`. Objects improved native
time by 1.02–1.03x. A separate object-only comparison used the preceding
installed extension for the baseline and improved all four cases by
1.01–1.07x. Times span valid and invalid `valid?` and `validate` cases.

| Object uniqueness comparison | Native before (µs) | Native after (µs) | VM speedup after |
| --- | ---: | ---: | ---: |
| Full uniqueness group | 51.93–54.01 | 50.49–53.02 | 4.71–4.86x |
| Object-only control | 52.04–53.98 | 49.38–52.71 | 4.79–5.01x |

Immediate integers remained at 3.56–4.70 µs (10.53–15.32x VM). Ordered
Bignum paths, which bypass structural fingerprints, measured up to 6% slower
in the grouped run. These observed variations are included rather than
attributed to the changed fingerprint algorithm. The overall 10x target
remains unmet. Group artifacts: `schemurai-fingerprint-view-before.json` and
`schemurai-fingerprint-direct-after.json`; object-only artifacts:
`schemurai-fingerprint-direct-objects-before.json` and
`schemurai-fingerprint-direct-objects-after.json`.

Focused tests passed (110 examples), including empty and nested containers,
embedded and heap-backed strings, Unicode, binary bytes, Float values,
subclass fallback, full errors, and GC compaction. The full suite retained
the two known VM failures (6522 examples, 1287 pending). Clippy, RuboCop,
formatting, and whitespace checks passed. An independently built and installed
gem passed package smoke tests, including nested structural uniqueness with
VM execution forbidden for native cases.

### Flat uniqueness table

The uniqueness index now uses a flat table of fingerprints and original Ruby
array indices. At least half the slots remain empty, so probing always reaches
an unused slot. Equal fingerprints require exact equality; unequal values
continue probing, including across the capacity boundary. This removes the
separate collision-link vector without copying instance values. Ordered
Bignum scans and mixed Integer/Float fingerprint normalization remain.

Controlled `BENCHMARK_GROUP=unique` runs used Rust 1.99.0, Ruby 4.0.6 with
YJIT, and the settings above. All 24 cases matched VM validity and detailed
errors. Native `valid?` allocated zero Ruby objects in every case.

| Uniqueness workload | Native before (µs) | Native after (µs) | VM speedup after |
| --- | ---: | ---: | ---: |
| Immediate integers | 5.47–6.83 | 3.51–5.04 | 10.34–16.20x |
| Objects | 51.39–53.96 | 53.21–53.67 | 4.49–4.58x |
| Ordered large integers | 8.23–10.01 | 8.31–9.55 | 6.29–7.03x |
| Ordered high-word integers | 7.42–9.00 | 7.44–8.69 | 6.96–7.85x |
| Shuffled large integers | 17.33–19.61 | 14.07–15.84 | 3.86–4.18x |
| Late unordered integers | 8.46–9.93 | 8.45–10.00 | 6.14–6.99x |

Immediate integers improved native time by 1.35–1.56x, and all four of their
cases exceeded 10x VM in this run. Shuffled large integers improved by
1.15–1.24x. Objects measured up to 3.7% slower. These local results do not
establish the overall 10x target. Artifacts: `schemurai-unique-slots-before.json`
and `schemurai-unique-slots-after.json`. Focused tests passed (109 examples),
including capacity boundaries from 17 through 1,025 elements, canonical
high-digit collisions, NaN containers, mixed values, and full errors. The
full suite retained the two known VM
failures (6522 examples, 1287 pending). Clippy, RuboCop, formatting, and
whitespace checks passed. An independently built and installed gem passed
package smoke tests with VM execution forbidden for native cases.

### Unordered Bignum index

Unordered arrays beginning with a Bignum now try a separate index using
CRuby's public `rb_hash`, guarded to accept only Bignums. Its Bignum branch
hashes existing digits without Ruby method dispatch; the thin adapter returns
only the hash scalar. Exact integer comparison resolves collisions. Any
non-Bignum restarts the whole array with canonical fingerprints so equal
Integer/Float pairs still share a bucket. The ordered-prefix paths remain.

The direct dispatch is visible in CRuby's
[3.4 source](https://github.com/ruby/ruby/blob/v3_4_0/hash.c#L199) and
[current source](https://github.com/ruby/ruby/blob/master/hash.c).
The implementation calls `rb_hash`, not the private `rb_big_hash` API.
An isolated test replaces `Integer#hash` with a raising method and forbids VM
execution, covering unordered integers, duplicates, and mixed Float equality.

Controlled `BENCHMARK_GROUP=unique` runs used Rust 1.99.0, Ruby 4.0.6 with
YJIT, and the settings above. All 24 cases matched VM validity and detailed
errors. Native `valid?` allocated zero Ruby objects in every case.

| Uniqueness workload | Native before (µs) | Native after (µs) | VM speedup after |
| --- | ---: | ---: | ---: |
| Immediate integers | 5.00–6.31 | 5.26–6.62 | 7.57–10.78x |
| Objects | 50.29–53.64 | 51.22–52.75 | 4.59–4.76x |
| Ordered large integers | 8.26–9.61 | 8.05–9.61 | 6.12–7.03x |
| Ordered high-word integers | 7.30–8.65 | 7.22–8.77 | 6.73–7.84x |
| Shuffled large integers | 24.89–26.43 | 17.23–18.60 | 3.18–3.37x |
| Late unordered integers | 8.31–10.04 | 8.42–9.96 | 6.02–6.71x |

Shuffled large integers improved native time by 1.42–1.49x. Immediate integer
times measured 3.9–5.2% slower; other workloads stayed within about 3% of their
baseline. The overall 10x target remains unmet. Artifacts:
`schemurai-big-hash-group-before.json` and
`schemurai-big-hash-group-after.json`. An independent shuffled-only run
measured 17.69–19.36 µs versus 25.04–26.19 µs (3.09–3.76x VM).
Focused tests passed (107 examples), plus the isolated hash-callback test.
Coverage includes unordered positive and negative integers, 64–4096-bit
boundaries, high-digit collisions, mixed values, full errors, and GC
compaction. The full suite retained the two known VM failures (6522 examples,
1287 pending). Clippy, RuboCop, formatting, and whitespace checks passed.
An independently built and installed gem passed package smoke tests, including
unordered integer validity and full duplicate diagnostics with native VM
execution forbidden.

### Dynamic record keys

Small-record lookup now caches schema-name fingerprints and filters candidates
for short input keys (at most eight bytes) when there are at least four fields.
The pointer-identity shortcut, exact CRuby string comparison, and per-record
ordinary-Hash lookup guard remain in place. Smaller records and longer keys
retain direct comparisons.

Controlled filtered runs built both variants with Rust 1.99.0, using Ruby 4.0.6
with YJIT and the settings above. Eight dynamically generated field names
measured 0.102–0.105 ms for `valid?` versus 0.106 ms before filtering
(8.26–8.33x VM); detailed validation measured 0.106–0.120 ms versus
0.113–0.122 ms. Two-field records stayed near 0.049–0.051 ms for `valid?`.
Moving the key metadata into a separate dense array did not improve these
measurements and was removed. This is a small local improvement, and the
record workloads still fall short of the 10x target.

Artifacts use `schemurai-object-records-dynamic-keys-controlled-before.json`
and `schemurai-object-records-dynamic-keys-controlled-after.json`; the two
control workloads use the same suffixes with `object-records` or
`pattern-object-records`. The runner now includes dynamic record keys,
bringing its full comparison to 160 method/validity cases. Focused tests passed
(104 examples), including noninterned keys, Unicode, ASCII-compatible binary
keys, GC compaction, and input mutation. The full suite retained the two known
VM failures (6522 examples, 1287 pending). Clippy and RuboCop passed.

### Pointer escape search

JSON Pointer and Relative JSON Pointer now scan pointer suffixes longer than
32 bytes with memchr's borrowed-slice escape iterator. Only tilde escapes need
inspection; their following byte must be `0` or `1`. Short suffixes retain the
scalar scan to avoid search dispatch overhead. memchr 2.8.3 was already locked
as a transitive dependency and is now declared directly.

Filtered runs built with Rust 1.99.0 and the settings above measured the new
long JSON Pointer workload at 0.015–0.019 ms versus 0.115–0.125 ms before,
or 29.75–31.80x VM. Short JSON Pointer `valid?` measured 0.012–0.013 ms
versus 0.016 ms; its VM speedup remains 4.96–5.00x. Short Relative JSON
Pointer retained 0.015–0.018 ms and 12.69–17.69x VM. Using memchr for
short pointers initially slowed the relative workload to 0.017–0.020 ms;
the scalar threshold removed that regression. The overall 10x target remains
unmet, including short JSON Pointer validity.

Artifacts: `schemurai-pointer-before.json`,
`schemurai-format-json-pointer-final.json`,
`schemurai-format-json-pointer-long-before.json`,
`schemurai-format-json-pointer-long-final.json`, and
`schemurai-format-relative-json-pointer-final.json`. The complete runner now
includes long JSON Pointer inputs (164 method/validity cases); the earlier
full-run audit predates this workload and optimization.
Focused tests passed (105 examples), covering every byte value at multiple
search boundaries, truncated and adjacent escapes, binary and Unicode strings,
long inputs, and GC compaction without VM evaluation. The full suite retained
the two known VM failures (6522 examples, 1287 pending). Clippy and RuboCop passed.
`schemurai-native-pointer.gem` was built and installed into a fresh gem directory.
The package smoke test passed, including long absolute and relative pointers
with native VM evaluation disabled; the loaded gem and extension paths were verified.

### Format array scans

Arrays with a single format assertion now select the parser before scanning.
One C call validates each ordinary String and borrows its byte view; Rust runs
the selected parser directly. Diagnostics use the same scan, collecting full
errors only for invalid items. Type failures, prefix offsets, attempted-item
coverage, special-object fallback, and error order are preserved. Rules with
length, pattern, or content assertions keep their existing evaluation path.

`BENCHMARK_GROUP=format` before/after runs used Rust 1.99.0, Ruby 4.0.6 with
YJIT, and the settings above. All 40 method/validity cases matched VM results
and detailed errors, with zero Ruby allocations for native `valid?`. Native
time improved in every case by 1.14–2.30x; 38 cases reached 10x VM. The two
remaining cases were short JSON Pointer validity (7.42–7.68x VM).
Times below span the four method/validity combinations for each workload.

| Format | Native before (µs) | Native after (µs) | VM speedup after |
| --- | ---: | ---: | ---: |
| date | 12.68–16.00 | 6.47–8.04 | 60.24–73.89x |
| time | 16.74–21.47 | 11.24–12.93 | 51.24–60.84x |
| date-time | 20.94–25.81 | 15.46–17.52 | 60.89–68.49x |
| duration | 16.04–19.80 | 10.72–12.53 | 52.68–62.12x |
| ipv4 | 18.14–22.45 | 12.22–14.08 | 64.65–78.29x |
| ipv6 | 43.84–49.06 | 38.28–39.80 | 57.38–61.02x |
| uuid | 37.01–41.51 | 30.72–32.53 | 52.47–55.25x |
| json-pointer | 12.72–16.64 | 6.52–9.87 | 7.42–24.55x |
| relative-json-pointer | 15.10–19.32 | 8.33–10.67 | 23.31–34.61x |
| json-pointer long | 14.42–18.68 | 9.23–10.80 | 52.43–60.07x |

Artifacts: `schemurai-format-scan-before.json` and
`schemurai-format-scan-after.json`. A separate short JSON Pointer run measured
validity at 6.36–6.51x VM and diagnostics at 20.46–23.51x; its artifact is
`schemurai-format-scan-pointer-filtered.json`. Grouped and single-workload runs
can differ because of YJIT specialization. These measurements do not establish
the overall 10x target. Focused tests passed (106 examples), including all nine
formats, typed and untyped items, non-string values, binary and UTF-16 strings,
prefixItems, unevaluatedItems, multiple errors, GC compaction, and unsupported
values. The full suite retained the two known VM failures (6522 examples,
1287 pending). Clippy, RuboCop, formatting, and whitespace checks passed.

### Content string scans

JSON strings scan an initial eight-byte word before selecting AVX2 at runtime,
SSE2, or the portable word scan. Vector loads cover complete input blocks only.
Base64 JSON retains 384-byte scratch for small values, uses a separate 8 KiB
stack frame for decoded payloads up to 8,192 bytes, and streams larger values
through the fixed 384-byte buffer. No JSON object tree is built.

Controlled `BENCHMARK_GROUP=content` runs used Rust 1.99.0, Ruby 4.0.6 with
YJIT, and the settings above. All 20 cases matched VM validity and detailed
errors. Native `valid?` allocated zero Ruby objects. Times span all four
method/validity combinations for each workload.

| Content assertion | Native before (µs) | Native after (µs) | VM speedup after |
| --- | ---: | ---: | ---: |
| Strict Base64 | 13.45–16.83 | 13.66–17.94 | 5.94–11.57x |
| JSON syntax | 47.53–52.03 | 48.14–52.37 | 6.21–9.46x |
| Base64 + JSON syntax | 56.20–61.87 | 56.25–60.39 | 7.50–10.61x |
| Base64 + JSON, 256-byte string | 76.14–82.11 | 59.32–65.03 | 7.21–10.05x |
| Base64 + JSON, 4,096-byte string | 889.21–914.81 | 463.86–489.05 | 7.97–9.51x |

The longer JSON workloads improved native time by 1.26–1.92x. Short JSON
times remained close to the baseline; strict Base64, whose implementation
did not change, measured up to 7.7% slower. These local runs do not establish
the overall 10x target. Artifacts: `schemurai-content-simd-before.json` and
`schemurai-content-avx-final.json`. Focused tests passed (106 examples), with
every byte value tested around vector and scratch boundaries. The full suite
retained the two known VM failures (6522 examples, 1287 pending).
An independently built and installed gem passed package smoke tests, including
medium and streaming Base64 JSON with VM execution forbidden for native cases.

The full-run tables below precede the later guards for builtin subclasses,
singleton objects, and arbitrary Hash keys. They describe that diagnostic
milestone rather than the current guarded implementation.

Linux x86_64 results on Ruby 4.0.6 with YJIT after native dependency and
evaluated-location diagnostics, using the defaults above. Detailed validation
now collects diagnostics directly instead of running a separate validity pass.
These tables come from one complete run with both assertion options enabled:

| Workload | valid? valid | valid? invalid | validate valid | validate invalid |
| --- | ---: | ---: | ---: | ---: |
| Integer array | 12.78x | 13.10x | 48.19x | 27.47x |
| Object records | 7.21x | 7.10x | 22.62x | 21.66x |
| Contains and unevaluated | 31.02x | 31.30x | 58.95x | 47.53x |
| Static references | 19.19x | 18.86x | 28.82x | 26.17x |
| Unique numbers | 14.07x | 13.90x | 13.58x | 11.63x |
| Unique objects | 9.00x | 8.92x | 9.02x | 8.69x |
| Pattern strings | 7.24x | 7.23x | 14.88x | 14.34x |
| Overlapping property annotations | 10.07x | 10.22x | 10.02x | 7.71x |
| Dynamic references | 31.13x | 30.96x | 43.26x | 39.56x |
| Fractional bounds | 14.74x | 14.71x | 33.26x | 28.98x |
| Integer multiples | 10.34x | 10.29x | 26.30x | 24.89x |
| Decimal multiples | 19.50x | 19.82x | 24.33x | 23.91x |

Native diagnostics now cover the contains/unevaluated and overlapping annotation
workloads. Invalid detailed validation improved from 0.98x to 47.53x for
contains/unevaluated and from 0.90x to 7.71x for overlapping annotations compared
with the preceding diagnostic milestone. Integer arrays improved from 12.27x
to 27.47x, object records from 10.85x to 21.66x, and dynamic references from
22.28x to 39.56x. Successful integer-array validation decreased from 62.05x to
48.19x; successful pattern validation decreased from 16.95x to 14.88x.
Ordinary object and pattern validity, structural uniqueness, and invalid
overlapping-annotation diagnostics still remain below 10x.

A focused before/after run for the Hash-key guards used Ruby 4.0.6 with YJIT,
width 1,000, 11 samples, and batches of 50. Compilation was excluded and both
assertion options were enabled, as in the full run. Native median times were:

| Object records | Before guards | After guards |
| --- | ---: | ---: |
| valid? valid | 0.046 ms | 0.064 ms |
| valid? invalid | 0.046 ms | 0.065 ms |
| validate valid | 0.046 ms | 0.066 ms |
| validate invalid | 0.049 ms | 0.069 ms |

The guarded run measured 3.42x/3.41x for validity and 9.63x/9.38x for detailed
validation. Native Ruby allocations remained zero for validity, three for
successful detailed validation, and sixteen for invalid detailed validation.
The extra key scan was a measured regression requiring optimization;
these results do not meet the 10x target. The focused result files are
`schemurai-native-object-boundary-before.json` and
`schemurai-native-object-boundary-after.json`.

The subsequent small-record walk reused the same focused settings. C now
gathers only borrowed VALUE handles in a fixed stack buffer, and Rust checks
keys and scalar fields without a C-to-Rust callback per key. Native medians were
0.059 ms for valid/invalid validity and successful detailed validation, and
0.064 ms for invalid detailed validation. That is approximately 7–10% lower
than the guarded run above. Ratios were 3.77x/3.93x for validity and
10.53x/11.71x for detailed validation; the measured VM medians also changed
to 0.223/0.230 ms and 0.622/0.744 ms, respectively, so the ratio increase cannot
all be attributed to native improvements. Ruby allocation counts were unchanged.
Validity still misses the 10x target. The focused result file is
`schemurai-native-object-record-walk.json`.

Arbitrary integer equality and uniqueness have a separate focused workload,
`unique large integers`: 1,000 consecutive integers starting at `2**200`, with
an additional duplicate in the invalid instance. Ruby 4.0.6 with YJIT, 31
samples, and batches of 100 measured:

| Operation | VM | Native | Speedup |
| --- | ---: | ---: | ---: |
| valid? valid | 0.062 ms | 0.035 ms | 1.79x |
| valid? invalid | 0.056 ms | 0.035 ms | 1.62x |
| validate valid | 0.056 ms | 0.036 ms | 1.57x |
| validate invalid | 0.058 ms | 0.037 ms | 1.59x |

Native validity allocated zero Ruby objects; detailed validation allocated
three for valid data and eleven for invalid data. Hashing only significant
sampled words lowered native validity from the initial 0.066 ms implementation
to 0.035 ms. The workload executes without VM delegation, but remains below
the 10x target. Integers beyond the finite Float range use bounded digit
samples; adversarial high-digit collisions still require complete comparisons
and may degrade indexing performance. Results are recorded in
`schemurai-native-large-integer-uniqueness.json`.

Before the crate-backed matcher, counted ASCII patterns used the focused
workload `counted pattern strings`,
using `^SKU-[A-Z0-9]{8}$` against 1,000 strings. Ruby 4.0.6 with YJIT, 31 samples,
and batches of 100 measured:

| Operation | VM | Native | Speedup |
| --- | ---: | ---: | ---: |
| valid? valid | 0.111 ms | 0.024 ms | 4.59x |
| valid? invalid | 0.112 ms | 0.024 ms | 4.65x |
| validate valid | 0.251 ms | 0.027 ms | 9.20x |
| validate invalid | 0.262 ms | 0.028 ms | 9.28x |

Native validity allocated zero Ruby objects; detailed validation allocated
three for valid data and thirteen for invalid data. Counted patterns and their
diagnostics execute without VM delegation, but this workload remains below
10x. Results are recorded in `schemurai-native-counted-patterns.json`.

The matcher now uses `regex-automata::meta::Regex` instead of the native
handwritten engine. `regex-syntax` parses patterns, and a compatibility adapter
preserves VM anchors and shorthand character classes. Groups, alternation,
negative classes, literal Unicode and repetitions within sequences now execute
without VM delegation. With Ruby 4.0.6 and YJIT, 1,000 strings, 31 samples and
batches of 100, the crate-backed implementation measured:

| Workload | Operation | VM | Native | Speedup |
| --- | --- | ---: | ---: | ---: |
| pattern strings | valid? valid | 0.095 ms | 0.025 ms | 3.85x |
| pattern strings | validate valid | 0.229 ms | 0.028 ms | 8.19x |
| pattern strings | valid? invalid | 0.096 ms | 0.030 ms | 3.22x |
| pattern strings | validate invalid | 0.245 ms | 0.029 ms | 8.34x |
| counted pattern strings | valid? valid | 0.113 ms | 0.029 ms | 3.90x |
| counted pattern strings | validate valid | 0.254 ms | 0.033 ms | 7.80x |
| counted pattern strings | valid? invalid | 0.115 ms | 0.029 ms | 3.98x |
| counted pattern strings | validate invalid | 0.280 ms | 0.034 ms | 8.17x |
| grouped pattern strings | valid? valid | 0.121 ms | 0.027 ms | 4.44x |
| grouped pattern strings | validate valid | 0.266 ms | 0.030 ms | 8.86x |
| grouped pattern strings | valid? invalid | 0.120 ms | 0.026 ms | 4.64x |
| grouped pattern strings | validate invalid | 0.277 ms | 0.031 ms | 9.02x |

The grouped workload uses `^(?:ord|sku)-[0-9]{2,8}:[A-Z]+$`. Native validity
allocates zero Ruby objects; detailed validation allocates three for valid
instances and thirteen for invalid instances. No instance bytes are copied.
Replacing the counted-pattern engine increased native validity from the
preceding 0.024 ms to 0.029 ms and valid detailed validation from 0.027 ms to
0.033 ms. An explicit cache with `search_half_with` did not improve the focused
measurements, so the implementation uses `is_match` and its internal cache pool.
These workloads remain below 10x. Results are recorded in
`schemurai-native-regex-automata-final-patterns.json`,
`schemurai-native-regex-automata-final-counted.json`, and
`schemurai-native-regex-automata-final-grouped.json`.

Start-anchored patterns now use one immutable forward DFA from
`regex-automata`. The crate's HIR prefix properties select this strategy;
DFA tables are limited to 64 KiB and auxiliary determinization memory to
256 KiB. The three short benchmark patterns use 832, 1,152 and 2,752 bytes of
DFA heap, respectively. `^a{4096}$` and `^(a|b)*a[ab]{20}$` exceed the table
limit and retain native execution through `meta::Regex`.

Unanchored expressions retain the meta engine's literal optimizations. A Rust
matcher-only experiment on 4,096 repeated `r` bytes followed by `ecord123`
measured `record[0-9]+` at 92 ns with meta and 4,962 ns with a bare forward DFA;
using that DFA for all expressions would therefore regress long searches.
The C adapter also reads CRuby's cached ASCII coderange flag to avoid redundant
UTF-8 scans; unknown ranges and mutated strings remain checked. Approximate
matcher heap usage is included in `ObjectSpace.memsize_of` for native programs.

With Ruby 4.0.6 and YJIT, 1,000 strings, 31 samples and batches of 100, the
DFA plus ASCII-cache implementation measured:

| Workload | Operation | VM | Native | Speedup |
| --- | --- | ---: | ---: | ---: |
| pattern strings | valid? valid | 0.097 ms | 0.018 ms | 5.30x |
| pattern strings | validate valid | 0.229 ms | 0.022 ms | 10.49x |
| pattern strings | valid? invalid | 0.097 ms | 0.023 ms | 4.13x |
| pattern strings | validate invalid | 0.238 ms | 0.026 ms | 9.17x |
| counted pattern strings | valid? valid | 0.117 ms | 0.021 ms | 5.52x |
| counted pattern strings | validate valid | 0.250 ms | 0.026 ms | 9.55x |
| counted pattern strings | valid? invalid | 0.117 ms | 0.022 ms | 5.26x |
| counted pattern strings | validate invalid | 0.261 ms | 0.027 ms | 9.56x |
| grouped pattern strings | valid? valid | 0.114 ms | 0.019 ms | 5.92x |
| grouped pattern strings | validate valid | 0.250 ms | 0.023 ms | 10.82x |
| grouped pattern strings | valid? invalid | 0.117 ms | 0.020 ms | 5.98x |
| grouped pattern strings | validate invalid | 0.262 ms | 0.025 ms | 10.46x |
| long unanchored pattern strings | valid? valid | 4.189 ms | 0.104 ms | 40.26x |
| long unanchored pattern strings | validate valid | 4.390 ms | 0.109 ms | 40.42x |
| long unanchored pattern strings | valid? invalid | 4.260 ms | 0.106 ms | 40.16x |
| long unanchored pattern strings | validate invalid | 4.369 ms | 0.112 ms | 38.96x |

The long unanchored workload uses `record[0-9]+` on 4,096 `r` bytes followed
by `ecord123`; the invalid last item omits the digits. Native validity allocates
zero Ruby objects for all four workloads. Detailed validation allocates three
for valid instances and thirteen for invalid instances. No instance bytes are
copied. Compared with the preceding meta-only milestone, valid native validity
improved from 0.025 to 0.018 ms for ordinary patterns, 0.029 to 0.021 ms for
counted patterns, and 0.027 to 0.019 ms for grouped patterns. Native valid
counted-pattern diagnostics improved from 0.033 to 0.026 ms, recovering the
preceding handwritten engine's 0.027 ms result. Some detailed workloads exceed
10x, but short validity and counted diagnostics remain below the target.
Results are recorded in `schemurai-native-regex-dfa-final-patterns.json`,
`schemurai-native-regex-dfa-final-counted.json`,
`schemurai-native-regex-dfa-final-grouped.json`, and
`schemurai-native-regex-dfa-final-unanchored.json`.

Single pattern-bearing string rules now combine the exact String class guard
and byte loan in one C call. Array scans and small-record fields reuse this
path; the matcher consumes the borrowed slice without another metadata query.
Non-string and unsupported-class values retain their previous classification,
and length checks still precede pattern checks. Forward DFAs now compile only
anchored start states and searches explicitly request anchored mode.

Ruby 4.0.6 with YJIT, 1,000 entries, 31 samples and batches of 100 measured:

| Workload | Operation | VM | Native | Speedup |
| --- | --- | ---: | ---: | ---: |
| pattern strings | valid? valid | 0.103 ms | 0.018 ms | 5.82x |
| pattern strings | validate valid | 0.222 ms | 0.023 ms | 9.52x |
| pattern strings | valid? invalid | 0.104 ms | 0.018 ms | 5.90x |
| pattern strings | validate invalid | 0.236 ms | 0.024 ms | 9.83x |
| counted pattern strings | valid? valid | 0.120 ms | 0.021 ms | 5.74x |
| counted pattern strings | validate valid | 0.248 ms | 0.027 ms | 9.13x |
| counted pattern strings | valid? invalid | 0.118 ms | 0.021 ms | 5.65x |
| counted pattern strings | validate invalid | 0.269 ms | 0.029 ms | 9.37x |
| grouped pattern strings | valid? valid | 0.125 ms | 0.019 ms | 6.60x |
| grouped pattern strings | validate valid | 0.263 ms | 0.024 ms | 10.78x |
| grouped pattern strings | valid? invalid | 0.127 ms | 0.019 ms | 6.62x |
| grouped pattern strings | validate invalid | 0.287 ms | 0.026 ms | 11.12x |
| pattern object records | valid? valid | 0.237 ms | 0.063 ms | 3.78x |
| pattern object records | validate valid | 0.606 ms | 0.063 ms | 9.62x |
| pattern object records | valid? invalid | 0.241 ms | 0.063 ms | 3.82x |
| pattern object records | validate invalid | 0.641 ms | 0.072 ms | 8.88x |

The added `pattern object records` workload validates one required `name`
property matching `^record[0-9]+$`, with additional properties forbidden.
Native validity allocates zero Ruby objects. Detailed validation allocates
three for valid instances and thirteen for invalid instances, including
pattern records. No instance strings or containers are copied.
Short-pattern timings remain close to the preceding milestone; the call
consolidation has not established a large speed improvement. Grouped detailed
validation exceeds 10x, while ordinary/count patterns and record workloads
remain below that target. Results are recorded in
`schemurai-native-guarded-string-view-patterns.json`,
`schemurai-native-guarded-string-view-counted.json`,
`schemurai-native-guarded-string-view-grouped.json`, and
`schemurai-native-guarded-string-view-records.json`.

An ordinary `object records` regression check used 1,000 entries, 11 samples
and batches of 50, matching the preceding record-walk measurement. Native
validity measured 0.060 ms for valid and invalid data; detailed validation
measured 0.061 and 0.066 ms. The preceding native timings were 0.059, 0.059,
0.059 and 0.064 ms, respectively. This small change does not establish a
material performance improvement or regression. The current result is recorded
in `schemurai-native-guarded-string-view-plain-records.json`.

Large uniqueness arrays now use a checked Bignum hint when their first entry
is a Bignum. Each entry still checks its actual type. The adapter combines that
check with up to 256 bits of scalar magnitude input; larger integers use the
existing 1,024-bit path, while mixed entries retain normal classification.
Fingerprints preserve exact Integer/Float normalization, and collisions still
compare the original values completely. No Ruby objects or instance trees are
created for these scalar inputs.

For 1,000 integers starting at `2**200`, Ruby 4.0.6 with YJIT, 31 samples and
batches of 100 measured:

| Operation | VM | Native | Speedup |
| --- | ---: | ---: | ---: |
| valid? valid | 0.055 ms | 0.033 ms | 1.69x |
| validate valid | 0.056 ms | 0.033 ms | 1.69x |
| valid? invalid | 0.056 ms | 0.033 ms | 1.71x |
| validate invalid | 0.058 ms | 0.034 ms | 1.68x |

Native validity allocates zero Ruby objects; detailed validation allocates
three for valid instances and eleven for invalid instances. Current native
validity is about 0.033 ms versus the preceding 0.035 ms measurement, a small
change rather than a large performance improvement. This workload remains far
below 10x. A mixed structural `unique objects` check measured native validity
at 0.087 ms and detailed validation at 0.088/0.090 ms for valid/invalid data;
these cases do not take the Bignum hint. Results are recorded in
`schemurai-native-bigint-hint-uniqueness.json` and
`schemurai-native-bigint-hint-objects.json`.

Structural uniqueness now borrows string pointers and lengths in one C call,
reads nested arrays through borrowed VALUE slices, and validates hash keys
during fingerprinting without a preliminary second key walk. Original Ruby
values still resolve collisions; mutation is rechecked on every validation.

For 1,000 `unique objects`, Ruby 4.0.6 with YJIT, 31 samples and batches of
100 measured:

| Operation | VM | Native | Speedup |
| --- | ---: | ---: | ---: |
| valid? valid | 0.233 ms | 0.061 ms | 3.80x |
| validate valid | 0.230 ms | 0.062 ms | 3.73x |
| valid? invalid | 0.234 ms | 0.063 ms | 3.74x |
| validate invalid | 0.239 ms | 0.065 ms | 3.70x |

Immediately preceding native timings were 0.086, 0.086, 0.087, and 0.090 ms,
respectively. Native validity allocates zero Ruby objects; detailed validation
allocates three for valid and eleven for invalid instances. This reduces
structural fingerprint time but remains below the 10x target. A numeric
uniqueness check measured native validity at 0.006 ms and detailed validation
at 0.006/0.007 ms for valid/invalid instances. Results are recorded in
schemurai-unique-view-before.json, schemurai-unique-view-after.json, and
schemurai-unique-view-numbers.json.

Homogeneous record arrays now choose their single object instruction before
the item loop and reuse an immutable resource-scope frame across siblings.
Annotation-tracked child nodes retain general evaluation. Native-only comparison
tests cover typed/untyped records, mixed instances, prefix items, and dynamic
references through nested resources.

With Ruby 4.0.6 and YJIT, 1,000 records, 31 samples and batches of 100:

| Operation | VM | Native | Speedup |
| --- | ---: | ---: | ---: |
| valid? valid | 0.225 ms | 0.056 ms | 4.03x |
| validate valid | 0.608 ms | 0.062 ms | 9.81x |
| valid? invalid | 0.224 ms | 0.056 ms | 3.99x |
| validate invalid | 0.653 ms | 0.066 ms | 9.85x |

Immediately preceding native timings were 0.059, 0.061, 0.059, and 0.063 ms,
respectively. The change modestly reduces validity time; it does not establish
a detailed-validation improvement, and these measurements remain below 10x.
Native validity allocates zero Ruby objects; detailed validation allocates
three for valid and sixteen for invalid instances. Results are recorded in
schemurai-record-loop-before.json and schemurai-record-loop-after.json.
An integer-array check measured native validity at 0.002 ms and detailed
validation at 0.002/0.004 ms for valid/invalid instances, recorded in
schemurai-record-loop-integers.json.
A pattern-string check measured native validity at 0.018/0.017 ms and detailed
validation at 0.023/0.024 ms for valid/invalid instances, consistent with the
preceding short-pattern native timings. Its results are recorded in
schemurai-record-loop-patterns.json.

Length-only string rules in array scans and record fields now obtain ordinary
instance classification and the character count in one C call. CRuby counts
characters for all encodings; the adapter borrows metadata without copying
strings. Native-only tests include UTF-8, UTF-16LE, binary strings, typed and
untyped rules, and mixed non-string instances.

For 1,000 object records, Ruby 4.0.6 with YJIT, 31 samples and batches of 100:

| Operation | VM | Native | Speedup |
| --- | ---: | ---: | ---: |
| valid? valid | 0.222 ms | 0.055 ms | 4.04x |
| validate valid | 0.641 ms | 0.061 ms | 10.53x |
| valid? invalid | 0.239 ms | 0.056 ms | 4.30x |
| validate invalid | 0.672 ms | 0.066 ms | 10.24x |

Immediately preceding native timings were 0.056, 0.063, 0.056, and 0.066 ms,
respectively. The difference is small; validity remains below 10x. Native Ruby
allocations remain zero for validity, three for valid detailed validation and
sixteen for invalid detailed validation. Results are recorded in
schemurai-record-guard-before.json and schemurai-string-length-guard-records.json.
A pattern-string check measured native validity at 0.018/0.019 ms and detailed
validation at 0.023/0.025 ms for valid/invalid instances, recorded in
schemurai-string-length-guard-patterns.json.

Integer bounds now stay native for instance magnitudes beyond i128 when each
schema limit has an exact bounded fraction and no multipleOf rule is present.
Their sign determines their ordering against every such limit. The scalar
read's overflow/sign status is reused without repacking or creating Ruby
objects. Arbitrary-magnitude multiples and larger schema limits still delegate.
Native-only tests compare validity and ordered diagnostics at 127, 128, 129,
200, 1,024, and 4,096-bit boundaries against VM.

The new large-integer bounds workload validates 1,000 integers starting at
2**200 against an integer minimum of 2**100; invalid input ends with zero.
Ruby 4.0.6 with YJIT, 31 samples and batches of 100 measured:

| Operation | VM | Native | Speedup |
| --- | ---: | ---: | ---: |
| valid? valid | 0.085 ms | 0.026 ms | 3.27x |
| validate valid | 0.258 ms | 0.023 ms | 11.24x |
| valid? invalid | 0.084 ms | 0.026 ms | 3.25x |
| validate invalid | 0.265 ms | 0.025 ms | 10.60x |

Detailed validation exceeds 10x in this measurement; validity remains below
the target. Results are recorded in schemurai-large-integer-bounds-final.json.
A fractional-bounds check measured native validity at 0.018 ms and detailed
validation at 0.014/0.016 ms for valid/invalid instances, recorded in
schemurai-large-integer-bounds-fractional.json.

Runtime numeric instructions now reuse the caller's ordinary Integer/Float
classification. After ruling out Float, Integer magnitude access omits repeated
kind and Float checks; schema metadata still receives the full checks. A native
guard test rejects coercible Numeric subclasses, Rational, Complex and other
out-of-domain objects before scalar access.

For 1,000 large-integer bounds entries, Ruby 4.0.6 with YJIT, 31 samples and
batches of 100:

| Operation | VM | Native | Speedup |
| --- | ---: | ---: | ---: |
| valid? valid | 0.085 ms | 0.023 ms | 3.77x |
| validate valid | 0.266 ms | 0.019 ms | 14.13x |
| valid? invalid | 0.085 ms | 0.022 ms | 3.78x |
| validate invalid | 0.271 ms | 0.021 ms | 12.78x |

Immediately preceding native timings were 0.026, 0.023, 0.026, and 0.026 ms,
respectively. Native Ruby allocations remain zero for validity, three for valid
detailed validation and seventeen for invalid detailed validation. Validity
still falls below the 10x target. Results are recorded in
schemurai-known-integer-before.json and schemurai-known-integer-after.json.
A fractional-bounds check measured native validity at 0.018 ms and detailed
validation at 0.014/0.016 ms for valid/invalid instances, consistent with the
preceding numeric measurement; results are recorded in
schemurai-known-integer-fractional.json.

Homogeneous arrays now select a single numeric instruction before their item
loop, covering fractional rules and Bignum instances beyond the Fixnum bounds
shortcut. Every instance retains ordinary-kind and required-type checks.
Depth limits and annotation-tracked child evaluation retain the generic path.
Native-only comparisons cover typed/untyped rules, unions, mixed instances,
prefix items and unevaluated-item annotations.

Ruby 4.0.6 with YJIT, 1,000 items, 31 samples and batches of 100 measured:

| Workload | Operation | VM | Native | Speedup |
| --- | --- | ---: | ---: | ---: |
| large integer bounds | valid? valid | 0.084 ms | 0.016 ms | 5.13x |
| large integer bounds | validate valid | 0.254 ms | 0.019 ms | 13.30x |
| large integer bounds | valid? invalid | 0.084 ms | 0.017 ms | 5.00x |
| large integer bounds | validate invalid | 0.262 ms | 0.021 ms | 12.44x |
| fractional bounds | valid? valid | 0.168 ms | 0.012 ms | 14.33x |
| fractional bounds | validate valid | 0.291 ms | 0.015 ms | 19.92x |
| fractional bounds | valid? invalid | 0.176 ms | 0.012 ms | 15.03x |
| fractional bounds | validate invalid | 0.315 ms | 0.017 ms | 19.06x |

Immediately preceding large-integer native timings were 0.022, 0.019, 0.022,
and 0.021 ms, respectively. Fractional validity was 0.018 ms. This change
reduces validity time; large-integer validity still remains below 10x.
Detailed evaluation uses its existing traversal. Native Ruby allocations remain
zero for validity and three for valid detailed validation; invalid large-integer
diagnostics allocate seventeen objects. Results are recorded in
schemurai-number-array-before.json, schemurai-number-array-after.json and
schemurai-number-array-fractional.json.
An integer-array check measured native validity at 0.002 ms and detailed
validation at 0.002/0.004 ms for valid/invalid instances, recorded in
schemurai-number-array-integers.json. Its validity speedup remains above 13x.

Fixnum multipleOf checks now compile exact i64 bounds and the reduced divisor's
i64 numerator into a native arithmetic rule. Direct remainder by that numerator
also handles fractional divisors because the input denominator is one. A
nonpositive numerator fails without evaluating remainder. Float, larger Integer,
larger numerator and fractional-bound operands keep the fraction path. Validity
and ordered diagnostics share the compiled comparisons and failure bits.
Native-only tests cover zero/negative divisors, fractional divisors, signed
boundaries, mixed types, conflicting bounds, arrays and record fields.

For 1,000 integer multiples, Ruby 4.0.6 with YJIT, 31 samples and batches of 100:

| Operation | VM | Native | Speedup |
| --- | ---: | ---: | ---: |
| valid? valid | 0.080 ms | 0.003 ms | 29.20x |
| validate valid | 0.231 ms | 0.007 ms | 34.87x |
| valid? invalid | 0.082 ms | 0.003 ms | 27.83x |
| validate invalid | 0.239 ms | 0.008 ms | 30.12x |

Immediately preceding native timings were 0.012, 0.015, 0.012, and 0.016 ms,
respectively. Native validity allocates zero Ruby objects; detailed validation
allocates three for valid and fifteen for invalid instances. This workload
exceeds 10x in all four modes. Results are recorded in
schemurai-integer-multiple-before.json and schemurai-integer-multiple-final.json.
The Float decimal-multiples workload, which retains the existing fraction
implementation, measured native validity at 0.085/0.084 ms and detailed
validation at 0.087/0.090 ms for valid/invalid instances, with speedups of
16.07-17.94x. Its results are recorded in schemurai-integer-multiple-decimals.json.

Integer multipleOf instances beyond i128 now use the existing fixed 1,024-bit
scalar adapter and native magnitude remainder. Their reduced divisor numerator
must fit i128, and schema bounds retain exact bounded fractions. Native tests
cover positive/negative powers, products and adjacent values, 64-bit divisor
boundaries, fractional divisors, the 1,024-bit magnitude edge, and ordered
diagnostics. Larger inputs still delegate; numerator one and nonpositive
numerators require no additional full magnitude read. If 2^64 is one modulo
the numerator, a compiled strategy sums at most sixteen magnitude words and
performs one remainder instead of dividing each word.

The new workload validates 1,000 integers of the form (2**200 + i) * 3 with
multipleOf 3 and minimum 2**100. Invalid input ends with 2**200 * 3 + 1.
Ruby 4.0.6 with YJIT, 31 samples and batches of 100 measured:

| Operation | VM | Native | Speedup |
| --- | ---: | ---: | ---: |
| valid? valid | 0.285 ms | 0.034 ms | 8.42x |
| validate valid | 0.513 ms | 0.036 ms | 14.43x |
| valid? invalid | 0.274 ms | 0.033 ms | 8.23x |
| validate invalid | 0.529 ms | 0.037 ms | 14.24x |

Before this coverage change, native delegated the workload and measured
0.266, 0.524, 0.265, and 0.524 ms, respectively, approximately the VM speed.
Native validity now allocates zero Ruby objects; detailed validation allocates
three for valid and fifteen for invalid instances. VM validity allocates about
3,000 Ruby objects per call. Detailed validation exceeds 10x here, while
validity remains below the target. Results are recorded in
schemurai-wide-multiple-before.json and schemurai-wide-multiple-final.json.
The existing Fixnum integer-multiples workload measured native validity at
0.003 ms and detailed validation at 0.007/0.008 ms for valid/invalid inputs,
with speedups of 27.51-32.30x. Its results are recorded in
schemurai-wide-multiple-fixnums.json.

Big Integer multipleOf rules now obtain their fixed 1,024-bit arithmetic words
once and reuse that buffer for i128 eligibility, bounds, and remainder. Values
that fit i128 retain direct arithmetic instead of the wider bit loop. Numeric
rules also retain CRuby's existing Fixnum tag flag, avoiding repeated C queries
for that tag. Boundary comparisons include the signed i128 edge and known
bound failures where oversized multiple diagnostics must delegate.

For 1,000 large-integer multiples, Ruby 4.0.6 with YJIT, 31 samples and batches
of 100 measured:

| Operation | VM | Native | Speedup |
| --- | ---: | ---: | ---: |
| valid? valid | 0.278 ms | 0.023 ms | 12.12x |
| validate valid | 0.502 ms | 0.025 ms | 20.16x |
| valid? invalid | 0.278 ms | 0.023 ms | 12.24x |
| validate invalid | 0.516 ms | 0.026 ms | 19.74x |

Immediately preceding native timings were 0.034, 0.036, 0.034, and 0.037 ms,
respectively. This workload now exceeds 10x in all four measured modes. Native
Ruby allocations remain zero for validity, three for valid detailed validation
and fifteen for invalid detailed validation. Results are recorded in
schemurai-single-wide-read-before.json and schemurai-single-wide-read-after.json.
The existing Fixnum integer-multiples check measured native validity at
0.003 ms and detailed validation at 0.006/0.008 ms for valid/invalid instances,
with speedups of 28.76-34.09x. Float decimal multiples measured native validity
at 0.085 ms and detailed validation at 0.088/0.090 ms, with speedups of
16.22-17.98x. Results are recorded in schemurai-single-wide-read-fixnums.json
and schemurai-single-wide-read-decimals.json.

Runtime Integer bounds now read public CRuby magnitude-size and sign metadata
when the magnitude requires more than sixteen bytes. Such inputs are outside
every exact bounded fraction limit, so exporting truncated arithmetic words is
unnecessary. Smaller magnitudes retain exact 128-bit word reads, including the
signed i128 boundary; schema metadata keeps the existing compilation checks.

For 1,000 large-integer bounds entries, Ruby 4.0.6 with YJIT, 31 samples and
batches of 100 measured:

| Operation | VM | Native | Speedup |
| --- | ---: | ---: | ---: |
| valid? valid | 0.083 ms | 0.012 ms | 7.17x |
| validate valid | 0.250 ms | 0.014 ms | 17.35x |
| valid? invalid | 0.083 ms | 0.012 ms | 6.96x |
| validate invalid | 0.258 ms | 0.017 ms | 15.36x |

Immediately preceding native timings were 0.017, 0.019, 0.017, and 0.022 ms,
respectively. Native validity allocates zero Ruby objects; detailed validation
allocates three for valid and seventeen for invalid instances. Validity remains
below 10x. Results are recorded in schemurai-integer-sign-before.json and
schemurai-integer-sign-after.json.
The Fixnum integer-array check measured native validity at 0.002 ms and detailed
validation at 0.002/0.004 ms for valid/invalid inputs, with validity speedups
above 13x; results are recorded in schemurai-integer-sign-fixnums.json.
The large-integer multiples check retained native validity at 0.023 ms and
detailed validation at 0.025/0.026 ms for valid/invalid inputs, with speedups
of 11.55-20.12x; results are recorded in schemurai-integer-sign-multiples.json.

Arrays with one numeric instruction, integer schema bounds and no multipleOf
now obtain ordinary-kind classification and Integer metadata in one C call.
Fixnum metadata uses direct magnitude/sign extraction; Bignum metadata retains
the public size/sign shortcut and exact reads near i128. The applicability flag
is compiled once. Float inputs retain their comparison semantics, and fractional
schema bounds keep their preceding scan to avoid its measured slowdown.
Native comparisons include Fixnum limits, mixed types, NaN and both infinities.

For 1,000 large-integer bounds entries, Ruby 4.0.6 with YJIT, 31 samples and
batches of 100 measured:

| Operation | VM | Native | Speedup |
| --- | ---: | ---: | ---: |
| valid? valid | 0.085 ms | 0.011 ms | 7.50x |
| validate valid | 0.265 ms | 0.015 ms | 17.64x |
| valid? invalid | 0.083 ms | 0.011 ms | 7.32x |
| validate invalid | 0.275 ms | 0.017 ms | 16.11x |

The immediately preceding run varied substantially: VM validity measured
0.140/0.117 ms and native validity 0.023/0.017 ms for valid/invalid data.
That shared variation does not establish a large improvement from this change.
The preceding stable milestone measured native validity at 0.012 ms; the current
0.011 ms represents only a small change and remains below 10x. Native Ruby
allocations remain zero for validity, three for valid detailed validation and
seventeen for invalid detailed validation. Results are recorded in
schemurai-number-bounds-view-before.json and schemurai-number-bounds-view-final.json.
A fractional-bounds check measured native validity at 0.012 ms and detailed
validation at 0.015/0.016 ms for valid/invalid inputs, with speedups of
13.82-20.68x, recorded in schemurai-number-bounds-view-floats-final.json.

Schema Integer bounds beyond i128 now use GC-rooted VALUE handles and CRuby's
public Big/Big comparison, without copying the bound or instance digits. Fixnum
inputs use the wide bound's sign. Float inputs against wide schema bounds and
unsupported multipleOf arithmetic retain VM fallback. Native tests compare
128-4,096-bit schema bounds for scalars, arrays, and object fields against VM
validity and ordered diagnostics after GC compaction, with VM execution forbidden.

For 1,000 entries with minimum 2**200 and values 2**256+i, Ruby 4.0.6 with YJIT,
31 samples and batches of 100 measured:

| Operation | VM | Native | Speedup |
| --- | ---: | ---: | ---: |
| valid? valid | 0.084 ms | 0.016 ms | 5.24x |
| validate valid | 0.250 ms | 0.019 ms | 12.96x |
| valid? invalid | 0.084 ms | 0.016 ms | 5.12x |
| validate invalid | 0.264 ms | 0.022 ms | 12.03x |

Validity allocates zero Ruby objects; detailed validation allocates three for
valid inputs and seventeen for invalid inputs. This expands native coverage,
but validity remains below the 10x target. Results are recorded in
schemurai-wide-schema-integer-bounds.json. Existing large integer bounds measured
0.012 ms native validity (7.04-7.35x), and large integer multiples measured
0.024 ms (11.26-11.29x), recorded in schemurai-wide-schema-bounds-regression.json
and schemurai-wide-schema-multiples-regression.json.
Fractional bounds measured 0.013 ms native validity (13.37-13.63x), recorded in
schemurai-wide-schema-float-regression.json. The focused native/differential suite
passed 85 examples. The full native suite ran 6,522 examples with the same two
existing VM failures (invalid type compilation and custom Numeric coercion),
independently reproduced with the VM backend, and 1,287 pending examples.

Pattern-only array item rules now select the regex-automata matcher once per
scan. Detailed validation shares that scan and collects diagnostics only for
invalid items, preserving prefix offsets and evaluated-item annotations. Type,
encoding, and cached ASCII metadata are still checked for every element.
Extra string rules retain the general path. No matching engine was added.

For 1,000 pattern strings, Ruby 4.0.6 with YJIT, 31 samples and batches of 100:

| Operation | VM | Native | Speedup |
| --- | ---: | ---: | ---: |
| valid? valid | 0.091 ms | 0.013 ms | 6.88x |
| validate valid | 0.231 ms | 0.014 ms | 16.89x |
| valid? invalid | 0.092 ms | 0.013 ms | 6.97x |
| validate invalid | 0.230 ms | 0.015 ms | 15.53x |

The immediately preceding baseline measured native validity at 0.018 ms and
detailed validation at 0.023/0.024 ms for valid/invalid instances, with VM
timings comparable to the new run. Native validity allocates zero Ruby objects;
detailed validation allocates three for valid instances and thirteen for
invalid instances. Validity remains below 10x. Grouped pattern strings measured
8.07-8.15x validity and 16.78-17.46x detailed validation. Results are recorded
in schemurai-pattern-batch-before.json, schemurai-pattern-batch-final.json, and
schemurai-pattern-batch-grouped.json. Focused native/differential tests passed
87 examples, including prefix offsets, multiple errors, mixed types, tracking,
meta-engine fallback, and mutated cached ASCII strings.
Long unanchored 4 KiB inputs retained meta-engine literal search optimizations:
native validity measured 0.098/0.100 ms and detailed validation 0.101/0.106 ms
for valid/invalid data, with VM speedups of 42.37-43.65x, recorded in
schemurai-pattern-batch-unanchored.json.
The full native suite ran 6,522 examples with the same two known VM failures
(invalid type compilation and custom Numeric coercion) and 1,287 pending
examples. Clippy, RuboCop, formatting, and whitespace checks passed.

String encoding metadata now uses CRuby's public RB_ENCODING_GET inline alias,
which retains rb_enc_get_index for extended encoding indices. A trial batching
32 borrowed string views slowed pattern validity from about 0.013 to 0.015 ms;
that trial was removed. Input bytes remain borrowed individually, with no
instance or view-buffer conversion. The expanded mixed-array comparison tests
include non-string and invalid entries at indices 0, 31, 32, and 63.

For 1,000 pattern strings, Ruby 4.0.6 with YJIT, 31 samples and batches of 100,
the final encoding-alias run measured native validity at 0.013/0.012 ms for
valid/invalid data (7.33/7.53x VM), and detailed validation at 0.013/0.014 ms
(17.59/16.44x). The fresh preceding baseline measured 0.013 ms validity
(6.83/6.97x); this is a small improvement and remains below 10x. Results are
recorded in schemurai-pattern-views-before.json, schemurai-pattern-views-after.json,
and schemurai-pattern-encoding-inline.json. Native Ruby allocations remain zero
for validity, three for successful detailed validation and thirteen for invalid
detailed validation. Focused native/differential tests passed 87 examples.
The full native suite ran 6,522 examples with the same two known VM failures
and 1,287 pending examples; Clippy, RuboCop, formatting and whitespace checks passed.

Float instances against Integer bounds beyond i128 now run natively without
multipleOf. Compilation records the exact ordering at the bound's rounded Float
using temporary 1,024-bit schema metadata; runtime compares scalar Float values
and uses that ordering only on a rounding tie. The word buffers are discarded.
Larger bounds round to Infinity, which is ordered against the finite Integer
without a digit read. NaN, signed Infinity, Float::MAX, and halfway rounding
boundaries are compared against VM validity and full diagnostics for scalars,
arrays and object fields, including Integer/number/union type masks. The focused
native/differential suite passed 88 examples with VM execution forbidden in
the new comparison matrix.

The array numeric metadata adapter now returns the Float scalar with its type
classification in one C call. Integer membership is calculated only when the
required type mask excludes general numbers. This avoids repeated C type/scalar
queries while keeping unusual-value fallback. The exact decimal arithmetic
required for Float multipleOf with wide Integer bounds still delegates to VM.

For 1,000 Float entries greater than minimum 2**200+1, with the final invalid
entry equal to the rounded 2**200, Ruby 4.0.6 with YJIT, 31 samples and batches
of 100 measured:

| Operation | VM | Native | Speedup |
| --- | ---: | ---: | ---: |
| valid? valid | 0.070 ms | 0.010 ms | 7.10x |
| validate valid | 0.162 ms | 0.013 ms | 12.13x |
| valid? invalid | 0.069 ms | 0.010 ms | 7.16x |
| validate invalid | 0.177 ms | 0.016 ms | 11.22x |

Before the fused scalar adapter, the new native comparison measured 0.013 ms
validity (5.52-5.58x); fusion reduces that to about 0.010 ms, still below 10x.
VM validity allocates about 1,000 Ruby objects for this workload; native validity
allocates zero. Native detailed validation allocates three for valid inputs and
seventeen for invalid inputs. Results are recorded in
schemurai-wide-schema-float-native.json and schemurai-wide-schema-float-fused.json.
The fractional-bounds regression measured native validity at 0.013 ms and
detailed validation at 0.015/0.017 ms for valid/invalid inputs, recorded in
schemurai-wide-float-fractional-regression.json.
Wide Integer instances retained native validity at 0.017 ms and detailed
validation at 0.020/0.024 ms for valid/invalid inputs, recorded in
schemurai-wide-float-integer-regression.json. The full native suite ran 6,522
examples with the same two existing VM failures and 1,287 pending examples.
Clippy, RuboCop, formatting and whitespace checks passed.

Numeric diagnostic prechecks now reuse the guarded evaluator used by validity
scans. Homogeneous numeric-array diagnostics select their compiled item rule
before scanning rather than dispatching the node for each element. Fixnum bounds
and multiples retain their primitive paths; wide Integer/Float bounds use the
fused metadata adapter. Only invalid elements enter full diagnostic collection,
with unchanged prefix offsets, item coverage and error order.

For 1,000 Float entries with wide Integer bounds, Ruby 4.0.6 with YJIT, 31 samples
and batches of 100 measured:

| Operation | VM | Native | Speedup |
| --- | ---: | ---: | ---: |
| valid? valid | 0.070 ms | 0.010 ms | 7.00x |
| validate valid | 0.164 ms | 0.010 ms | 16.54x |
| valid? invalid | 0.070 ms | 0.010 ms | 7.06x |
| validate invalid | 0.182 ms | 0.013 ms | 14.33x |

The fresh preceding baseline measured native detailed validation at 0.013 ms
for valid inputs and 0.016 ms for invalid inputs; validity remains approximately
0.010 ms and below 10x. Results are recorded in
schemurai-number-diagnostics-before.json and schemurai-number-diagnostics-final2.json.
Object-record checks retained 0.055/0.056 ms validity and 0.063/0.065 ms detailed
validation for valid/invalid inputs, recorded in
schemurai-number-diagnostics-records-final.json.
Integer multiples measured 0.003 ms native validity (23.79-23.91x), 0.004 ms
valid detailed validation (56.96x) and 0.005 ms invalid detailed validation
(46.19x), recorded in schemurai-number-diagnostics-multiples-final2.json.
Focused native/differential tests
passed 88 examples. The full native suite ran 6,522 examples with the same two
known VM failures and 1,287 pending examples. Clippy, formatting and whitespace
checks passed.

Nonrepresentable Integer uniqueness buckets now fold all sampled magnitude
words in order and apply the final mixing operation once, rather than mixing
each word separately. Exactly representable Integer/Float normalization and
full VALUE equality on collisions retain their existing behavior. Tests include
equal low words with different higher words, duplicate values constructed
separately, mixed Float values and unsampled high-digit collisions.

For 1,000 large Integers, Ruby 4.0.6 with YJIT, 31 samples and batches of 100:

| Operation | VM | Native | Speedup |
| --- | ---: | ---: | ---: |
| valid? valid | 0.065 ms | 0.025 ms | 2.57x |
| validate valid | 0.058 ms | 0.026 ms | 2.23x |
| valid? invalid | 0.058 ms | 0.026 ms | 2.25x |
| validate invalid | 0.060 ms | 0.027 ms | 2.19x |

The fresh preceding baseline measured native validity at 0.033 ms and detailed
validation at 0.033/0.035 ms for valid/invalid inputs. This reduces native time
by about one fifth but remains far below 10x. Results are recorded in
schemurai-unique-word-hash-before.json and schemurai-unique-word-hash-after.json.
The added workload with constant low words and varying higher words measured
0.025/0.026 ms validity and 0.026/0.028 ms detailed validation for valid/invalid
inputs (2.07-2.49x), recorded in schemurai-unique-word-hash-high.json.
Unique objects retained native validity at 0.062/0.063 ms and detailed validation
at 0.063/0.064 ms, recorded in schemurai-unique-word-hash-objects.json.
Native validity allocates zero Ruby objects, successful detailed validation three,
and invalid detailed uniqueness validation eleven. Focused native/differential
tests passed 88 examples. The full native suite ran 6,522 examples with the same
two known VM failures and 1,287 pending examples. Clippy, RuboCop, formatting and
whitespace checks passed.

Uniqueness collision links are now allocated only when distinct values share
a fingerprint. Ordinary scans allocate only the native bucket table and avoid
per-item link writes; 1,000 items save roughly 8 KiB of temporary link capacity
on 64-bit platforms. Duplicate candidates still compare full original VALUEs
before any link allocation. Tests exercise a 40-item collision chain with
duplicates at its first, middle and last entries.

For 1,000 large Integers, Ruby 4.0.6 with YJIT, 31 samples and batches of 100,
native validity measured 0.025/0.026 ms and detailed validation 0.026/0.028 ms
for valid/invalid inputs (2.16-2.60x VM). The preceding baseline measured
0.026 ms validity and 0.026/0.028 ms detailed validation. These timings are
broadly unchanged; this change reduces temporary native storage and does not
establish a speed improvement. Results are recorded in
schemurai-unique-links-before.json and schemurai-unique-links-after.json.
Unique objects measured 0.062 ms native validity and 0.062/0.063 ms detailed
validation, recorded in schemurai-unique-links-objects.json. Native Ruby
allocation counts remain unchanged. Focused native/differential tests passed
88 examples; the full native suite ran 6,522 examples with the same two known
VM failures and 1,287 pending examples. Clippy, RuboCop, formatting and whitespace
checks passed.

Hash fingerprint traversal now checks each key's exact String class and loans
its byte pointer and length in a single C callback. Rust still computes the
hash and checks all collisions against original Ruby values. This eliminates
two C calls per key without copying strings or constructing an instance tree.
Empty, Unicode, binary and heap-backed keys are tested after GC compaction;
unsupported keys retain VM delegation.

With Ruby 4.0.6 and YJIT, 1,000 unique objects, 31 samples and batches of 100,
native validity measured 0.055-0.056 ms and detailed validation 0.055-0.057 ms
across two runs, compared with 0.063-0.065 ms and 0.063-0.067 ms beforehand.
The confirmation run measured 4.26-4.46x VM, below the requested 10x target.
Results are recorded in schemurai-key-view-before.json,
schemurai-key-view-after.json and schemurai-key-view-confirm.json. Native
validity allocated zero Ruby objects, valid diagnostics three and invalid
diagnostics eleven. Focused native/differential tests passed 92 examples;
the full native suite ran 6,522 examples with the same two known VM failures
and 1,287 pending examples. Clippy, RuboCop, formatting and whitespace checks
passed.

Short string fingerprints now read every byte into bounded scalars, include
the length and mix once for strings up to eight bytes. Longer strings retain
their existing hash. This also applies to compiled property lookup keys;
all collisions still compare the original strings or JSON values. Tests cover
empty strings, embedded zero bytes and the eight/nine-byte boundary.

For 1,000 unique objects, Ruby 4.0.6 with YJIT, 31 samples and batches of 100,
native validity measured 0.052-0.053 ms and detailed validation 0.052-0.054 ms
across two runs. The preceding baseline measured 0.056-0.057 ms validity and
0.057-0.058 ms detailed validation. The confirmation run measured 4.57-4.90x VM,
below the requested 10x target. Results are recorded in
schemurai-value-view-before.json, schemurai-short-fingerprint-after.json and
schemurai-short-fingerprint-confirm.json. Focused native/differential tests
passed 93 examples; the full native suite ran 6,522 examples with the same two
known VM failures and 1,287 pending examples. Clippy, RuboCop, formatting and
whitespace checks passed.

Immediate integer fingerprints now decode the original VALUE in Rust after
the C headers confirm the supported signed encoding and pointer width. An
unsupported encoding disables the hint and retains public C numeric adapters.
Tests cover signed immediate boundaries, negative zero and exact/inexact
Integer/Float pairs, including nested records, with VM execution forbidden.

For 1,000 unique integers, Ruby 4.0.6 with YJIT, 31 samples and batches of 100,
the confirmation run measured 4.77/5.13 microseconds native validity and
4.93/6.55 microseconds detailed validation for valid/invalid inputs. The
preceding validity baseline measured 5.19/5.14 microseconds; the improvement
is small and invalid validity is broadly unchanged. The confirmation ratios
were 7.65-11.47x VM, recorded in schemurai-fixnum-hash-confirm.json, with the
preceding and initial runs in schemurai-fixnum-hash-before.json and
schemurai-fixnum-hash-after.json. Unique objects measured 0.051-0.053 ms
(4.76-4.99x VM), recorded in schemurai-fixnum-hash-objects.json. The overall
10x target remains unmet. Native validity allocated zero Ruby objects.
Focused native/differential tests passed 94 examples; the full native suite
ran 6,522 examples with the same two known VM failures and 1,287 pending
examples. Clippy, RuboCop, formatting and whitespace checks passed.

Numeric bounds and multiples now share the header-validated immediate decoder
already used by fingerprints. Array validity, diagnostic prechecks and compiled
record fields decode guarded VALUEs in Rust without a per-number C call.
Existing differential tests exercise signed boundaries, inclusive/exclusive
bounds, multiple divisors, Float and Bignum inputs, and full error ordering.

With Ruby 4.0.6 and YJIT, 1,000 integer array items, 31 samples and batches of
100, native validity measured 1.18/1.87 microseconds and detailed validation
1.75/3.39 microseconds for valid/invalid inputs (17.40-63.58x VM), recorded in
schemurai-direct-number-array.json. Native validity allocated zero Ruby objects;
valid/invalid diagnostics allocated three/sixteen. Object records remained
broadly unchanged at 0.056-0.057 ms validity and 0.062-0.066 ms diagnostics
(3.95-10.06x VM). Results are recorded in schemurai-direct-number-before.json
and schemurai-direct-number-after.json. The overall 10x target remains unmet.
Focused native/differential tests passed 94 examples; the full native suite ran
6,522 examples with the same two known VM failures and 1,287 pending examples.
Clippy, formatting and whitespace checks passed.

Character-length adapters now avoid the Ruby length call for binary strings
and for UTF-8/US-ASCII strings with an existing ASCII coderange cache. Other
encodings and non-ASCII strings retain CRuby's character-length API. Exact
String guards still reject subclasses. Tests mutate one string's content and
encoding repeatedly through scalar, array and record validators, comparing
validity and full errors against VM with native fallback forbidden.

For 1,000 object records, Ruby 4.0.6 with YJIT, 31 samples and batches of 100,
the confirmation run measured 0.052/0.051 ms native validity and 0.058/0.061 ms
detailed validation for valid/invalid inputs, compared with the preceding
0.056/0.057 ms and 0.062/0.066 ms baseline. Confirmation speedups were
4.25-4.26x for validity and 10.42-10.75x for detailed validation. Results are
recorded in schemurai-string-length-before.json,
schemurai-string-length-after.json and schemurai-string-length-confirm.json.
The overall 10x target remains unmet. Focused native/differential tests passed
95 examples; the full native suite ran 6,522 examples with the same two known
VM failures and 1,287 pending examples. Release compilation, RuboCop and
whitespace checks passed.

Small-record fields now select simple integer bounds or string-length checks
once at compilation. Runtime field checks retain exact instance guards, depth
limits and identity-key Hash delegation, without reclassifying child opcodes.
For 1,000 object records, Ruby 4.0.6 with YJIT, 31 samples and batches of 100,
native validity measured 0.049-0.051 ms across two runs versus the preceding
0.052/0.055 ms valid/invalid baseline. Detailed validation measured
0.061-0.062 ms versus 0.059/0.063 ms; no improvement is established for detailed
validation. The confirmation run measured 4.44-4.48x VM validity and
9.93-10.08x detailed validation. Results are recorded in
schemurai-record-check-before.json, schemurai-record-check-after.json and
schemurai-record-check-confirm.json. The overall 10x target remains unmet.
Focused native/differential tests passed 95 examples; the full native suite
ran 6,522 examples with the same two known VM failures and 1,287 pending
examples. Clippy, formatting and whitespace checks passed.

Small-record traversal no longer zeroes the entire 16-VALUE stack buffer before
C writes the original key/value handles. Rust reads only the initialized
prefix after a successful bounded call; empty, full, overflowing and rejected
records are tested without VM execution for supported inputs.

For 1,000 object records, Ruby 4.0.6 with YJIT, 31 samples and batches of 100,
the confirmation run measured 0.049/0.048 ms native validity and 0.058/0.062 ms
detailed validation for valid/invalid inputs, compared with 0.049/0.049 ms and
0.061/0.062 ms beforehand. Validity is broadly unchanged; the change removes
redundant initialization rather than establishing a substantial speedup.
Results are recorded in schemurai-record-buffer-before.json,
schemurai-record-buffer-after.json and schemurai-record-buffer-confirm.json.
The initial after-run VM validity was slower at 0.348/0.393 ms, while native
stayed at 0.048 ms; its larger speedup ratios should not be attributed to this
change. Confirmation ratios were 4.49-4.52x VM validity and 10.16-11.39x detailed
validation. The overall 10x target remains unmet. Focused native/differential
tests passed 96 examples; the full native suite ran 6,522 examples with the same
two known VM failures and 1,287 pending examples. Clippy, RuboCop, formatting and
whitespace checks passed.

A current complete run uses Ruby 4.0.6 with YJIT, 1,000 items, 31 samples and
batches of 100. All 136 measured cases matched VM results and full errors;
106 measured at least 10x VM. The minimum was 3.34x for invalid large-integer
uniqueness diagnostics. Large-integer uniqueness remained at 0.025-0.028 ms
native across consecutive and high-word inputs (3.34-3.53x VM), making it the
slowest relative workload in this run. All 68 native validity measurements
allocated zero Ruby objects. Results are recorded in
schemurai-native-current-full.json; the overall 10x target remains unmet.

The benchmark now checks the raw native program's validity and diagnostics
before timing, aborting if either would delegate to VM. A separate check
verified native support and correct results for all 68 valid/invalid inputs
(136 operations). RuboCop and whitespace checks passed.

Nonrepresentable integer fingerprints now fold all sampled words through two
independent multiplication lanes before one final mix. Exact Integer/Float
normalization and full collision comparisons are unchanged. Tests retain
unsampled high-digit collisions, long collision chains and width boundaries.

For 1,000 large integers, Ruby 4.0.6 with YJIT, 31 samples and batches of 100,
native validity measured 0.024-0.025 ms and diagnostics 0.025-0.026 ms across two
runs, versus the preceding 0.025-0.026 ms and 0.027 ms. The confirmation run
measured 2.19-2.61x VM; its workload-specific VM timings differ from the preceding
complete run, so ratios are not directly comparable between those runs.
Results are recorded in schemurai-integer-lanes-before.json,
schemurai-integer-lanes-after.json and schemurai-integer-lanes-confirm.json.
High-word integer IDs measured 0.024-0.025 ms validity and 0.025-0.026 ms
diagnostics (2.23-2.63x VM), recorded in schemurai-integer-lanes-high.json.
Native validity allocated zero Ruby objects. Focused native/differential tests
passed 96 examples; the full native suite ran 6,522 examples with the same two
known VM failures and 1,287 pending examples. Clippy, formatting and whitespace
checks passed. The overall 10x target remains unmet.

Integer fingerprints now reuse the active word range found during exact
Float-representability checks instead of scanning the high words twice. The
oversized path still trims its sampled low words separately, including an
empty prefix, preserving existing fingerprints and full collision checks.
For 1,000 large integers with Ruby 4.0.6 and YJIT, 31 samples and batches of 100,
native validity remained approximately 0.025-0.026 ms and diagnostics
0.026-0.027 ms; no speed improvement is established. Results are recorded in
schemurai-integer-trim-before.json and schemurai-integer-trim-after.json.
Focused native/differential tests passed 96 examples; the full native suite
ran 6,522 examples with the same two known VM failures and 1,287 pending
examples. Clippy, formatting and whitespace checks passed. The overall 10x
target remains unmet.

The streamed Base64 decoder now combines the four sextets' alphabet checks
into one decision per group. It still decodes into a scalar register without
copying the Ruby string or constructing a JSON tree. For 1,000 Base64 JSON
strings on Ruby 4.0.6 with YJIT, 31 samples and batches of 100, native validity
measured 0.104-0.108 ms versus 0.108-0.110 ms before the change; diagnostics
measured 0.106-0.111 ms versus 0.112 ms. The observed gain is small. The
confirmation run measured 4.04-4.11x VM validity and 5.80-5.86x diagnostics,
so this workload still falls short of 10x. Artifacts are
schemurai-base64-quartet-before.json, schemurai-base64-quartet-after.json and
schemurai-base64-quartet-confirm.json. An exhaustive byte-mutation check
covers each encoded position for JSON inputs with all three padding lengths,
with VM execution forbidden during native validation. Focused tests passed
97 examples; the full native suite ran 6,522 examples with the same two VM
failures and 1,287 pending examples. Clippy, Rust formatting and Ruby lint
passed. A separate 32-bit-word Integer packing experiment did not establish
a speed improvement and was reverted.

Short Base64 JSON content now decodes into fixed 96-byte stack scratch before
syntax scanning. Full groups batch alphabet checks; the final padded group
retains the strict header and cursor checks. Longer input keeps scalar
streaming, so scratch does not grow with the input. No Ruby instance is
converted or copied across the language boundary, and no Ruby decoded string
or JSON tree is created. A first experiment that filled scratch through the
cursor for every group was slower and was replaced by batched decoding.
On the same 1,000-element workload, native validity measured 0.068-0.070 ms
and diagnostics 0.071-0.075 ms, compared with 0.104-0.108 ms and
0.106-0.111 ms for the preceding cursor implementation. Confirmation measured
6.20-6.34x VM validity and 8.66-8.75x diagnostics. Artifacts are
schemurai-base64-stack-bulk.json and schemurai-base64-stack-confirm.json.
The new long-content workload uses a JSON object containing a 256-character
string and measures the retained streaming path: 0.355-0.358 ms validity
and 0.352-0.353 ms diagnostics, only 1.17-1.18x and 1.80-1.82x VM
(schemurai-base64-stack-long.json). Both paths allocate zero Ruby objects
for validity, three for successful diagnostics and 11 for invalid diagnostics.
The focused suite passed 98 examples, including both validity and detailed
errors around the scratch boundary for every padding length, with VM execution
forbidden. The full suite ran 6,522 examples with the same two VM failures
and 1,287 pending examples. Clippy, formatting and Ruby lint passed.
The overall 10x target remains unmet, especially for long content.

Long Base64 JSON now refills the same 96-byte stack buffer instead of decoding
one scalar group per parser step. Short content shares its batched decoder;
alphabet and padding checks are retained. Both plain and decoded JSON skip
ordinary string bytes in eight-byte groups, stopping at the first quote,
escape or control byte. A first conservative scanner regressed short content
by repeatedly rescanning the prefix before a special byte; locating that first
byte and handling the short remainder removed the regression.
For the 1,000-element content group on Ruby 4.0.6 with YJIT, 31 samples and
batches of 100, long Base64 JSON validity measured 0.180-0.181 ms and
diagnostics 0.181-0.182 ms, versus 0.355-0.358 ms and 0.352-0.353 ms
before buffering. Its current VM ratios are 2.33-2.37x and 3.42-3.45x.
Short Base64 JSON measured 0.069 ms validity and 0.069-0.070 ms diagnostics
(6.18-6.30x and 9.10-9.24x VM). Plain JSON measured 0.048 ms validity and
0.053-0.055 ms diagnostics (5.80-5.86x and 8.55-8.60x VM).
Results are recorded in schemurai-content-buffer-final.json; intermediate
measurements are in schemurai-content-string-run-long.json,
schemurai-content-buffer-long.json and schemurai-content-buffer-group.json.
The focused suite passed 99 examples, including all byte values at multiple
string offsets and escapes/surrogate pairs spanning two refill boundaries,
with VM execution forbidden during native validation. The full suite ran
6,522 examples with the same two VM failures and 1,287 pending examples.
Clippy, formatting and Ruby lint passed. The overall 10x target remains unmet.

Base64 validation and decoding now use `base64-simd` 0.8.0. The crate's strict
STANDARD APIs borrow the input and decode directly into the fixed 96-byte
stack scratch; no allocating decode API is used. Its default runtime CPU
detection selects SIMD when supported and otherwise uses its scalar path.
The handwritten alphabet table, header checks and scalar decoder were removed.
Chunk decoding also verifies the returned output length: a valid padded ending
inside an intermediate chunk must be rejected, rather than leaving stale
scratch bytes available to the parser. The new regression test first reproduced
that false acceptance and then passed with the length guard.
The checked content group run measured 0.059 ms validity and 0.061-0.063 ms
diagnostics for short Base64 JSON (7.14-7.25x and 10.14-10.19x VM).
Long Base64 JSON measured 0.118-0.121 ms validity and 0.121-0.123 ms
diagnostics (3.65-3.71x and 5.09-5.11x VM), compared with 0.180-0.181 ms
and 0.181-0.182 ms before the crate. Strict Base64 measured about 0.014 ms
validity and 0.017 ms diagnostics (5.78-5.95x and 11.90-12.22x VM).
The authoritative artifact is schemurai-content-simd-checked.json, using
1,000 elements, Ruby 4.0.6 with YJIT, 31 samples and batches of 100.
Focused tests passed 100 examples, including every byte value at SIMD/refill
boundaries and intermediate padding. The full suite ran 6,522 examples with
the same two VM failures and 1,287 pending examples. Clippy, formatting and
Ruby lint passed. A newly built schemurai-native-simd.gem installed and compiled
from packaged sources; the isolated package smoke test passed, including long
content and invalid intermediate padding, with native VM fallback forbidden.
The overall 10x target remains unmet.

Base64 JSON scratch is now fixed at 384 bytes, reducing refills for larger
inputs while keeping memory independent of input size. Content that fits uses
`MaybeUninit` and passes only the initialized slice returned by successful
crate decoding to the parser, with exact output-length checks. Failed or partial
output is never read. No new unsafe Rust code or allocating decode API was
introduced. Larger inputs still refill an initialized fixed buffer.
The content group measured 0.058 ms validity and 0.059-0.063 ms diagnostics
for short Base64 JSON (7.26-7.41x and 10.37-10.39x VM). The 256-character
JSON string workload measured 0.077-0.079 ms validity and 0.080 ms diagnostics
(5.39-5.42x and 7.94-7.98x VM), compared with 0.118-0.121 ms and
0.121-0.123 ms with 96-byte scratch.
A new 4-KiB string workload exercises repeated refills. Before this change
it measured 1.336-1.340 ms validity and 1.339-1.342 ms diagnostics; afterward
it measured 0.868-0.884 ms and 0.883-0.885 ms (4.50-4.56x and 4.66-4.88x
VM). Measurements use 1,000 elements, Ruby 4.0.6 with YJIT, 31 samples and
batches of 100. Artifacts are schemurai-content-scratch-large-before.json
and schemurai-content-scratch-after.json. All three Base64 JSON workloads
allocate zero Ruby objects for validity, three for valid diagnostics and 11
for invalid diagnostics. Benchmark output now flushes after each completed
case so longer measurements show progress.
Focused tests passed 100 examples with expanded coverage of the 384-byte
boundary, invalid bytes, intermediate padding and escapes across refills.
The full suite ran 6,522 examples with the same two VM failures and 1,287
pending examples. Clippy, formatting and Ruby lint passed. A new
schemurai-native-scratch.gem installed from packaged sources and passed the
isolated package smoke test with long content and invalid intermediate padding.
The overall 10x target remains unmet.

String rules now reuse the guarded pattern byte view for subsequent format
and content assertions. Private C view helpers remove extra adapter-to-adapter
calls while preserving the public Ruby accessor and exact-class checks.
Standalone and borrowed Rust paths are specialized at compile time; an initial
shared implementation slowed detailed checks, and the specialization removed
that regression. Extending the guarded path to rules without a pattern did not
establish a gain and was reverted.
A controlled C-only comparison for 1,000 patterned strings measured native
validity at about 0.013 ms before and 0.011-0.012 ms afterward. Current ratios
are 7.90-8.22x VM validity and 17.73-19.06x diagnostics; artifacts are
schemurai-pattern-direct-view-before.json and schemurai-pattern-direct-view-after.json.
The new combined string workload applies length, digit pattern, relative JSON
pointer format and JSON content assertions. Separate views measured about
0.026-0.027 ms native validity; shared, specialized views measured 0.021-0.022 ms
with 0.032-0.035 ms diagnostics. Current VM ratios are 19.98-20.18x validity
and 20.71-22.26x diagnostics, recorded in
schemurai-combined-string-separate-view.json and
schemurai-combined-string-specialized-view.json.
Standalone Base64 JSON remained 0.057-0.058 ms validity and 0.060-0.062 ms
diagnostics (7.46-7.60x and 10.33-10.58x VM), recorded in
schemurai-content-final-view-short.json. These measurements use Ruby 4.0.6
with YJIT, 31 samples and batches of 100. Focused tests passed 101 examples,
including combined assertions at root, array and record positions after GC
compaction, with exact VM error parity and VM execution forbidden for native
checks. The full suite ran 6,522 examples with the same two VM failures and
1,287 pending examples. Clippy, formatting and Ruby lint passed.
The overall 10x target remains unmet.

An engine comparison forced anchored patterns through `regex-automata`'s
meta matcher. Its pooled `is_match` API measured about 0.016 ms validity and
0.016-0.018 ms diagnostics for the 1,000-element pattern workload; creating
one explicit cache per array and calling `search_half_with` remained about
0.016 ms validity and 0.017-0.019 ms diagnostics. Neither beat the existing
immutable DFA, so both experimental changes were removed. Artifacts are
schemurai-regex-meta-pool.json and schemurai-regex-meta-cache.json.
Boolean DFA compilation now uses the crate's `LeftmostFirst` match kind.
Its 0.011 ms validity and 0.012-0.014 ms diagnostics are approximately the
same as the previous DFA; no substantial speed improvement is established.
The measured VM ratios were 8.20-8.34x and 17.84-19.55x
(schemurai-regex-leftmost.json). Grouped patterns measured 0.012 ms validity
and 0.013-0.014 ms diagnostics, 9.88-9.96x and 19.22-19.78x VM
(schemurai-regex-leftmost-grouped.json). Measurements use Ruby 4.0.6 with
YJIT, 1,000 elements, 31 samples and batches of 100. The focused suite passed
102 examples, including priority, empty alternatives, lazy repetition and
Unicode parity at root and array positions. The full suite ran 6,522 examples
with the same two VM failures and 1,287 pending examples. Clippy, formatting
and Ruby lint passed. Matching remains entirely crate-backed over borrowed
Ruby bytes. The overall 10x target remains unmet.

All native validity workloads allocate zero Ruby objects. Successful native
detailed validation now allocates three Ruby objects, including the GC-owned
diagnostic report, instead of two at the preceding milestone. The invalid
contains/unevaluated and overlapping workloads each allocate 11 Ruby objects;
dynamic references allocate 16 instead of 1029, and decimal multiples 13
instead of 7023. These are public output allocations, not instance copies.

Format workloads use arrays of 1000 strings; invalid inputs replace the final
string. Native invalid detailed format validation allocates 12 Ruby objects
instead of the VM's 19 or 20. Tests cover all 1168 official format validity
cases across the three dialect suites with VM execution forbidden.

| Format | valid? valid | valid? invalid | validate valid | validate invalid |
| --- | ---: | ---: | ---: | ---: |
| date | 40.75x | 40.65x | 43.29x | 40.42x |
| time | 42.62x | 42.68x | 43.99x | 41.71x |
| date-time | 52.48x | 114.20x | 52.61x | 101.50x |
| duration | 89.91x | 88.37x | 87.67x | 82.42x |
| ipv4 | 112.50x | 112.97x | 80.75x | 76.67x |
| ipv6 | 72.33x | 72.15x | 68.40x | 66.59x |
| uuid | 134.40x | 131.01x | 92.16x | 88.38x |
| json-pointer | 24.19x | 24.35x | 25.49x | 24.62x |
| relative-json-pointer | 33.30x | 33.34x | 30.05x | 28.39x |

The VM timings increased during the later portion of this complete run, while
native timings remained near the preceding milestone. For example, date-time
validity took 0.971 ms for valid input and 2.109 ms for invalid input on the VM,
versus 0.019 ms and 0.018 ms natively. These tables report the observed ratios;
changes in the ratio should not all be attributed to native implementation
improvements. Workload order and YJIT specialization affect comparisons.

Content workloads also use arrays of 1000 original Ruby strings, replacing the
final string for invalid inputs:

| Content assertion | valid? valid | valid? invalid | validate valid | validate invalid |
| --- | ---: | ---: | ---: | ---: |
| Strict Base64 | 20.28x | 20.39x | 26.14x | 25.54x |
| JSON syntax | 10.96x | 11.11x | 14.49x | 14.44x |
| Base64 + JSON syntax | 6.03x | 6.11x | 7.93x | 7.99x |

JSON syntax is scanned without an object tree. Encoded JSON uses fixed stack
scratch, refilled for long input, as described above. Alphabet validation is
batched into the decoder. Invalid
content diagnostics allocate 11 Ruby objects instead of the VM's 1021, 3022,
or 5022.

A separate current run with `BENCHMARK_GROUP=content` uses its own YJIT warmup
and specialization. It demonstrates the difference from the complete run:

| Filtered content assertion | valid? valid | valid? invalid | validate valid | validate invalid |
| --- | ---: | ---: | ---: | ---: |
| Strict Base64 | 5.66x | 5.73x | 11.59x | 10.59x |
| JSON syntax | 6.20x | 6.27x | 9.53x | 9.45x |
| Base64 + JSON syntax | 4.04x | 4.09x | 5.70x | 5.76x |

Native-only tests compare all 385 official unevaluated-location cases and all
official dependency cases against full VM errors. Diagnostics retain locally
attempted items and properties, discard failed applicator annotations, and
merge successful trial annotations. Fully covered containers skip unevaluated
scans. Object diagnostics use compiled native property lookup tables rather
than a schema-property scan for every input key.

Unsupported leaves, unresolved references, and path encodings still delegate
to the VM. Structural uniqueness, ordinary object/pattern validity, overlapping
annotation diagnostics, and content need further performance work. The backend
as a whole does not yet meet the requested target. Measurements are local
results, not portable guarantees.

### Rust inline attribute audit

The audit removed ten redundant attributes from the native Rust backend:

- Plain `#[inline]` on `Object::check_required`, `Object::check_keys`,
  `Object::check_dependent_required`, and `content::string_special_word`.
- `#[inline(always)]` on `BufferedBase64::byte`, `BufferedBase64::advance`,
  `Parser::peek`, and `Parser::advance`.
- `#[inline(never)]` on `Execution::integer_items` and `Execution::record_items`.

With Rust 1.99.0, x86-64 Linux, release LTO and one codegen unit, removing
these attributes together left all 1,981 generated function bodies identical.
Assembly was generated with
`cargo rustc --manifest-path ext/schemurai_native/Cargo.toml --release --locked -- --emit=asm`.
The remaining assembly differences were source-line numbers in panic-location
constants. Both item helpers remained separate functions under compiler-managed
inlining. Each of the four removed `inline(always)` attributes was also checked
individually against the original assembly.

Removing the slice input's `byte` hint, `Parser::take`, or `Parser::whitespace`
individually changed generated parser code. Removing all three together changed
register allocation and parser-position stores in the number/container loops.
They remain as a measured group, with their reason documented at the call sites.
`Parser::value` retains its previously measured dispatch specialization (see
"Full audit after JSON value dispatch inlining"). The three bounded Base64
helpers still isolate medium, 8 KiB and streaming scratch frames; the UUID
helper and unordered Bignum helper retain their documented layout/frame reasons.

A focused control used Ruby 4.0.6/YJIT, 128 repeated strings, 31 median samples
of 300 direct native-program calls, and 1,000 warmup calls per method. It covered
plain and Base64 JSON, valid and invalid inputs, and validity and diagnostics:
40 cases per run. Every case checked native support and exact VM error parity
before timing. The JSON fixtures were:

- `{"id":1,"flags":[true,false,null],"name":"record"}`
- ` { "id" : 1, "flags" : [ true, false, null ], "name" : "record" } `
- `[0,-1,1.25,2e10,0.0002,-3E-2]`
- `[true,false,null,true,false,null]`
- `{"a":[{"b":[true,1,null]},[],{}]}`

Invalid fixtures appended `!` before optional Base64 encoding. A repeat reversed
the extension order. Selected valid plain-JSON diagnostics illustrate why the
three hints were retained; times are microseconds for the whole 128-item array:

| Fixture | Original | Three hints removed | Final, reverse-order repeat | Three hints removed, repeat |
| --- | ---: | ---: | ---: | ---: |
| Record | 4.41 | 4.50 | 4.44 | 4.58 |
| Whitespace | 5.04 | 5.15 | 5.04 | 5.19 |
| Numbers | 3.89 | 4.18 | 3.91 | 4.34 |
| Literals | 2.32 | 2.44 | 2.32 | 2.43 |
| Nested | 4.41 | 4.71 | 4.47 | 4.78 |

Invalid diagnostic timings were mixed, and the repeat's plain-record validity
was faster with the hints removed. This is a local tradeoff supporting the
retained group, not a speedup claim for every input or architecture. The final
ten-attribute deletion itself preserves generated instructions in this build.

Final validation passed 35 Rust unit tests, 183 native/oracle differential
examples, Clippy with warnings denied, formatting and whitespace checks. The
final `native_shared_scans.rb` run passed all 36 direct-native/VM-parity cases,
including tracked/untracked required and dependent-required assertions, using
31 samples of 100 calls at width 1,000.

`jscpd -f ruby,rust -r ai --no-tips` reported 118 clones (5.2%). Review of
changed-code surroundings found existing interval calculations for compiled
record fields and runtime integer arrays, and guarded rule selection in the
general/specialized item paths. These remain in their existing phases and use
sites: this audit changes attributes and comments, not their rules or
responsibilities. Content/format scan wrappers serve different parser and
encoding guards. Manual cross-language review confirmed that Ruby/VM content
and dependent-required rules intentionally mirror native semantics as
independent implementations checked by differential tests. No new evaluation
logic or duplicated rule was introduced. Two existing formatting differences
in `lib.rs` were normalized by `cargo fmt`.
