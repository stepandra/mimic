# Implementation ledger

This is the implementation boundary for the first assembled version. The
requirements in `SLICES.md`, `WORKSHOP.md`, and `AUTOPILOT.md` remain the target;
code existence and synthetic tests do not constitute native-client or provider
validation.

## Scope by slice

| Slice | Implemented surface | Gate still requiring external evidence or additional integration |
|---|---|---|
| A1 | Offline HTTP/1.1 capture; loopback, single-allowlisted-upstream TLS CONNECT recorder; private CA generation; observed ALPN; redaction before persistence | Capture a real native CLI session using an operator-owned test account; JA4 measurement is not implemented |
| A2 | BLAKE3-addressed zstd objects, idempotent add, validated load, selection, export, rotation | Large-corpus operational sizing and retention policy |
| A3 | Header name/case/order/value, beta, structural JSON, and transport drift reports | Real two-version capture comparison; no vendor version claim is inferred from the design documents |
| B1 | Strict TOML schema, lint, ordered rules, beta restrictions, limited generators | A measured baseline persona from a real corpus |
| B2 | Per-request-kind drafting, constant/passthrough inference, notes on uninferred rules | ≥90% agreement with a reviewed measured baseline; redacted values must not become inferred constants |
| B3 | Ordered raw HTTP/1.1 materialization, verified HTTPS, bounded response framing | Native transport fingerprints, HTTP/2, timing distributions; unresolved redacted fields require runtime input |
| C1 | Loopback echo/required-header oracle, deterministic JSON/SSE, counters, bounded sanitized request inspection | TLS/ALPN forcing in the lab itself; the separate recorder has its own TLS test path |
| C2 | Response-class and first-byte envelope verdicts; real localhost rejection-sensitivity test | Live provider acceptance, richer provider-specific error taxonomy |
| D1 | Private atomic credential store, configurable PKCE flow with loopback callback, refresh singleflight/backoff, metadata-only management | Real Claude registration/login/refresh; no shipped or inferred live OAuth client registration; age encryption is not implemented |
| D2 | Sticky and cooldown-aware fleet selection, leases, reusable per-origin egress client | Proxy/bound-egress support; stream connection reuse and multi-profile managed-service orchestration |
| D3 | Unified windows, reset/utilization/cooldown parsing, persisted serialized ledger | Real response-header calibration and shared quota reservation across production Workshop runners |
| D4 | Authenticated loopback ingress, Anthropic/OpenAI routing, incremental SSE, managed persona reload, credential/fleet/quota integration | Installed SDK smoke tests, real upstream traffic, streaming overhead p50 <5 ms |
| E1 | Canonical turns, blocks, tools, thinking and usage; native Anthropic structural roundtrip | Real-corpus golden coverage beyond synthetic fixtures |
| E2 | OpenAI Chat request/response translation and incremental SSE state machine | Full provider event coverage; unsupported lossy features and Gemini fail explicitly |
| F1 | Strict drive configuration, digest-pinned Docker argument vectors, deterministic seed inputs and coverage checks | Actual containerized native-client runs and repeat-capture determinism; Docker daemon was unavailable during initial implementation |
| F2 | Explicit registry polling, durable debounce and PB queueing | Live registry service operation and long-running scheduling |
| F3 | Durable PB/PO/CO stage state, budget gates, review, immutable artifacts, signed production promotion/rollback, isolated lab promotion | Production acquisition/capture/oracle/canary adapters and SLO windows; the CLI queues production work rather than inventing stage results |
| G1 | Local schema-constrained inference request, independent validation, evidence spans, byte/retry/replan bounds | Historical ≥95% classifier validity and live-model evaluation; the HTTP client buffers responses before the post-read size check |
| G2 | Conservative classification routing; minimal patches checked against a supplied bounded persona base and caller lint | Ten historical labeled drifts; large or credential-marker-bearing bases can be ineligible under conservative redaction; production patch application remains the trusted runner's responsibility |
| G3 | Restricted diagnostic categories/actions, deterministic fact-based reporting, typed human escalation | Persistent messenger confirmation UI; real failed-run/model/replan end-to-end evidence |
| H1 | Header/JSON/exact-secret redaction, structured logging, counters and gauges with constrained labels | Full deployment-wide secret scanning against real auth stores; complete production instrumentation |
| H2 | Authenticated API and vendored panel; shared credential/key stores; persona draft creation, active lookup and gated promotion; quota and typed drift views | Full persona draft inventory/deletion needs a typed index; immutable stage artifacts are deliberately not exposed as generic CRUD |

The conditional Rust slices are **not activated**:

- **R1:** no lab evidence currently justifies a TLS/HTTP/2 impersonation NIF.
- **R2:** no benchmark currently establishes a corpus parsing bottleneck.

## Local vertical paths

`mimic demo <corpus-directory>` uses an explicitly synthetic request:

1. Parse an HTTP/1.1 frame.
2. Persist and deduplicate the redacted capture.
3. Draft, render, parse, and lint a persona.
4. Supply the original synthetic request's runtime fields to the draft.
5. Replay over a real loopback socket and stop the lab.

`mimic workshop lab-bump <state-directory> <run-id> [trivial|breaking]`
exercises acquisition of a **built-in synthetic fixture**, actual loopback
capture, structured diff, deterministic classification, candidate lint, a
local oracle, and three local canary requests. Its budget reservations are
synthetic estimates, not provider usage measurements. Successful promotion is
restricted to `synthetic-lab`. Production promotion rejects synthetic evidence.

This is not a substitute for acquiring and executing an actual native CLI, or
observing a production canary for its required duration.

## Management and ingress share state, not a second registry

For the built-in managed-service path, use one explicitly created **absolute
0700 state directory**. Credential files and client-key verifiers are
namespaced within that directory; Workshop uses its own subdirectories.

```text
mimic management serve <private-state-dir> [port]
mimic serve managed <port> <origin> <private-state-dir> <provider> <credential-id> <anthropic|openai>
```

Supply `MIMIC_MANAGEMENT_KEY` through the environment; it must be at least
32 characters. Supply client keys through the management API or key-store
library, not command-line arguments. The management panel does not persist its
Bearer key in browser storage.

A draft upload lints and stores TOML but does **not** mutate an active pointer.
Only a gated Workshop promotion activates it. Managed ingress rereads that
pointer and client-key verifiers on each request. Revocation therefore does
not require an ingress restart.

The drift endpoint reads an explicit index of structured differ reports, not
all artifacts. Trusted stage adapters call `control.record_drift` after writing
an actual report. Unknown, arbitrary, and credential artifacts are not listed.

## Interpretation of fidelity and privacy

- Header **order, case, and duplicates** are explicit data, not dictionary
  entries. This does not promise preservation of all insignificant whitespace.
- The lab exposes **sanitized reconstructed frames**, not packet captures.
- Corpus privacy intentionally removes private content. A redacted placeholder
  is unknown data, not evidence of a constant wire value.
- The corpus's strict default rejects unapproved JSON object keys rather than
  risk storing a credential-keyed map. New provider schemas require explicit
  review of that policy; arbitrary unknown fields are not silently retained.
- UTF-8 JSON/SSE and HTTP/1.1 are the initial supported wire path. Unsupported
  encodings, lossy dialect features, transport profiles, and binary data fail
  explicitly.
- TLS verification is enabled for upstream connections. The recorder's own CA
  is opt-in per QA client and is never installed in the host trust store.
- An unknown JA4 remains unknown. An observed lack of ALPN is not relabeled as a
  negotiated protocol.

See the individual `track-*.md` guides for API contracts and limitations. The
assembled test/build outcomes belong in the validation report, not in the
requirements documents.
