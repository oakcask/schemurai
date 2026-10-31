# Backend selection

`Schemurai.backend` reports the selected backend. Validators and schema
registries expose the backend captured when they were created.

The `backend:` keyword and `SCHEMURAI_BACKEND` accept `ruby`, `vm`, `native`, or
`default`. The production default is explicitly `ruby`. The `vm` backend
compiles schema nodes into immutable Ruby instruction streams as the schema
graph is built and executes them with the validator VM. Validators from the
same VM registry reuse those streams. Both backends retain the same compiled
Ruby schema graph and public result objects.

## Rust native backend (in development)

`backend: :native` and `SCHEMURAI_BACKEND=native` select the Rust extension.
The production default remains Ruby. The source gem builds the extension with
Cargo and mkmf; Rust 1.93+, a C toolchain, and Ruby development headers are
required. Linux/CRuby is the currently verified native platform.
If cargo cannot be found, installation writes a no-op extension Makefile and
skips native compilation. Ruby and VM remain available. Explicit native
selection still raises `LoadError` when the extension is absent, rather than
silently changing the selected backend. Reinstall the gem with cargo available
to build the native extension. A compiler or Rust build error when cargo is
present still fails installation.
Cargo builds the locked Rust dependencies, including Ryu for decimal conversion;
the first build downloads them unless they are already cached.
The installed-gem smoke test forbids VM execution for its native cases. It
covers references, numeric limits, regex matching, formats and content, plus
shared NaN containers and in-place string encoding changes. A current isolated
source-gem installation was verified on Linux with CRuby 4.0.6; its extension
was rebuilt from the packaged Rust/C sources rather than a checkout binary.

Native validation does not load or construct a VM evaluator and has no execution
fallback to that backend, with or without invocation limits. It reuses only the
VM compiler's immutable instruction format. The native compiler rejects an
unknown instruction or unsupported internal operand before publishing a program.
An unresolved reference is a supported failing assertion, including inside Ruby
container callbacks; later registry registration rebuilds the native program.
Ruby-sensitive behavior uses shared primitive/traversal helpers through libruby
after Rust unwinds. If execution ever exhausts those paths without a pending
runtime request, it raises an internal coverage error instead of replaying the
instance through another evaluator.

The current complete benchmark audit on Ruby 4.0.6/YJIT, Rust 1.99 and
x86_64 Linux reached the 10× VM target in all 168 measured cases (minimum
10.039×, median 25.136×). It used arrays of 1,000 elements, 31 samples and
100-call batches and checked native coverage, validity and full errors.
All 84 native `valid?` cases allocated zero Ruby objects. See
[`benchmark/README.md`](../benchmark/README.md) for the measurement details
and earlier results. The smallest margin is narrow; results depend on the
platform and workload.

CI runs native differential tests on `ubuntu-24.04` (x64) and
`ubuntu-24.04-arm` (arm64), with Ruby 4.0.0/latest 4.0 and default/portable builds.
Adding `workflow:enable-benchmark` to a PR starts the
`benchmark / native backends` workflow, which compares YJIT-enabled VM and native
on both architectures with Ruby 4.0. Each job publishes per-case timings,
speedups and allocation counts in its Workflow Summary and saves the raw JSON
as an artifact. The performance target is informational; correctness gates
fail the job. The package workflow also installs without cargo on PATH and
checks Ruby/VM operation plus explicit native unavailability.

For a development checkout, build and load the extension with:

```sh
cd ext/schemurai_native
ruby extconf.rb
make
cd ../..
bundle exec ruby -Ilib -Iext/schemurai_native -rschemurai -e 'p Schemurai.compile(true, backend: :native).valid?(nil)'
```

Native opcode identifiers, type masks, numeric-rule flags and adapter status
codes are named in `ext/schemurai_native/protocol.def`. C includes that shared
definition and Cargo generates Rust constants from it during the build; Ruby
diagnostics use the constants exported by the extension. A compatibility test
checks the shared masks against the Ruby VM compiler's constants.
The same definition assigns private constructor accessor indexes. Their Ruby
method IDs are initialized once when the extension loads, before Ractor use;
construction still invokes the accessors through protected Ruby method calls.

The existing Ruby compiler builds the dialect-aware immutable VM programs.
Rust reads those programs once and stores native instructions plus opaque
CRuby `VALUE` handles. Instances cross the boundary as a single `VALUE`;
validation directly reads the original Array, Hash, and String storage. There
is no JSON/Marshal serialization, Rust JSON tree, or instance copying. Integer
array loops borrow array storage for the duration of an allocation-free scan.
Schema operands are retained and pinned by the TypedData GC mark callback,
including during compilation and compaction. Rust allocations are released by
the TypedData finalizer. The GVL stays held throughout native execution.
Compilation callbacks use `rb_protect` in C; Ruby exceptions return through
Rust as ordinary errors and are raised after the Rust stack has unwound.
Rust panics are caught at evaluation/compilation entry points.

Ruby-specific regexp behavior and JSON content transcoding use runtime requests
rather than VM execution.
Rust returns after releasing all borrowed views, memo state and partial reports;
C then calls the shared ECMA translator and `Regexp#match?`, or `JSON.parse`,
through libruby.
An invocation-local numeric-key table stores the observation, and native
evaluation restarts using it. Before the first Ruby operation, a replay restores
input-order property routing and the separate property-name phase so a
reordered fast scan cannot expose an exception from an unvisited operation.
The runner marks pending and completed observation
handles for GC. An ensure handler clears results on success and exceptions;
the runner's unbounded scalar and regexp caches persist on that validator. Ractors own separate
tables and Ruby regexps. Both Ruby and native duration deadlines remain fixed
across retries, and native error limits are checked before another runtime call.
The existing Validator Rust matcher path needs no Ruby call or extra Ruby allocation.
JSON content with other source encodings, or invalid US-ASCII bytes, uses Ruby
for encoding conversion and parsing. It preserves the VM's rescue of
`ArgumentError` and `JSON::ParserError`, while propagating encoding exceptions.
Ruby may build a temporary JSON value in this path; only its assertion result is
retained. UTF-8, binary and valid US-ASCII content, including decoded Base64, keep
the native parser. Runtime observations and retry deadlines are shared between
regexp and JSON operations in `ext/schemurai_native/src/runtime.rs`.
Diagnostic pointers retain native UTF-8 text and defer names with other or
invalid encodings. Deferred names are escaped by the same Ruby helper as the
Ruby and VM evaluators, then appended using Ruby's encoding compatibility rules.
Pointer requests occur when recording an error, after the error-limit check,
with the instance path before the schema path. They do not raise for paths
whose errors are never recorded. The runtime request owns its native text and
name handles across retries. The runner roots completed Ruby strings until the
report takes ownership; report marking retains them through output allocation.
UTF-8 diagnostic pointers keep native generation without Ruby calls.
Cold runtime cases can repeat native traversal once per distinct observation,
so many distinct strings may take quadratic traversal work. This bridge trades
that cold-path cost for keeping Ruby calls entirely outside borrowed Rust frames.

### Evaluation design policy

Native evaluation should share compiled rule metadata, predicates, lookup
strategies and container scans between `valid?` and `validate`. Execution policy
controls early termination, evaluated-location collection and error collection.
An optimization to a shared algorithm should therefore benefit every applicable
execution policy without requiring a second implementation of the same rule.
Branch scans and `contains` match counting now use shared helpers in
`ext/schemurai_native/src/evaluation.rs`. Ordinary and tracked validity use a
shared declared-property scan, and all three modes share property, pattern and
additional-property routing. The `eval`, `eval_tracked_kind` and `collect`
traversals retain their policy-specific control flow and scalar specializations.
Required and dependent-required verdict checks share predicates while retaining
their positions before and after property evaluation, respectively. Specialized
pattern, format and content item diagnostics share coverage marking and the
invalid-item callback; their guarded byte views and parser selection stay separate.
Cycle detection and scope projection share iterative DFS postorder generation,
with caller-owned visited buffers and separate component representations.

The responsibilities are:

| Responsibility | Shared behavior | Policy-specific behavior |
| --- | --- | --- |
| Rule checks | Type guards, JSON equality, numeric failure bits, string assertions and compiled operands | Convert failures into a verdict or ordered errors |
| Object lookup | Key guards, property lookup, pattern matching and selection of additional properties | Record evaluated keys and construct error paths |
| Array scans | Item selection, borrowed storage and scalar scan specializations | Stop on a conclusive verdict or visit remaining errors; record evaluated indices |
| Applicators and references | Branch evaluation, resource scope, cycle guards and annotation merge rules | Decide which branches must be visited and which errors are exposed |

Validity may stop once its answer is conclusive. Detailed validation must visit
all locations needed for complete ordered errors. Either mode must visit all
successful branches and matching locations whose annotations are needed by
`unevaluatedProperties` or `unevaluatedItems`; annotation demand is separate
from the choice of public method. For example, an `anyOf` success can terminate
evaluation when further branch annotations and compatibility checks are
unnecessary. A failing `oneOf` diagnostic may still need the exact number of
matching branches, and a failing `contains` diagnostic may need the exact match
count. Error details constrain
termination as well as error locations.

Where diagnostics need both errors and evaluated locations, the child traversal
should return its verdict and annotation result while collecting errors. The
caller should consume that result rather than evaluate the same subtree again
solely to recover annotations. This is implemented for `allOf`, conditional
branches, references and tracked schema dependencies. Preserve the distinction
between locally attempted locations retained by diagnostics and successful
annotations exported by an applicator. Error count alone is not a substitute
for the evaluation result.

Sharing must preserve the existing VM compatibility behavior: complete error
fields and order, numeric equality, key encodings and identity-Hash handling,
dynamic scope, recursion/depth limits, unsupported results and named exceptions.
Changing termination or lookup order requires checking these behaviors, including
an unsupported or exceptional value after an earlier conclusive branch.
Borrowed Ruby storage remains protected by the GVL and must not span a Ruby
allocation or callback. Do not cache instance results across public calls;
instances and registry resolution can change between calls.

Policy specialization should keep unused annotation and reporting work out of
the validity path. Shared code may use generics, callbacks or focused helpers;
a single interpreter loop or a runtime policy object is not required. Retain a
specialized path only when its workload or output requirements justify it, and
have it reuse the shared predicates and compiled metadata.

Review duplication by mapping each keyword across ordinary validity, tracked
validity and diagnostics. Compare traversal direction, termination conditions,
subtree evaluation count and specialization selection, even when the source
text differs. Extend the shared branch/property scans and combined
diagnostic/annotation results incrementally to other container specializations.
JSON equality and uniqueness also provide examples of shared checks.

Declared-property scans adapt to sparse objects: when schema properties exceed
four times the input size and there are more than eight declarations, discover
matching property indices through the same compiled lookup table used by
diagnostics. Sort and deduplicate candidates before evaluating them so validity
retains schema order. Precompiled required-property indices preserve the position
of missing-required failures, and final lookups use schema key handles to retain
identity-Hash semantics. Dense objects keep direct schema-order lookups.
The sparse scan takes O(N log N + R) expected work and O(N) temporary native
storage for N input keys and R required declared properties, excluding child
evaluation and key-byte processing.

Shared, acyclic reference targets use invocation-local memoization keyed
by node, original VALUE and evaluation depth. Scope-dependent targets also key
results by their effective outermost dynamic anchor bindings. Tracked validity stores the verdict
and exported locations; diagnostics store only complete successful traversals,
with annotation demand included in the key. Returned coverage is independently
owned, so merging one branch cannot change another branch's cached annotations.
Two references to every preceding definition previously expanded a depth-D
definition chain into O(2^D) evaluations, including successful annotated objects
and arrays. Memoization reduces this equal-depth chain to O(D) evaluations,
plus coverage copying and merging. Repeated array/object position scans also
admit acyclic children whose reachable graph contains another position scan,
even when a schema has only one reference to that child. This covers shared
input graphs reached by `items`, `additionalItems`, `contains`, unevaluated
items/properties, pattern/additional properties and property names. Position-only
candidates without nested iteration keep their direct scans, avoiding cache
admissions for ordinary scalar/record arrays. The existing cycle, unsupported
and dynamic-binding checks still apply. Two temporary bit vectors track loop
roots and reachable iteration during the same O(N + E + A + K) graph analysis.
`benchmark/native/runtime/repeated_positions.rb` measures single-reference chains over
shared input containers and distinct record controls.
Verdicts retain at most 4,096 entries;
tracked validity and diagnostic successes share up to 8,192 entries and a
65,536-slot allocation budget. FIFO eviction releases old results when either
limit is reached, so later instance locations can still reuse shared targets.
Previously a full cache refused all subsequent admissions, restoring O(2^D)
work for later records in a wide array. Admission and eviction take constant
expected work per result, excluding coverage copying; the eviction queue is
bounded by the entry limit too. A single result larger than the slot budget is
left uncached without evicting other results. After compiling all reachable
anchor bindings, dynamic references whose every possible binding equals their
fallback target become static native references. The original opcode and
diagnostic paths remain `$dynamicRef`. This proof takes O(A + E) work and O(K)
temporary slots for A compiled bindings, E instructions, and K anchor names,
and lets shared acyclic graphs with invariant dynamic leaves reuse results.
For genuinely scope-dependent references, the compiler includes all possible
binding targets in its cycle analysis. One virtual dispatch vertex per anchor
name avoids duplicating every binding edge for every reference; analysis takes
O(N + E + A + K) work and storage for N nodes, E instruction edges, A bindings
and K anchor names. Recursive dispatch adds one shared vertex and edges to
recursive resource roots. Cyclic and recursive candidates use the guard-context
keys described below, preserving the active-reference guard's behavior.
Scope-independent nodes skip scope-key construction. A single dynamic name
uses the existing effective binding in its scope frame in O(1); multiple names
construct an exact binding vector in O(KS) work for S active scope frames.
Equivalent vectors share an invocation-local ID. FIFO interning retains at
most 4,096 signatures and 65,536 binding slots, with shared buffers between the
lookup table and eviction queue. IDs are never reassigned after eviction,
including while a child evaluation can still record a parent result. Signatures
exceeding the slot budget leave scoped results uncached without dropping useful
stored scopes. This additional storage is bounded separately from annotations.
Cyclic reference graphs previously disabled reuse, so shared input containers
could expand O(D) stored nodes into O(2^D) evaluations. Selected cyclic and
recursive candidates now include the exact active `(source, VALUE)` membership
set, effective dynamic bindings and effective recursive root in their keys.
Membership is sorted and deduplicated because guard order does not affect
reference short-circuiting. Iterative strongly connected component analysis
excludes sources outside schema cycles. A bounded, invocation-local input
acyclicity proof removes distinct ancestor instances and schema cycles that
require changing input position; object dependencies retain same-instance edges.
The proof visits at most 4,096 new containers with the evaluation depth limit,
retains at most 4,096 positive results, and keeps full guards when inconclusive.
A lazily allocated 8 KiB repeat detector avoids constructing heavy keys on most
first visits. Approximate admission can only add cache attempts: stored verdicts
and annotations still use exact keys. The detector resets after 4,096 admissions.
Guard signatures share the existing 4,096-entry / 65,536-slot scope budget.
Construction costs O(G log G + KS + S) for G relevant active guards, K dynamic
names and S scope frames, plus bounded input analysis. Compilation uses a
constant number of O(N + E + A + K + R) graph analyses, including R recursive
resources, and retains five additional node bit vectors. Linear recursion
without repeated positions or branching keeps direct evaluation. These choices
reduce shared recursive workloads substantially but add some overhead to
ordinary recursive trees; `benchmark/native/runtime/cyclic_memo.rb` measures both.

These limits bound extra retained memory rather than guaranteeing
linear evaluation for arbitrary schemas. Failed diagnostics still visit each
path: if the contract requires 2^D distinct errors, producing them takes at
least O(2^D) work. See the reproducible workloads in
`benchmark/native/runtime/algorithms.rb`.
`benchmark/native/runtime/memo_turnover.rb` exercises arrays that exceed the entry
budget and confirms direct native coverage after the limits are crossed.
`benchmark/native/runtime/dynamic_memo.rb` exercises the previously exponential
shared-reference chain ending in an invariant dynamic reference.
`benchmark/native/runtime/contextual_memo.rb` covers changing single and multiple
bindings, including annotation collection, with exact VM parity.

Dynamic binding discovery stores only actual `(resource, name) -> target`
results; absent bindings do not append redundant `nil` GC roots. A single-name
query uses the direct resource/name lookup and resolved prefixes, avoiding
enumeration of unused declarations. Once multiple names appear, a reverse index
joins registered names with resources actually declaring them. Resource tables
append names, including late external documents that reuse an existing resource.
A per-resource declaration count and indexed prefix discover these additions;
new names and new resources are processed in subsequent passes. This also fixes
missed overrides when a late document adds an already registered name to an
already visited resource. Temporary roots pin index names across compilation
callbacks/GC compaction and are released with the name-ID index at the fixed point.
Hash lookup registers dynamic name IDs instead of linearly scanning all K names.

For R reached resources, K registered names, B declarations (including unused
names), A matched bindings and P discovery passes, the indexed join takes
expected O(RP + B + K + A + T) work, excluding name bytes and child compilation.
T counts keys copied by Ruby snapshots: a stable resource is copied once, but a
growing resource can copy older names again even though only its new suffix is
indexed. Temporary storage is O(R + B + K + A), while retained binding tables
store O(K + A). Many unused declarations can cost more in the multi-name case;
the single-name path keeps direct lookups. Single-name scope metadata uses the
compiled index in O(N) expected work for N nodes, replacing an O(NA) scan.
See `benchmark/native/compile/scope.rb` for cached-VM constructor timing and
sparse scaling; the Cartesian O(RK) absent-lookup work is eliminated from the
multi-name discovery path.

Detailed `anyOf` and `oneOf` scans remain complete to preserve later VM
exceptions and exact match counts. Counted `contains` validity, tracked
evaluation and diagnostics also retain complete scans. Untracked validity in
older dialects stops at the first match, matching the VM's `any?` behavior and
avoiding exceptions in unvisited later items. The compiler's `count_contains`
flag selects these policies in the same shared scan. Shared scans make these
termination requirements explicit rather than assuming both public methods can stop at the
same point.

Each runtime refactoring must check native coverage without VM fallback and
compare both validity and full ordered errors with the VM. Exercise annotation
demand, invalid and unsupported cases, mutable instances and GC compaction as
applicable. Measure `valid?` and `validate` separately on valid and invalid inputs,
with compilation excluded, and include sparse objects, large branch sets and
nested applicators when those algorithms change. Report Ruby allocations and
native buffer costs where relevant; zero Ruby allocations do not imply zero
native allocation overhead.

Native instructions currently handle primitive types, unions, basic string
lengths, numeric limits and decimal multiples, built-in formats, combiners and conditionals, tuple/list items,
contains, properties, required names, property names, additional properties,
dependent assertions (including Draft 7 dependencies), `$ref`, `$dynamicRef`, `$recursiveRef`, JSON object
equality, `uniqueItems`, `unevaluatedItems`, and `unevaluatedProperties`.
Resolved static references become native node indices. A stack of source/instance
pairs preserves the VM's cycle guard without allocating Ruby tracking objects.
Unresolved references use native failures and diagnostics. Adding a resource to a
mutable registry rebuilds affected native programs so an existing validator can
succeed later.

Numeric rules retain the VM's two comparison modes: ordinary Float bounds use
Ruby-compatible Float/Integer and Float/Rational comparisons; `multipleOf`
compares exact fractions derived from the shortest decimal spelling. Ryu writes
that spelling into a stack buffer, with no Ruby string allocation. Fraction
comparison uses continued fractions instead of overflowing cross products.
Reduced-fraction divisibility avoids multiplication altogether. Bounded integer
operands use a nonallocating CRuby scalar adapter and native 128-bit arithmetic.
Larger Integer instances with bounds alone run natively with bounded fractions
or Integer limits of arbitrary magnitude. Their sign determines comparison
against exact bounded fractions because their magnitude exceeds every such
limit; wider Integer bounds use rooted handles as described below.
When the magnitude needs more than sixteen
bytes, public CRuby size/sign metadata determines that ordering without exporting
integer words. Magnitudes near the signed i128 boundary retain exact word reads.
When every Integer bound fits i128 and there is no multipleOf assertion,
compilation combines the comparisons into a result for each sign outside that
range. Runtime scans select that result without revisiting individual limits.
The numeric view combines Bignum classification and public size/sign metadata;
Rust reads only the output initialized for that input kind and sign.
Arrays whose single numeric instruction has integer schema bounds and no
multipleOf rule combine ordinary-kind classification and Integer metadata or
the Float scalar value in one C adapter call. Ruby Integers are compared directly
from that metadata; Float instances use the same exact comparison rules without
repeating type and scalar queries. Float Integer-membership checks are only
performed when the required type mask needs them. Fractional schema bounds
retain the existing array scan. Required masks, special-object runtime requests and
non-finite Float behavior are checked against VM.
For a single Integer bound outside i128, Bignum array items compare the original
rooted handles directly through the checked nonallocating Big/Big comparator.
This skips scalar magnitude metadata and word reads. Required type masks and
inclusive/exclusive comparisons remain in Rust; other input kinds retain their
existing classification and Float comparison rules.
Integer multiples with magnitudes up to
1,024 bits use the existing fixed-word scalar adapter and native remainder
calculation, including fractional divisors whose reduced numerator fits i128.
Bounded-fraction limits on those instances use sign comparisons; wide Integer
limits compare the original handles. If 2^64 is congruent to
one modulo the numerator, a sum of the magnitude words replaces per-word
division; this strategy is selected at compilation. Non-Fixnum instances with
a positive numerator greater than one obtain those
words once: the same fixed buffer determines whether native i128 arithmetic is
available, supplies exact bounds comparisons, and feeds the wider remainder
calculation when needed. Numeric rules retain the Fixnum tag flag obtained from
CRuby at initialization to avoid repeating its C query during evaluation.
Larger Integer instances use a Rust-owned scalar word buffer sized through
CRuby's public integer metadata and packing APIs, then reuse the same remainder
calculation. These APIs invoke no Ruby methods and allocate no Ruby objects;
borrowed instance storage remains valid. The temporary buffer grows with the
Integer's magnitude and is released after the assertion.
Numerator one and
nonpositive numerators require no full magnitude read, even for larger instances.
Float inputs represented by bounded decimal fractions can also combine
multipleOf with wide Integer schema limits: the fraction's numerator fits i128
and its positive denominator bounds its magnitude, so a wider Integer limit's
sign determines the comparison. Beyond fixed-width arithmetic, native
evaluation uses `num-bigint`/`num-rational` for arbitrary Integer divisors,
compiler-produced Rational limits, and every finite Float decimal exponent.
The fixed and arbitrary paths share decimal-spelling parsing and bound-failure
predicates. Arbitrary schema fractions are retained only when their components
do not fit i128; runtime temporaries contain numeric scalars rather than a
converted instance tree. They allocate no Ruby objects and invoke no Ruby
methods. Non-finite decimal conversions record a terminal native status for
NaN or either Infinity; the C boundary raises the VM-compatible `ArgumentError`
after Rust unwinds. Invalid numeric operands still delegate for their Ruby
behavior. Schema rational
operands and rounded bounds are captured at compilation, never recomputed by
Ruby callbacks during evaluation. The integer-array fast scan remains available.
Native memory reporting includes numeric metadata and retained fraction digits;
the arbitrary-precision crate exposes used digits rather than spare capacity.
Runtime numeric instructions reuse the caller's ordinary-number classification:
after excluding Float, the Integer scalar adapter does not classify that value
again. Schema numeric metadata retains its full Integer/Float checks. Unusual
Numeric subclasses and other out-of-domain values delegate before scalar access.
Numeric validity and diagnostic prechecks share the same guarded evaluator.
Homogeneous numeric-array diagnostics select their item rule before scanning,
reuse the fused bounds metadata path, and collect full diagnostics only for
invalid items. Prefix indices, attempted-item coverage and error order retain
the general traversal's behavior. Fixnum multipleOf uses its direct primitive
path in both scans.
Homogeneous arrays also select single numeric instructions before scanning,
including fractional rules and Bignum inputs that cannot use the Fixnum bounds
shortcut. Required type masks, non-numeric applicability and depth limits retain
the generic evaluator's behavior; annotation-tracked child nodes retain that
evaluator directly.
Fixnum instances with a multipleOf divisor whose reduced numerator fits i64
and exact integral i64 bounds use native 64-bit comparisons and remainder.
The divisor may be fractional: the Integer's unit denominator always divides
the divisor's denominator. Nonpositive numerators remain invalid without
executing remainder; other operands retain the fraction implementation.
Validity and diagnostics share the compiled arithmetic rules and failure bits.

All nine built-in formats (`date`, `time`, `date-time`, `duration`, `ipv4`,
`ipv6`, `uuid`, `json-pointer`, and `relative-json-pointer`) use native byte
parsers. Calendar boundaries, fractional seconds, UTC-adjusted leap seconds,
duration component ordering, IPv4 tails in IPv6, and pointer escapes preserve
the existing Ruby behavior. Parsers borrow original string storage and allocate
no Ruby objects or Rust instance tree. The `format` option and per-resource
Format-Assertion vocabulary enable assertions independently for each evaluator.
JSON Pointer and Relative JSON Pointer retain scalar escape checks for pointer
suffixes up to 32 bytes. Longer suffixes use memchr to find tilde escapes in the
borrowed input; only `~0` and `~1` are accepted. No pointer tokens or decoded
strings are allocated.
Arrays whose items have only a format assertion select the native parser before
scanning. Each item combines the exact String-class guard and borrowed byte
view in one C call, retaining ordinary classification for other values.
Diagnostics use the same scan and collect complete errors only for invalid
items, including type failures. Prefix offsets, attempted-item coverage and
error order retain the general traversal's behavior. String length, pattern
or content combinations keep their existing evaluator.
Disabled format/content assertions stay native annotations; unknown optional
formats remain ignored. Strict unknown formats are still rejected by the schema
graph before compilation.

Opt-in Base64 and JSON content assertions also run in Rust. `base64-simd`
performs strict alphabet, padding placement and unused trailing-bit checks;
its default CPU detection selects SIMD or the crate's scalar implementation.
Encoded JSON of at least 128 decoded bytes uses
[`base64-turbo 0.5.0`](https://docs.rs/crate/base64-turbo/0.5.0)'s
strict slice decoder, with runtime CPU selection and scalar fallback.
This dependency requires Rust 1.93; current local validation uses Rust 1.99.
Arrays whose items have only a content assertion select a shared content scan
before visiting items. Plain JSON obtains an ordinary String guard, original
byte pointer/length and encoding metadata in one C call. Base64 retains an
encoding-independent String view. JSON's encoding adapter uses CRuby's public
inline encoding query, including its fallback for extended indices. The guarded
plain-JSON view enters the Rust syntax scan directly; US-ASCII inputs still
require ASCII bytes, while other encodings use Ruby transcoding and JSON parsing.
Diagnostics use the same
scan and collect full errors for invalid items, preserving prefix offsets and
attempted-item coverage. Length, pattern, or format siblings retain their
existing evaluation path. No new C parsing or instance conversion is introduced.
The array scan selects a Rust specialization for its Base64/JSON combination
before the item loop. String-view outputs are read only after the C guard
initializes them; non-String and unsupported values never read those outputs.
Plain JSON is scanned directly from the original string. Value-kind dispatch
is inlined into the parser loops, retaining the same syntax and depth checks;
no JSON tree is constructed. Encoded JSON with
fewer than 128 decoded bytes uses uninitialized fixed stack scratch with
`base64-simd`. Payloads of 128 through 384 bytes use a separate initialized
buffer; payloads up to 8,192 bytes decode in a separate initialized 8 KiB
buffer, each with two extra bytes for the decoder's conservative output bound.
Only the exact written prefix is parsed. This avoids repeated
decoder setup. The larger frame is kept out of the short-content path.
Larger payloads refill a separate buffer with up to 1,536 decoded bytes
and two extra capacity bytes as the parser advances;
its frame is kept out of the shorter-content paths. Scratch size is bounded
independently of input size. String scanning checks the first
eight bytes for short keys, then uses thirty-two-byte groups on x86_64 CPUs
with AVX2 detected at runtime, or sixteen-byte groups when SSE2 is enabled.
Little-endian ARM64 targets with NEON enabled use sixteen-byte groups, packing
the comparison lanes into four-bit flags to locate the first special byte.
Other targets and tails retain the portable eight-byte and
scalar scans. Quotes, escapes and bytes below 0x20 terminate the ordinary run,
including at refill boundaries; vector loads only read complete input chunks.
The original
Ruby string is borrowed directly; decoded bytes are derived content operands,
without a Ruby string allocation, instance-tree conversion or JSON object tree.
Each decoded chunk must have the expected output length, rejecting padded
intermediate chunks before the parser can read unwritten scratch bytes.
The crate receives only borrowed input and the fixed caller-owned output slice.
When a string rule combines a pattern with format or content assertions, the
guarded pattern view is reused by subsequent assertions instead of borrowing
the same string again. Private C helpers keep metadata lookup within the
adapter; separate compiled Rust paths retain standalone checks for diagnostics
and rules without a pattern, avoiding runtime view dispatch there. Original
Ruby VALUEs remain alive under the GVL throughout every borrowed view.
For the shortest content, `MaybeUninit` avoids zeroing bytes before
decoding; the parser receives only the initialized slice returned on successful
decoding with the exact expected length. Partial or failed output is never read.
JSON strings, escapes,
surrogate pairs, numbers, containers, trailing input, and the default depth limit
of 100 match the existing VM. UTF-8/binary input and valid US-ASCII input stay
native; other encodings delegate to preserve Ruby's transcoding and exceptions.
As in the VM, contentSchema remains an annotation.

Dynamic and recursive references use resource/anchor metadata captured during
compilation. Resource roots and dynamic-anchor programs are compiled before
execution; binding discovery continues until newly reached resources and
anchor names have also been indexed. Native scope frames preserve the VM's
outermost matching-resource rule, enter only for programs whose flags track
scope, and disappear on return from branches and references. Dynamic references
without a matching dynamic anchor retain ordinary static-reference behavior.
A single-anchor scope carries its effective binding in the stack frame, avoiding
repeated table scans. General multi-anchor schemas use compiled native tables.
The same scope frames are used during evaluated-location tracking. Reference
routing uses native tables; reached assertions can yield runtime requests.
It allocates no Ruby tracking objects and performs no instance conversion.

JSON equality compares objects independently of key order and compares integral
Float/Integer values without rounding the Integer to a Float. Large uniqueness
checks index structural fingerprints and retain only indices into the original
Ruby array. A flat table stores only fingerprints and original array indices;
arrays of at most 65,535 elements use eight-byte slots containing 48 fingerprint
bits and a one-based 16-bit index. Zero marks an empty slot. Larger arrays use
the full fingerprint and a machine-sized index in sixteen-byte slots. At least
half the slots remain empty. Collisions advance through consecutive
slots, wrapping at the capacity boundary. Every fingerprint
collision is resolved with exact JSON equality. Small arrays use direct
comparisons. Native index storage is capped at 64 MiB and uses fallible
allocation. When a fingerprint is unavailable or index allocation is declined,
native evaluation checks each item's graph before comparing it against earlier
items. The proof uses an explicit stack without the fingerprint depth bound.
Ordinary acyclic values use the same ordered direct comparisons as small arrays;
ordinary cycles raise `SystemStackError` at the C boundary. Special values still
delegate, preserving Ruby fingerprint callbacks and errors. Item order retains
an earlier duplicate result before a later cyclic or special value is visited.
This can take quadratic work but does not require VM execution for ordinary
JSON values.
Container equality visits nested values
even when both operands are the same Ruby object, preserving VM behavior for
NaN and unsupported nested values. Arrays beginning with a Bignum use a
guarded ordered scan first: adjacent original integers must be strictly
ascending or descending. This avoids copying magnitude words and building a
fingerprint table. Every comparison checks both operands are Bignums before
calling the nonallocating Big/Big branch of CRuby's public comparator. A short
unordered tail of at most sixteen elements searches the proven ordered prefix
by binary search and checks its own duplicates directly. Mixed values or larger
unordered tails retain the indexed equality path. No input order or type is
assumed, and the normal depth guard still applies. Unordered Bignum arrays
first try an index using sign and a low 32-bit magnitude sample. A C guard accepts
only `T_BIGNUM`, then calls public `rb_integer_pack`; its documented
[overflow behavior](https://docs.ruby-lang.org/capi/en/master/df/d5e/include_2ruby_2internal_2intern_2bignum_8h.html)
still supplies that low word. This is collision-filter metadata, not a
conversion of the original integer. Every matching fingerprint requires exact
comparison of original Big/Big handles. The short index uses four-byte slots
through 65,535 elements (16 filter bits and a 16-bit index with zero reserved
for empty). Larger arrays through the 32-bit index limit use eight-byte slots
with a 32-bit filter and index. This halves slot storage; truncated filters
only select exact comparison or a wider retry. The canonical and 64-bit
indexes retain their original eight/sixteen-byte slots.
A matching short fingerprint with
unequal original integers immediately restarts with the previous low 64-bit
index; excessive bucket probing also triggers that wider pass. C returns the
short sample and sign as register-sized metadata, with a separate rejection
bit for other kinds, and always initializes the packed low word before reading
it. The public API's single 32-bit word path avoids the wider packing loop on
the locally tested CRuby build. See the
[CRuby implementation](https://github.com/ruby/ruby/blob/v4.0.6/bignum.c).
After sixteen unequal fingerprints or excessive probing in the 64-bit pass,
the whole array restarts with CRuby's public `rb_hash`, guarded in C
to accept only `T_BIGNUM`. The retry state lives in a separate non-inlined
Rust function; ordinary scalar indexing has no collision-budget branch.
CRuby's Bignum branch hashes existing digits directly
and returns a Fixnum without Ruby method dispatch or allocation; the adapter
does not call the private `rb_big_hash` API. Collisions use exact integer
comparison. Any non-Bignum restarts the entire array with canonical JSON
fingerprints, preserving equal Integer/Float pairs. No digit buffer or Ruby
Hash is created for the Bignum-only index. The canonical path uses a checked
integer hint: each subsequent Bignum combines its type check and
256-bit scalar fingerprint input in one C call. Magnitudes beyond 256 bits use
the existing 1,024-bit adapter, while non-Bignum entries retain ordinary
classification. The hint never assumes the rest of the array has one type.
Arbitrary integer equality uses CRuby's
noncoercing digit comparator through a thin adapter. Rust compares mixed
Integer/Float values using fixed stack words and the Float's exact binary bits;
this avoids CRuby's allocating mixed comparison path. Numeric fingerprints
normalize exactly representable Integers to their equal Float's binary bits.
Immediate integer fingerprints, numeric bounds and multiple checks share a
Rust decoder for the borrowed VALUE. It is enabled only when the C headers
confirm the supported signed encoding. Otherwise the immediate hint is
disabled and numeric reads retain the public C adapters. Array validity,
diagnostic prechecks and compiled record fields use the same guarded decoder.
Other Integer buckets fold every sampled scalar word in two independent
multiplication lanes and mix their combined result once. This shortens the
dependency chain without dropping words or changing exact collision checks.
Integers beyond the 1,024-bit finite Float range use CRuby's full native digit
hash, with no Ruby method dispatch or allocation. Their fingerprints need no
Float normalization because no finite Float can equal them. This avoids
systematic high-digit collisions in mixed and nested `uniqueItems` values and
compiled enum indexes. Exact comparisons still decide every hash collision.
Instance trees are never rebuilt in Rust containers. Structural fingerprints
combine ordinary-kind checks and borrowed storage metadata in one C call.
Strings provide their original byte pointer and length, arrays their original
VALUE storage and length, and hashes their size. Floats provide one scalar;
booleans provide their truth value. Rust reads only fields initialized for the
returned kind. Subclasses and unusual values use the shared Ruby value primitives. Structural
hashes directly borrow Ruby strings and traverse Ruby arrays and hashes.
The Hash fingerprint iterator checks
each key's exact String class in C and passes its original byte pointer and
length to Rust in the same callback. Rust computes the fingerprint without
copying keys or calling Ruby while the byte view is live. Strings up to eight
bytes use bounded scalar reads covering every byte, include their length, and
mix the result once. Longer strings retain the byte-wise hash. Both uniqueness
and compiled property lookup use this fingerprint; collisions still require
comparison of the original strings.

Evaluated locations are collected in Rust when an unevaluated assertion needs
annotations. Array indices use bitsets. Property names known at compilation
receive native indices and also use bitsets; additional input keys are retained
as borrowed VALUE/hash pairs in native sets. Successful branches, references,
and conditionals merge their annotations; failed branches and `not` discard
them. Nested instance locations have separate buffers. The ordinary validity
path keeps its early exits and skips annotation collection when it is unnecessary.
An empty annotation accumulator takes ownership of a successful branch's native
buffer instead of allocating and copying another buffer. Subsequent branches
still union their bits and borrowed key sets. Applicator evaluations of the same
instance reuse its guarded kind while entering each branch's resource scope;
the GVL and callback-free native evaluation keep that instance unchanged. Simple
property assertions use the same direct leaf checks as small-record fields.

Compilation groups adjacent equivalent `anyOf` and `oneOf` branches while
retaining their original multiplicity. Object branches qualify only when their
ordered property key handles, required-property flags, remaining required keys,
type requirement and count bounds agree, and their leaves are identical type
checks or boolean schemas. Pattern, additional-property, dependency, name and
unevaluated rules exclude this optimization. A successful group contributes its
full match count but merges evaluated locations once. Original operands remain
available for diagnostics. Nonadjacent branches retain their evaluation order,
including unusual values that require ordered Ruby runtime requests.
This groups compiled schema operations; it does not cache or copy instances.

Small-record field lookup caches every byte, the length and the encoding index
of schema names up to eight bytes at compilation. After checking key identity,
records with at least four fields borrow the input key's pointer, length and
encoding in one C call. Matching scalar bytes and length establish exact
equality when the encoding index also matches. Different encodings retain
CRuby's compatibility comparison; its same-encoding rule is documented in
the [CRuby string comparison source](https://docs.ruby-lang.org/capi/en/master/d1/db0/string_8c_source.html).
The scalar's overlapping first/last words cover every byte, including embedded
NULs; lengths remain separate, so padded words cannot conflate different keys.
Smaller records and longer keys retain direct string comparisons. Schema names
come from the VM compiler's immutable snapshot, and input metadata is acquired
on each lookup without caching instance pointers or allocating Ruby objects.
The distinct
schema-key lookup still verifies ordinary Hash key semantics on every record.
For four to eight short compiled names, the compiler also tries to find a
four-bit window of byte/length metadata giving each schema key a distinct
slot in a fixed sixteen-slot index. Encoding is excluded from slot selection
so compatible ASCII keys remain candidates; every indexed candidate still
requires exact bytes, length and the encoding checks above. Unknown keys
sharing a slot cannot match solely through the index. If no window separates
all names, or a name is longer than eight bytes, the original scan remains.
For each record, its first actual key selects whether to try identity matches
first or use the index directly. The first schema property provides an
immutable identity hint before scanning the other schema handles. Both
strategies verify every key, including mixed layouts and reversed order, and
the choice is discarded after the record. No instance pointers or values are
cached between validations.
Required names map to the record's field bits during compilation, including
reordered and repeated names. One visited-field mask therefore detects
duplicate equal keys and checks required fields without a second mask update.

Structural uniqueness fingerprints borrow string bytes with one pointer/length
query and scan nested arrays through borrowed Ruby VALUE slices. Hash keys are
checked during the fingerprint walk, avoiding a second preliminary key walk;
non-string keys still delegate before any Ruby lookup. These views are read
under the GVL without Ruby allocation or callbacks and are reacquired for every
validation, including after instance mutation.
Structural equality and fingerprints also reuse completed container results
within a single comparison or hash. Ordered value pairs plus evaluation depth
key equality; value identity plus depth keys fingerprints. The first four
relative levels skip cache bookkeeping for shallow ordinary trees. Deeper
shared graphs can reuse whole subtrees, including nonadjacent repeated children,
without treating identical containers as automatically equal: NaN descendants,
unsupported children and key validation retain their behavior.
Equality keeps its bounded recursive prefix for shallow comparisons and uses
explicit continuations beyond depth 256. Both traversals share scalar equality
and numeric comparison rules, and preserve depth-first Array/Hash order.
Continuations and active-pair tracking use native storage proportional to the
deep traversal. Repeated active comparison pairs record a terminal native
stack error, which the C boundary raises as Ruby's `SystemStackError` after
Rust has unwound; cyclic equality does not execute the VM. Fingerprinting and
schema evaluation retain their separate depth
guards, so this change removes the equality depth limit only.
Each cache retains at most 4,096 results with FIFO eviction and is discarded
before another comparison/hash or Ruby callback. This bounds auxiliary storage;
it does not guarantee polynomial traversal for arbitrary graphs whose reusable
working set exceeds the limit. When the working set fits, the repeated binary
container chain takes O(D) work after a constant four-level prefix instead of
O(2^D). Large branching factors still require scanning their actual edges.
Ordinary deep trees pay table bookkeeping. `benchmark/native/runtime/shared_containers.rb`
covers shared array/hash graphs and an ordinary shallow-tree control.
Known schema key fingerprints are cached once during compilation. Array/object
rule payloads live separately from scalar opcodes to keep instruction storage
compact. No Ruby allocation or callback occurs during these traversals.
Homogeneous arrays select an eligible single record-object instruction once
before scanning their items in a dedicated Rust loop. An immutable
schema-resource frame is shared by
the sibling evaluations, preserving dynamic reference bindings and depth
limits. Nodes requiring annotation tracking retain the general evaluation path.
Array items and record fields whose string rules only constrain length combine
ordinary-instance classification and character-count metadata in one C call.
Character counts read the existing byte length for binary strings and for
UTF-8/US-ASCII strings whose ASCII coderange is already cached. Other strings
use CRuby's existing character-length API. Encoding and coderange are checked
on each call, preserving in-place mutations and encoding changes. This path
creates no byte copy and preserves subclass and unusual-value runtime requests.

Patterns use `regex-automata`, with parsing supplied by `regex-syntax`;
the native backend contains no matching engine of its own. Patterns that must
start at the beginning of the instance use a single immutable forward DFA.
These boolean searches use `LeftmostFirst`: one match suffices, including an
empty or lower-priority alternative. Root and array tests compare priority,
lazy repetition, empty alternatives and Unicode cases with the VM.
The crate's HIR properties determine whether a start anchor is mandatory,
including grouped alternatives. Eager DFA tables are limited to 64 KiB and
auxiliary determinization memory to 256 KiB; larger expressions use
`meta::Regex`. Unanchored patterns also use the meta engine, preserving its
literal search optimizations on long inputs.
The compatibility adapter preserves the VM's absolute `^`/`$` anchors and
explicit `\d`, `\D`, `\w`, `\W`, `\s`, and `\S` character classes.
Control escapes (`\a`, `\f`, `\n`, `\r`, `\t`, `\v`) and explicit
absolute anchors (`\A`, `\z`) are parsed and matched by the crates directly.
Literal Unicode, positive/negative character classes, dot, ordinary capturing
and noncapturing groups, alternation, lazy repetitions, and repetitions within
sequences run natively. Counts are bounded at 4,096 and each compiled NFA and
lazy-DFA cache has a 1 MiB limit. If neither native strategy can compile the
pattern, it delegates to Ruby, preserving invalid-pattern diagnostics. Matching borrows UTF-8/US-ASCII instance bytes;
it never creates a Rust copy of the instance. The meta matcher reuses its internal search caches through `is_match`. Eager DFAs use
`try_search_fwd` with explicit anchored, earliest-match search; both stop once
validity is known. Only anchored start states are compiled for these DFAs.
Single string rules, homogeneous string-array scans, and small-record string
fields combine the ordinary String class check and byte loan in one C adapter
call. The same borrowed slice goes straight to the
crate matcher, without a second metadata query or an instance copy. Length
bounds keep their original precedence, and non-string or subclass instances
retain the existing classification and Ruby runtime behavior.
For array item rules containing only pattern and an optional type, the native
scan selects the crate matcher once for the array. Detailed validation uses
the same scan and generates diagnostics only for invalid elements, preserving
their original indices, prefix offsets, and evaluated-item annotations. Each
element retains its own class and encoding checks; additional string rules
retain the general path.
The C adapter reads CRuby's existing ASCII coderange flag so known ASCII
strings avoid a second UTF-8 scan. Unknown coderanges remain checked in Rust,
and mutations and encoding changes are rechecked on every call. String encoding
metadata uses the public `RB_ENCODING_GET` alias for encoding indices;
extended indices retain CRuby's normal function path. No batch of instance
views or string contents is copied across the boundary. Matcher heap
memory is included in the native program's approximate `ObjectSpace.memsize_of`
report. Lookaround, backreferences, named groups, inline flags, Unicode
properties, class set operations, adjacent repetition operators, invalid input
encodings, and other string encodings request Ruby's regexp behavior through
the C boundary. `pattern` assertions convert `RegexpError` to validation errors
and skip later format/content assertions, while pattern-property routing keeps
the exception. Other encoding exceptions retain their class and message. The
Ruby evaluator, VM and native runtime bridge share the ECMA translation helper.
The same matching behavior handles overlapping
`patternProperties` and their evaluated-property annotations.

Integer schema bounds beyond i128 retain GC-rooted Ruby VALUE handles. Ordinary
Big/Big comparisons use CRuby's public `rb_big_cmp` without exporting digits;
Fixnum inputs are ordered by the wide bound's sign. Float comparisons against
these wide bounds compare the instance with the bound's rounded Float, using
a cached exact ordering when those Float values are equal. Compilation computes
that ordering with temporary fixed 1,024-bit schema metadata; larger bounds
round to Infinity, whose ordering against every finite Integer is known. The
word buffers are discarded, and runtime Float instances use only their scalar
value. NaN and positive/negative Infinity retain VM behavior. This does not
extend the exact decimal arithmetic used for `multipleOf`.

Unresolved `$ref`, `$recursiveRef`, and `$dynamicRef` targets compile to native
failure instructions retaining the resolution message. Validity returns false;
diagnostics preserve the VM's keyword, message and schema location without
executing the VM. A mutable registry can register the missing target later.
Validators with unresolved instructions rebuild their native program when the
schema graph grows, including growth during lazy external-resource indexing.
Resolved validators keep their existing program. Shareable registries continue
to require successful reference resolution before sharing.

Unknown instructions and unsupported internal operands are rejected during
native compilation. A native storage optimization can return an internal
unsupported result to select an ordered runtime request. Numeric assertions on
unusual Numeric objects use staged libruby calls. Null numeric operands execute the original Ruby
comparisons or divisibility methods through libruby after Rust has returned,
preserving Ruby exceptions and operator visibility. Native traversal interleaves
those observations with ordered failures so earlier error limits and diagnostic
path exceptions retain priority. Runtime observations distinguish operation,
source and instance, and are cleared after each invocation.
Required and dependency operands retain a compiled flag for ordinary String
keys. Those keys use the native lookup and property-mask paths. Other operands
use public Ruby `Hash#key?` dispatch through libruby after Rust returns, because
even a key absent from a string-keyed object can invoke a Ruby `hash` method
that raises. This also handles String operands with singleton methods without
executing the VM. Original operand values and duplicates remain available for
ordered diagnostics. Record masks and String fingerprints only receive ordinary
String operands; other keys use the general native object traversal.
Programs containing such runtime keys render diagnostic messages through libruby
at their original evaluation positions as well. This preserves an earlier
message-rendering exception before a later key lookup. Invocation-local message
results and completed reports are GC-marked, and each output error receives an
independent message String. Trials still discard errors without rendering them.
Boolean instructions, empty schemas, references and applicators defer instance
classification until they reach a node that examines the instance. Their native
control flow therefore accepts arbitrary Ruby values, including BasicObject,
builtin subclasses, non-string-keyed Hashes and cyclic containers, whenever the
reached assertions do not need to inspect them. A compiled per-node requirement
distinguishes no inspection, a type predicate, and typed storage access. Its
exhaustive opcode match requires new instruction types to declare that need.
Diagnostic and trial branches retain their full traversal policy: a later
instance-dependent branch still performs its guard even when validity could
have stopped earlier. Same-instance branches share a lazy classification cell,
so the first full guard supplies later siblings without rescanning Hash keys.
This proof lasts only while Rust borrows that instance; runtime retries start
with a fresh cell. A record's shallow class guard is never exported to siblings.
Immediate Integer tags can still supply their kind without Ruby inspection.
Pure boolean children also avoid unnecessary guards in
array, property, contains and small-record traversal. Existing depth and budget
checks continue to apply.
For unsupported Ruby representations, single and union `type` assertions call
shared Ruby type predicates through libruby after Rust unwinds. Their distinct
method-call orders are preserved, including unions containing only one name.
Ruby, VM and native runtime predicates share the same type checks and masks.
A successful Ruby predicate is never treated as proof of native Array, Hash,
String or numeric storage; assertions that read storage still need their own
guard. Dynamic type observations are keyed by reached occurrence as well as
operation and instance. Result memoization and grouped branch execution stop
coalescing calls once such predicates are reached, preserving stateful methods.
Diagnostic prechecks do not execute a dynamic predicate twice. Before invoking
one, an ordered retry also renders earlier messages at their evaluation positions,
preserving message exceptions and side effects before later predicates. Message
observations distinguish output occurrences. Ordinary supported values retain
the native bit-mask and scan paths.
Numeric assertions preserve Ruby applicability, integral checks, decimal conversion
and comparison methods for special instances. Validity uses one Ruby numeric
frame; diagnostic and trial traversal yields between individual assertions so
error limits and message exceptions keep their original priority. VM execution
and native runtime frames share numeric rules and bounded decimal/multiple
caches. Unbounded calls retain their runner's cache; bounded calls use a fresh
cache, matching the VM's invocation-local limited evaluator. Ordinary JSON
numbers keep native arithmetic until a dynamic call requires ordered replay;
that replay also routes earlier numeric assertions through Ruby to preserve
current-invocation cache observations. Pure native calls do not populate Ruby
caches. Successful runtime predicates never authorize native storage access;
mixed schemas route later storage-sensitive assertions through their own runtime
requests when necessary. Numeric runtime frames and results are rooted outside Rust,
and separate Ractors own separate frames and caches.
String assertions on builtin subclasses, singleton-method strings and values
with custom string applicability now use libruby frames as well. Frames retain
the original Ruby length result without converting it to a native size. Length
comparisons, regexp matching, format methods and content conversion therefore
retain their Ruby behavior. VM and native runtime validity share string checks
and regexp compilation. Unbounded frames share the runner's regexp cache;
bounded calls use an invocation-local cache.
Diagnostic and trial traversal yields between reached assertions. RegexpError
rescues retain the VM's complete string-check boundary, including exceptions
from error messages and deferred diagnostic pointers. A failed error-rendering
attempt still reserves an error slot; the rescue handler runs once and its own
exceptions propagate. Ruby deadline checks stay at the original string method
boundaries, with native limits captured once before retries. A transition from
existing runtime operations to occurrence-based scalar frames replays before
servicing the first frame request so earlier scalar calls cannot shift its
identity. Ordinary strings retain borrowed native storage and scalar item
scans; unsupported item views visit the general native scalar evaluator.
Const, enum and uniqueItems keep their native algorithms for supported values.
When a reached comparison or fingerprint needs custom Ruby behavior, they call
shared Ruby value primitives through libruby. These primitives traverse values
and preserve numeric predicates, class checks, collection methods, equality and
hashing; they do not execute schema instructions. Indexed enums bypass native
kind filtering for unsupported roots, retaining schema-order Ruby comparisons.
Uniqueness keeps the VM's linear/indexed threshold and callback order by sharing
its existing implementation. Invocation-local occurrence keys prevent repeated
references or equivalent branches from coalescing stateful equality/hash calls.
Native stack and budget failures remain terminal, rather than requesting Ruby
work after a limit has already failed. VM and native runtime comparison bodies
and limited checkpoints share one module; the Ruby backend retains its distinct
json-kind comparison policy. Ordinary deep equality and indexed uniqueness
remain native, including their existing iterative traversal and resource bounds.
Successful detailed validation builds its public Result in Ruby. Rust now collects ordered
diagnostics for supported scalar rules, arrays, ordinary objects, combiners,
conditionals, and references. Object errors follow input Hash order; required
errors preserve schema order. It preserves instance and schema paths, including nested array
indices and reference keywords. The traversal allocates no Ruby objects and
never serializes the instance. A GC-marked native report holds the original
VALUE handles while C creates output records after Rust has returned; thin Ruby
rendering uses the existing shared error-message functions. Dependencies preserve
schema order across required-key and schema dependencies. Evaluated-location
diagnostics retain local attempted items/properties even when child validation
fails, discard failed applicator annotations, and merge successful trial
annotations before checking unevaluated locations. Native-only tests compare
all 385 official unevaluated-location cases against the VM's complete errors.
Exact `Symbol` and ordinary `Object` instances with their standard methods are
native scalars outside the JSON type masks: they match no JSON type, and assertions for other types do not
apply. Structural equality and `uniqueItems` compare their identities, with
invocation-local fingerprints derived from the original handles. Instance
variables do not participate in that comparison. Method-definition metadata is
checked through libruby after Rust returns, because callable-method lookup may
allocate. That observation lasts only for the current invocation; class-wide
changes to type, equality or hash methods request Ruby predicates/value primitives
or Ruby traversal helpers for container operations. The active
runner is selected through thread-local C state only while Rust evaluates,
keeping recursive C entry and separate Ractors isolated. Ordinary JSON values
need no method-definition request. These inputs can be nested in
ordinary arrays and string-keyed Hashes; schema operands must still be JSON-shaped.
Applicator trials share the native diagnostic traversal with error recording and
path construction disabled. Like the VM, they finish scalar assertions even after
an earlier failure, but short-circuit ordinary container children. This preserves
later scalar exceptions without introducing a separate trial interpreter;
single-assertion scalar rules retain direct native checks. Trials export only
successful annotations and do not consume diagnostic error limits.
Container validity successes do not bypass diagnostic collection: descendants
can still raise during complete diagnostic trials. Only proven scalar checks
and cached complete diagnostic successes skip that traversal.
Container assertions without child-schema traversal use libruby frames when
their applicability, length or comparison methods require Ruby behavior. This
covers minItems/maxItems, minProperties/maxProperties, uniqueItems and the
empty tuple gate, including Array/Hash subclasses and singleton methods.
Object assertions with required keys and no child-schema operations also use
these frames for special inputs. Required validity shares its ordered key
checks with the VM; diagnostics yield after each key and render each missing
key before attempting the next. Duplicate names retain distinct calls.
Malformed required operands retain their Ruby iteration or method errors,
without borrowing Array storage from non-array values. Generated Hash iteration
pairs remain rooted through message rendering, and ordinary supported Hashes
keep native required-key lookup, including identity Hashes.
Property-list dependencies without child schemas follow the same split:
ordinary Hashes use native lookup, while special inputs use libruby for
dependency triggers and required keys. Validity shares the VM's key-loop
primitives. Diagnostics preserve each trigger call, skip absent triggers,
render duplicate failures separately and yield before later key checks.
Malformed dependentRequired values retain Ruby iteration/method errors when
their trigger is present. Generated diagnostic keys remain rooted through
compaction and frames remain isolated between Ractor runners.
Bounds validity shares its comparison rules with the VM; diagnostics retain
fresh length reads for each assertion and message. Object diagnostics also
retain the original Hash iteration and property lookup, even without child
schemas. Frames preserve exception ordering, trial short circuits and error
limits, and remain rooted during GC and private to each Ractor runner.
Ordinary supported containers retain native size and uniqueness algorithms.
Object validity with only count assertions needs no key scan because only its size is read.
Array and Object validity can call native children from Ruby indexed traversal,
any?/count and each/each_key methods when no unevaluated-location traversal is
required. Shared Ruby helpers preserve item/property selection, length snapshots,
indexing, pattern matching, key names and dependency order. Native children are selected by compiled
Program identity; Ruby never reads their instruction streams. The compiler proof
admits scalar assertions, empty schemas, logical applicators and Array/Object
child traversal, including nested contains. Static, dynamic and recursive
references are admitted when every possible target has an execution path and
needs no exported annotations, including cycles and recursive input graphs.
One shared dispatch vertex per anchor name, plus one for recursive resources,
keeps binding edges shared. Reverse-edge propagation marks every ancestor of
an unsupported instruction or annotation demand and every root that can reach
container callbacks. This linear proof handles cycles without assuming a
finite schema path depth. It shares flag propagation with memoization analysis.
The whole-root proof requires every reachable instruction to have a runtime
path. Unsupported internal instructions are rejected during compilation; the
graph guard remains a defensive check before user callbacks can run. Earlier type predicates join ordered
runtime observations before the first callback can mutate their instance.
After Rust unwinds, C creates the callback. Boolean and type children dispatch
in C, sharing the ordinary runtime type helper without allocating per-yield
observations. Other children reuse a runner with separate observations for
each yield and a fresh runner on reentry. Bounded child entries, reached
instructions and oneOf branches request Ruby checkpoints in evaluation order;
unbounded children skip these requests. Shared Ruby scalar primitives
preserve method dispatch even for ordinary yielded values.

Untracked validity suspends at a native stack depth of 256, before entering the
next schema node. After all Rust frames and borrowed views unwind, C starts a
fresh native runner for that node and instance and records its verdict as a
runtime observation. Parent traversal resumes by replaying that observation.
Container callbacks also start at native depth zero. These boundaries bound
physical Rust recursion while preserving logical references through the shared
active-source and resource context, including across long alias cycles.
Continuation runners inherit the original absolute deadline, scalar/regexp
state and callback execution mode. Ordinary validity continuations keep native
budget polling; continuations within Ruby iteration blocks preserve those
blocks' Ruby checkpoint boundaries. No extra schema-entry checkpoint is emitted
before suspending. Saved callbacks retain their original cache/budget scope and
start a fresh native stack when called later.

Detailed collection now has an owned report continuation protocol as well. Its
snapshot includes both pointer prefixes, prior errors, reserved-error count,
limits and silent/annotation policy. C starts another native collector only
after Rust unwinds, and roots the seed and completed report as TypedData.
Parent replay adopts the complete report and its independent verdict/location
buffers together. Error counts alone never stand in for the child's verdict.
Public top-level reports discard returned location buffers after consumption;
only internal results retain them for their parent. Report marking includes
unrendered pointer names and location keys, and memory reporting includes the
owned buffers.
The initial detailed admission covers scalar assertions, container headers,
logical applicators and resolved references, including long circuits. Roots
reaching other container traversals retain their guard before new native report
calls can expose Ruby side effects. Full container diagnostic and annotation
callbacks remain separate cases. Owned prefix/error snapshots add cold-path
copying and storage; substantially larger deep error workloads may need a
shared error log or result deltas.
Callback scopes use an evaluator-owned live Ruby resource Array. Before each
Ruby request, native execution publishes an owned scope snapshot after Rust
unwinds. Changed scope contents are recorded with the request and replayed with
its cached result, so public reentry can clear scopes without restoring stale
bindings. Child callbacks inherit the Array's current contents, including when
saved blocks run under another resource or after native program refresh.
Bounded invocations own separate Arrays. Pending native scope-entry counts let
C unwind the live Array when a Ruby request raises. Completed native calls
publish their final scope contents. Reference context is enabled conservatively
for programs containing references, including scalar and diagnostic paths:
Ruby primitive methods can reenter saved schema blocks without any container
callback. Programs without references skip context tracking. Publishing compares
identity values first and avoids allocating a Ruby Array when contents match.

Callbacks also inherit active reference guards by compiled Program identity and
instance identity. Native stack guards are copied before a Ruby request and
published as a flat Ruby Array; callback completion restores its incoming
native guards even when Ruby raises. The remaining VM evaluator shares its
identity Hashes with native readers and consults the native guard Array before
entering a reference. Native never replaces VM identity Hashes or their entries,
so VM ensure cleanup retains ownership of its guards. Bounded invocations keep
private state. Both static and dynamic references need this bridge: user methods
can invoke a saved block for the same reference and instance even when the
compiled schema graph is acyclic. Stack records are borrowed only within native
frames and copied before unwinding; no Rust stack pointer crosses into Ruby.
Original dynamic names survive invariant-target simplification for callback
scope polling. Scoped lookup walks outer to inner and shares binding predicates
with the ordinary native lookup, while issuing the VM's per-resource checkpoints.
The original Ruby method can rescue child exceptions and run ensure clauses.
Children use the VM's scalar checkpoints, while the parent retains its native
invocation deadline and polls it after successful scalar yields. A callback
scope shares the owning evaluator's caches;
bounded calls own private caches. Retained blocks keep their original scope
and limited-evaluator budget-clearing behavior through GC compaction.
Reentrant calls use independent observations and cleanup. Invocation observations
are cleared through one ensure boundary, with persistent scalar caches retained.
Array diagnostics and trials use indexed Ruby traversal with owned native
report collectors. The collector transfers error reservations, paths and
annotations to native child runners while Ruby retains its length, indexing,
range and contains iteration behavior. VM and native frames share that Array
iteration helper. Object reports now use the same owned collector boundary and
share their property, pattern, name, dependency and unevaluated traversal with
the VM. Both container callback graphs require every reachable report operation
to have a native path before any user callback runs.
Retained native validity blocks inherit the current native report collection
when they reach a tracked schema, including through references. Suspended
runtime requests snapshot that collection before path scopes unwind. Their
completed error effects are replayed with the corresponding runtime observation,
so nested scalar calls preserve error order and trial isolation. Public reentry
can clear a collection; replay preserves that reset and the VM's path cleanup
behavior. Trial contexts restore their caller's collection, and bounded public
invocations keep independent state. Interrupted child and Array frames transfer
already collected errors when a Ruby caller rescues their exception.
Ruby container traversal shares the VM's data-only evaluation pool. A buffer
retains both its property and item Sets, including when an older Object block
runs after the same slot has been reused by an Array. Native results retain
opaque buffer handles; merges call the shared buffer's merge method after Rust
unwinds, preserving receiver identity and key hash/equality behavior. Native
code never borrows those Ruby sets or caches their cardinality for scan elision.
Ordinary invocations without exposed Ruby buffers keep their native location
bitsets. Once a validator has used the shared pool, later public invocations
start with ordered container traversal so buffer acquisition order stays the
same. Bounded invocations own independent pools. Owned export snapshots root
native property handles across Ruby allocation and compaction.
Retained Object iterator blocks follow the active collection while preserving
their original program and budget owner. Silent failures still affect the
current trial's verdict even when a Ruby caller rescues a retained block's
nonlocal return or a later primitive exception. Silent children share the active
failure collection; only explicit trials isolate it. Validity and diagnostic
entrypoints share graph admission, including validity children reached from
silent diagnostic trials beyond the native physical stack bound.
Object pattern matching uses the shared Ruby regexp cache and deadline wrapper.
Frames read the invocation's current budget when retained each blocks run, so
limited blocks observe the VM's cleared budget after the public call returns.
The native evaluator owns unbounded number/regexp state. Alternating validity
and detailed validation, or recompiling after reference registration, retains
the same Ruby conversion/cache observations.
The default Ruby evaluator keeps its own traversal policy. Native arithmetic
and Ruby diagnostic callbacks remain separate because their observable reads
and iteration requirements differ.
Unresolved reference children use native failure and diagnostic paths, including
special containers and native continuations. Later registry additions rebuild
the native program before execution. Unsupported internal operands/instructions
are rejected before a native program is published. Object report callbacks export
evaluated property sets through owned results. Tracked or detailed continuations
require every reachable operation to have a native report path;
defensive graph guards continue to reject unsupported instructions.
Lookup-based paths check
every key without invoking Ruby methods, keeping Ruby's hash/equality callbacks
outside Rust evaluation. Small records with up to eight declared keys and eight
input entries combine this check with a single Hash walk. C passes only borrowed
VALUE handles through a fixed stack buffer. C initializes only the returned
key/value pairs; Rust borrows that written prefix and never reads the unused
tail or a buffer returned with an error.

When available, this stack-buffer walk uses CRuby's exported internal
`rb_hash_stlike_foreach` symbol, detected by mkmf at build time. Its C callback
only reads keys and values under the GVL: it does not allocate, mutate the Hash,
invoke Ruby, or call Rust. This restriction lets it omit iteration-level and
exception-cleanup bookkeeping. The same optional walk checks ordinary Hash
key classes before general native lookups, with an equally restricted C-only
callback. Walks that invoke Rust retain their existing APIs.
If the symbol is unavailable, it uses public `rb_hash_foreach`. To explicitly
build that fallback in a checkout, run `ruby extconf.rb --enable-portable-hash-walk`
followed by `make clean` and `make` in the extension directory. The internal
symbol's ABI is less stable than Ruby's public extension API; CI covers both
build modes.

On CRuby 4.0, the default build additionally checks the internal storage
flag in a fresh embedded interpreter, using ordinary, frozen and identity
Hashes of sizes zero through eight. Only a successful check enables the
small-record hint: an AR-table Hash has ordinary key semantics, so Rust can
omit the distinct-schema-key lookup. C reads the public object flags without
dereferencing a private table, and tags that proof separately from the number
of initialized handle pairs. Identity Hashes and ordinary ST-table Hashes keep
the existing lookup. The proof follows CRuby's
[3.4 implementation](https://github.com/ruby/ruby/blob/v3_4_7/hash.c) and
[4.0 implementation](https://github.com/ruby/ruby/blob/v4.0.6/hash.c), rather than
the behavior of an overridable Ruby predicate. Other API versions, cross builds,
failed checks and `--enable-portable-hash-walk` retain the original path. This
is another version-limited use of CRuby internals, not a public storage ABI.

Rust tests required-key bits and
precompiled integer bounds and string-length checks directly. Simple field
checks are selected once during compilation, avoiding repeated child-opcode
and rule classification on each record. No Ruby Hash, String, or numeric value is
converted into a Rust representation. Distinct schema lookup keys are retained
at compilation to distinguish identity-key Hashes; ambiguous matching keys
use Ruby key lookup. Larger records and annotation
rules use the general native path. Schema lookup keys are checked at compilation
as well. Unusual leaves use Ruby runtime helpers, while unusual path encodings
use the shared Ruby JSON Pointer escaping helper. Arrays scan supported scalar items first and
only construct diagnostic paths for failing items.
Detailed validation uses the native diagnostic traversal directly instead of a
separate validity pass. Fully covered containers skip unevaluated scans. Object
diagnostics use compiled native property lookup tables to avoid scanning every
schema property for each input key.
Compiler roots live in a separate native allocation, so GC marking during Ruby
reference-resolution callbacks does not borrow the mutable compiler state.
Memory-size callbacks also avoid that state while compilation is in progress.
Reentrant evaluation during compilation raises an error; failed compilation
releases its roots and permits initialization to retry.
Shared registries retain immutable Ruby programs; each Ractor
constructs and owns its native evaluator independently.

This is an implementation milestone, not the completed native VM. The remaining
work is to move those delegated operations and detailed error evaluation into
Rust, strengthen boundary safety for allocating native helpers, and meet the
10x YJIT target across the representative workloads. The differential test
checks both `valid?` and `validate` for the complete selected catalog, but VM
delegation means conformance alone does not establish complete native coverage.
Running the full 6,522-example suite with native as the default currently has
two failures also reproduced with VM: an invalid type name raises during
compilation, and a Numeric subclass with only a decimal string representation
raises during bound comparison. Those tests describe Ruby-backend behavior;
native retains the VM behavior. The suite also has 1,287 pending cases, so
this result does not claim support for the entire official optional catalog.
See `benchmark/native/runtime/comparison.rb` for performance and allocation measurements that
include valid and invalid instances and delegated operations.

Public-behavior regressions found during native development are shared through
`spec/support/backend_regressions.rb`. The ordinary RSpec suite runs them with
Ruby and VM; `test/evaluator_backend_test.rb` runs the same examples for its
selected backend, including both native build modes in CI. The examples cover
applicator multiplicity and required flags, intermediate Base64 padding,
seeded JSON/Base64 and pattern mutations, integer equality and bound endpoints,
key encoding, annotation diagnostics, mutable inputs and recursive scope.
Differential assertions compare validity and every detailed error field.
An explicit compatibility example records the existing Float/Integer bound
comparison difference: Ruby uses decimal spelling, whereas VM/native use the
ordinary numeric comparison. It is not treated as shared equality.
Native-specific checks for allocation, fallback and GC safety remain in
`test/native_backend_test.rb`.

The shared set has 14 regression examples per backend. Local Ruby 4.0.6 checks
passed the default suite (6,550 examples, zero failures, 1,287 pending), VM
differential suite (17 examples), and native/differential suite in both default
and portable builds (132 examples each). The portable extension was installed
separately and its loaded location asserted. The two seeded mutation examples
also have the `fuzz` tag for focused runs.

```sh
bundle exec rspec spec/backend_regressions_spec.rb
bundle exec rspec spec/backend_regressions_spec.rb --tag fuzz
SCHEMURAI_DIFFERENTIAL_BACKEND=native bundle exec rspec \
  -Iext/schemurai_native test/evaluator_backend_test.rb
```
