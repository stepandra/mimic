# Assembled validation results

## Final gate

The fully assembled source passed **179 tests twice**, with no failures.
Validation used Gleam **1.18.1** and Erlang/OTP **29**, with `b3sum`, `zstd`,
and OpenSSL available on `PATH`.

The parent thread's terminal could not materialize its Delta checkout
(`the checkout kept changing`). The final gate therefore used a **fresh
isolated Delta snapshot of the assembled source**, not the stale parent
on-disk checkout. The only change made during that gate was formatting
`src/mimic/ingress.gleam`; that formatting change was returned with the
validated source. No commit or push was made.

| Command or workflow | Result |
|---|---|
| `gleam format --check src test` | Passed after formatting the flagged ingress file |
| `gleam test`, first run | **179 passed**, exit 0 |
| `gleam test`, repeated in the same checkout | **179 passed**, exit 0 |
| `gleam export erlang-shipment` | Exit 0 |
| `./mimic help` | Exit 0; launcher executable mode confirmed |
| `gleam run -- help` | Exit 0 |
| `gleam run -- doctor` | Exit 0 |
| `gleam run -- metrics` | Exit 0 |
| `gleam run -- obs metrics` | Exit 0 |
| `gleam run -- demo <fresh-corpus-directory>` | Exit 0; deduplication, persona lint, real loopback replay |
| `gleam run -- record ca <fresh-private-directory>` | Exit 0 |
| Invalid command | Expected exit 1 |
| Fresh `workshop lab-bump ... trivial` | Exit 0; isolated `synthetic-lab` promotion |
| Fresh `workshop lab-bump ... breaking` | Expected exit 1; BREAKING pause, active digest not replaced |
| `workshop status` for each run in a **new BEAM process** | Exit 0 for both complete and paused checkpoints |
| Shipment `help`, `doctor`, and `demo` from a different working directory | Exit 0 with required tools on `PATH` |
| Shipment assets | All 3 management and 8 Autopilot assets byte-identical to source |
| `git diff --check`, `git diff --cached --check` | Exit 0 |
| `jj --no-pager status` | Exit 0; no commit made |

The cold compile produced dependency-only deprecated `Header` warnings in
`gramps` and `mist`. There were **no application compile warnings**.
The negative certificate-verification tests intentionally emit TLS
`Unknown CA` notices.

A preliminary shipment demo without the supplied tool `PATH` failed with
`b3sum executable unavailable`. Repeating it with the documented runtime
dependencies succeeded. The shipment does not bundle external corpus tools
or silently substitute a different hash.

## Cross-track evidence

The suite and integration runs include:

- Actual loopback CONNECT, client TLS and upstream TLS, own-CA generation,
  upstream certificate rejection, HTTP/1.1 recording and chunked SSE.
- BLAKE3/zstd corpus persistence, deduplication, corruption/symlink rejection,
  redaction values and object-key handling, supported media types, and unknown
  ALPN represented honestly.
- Persona parsing/drafting/linting, preserved header order/case/duplicates,
  per-occurrence beta values, effective forbidden-beta validation, and rejection
  of unresolved redacted headers.
- Replay framing across arbitrary socket segmentation, informational responses,
  HEAD/304 no-body semantics, chunk extensions/trailers, and byte/deadline bounds.
- Two requests using one egress TCP accept, close/reconnect behavior, and
  rejection of an untrusted TLS peer.
- Mock OAuth callback/token exchange, private credential persistence, refresh
  singleflight, quota persistence and cooldown-aware scheduling.
- Anthropic/OpenAI structural and streaming translation using synthetic data.
- Management draft creation without activation; rejected unapproved promotion;
  a separately gated synthetic pipeline activating a candidate; real managed
  ingress forwarding the configured upstream Host and stored upstream
  authorization rather than client credentials; revocation denying the next
  request.
- Workshop reservation before side effects, failure/crash handling, ownership
  recovery, authorized operator actions, idempotent watch delivery, safe Docker
  argument construction, and absolute execution deadlines.
- Workshop checkpoints read in independent fresh BEAM processes, including
  complete, paused/BREAKING and in-flight states.
- Model-output closed-schema validation, citation bounds, byte limits,
  structured/folded credential suppression, exact diff-hunk validation against
  a supplied persona base, and constrained diagnostic actions.

These are **synthetic/local tests**. No successful live upstream validation is
inferred from them.

## Browser and packaging

The integration worker exercised the vendored management panel with
`agent-browser` against an exported shipment launched from `/tmp`:

- JS/CSS returned HTTP 200.
- Unauthenticated API requests returned 401.
- Credential and client-key creation/listing/deletion worked without echoing
  token values.
- A valid persona draft returned 201 and remained inactive.
- Invalid drafts and unapproved promotion returned 422.
- No JavaScript console errors were observed.

The browser and management process were closed afterward. This browser pass
preceded the last low-level hardening merges; the final 179-test gate rechecked
packaging and byte-identical assets but did not repeat browser interaction.

## Not established

No live provider requests, real OAuth accounts, native CLI captures, live local
model inference, or real Docker containers were used. Docker was installed but
its daemon was unavailable. The following remain outside this evidence:

- Native-client and real SDK compatibility gates, the measured persona baseline
  and ≥90% drafting agreement.
- JA4/TLS ClientHello/HTTP/2 impersonation or a demonstrated need for the
  conditional Rust slices.
- Historical classifier accuracy/validity targets and the ten-diff model gate.
- Production stage adapters, shared production budget reservations, full
  canary/SLO windows, and streaming overhead p50 <5 ms.
- Power-loss/directory-fsync and network-filesystem durability.
- Complete deployment-wide secret scans using real credential stores.

See [IMPLEMENTATION.md](IMPLEMENTATION.md) for the per-slice implementation
boundary, including features deliberately left unsupported or incomplete.
