# MIMIC

A local-first compatibility laboratory for AI CLI HTTP protocols, written in
Gleam on the BEAM. Captures, wire profiles, structured diffs, replay, deterministic
upstreams, and gated pipelines are tools for testing software and endpoints you
are authorized to operate.

The product requirements live in [SLICES.md](SLICES.md),
[DESIGN.md](DESIGN.md), [WORKSHOP.md](WORKSHOP.md), and
[AUTOPILOT.md](AUTOPILOT.md). Those are design documents, **not claims of measured
compatibility with a provider**. Synthetic fixtures are not native-client captures.

## Requirements

- Gleam **1.18+**, Erlang/OTP **28+**, and Rebar3.
- `b3sum` (BLAKE3) and `zstd` for corpus persistence. No fallback hash or
  mislabeled compression is used.
- `openssl` for local recording certificates and TLS tests.
- Docker for sandboxed drives. A temporary working directory is not a sandbox.

Install tools through your normal package manager. `b3sum` can also be installed
with `cargo install b3sum --locked`. The repository never changes your system
certificate trust store.

```sh
gleam deps download
gleam test
gleam run -- help
gleam run -- doctor
```

To exercise the local corpus → persona → replay → lab path without credentials:

```sh
gleam run -- demo .mimic/demo-corpus
```

This starts a loopback lab on an ephemeral port, stores and deduplicates a
**synthetic** request, drafts and lints a persona, replays the request, prints a
JSON report, and stops the lab. It does not contact a provider.

The synthetic Workshop adapter exercises a complete local PB pipeline:

```sh
gleam run -- workshop lab-bump .mimic/workshop demo-trivial trivial
gleam run -- workshop lab-bump .mimic/workshop demo-breaking breaking
```

Use a new run ID each time. The first command records actual loopback requests,
computes drift, drafts and lints a candidate, runs a local oracle and three
canary requests, and promotes **only to the `synthetic-lab` registry**. The second
deliberately makes the lab reject the baseline: it must stop without promotion.
Neither command acquires a native CLI binary or validates a production SLO.

The checked-in `./mimic` launcher invokes `gleam run` and also recognizes a local,
ignored `.tools/` toolchain. All commands can instead be run with
`gleam run -- <command>`. Run a feature command without arguments to see its
specific usage.

## Commands

| Track | Commands | Purpose |
|---|---|---|
| A | `record`, `corpus`, `diff` | Redacted recording, deduplicated storage, structured drift |
| B | `persona`, `replay` | TOML wire profiles, validation, drafts, ordered HTTP/1.1 |
| C | `lab`, `check` | Deterministic upstream, acceptance and latency checks |
| D | `auth`, `fleet`, `fleet quotas`, `serve` | Credentials, scheduling, quota accounting, API ingress |
| E | Library under `mimic/dialect` | Anthropic/OpenAI translation and incremental SSE |
| F | `drive`, `watch`, `workshop` | Sandboxed scenarios, version events, durable gated pipelines |
| G | `autopilot` | Schema-constrained local inference and evidence-checked proposals |
| H | `metrics`, `management` | Redaction, observability, authenticated control API and panel |

Feature-specific contracts, examples, and limitations are documented under
[`docs/`](docs/). Examples under [`examples/`](examples/) are synthetic and contain
no usable provider credentials.

The [implementation ledger](docs/IMPLEMENTATION.md) maps every requested slice
to the available code and its outstanding gates. In particular, production
Workshop adapters, real-client captures, real OAuth, transport fingerprints,
and performance targets are not implied by the local demonstrations.
The [validation report](docs/VALIDATION.md) records the final 179-test runs,
CLI/shipment checks, browser QA, and the limits of that evidence.

## Architecture and invariants

`mimic/types.gleam` defines a shared wire model. Header lists preserve **order,
case, and duplicates**; they are not converted to a dictionary. Bodies in the
initial wire path are UTF-8 JSON/SSE. Unsupported encodings and protocols must
fail explicitly rather than produce a misleading capture or replay.

Gleam owns domain logic. Namespaced Erlang FFI modules provide sockets, crypto,
process execution, and filesystem operations. External executables are launched
with argument vectors, not interpolated shell commands.

- Services bind loopback by default; API and management access require keys.
- Captures are redacted before hashing and persistence. Credentials are never
  model grounding data or metric labels.
- TLS upstream verification remains enabled. An interception CA is scoped to the
  QA client, never installed system-wide.
- Unknown transport fingerprints remain unknown. HTTP/1.1 fidelity does not
  imply ClientHello, JA4, HTTP/2 SETTINGS, or HPACK fidelity.
- Workshop controls ordering, budgets, human gates, and promotion. Model output
  is a proposal, never proof that lint/oracle/canary passed.
- Adding a persona through management creates a validated draft, not an active
  profile. Activation uses Workshop's gated promotion; the control API cannot
  bypass oracle, canary, or approval by writing an active pointer directly.
- Live endpoints, test accounts, installed native CLIs, and local inference
  servers must be explicitly supplied by the operator. The default tests do not
  consume provider credits.

R1 (Rust egress impersonation) is conditional on a lab demonstrating transport
sensitivity. R2 (SIMD corpus parsing) is conditional on a measured parsing
bottleneck. Neither should be introduced merely to populate the roadmap.

## Development and release

```sh
gleam format --check src test
gleam test
gleam export erlang-shipment
```

The shipment includes the BEAM application and vendored static assets. It still
needs an Erlang runtime and the external tools required by the commands you use.
CI runs format, tests, the environment diagnostic, and shipment creation on
Linux. Local state, downloaded development tools, and build output are ignored.

See [AGENTS.md](AGENTS.md) for contribution boundaries and safety invariants.
Licensed under [MIT](LICENSE).
