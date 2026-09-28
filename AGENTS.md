# Implementation rules

MIMIC is a Gleam/BEAM application. See SLICES.md for scope, WORKSHOP.md for
pipeline gates, AUTOPILOT.md for constrained model roles. These documents are
requirements, not evidence that upstream behavior has been measured.

- Keep orchestration and domain logic in Gleam. Small Erlang FFI modules may
  provide OS, crypto, sockets, and atomic filesystem primitives.
- Do not fabricate captures, measured profiles, successful external validation,
  TLS fingerprints, or benchmark results. Mark fixtures as synthetic.
- All services bind loopback by default. Never persist credential values in
  captures, logs, metrics, or model grounding packs. Explicitly configured,
  operator-owned endpoints only; no live upstream tests by default.
- Unsupported protocols must fail explicitly rather than silently lose fidelity.
- No shell command concatenation with user input. Use argument vectors.
- Use `apply_patch` to edit source. Do not edit another parallel worker's files.
- Test with `gleam test`, format with `gleam format`, and document unverified gates.
- `.jj` is present: no mutating Git commands. Do not commit during parallel work.

## Shared contracts

`mimic/types.gleam` owns wire types. Header lists preserve order, duplicates, and
case. Bodies are UTF-8 JSON/SSE strings in the initial HTTP/1.1 path; reject
unsupported binary encodings rather than corrupting them. All `Result` errors at
module boundaries use `String` unless a domain-specific public error is needed.
Times are integer milliseconds unless a field explicitly says seconds.

The parent owns `src/mimic.gleam`, `src/mimic/types.gleam`, root build files,
README, CI, and integration tests. Workers own their assigned namespaces and
test files. Provide a `cli(args: List(String)) -> Result(String, String)` in each
top-level feature module so the parent can wire the CLI without coupling internals.
Commands that run a server may block until shutdown. Never exit the VM in feature
modules.

Namespaces:
- A: `mimic/corpus`, `mimic/recorder`, `mimic/differ`, `mimic/wire`
- B: `mimic/persona`, `mimic/replay`
- C/D4: `mimic/lab`, `mimic/check`, `mimic/ingress`
- D1-D3: `mimic/auth`, `mimic/fleet`, `mimic/quota`
- E: `mimic/ir`, `mimic/dialect`
- F: `mimic/drive`, `mimic/watch`, `mimic/workshop`
- G: `mimic/autopilot`
- H: `mimic/observability`, `mimic/management`

Top-level feature modules may have corresponding subdirectories. FFI filenames
must be namespaced (e.g. `mimic_corpus_ffi.erl`). Each worker should add tests
named `<feature>_test.gleam`. Runtime data belongs under an explicit state dir,
not the source tree; examples under `examples/` must contain no real secrets.
