# Native VALUE ownership and safety

The native evaluator borrows CRuby objects. It does not decode the instance
into a Rust object graph. A `Value` is an opaque handle, not a GC root, an owned
Ruby object, or permission to access another Ractor's objects.

## Ownership

| Storage | Owner and reachability | Mutation and sharing |
| --- | --- | --- |
| Compiled instructions and metadata (`Engine`) | C `holder` owns the engine and a separate `Roots` allocation. `Engine::retain` registers compilation operands and callback results there. Programs and their reachable operands remain rooted. | Compilation requires exclusive engine access. Published instructions are immutable. |
| Temporary instance handles and views | The C evaluation frame keeps the instance and program owner alive with Ruby references and `RB_GC_GUARD`. Descendants remain reachable through those objects. | Borrow only during native execution under the GVL, while the input is unchanged. |
| Observations, pending operations, scope snapshots and reports (`Caches`) | C `runner_holder` owns caches, an immutable root snapshot for suspended passes, and Ruby roots for inherited seeds and completed runtime results. | Each validator/Ractor owns its runner. The runner cannot be made shareable. |
| Exported reports and property locations | C TypedData owns each allocation, invokes its mark callback and frees it exactly once. | Mutable report collection uses immutable seeds/results as backup roots while native code holds exclusive access. |

`Roots` is separate from `Engine` because compilation can call Ruby while Rust
holds `&mut Engine`. The GC callback must not manufacture `&Engine` during that
exclusive borrow. Root-vector mutation must end before calling allocating Ruby
adapters. The root callback takes only the separate allocation.

All marks use `rb_gc_mark`, through `sn_pin`. Handles are pinned rather than
updated after compaction: the extension has no compact callback and Rust stores
VALUEs in vectors and identity indexes. Switching to movable marking would
require updating every stored handle and rebuilding address-based indexes.

## Native execution and Ruby callbacks

String, Array and Hash views point into CRuby storage. Rust allocation is
allowed while those views are live; Ruby allocation, mutation and callbacks are
not. Evaluation adapters inspect data or perform lookup in already prepared
identity tables. A required Ruby operation records a request and returns to C.
C executes Ruby only after the native frames and their views have unwound, roots
the completed result, and then resumes evaluation.

Compilation's allocating adapters (`sn_field`, `sn_pairs`, `sn_key_copy`,
`sn_resolve`, `sn_resolution_error`, `sn_resource_program`, `sn_anchor_names`,
`sn_anchor_program`) use
`rb_protect`. Exceptions become status codes and rooted exception handles, so
Ruby longjmp does not cross Rust frames. Rust FFI entrypoints contain panics.
C uses `rb_ensure` to restore runner and callback state on Ruby unwinding.

The boundary AST check permits allocating adapters only in methods with
`&mut Engine`. Evaluation has shared engine access. A per-invocation `Ruby` token is created only at audited C entrypoints.
Borrowed byte/Array slices borrow `&Ruby`; their lifetime cannot outlast that
token. Protected allocating adapters are private imports exposed as methods
requiring `&mut Ruby`. The compiler rejects a callback while a slice loan is
still used, and evaluation receives only `&Ruby` through `Execution`.
Compiler helpers explicitly pass `&mut Ruby`; they cannot acquire exclusive
access while one of their views remains live. Small Hash snapshots copied into
a Rust buffer instead borrow that buffer through `initialized_values`.

The AST check also rejects token creation outside those entrypoints, direct
Rust reentry into them, and raw slice constructors outside the boundary module.
This prevents introducing a fresh token or an unbounded slice helper to bypass
the borrow checks. The C checker described below checks adapter effects and ownership structure.
The reviewed CRuby leaf API contracts remain a trusted part of the boundary.

## GC while another Ractor is stopped

A stopped native pass can hold a `RefCell` borrow. Marking must neither panic
on a borrow conflict nor read through an active mutable reference.
`trace_runner_fields!` therefore uses `try_borrow` for explicitly classified
runner fields. Before a suspended pass calls Ruby, C captures a complete,
immutable `RootSnapshot`. Complete traversal fails rather than omitting a
borrowed field. The snapshot owns only copied handles and is marked independently
of the mutable caches. It preserves handles even if a callback removes their
last reference from the input or clears the cache that originally held them.

On reentry, the prior snapshot retains handles from earlier passes. New native
observations refer to the current input/schema or to completed callback results
rooted in C before publication. A subsequent suspension replaces the snapshot
only after the replacement is complete. Cleanup clears caches before freeing
their snapshot. Snapshot storage is private, immutable and neither `Send` nor
`Sync`; the C owner accounts for and frees it explicitly.

Runtime location accessors may return fresh sets. C therefore roots the buffer,
properties and items individually, rather than assuming the buffer retains the
other two objects. Report collectors retain these roots while their mutable
native report is unavailable to marking.

This fallback is allowed only for the audited runner structures, not arbitrary
`RefCell<T>`. Live reference-frame pointers refer to native stack frames and
must not be followed by the GC visitor. Their program and instance handles
are also reachable from the C-owned registry and input. The opaque C runtime
lookup pointer similarly borrows C-owned state.

## Ractor publication

`make_shareable` first calls `ready_program`, which rejects an uninitialized or
still-compiling engine. It makes each hidden root and the program shareable
before making the frozen Program TypedData shareable. Only that TypedData has
`RUBY_TYPED_FROZEN_SHAREABLE`; runners, reports and collectors do not.
An allocated Program also retains a hidden TypedData guard without that flag.
The guard prevents the generic `Ractor.make_shareable` API from publishing a
Program during a compiler callback. Only successful initialization removes it;
failure retains it. Once ready, generic publication traverses all hidden roots
through the mark callback and freezes their reachable objects as well.

In Rust, `Value` has a transparent machine-word layout and a zero-sized
`PhantomData<Rc<()>>` affinity marker. It is `Copy` but neither `Send` nor `Sync`.
This property propagates through containers and native objects holding handles.
Runtime pointer caches consequently use `Rc`, not `Arc`. The shared immutable
engine is published through the audited C/Ruby protocol; there is no Rust
`unsafe impl Send` or `Sync` to grant general access to arbitrary handles.

## Compiler and static checks

`src/ruby.rs` contains the handle representation and imported C adapters.
`src/ruby_trace.rs` contains independent traversal traits and field macros.
They do not depend on schema evaluation rules. This boundary allows a later
extraction of common handle/tracing code into a crate, leaving the
Schemurai-specific adapters and owner protocol in the extension.

`trace_fields!` destructures every field without `..`. Adding a field fails
compilation until it is classified. Traced fields must implement `Trace`;
non-traced fields must implement `NativeOnly`, which has no implementation for
`Value`, including nested VALUE containers. `native_fields!` applies the same
exhaustive check to native-only aggregates. Enum and tuple implementations use
exhaustive patterns. The compiler checks roots, reports, paths, property
locations and all runner snapshots with this scheme.

The header-verified immediate-integer tag has its own `FixnumTag` type. It is
native metadata, distinct from both Ruby handles and traversal depths, so the
compiler rejects swapping the tag and depth when forwarding fingerprint calls.

`tests/ruby_contract.rs` compiles positive and negative fixtures with `rustc`.
It checks integer/handle separation, private representation, `Send`/`Sync`
rejection, omitted fields and Ruby handles hidden in native-only fields. It also
checks snapshot encapsulation and thread affinity. Runtime unit tests check
complete traversal, borrow conflicts and retention after the source is cleared.
The compile fixtures also check that byte/Array/buffer loans cannot escape, allocating adapters cannot
overlap a live loan, evaluation cannot call them through a shared token, and
the raw allocating imports are private.
`tests/ruby_boundary.rs` parses production Rust with `syn` and rejects new
foreign declaration sites, VALUE aliases, affinity overrides, direct pinning,
raw bit reconstruction, unreviewed manual tracing implementations, Rust
thread-local state, and use of the runner fallback outside its audited owners.
Both run under the existing CI `cargo test --locked` gate.

`protected.def` is the common inventory of protected adapters and their C
callbacks. The Rust AST check requires private raw imports and unsafe methods
with mutable token receivers for this inventory. The C check requires every
listed adapter to return through the common `protected_result` exception
barrier. Exception classification is included: constant lookup may invoke
Ruby (including `const_missing`/autoload), so it cannot be an unprotected leaf.
The compiler temporarily roots an exception while classifying it and extracting
its message, and removes that temporary root before publishing the Program.

`script/native_safety/check.rb` parses Clang's expanded, typed C AST. Run it
with Clang and the Ruby used to build the extension. Its checks cover:

- The transitive call graph of every other Rust-imported adapter, including
  functions passed as callbacks and effects introduced by C macros. Unknown
  external calls and indirect calls fail until explicitly reviewed.
- The exception barrier's capture/clear/return control flow.
- Every TypedData VALUE field, every opaque Rust root, the ST-table key-marking
  callbacks, callback registration and the shareability flags.
- The order of hidden-root publication, and rejection of unfinished Programs.
- The intrinsically unshareable construction guard and its success-only removal.
- Complete suspended-pass snapshot capture, replacement and cleanup order,
  independent marking, destruction and memory accounting.
- The inventory of C globals; metadata tables cannot gain Ruby object fields.
- Root writes immediately preceding message, pointer, property and report
  result publication into Rust. Report pointers must come from the rooted
  TypedData result; every handle copied from runtime locations is rooted.

CI checks both portable and optimized Hash walks. `test/native_safety_test.rb`
compiles independent negative C fixtures to check rejection of hidden allocation,
unreviewed indirect calls, missing mark fields, incorrect publication order,
shareable mutable state, premature construction-guard removal, snapshot lifetime
violations, and publication without a preceding C root write. Ruby subprocess
tests exercise input mutation during suspended pointer callbacks, compacting GC,
independent Ractors and generic publication during compilation.

The checks prove these restricted contracts under explicit boundary assumptions;
they are not a proof of arbitrary unsafe Rust or C. The Rust AST check does not
expand arbitrary macros. The Clang check sees macro expansion but trusts the
listed CRuby leaf APIs for their documented operand domains (ordinary strings,
integers and identity tables), C stack/GC guards, and initialization of unsafe
loan inputs. It does not infer arbitrary Ruby object reachability or track
arbitrary mutations of inputs across Ruby callbacks. The current protocol uses
complete snapshots and explicit C result roots to preserve handles across those
callbacks. A standalone safe API would still need to encapsulate the C owner,
GVL, operand-domain and publication obligations rather than exporting the unsafe
FFI entrypoints as safe general-purpose operations.
