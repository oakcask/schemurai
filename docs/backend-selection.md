# Backend selection

`Schemurai.backend` reports the selected backend. Validators and schema
registries expose the backend captured when they were created.

The `backend:` keyword and `SCHEMURAI_BACKEND` accept `ruby`, `vm`, or
`default`. The production default is explicitly `ruby`. The `vm` backend is a
native extension: it compiles schema nodes into immutable C instruction and
rule structures, then executes them in the native evaluator. Validators from
the same VM registry reuse those programs. Both backends retain the same Ruby
schema graph and public result objects; format callbacks and detailed error
messages also remain Ruby integration boundaries.

Installing Schemurai therefore requires the normal Ruby native-extension build
toolchain even when the Ruby backend is selected. The Ruby backend remains the
compatibility oracle, including a cold fallback used by the VM for the explicit
out-of-domain instance cases documented in `compatibility-domain.md`.
