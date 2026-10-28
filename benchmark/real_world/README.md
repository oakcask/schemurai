# Real-world schemas and generated inputs

This pilot complements the official conformance suite and the existing synthetic
algorithm benchmarks. It covers three independently maintained schemas used by
real tools and data formats. Instances are generated specifically for this
repository; they are not production traffic or copied user configuration.

## Sources and license boundaries

| Directory | Upstream | License covering downloaded schema.json |
| --- | --- | --- |
| `schemas/github-workflow/` | [SchemaStore GitHub Workflow](https://github.com/SchemaStore/schemastore/blob/master/src/schemas/json/github-workflow.json) | Apache-2.0, local `LICENSE` |
| `schemas/taskfile/` | [Task's official schema](https://github.com/go-task/task/blob/main/website/src/public/schema.json) | MIT, local `LICENSE` |
| `schemas/geojson/` | [GeoJSON's published schema](https://github.com/geojson/schema/blob/gh-pages/GeoJSON.json) | MIT, local `LICENSE` |

Each directory's `LICENSE` applies to that directory's downloaded `schema.json`.
The schemas are saved byte-for-byte without modification. The source metadata,
generated instances, harness code and documentation are authored for Schemurai
and remain covered by the repository's root `LICENSE`. An upstream license does
not extend to sibling schema directories or the harness.

Each `source.json` pins the schema and license repositories, branches, commits
and paths. GeoJSON publishes generated schemas on `gh-pages` and its license on
`main`, so those commits are tracked independently. The approved license text is
committed beside the metadata. Downloaded schemas and receipts are ignored by
Git; CI uploads them with results so the exact tested bytes remain inspectable.

## Fetch and update

```sh
ruby script/fetch-real-world-schemas
```

Fetching uses immutable commit URLs, verifies the upstream license against the
local approved text and digest, checks the dialect and rejects unpinned external
references. It then records the schema digest and complete source metadata in
`receipt.json`. Tests are offline after fetching. They reject missing downloads,
changed bytes and receipts from an older source pin.

Renovate's custom manager tracks branch digests in both dependency blocks of
`source.json`, using its [git-refs datasource](https://docs.renovatebot.com/modules/datasource/git-refs/).
It proposes a grouped update weekly; the corpus CI fetches those new revisions
and reruns correctness checks and benchmarks. Updates require review. A license
change fails fetching until the license, declared SPDX identifier and approved
digest have been reviewed together. A dialect change, new external reference or
changed input contract also requires an explicit harness update.

## Correctness and mutation fuzzing

```sh
bundle exec rspec test/real_world_schema_test.rb
FUZZ_BACKENDS=ruby,vm,native ruby -Iext/schemurai_native script/real-world-fuzz
FUZZ_SEED=123 FUZZ_SIZE=32 FUZZ_MUTATIONS=1000 ruby script/real-world-fuzz
ruby script/real-world-fuzz --replay failure.json
```

Build the native extension before selecting `native`. The standalone runner
defaults to `ruby,vm`, seed 9571, size 8 and 100 pairs of destructive/exploratory
mutations per schema. Set
`FUZZ_ARTIFACT` to choose the failure JSON file; its default is in the system
temporary directory. The artifact embeds the exact schema, instance, seed,
mutation index, edited position, before/after values, broken type contract and
expected public errors, allowing replay after upstream updates.
Replay uses the backends selected by `FUZZ_BACKENDS` too. Shared-container
controls restore their Ruby object identity when replayed. The active input is
saved before entering a backend, including before a native crash or timeout;
successful campaigns remove the artifact.

Schema-specific builders produce successful workflows, Taskfiles and GeoJSON
collections with varied command/step/geometry branches. Reviewed invalid controls
break nested fields at the first, middle and final position. Equal-content
controls use either shared Ruby containers or independent copies. Shared identity
is a Ruby API workload; serialized JSON represents the copied form.

Each guaranteed destruction chooses a nested run/uses field, task command or
geometry coordinate from a successful input and replaces it with a randomly
selected null or boolean. These types violate reviewed contracts for those fields.
The generator creates the edited instance and exact expected public errors
(instance path, schema path and keyword) together, without consulting a backend.
The same mechanism creates the fixed first/middle/last-position controls.

Every backend must reject the instance with that exact error list. Restoring the
edited field must make the input valid again. Thus consistent rejection for an
unrelated error is insufficient. Expected diagnostics describe the public API:
workflow errors appear at the enclosing job's `oneOf`, Taskfile errors at the
task's `anyOf`, and GeoJSON errors at its root `oneOf`. Leaf diagnostics are not
exposed through these failed applicators, so the separate mutation pointer
records the actual edit; a root GeoJSON diagnostic alone cannot identify which
coordinate failed. These contracts are deliberately specific to the current
builders and must be reviewed when upstream semantics or diagnostics change.

The exploratory mutator deletes members, inserts unexpected values or replaces arbitrary
nested positions. Its replacement pool includes upstream enum/const values,
numeric boundaries and bounded length/count boundaries. This is seeded mutation
of schema-specific successful inputs, not a general JSON Schema instance
generator or coverage-guided fuzzer. Replacements need not match the constraint
at the chosen path. Mutants have no assumed validity: another branch may accept
them. These exploratory cases retain backend comparisons rather than an invented
expected error. Ruby/VM/native comparisons check both public methods and ordered error
paths/keywords; error wording follows the existing oracle's exclusion policy.
The independently expected controls reduce reliance on backend agreement alone.

PR CI uses a fixed seed. Weekly/manual runs also explore a seed derived from the
run number, recorded in case IDs, with 1,000 mutations per schema. The CI job has
a 15-minute process lifetime bound; individual native calls have no hard deadline.
For local exploration use an
OS process limit, for example `timeout 120s ruby script/real-world-fuzz` on Linux.
Minimizing findings and promoting them to fixed regressions remains manual.

## Performance

```sh
BENCHMARK_BACKENDS=ruby,vm,native BENCHMARK_JSON=real-world.jsonl ruby -Iext/schemurai_native benchmark/real_world.rb
BENCHMARK_SIZES=8,16,32,64 BENCHMARK_ITERATIONS=15 BENCHMARK_BATCH=10 ruby benchmark/real_world.rb
```

The runner checks expected verdicts and backend diagnostic parity first. It
reports compilation separately from `valid?` and `validate`, keeping individual
schema/size/failure-position/representation cases separate. JSONL includes raw
timing samples, Ruby allocations per call, error counts, serialized input bytes,
source revisions/digests, seed and Ruby/YJIT metadata. Native support is measured
directly and reported, so public API fallback is visible. Ruby allocation counts
do not measure native heap usage. GC runs before each sample; cases and backend
order are shuffled deterministically. Input generation is outside timing.

Use the same harness and fetched corpus on base and candidate release builds,
on an idle machine, with repeated alternating runs. Inspect per-case regressions
and growth across sizes; this CI report is not a timing gate or a speedup claim.
Existing reference/memoization/collision benchmarks remain the adversarial layer.
The three initial schemas are all draft-07 and are not representative of every
application, dialect, dynamic scope or worst-case graph. Extend the corpus across
those axes instead of optimizing only for these generated shapes.
