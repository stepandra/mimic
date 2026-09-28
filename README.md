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
The [original validation report](docs/VALIDATION.md) records the initial
179-test runs, CLI/shipment checks, browser QA, and the limits of that evidence.
Provider integration and its current limitations are tracked separately in
[docs/PROVIDER_INTEGRATION.md](docs/PROVIDER_INTEGRATION.md). Historical
per-thread test totals must not be added together or presented as one build.
The [combined validation report](docs/INTEGRATION_VALIDATION.md) records the
assembled 463-test gate, CLI/shipment workflows and remaining conformance gaps.

## Provider gateway

The provider gateway is an explicit, separate mode; the original `serve` and
`serve managed` paths remain available for existing local laboratory workflows.

```sh
gleam run -- serve providers /absolute/path/to/providers.json
gleam run -- providers
```

The gateway uses the configured account/model registry and runtime-owned
credentials. It does not discover accounts, contact provider endpoints at
startup, or silently fall back to an arbitrary OpenAI-compatible service.
Keep the state directory private, provision credentials separately from the
secret-free configuration, and supply only endpoints you own or are authorized
to use. Never put tokens in command arguments, checked-in configuration, logs
or conformance reports.

The assembled code includes the shared Responses protocol, provider runtime,
and provider-specific adapters. **Inclusion is not a claim of CPA parity.**
Provider capabilities and the gateway's exposed routes are intentionally
separate: unsupported transports, conversions and request shapes fail
explicitly. In particular, the experimental Devin binary path is restricted
to numeric-loopback test endpoints. Gemini, Antigravity and Copilot are outside
the selected integration scope.

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
make integration
gleam export erlang-shipment
```

The shipment includes the BEAM application and vendored static assets. It still
needs an Erlang runtime and the external tools required by the commands you use.
`make integration` runs the assembled synthetic tests, standalone local
protocol/runtime scenarios, a fresh-VM credential restoration check, the
conformance schema check, and shipment creation. CI runs that same local gate
on Linux. Python 3 is needed for test drivers, not for the runtime service.
Local state, downloaded development tools, and build output are ignored.

The **strict CPA differential gate is separate**:

```sh
make parity DRIVERS=/absolute/path/to/drivers.json
```

Missing CPA drivers or unsupported required capabilities cause a nonzero exit.
A green local integration build does not waive those failures, establish live
provider compatibility, or mean that native-client workflows have been tested.

See [AGENTS.md](AGENTS.md) for contribution boundaries and safety invariants.
Licensed under [MIT](LICENSE).
