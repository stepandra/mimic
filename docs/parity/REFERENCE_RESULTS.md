# Reference-driver measured handoff

## Outcome

**Partial executable slice; strict release still 0/37.** CPA was built from the
unmodified pin and executed in a tested OS sandbox. No live verification.
The current runnable command stops CPA before launch because an unconditional
background updater violates the requested disabled-background condition.
It still runs the supported MIMIC gateway probes and emits failing evidence.

This is not another source-only claim, but it is also **not** a complete D1–D5
implementation. HTTP Messages/Chat are the only executable fixture bindings.
TLS, WS, Connect, tools/usage beyond the buffered Messages response, refresh,
failover, cancel and restart are unimplemented in this reference wrapper.
Provider peer hooks are not integrated; absent/unsupported checks remain red.

## Base, build and isolation

- Attached worktree started clean on `c3ca7e80`. Added the explicitly requested
  GitHub `origin` with `jj`, fetched, verified `main@origin` at
  `3e00808ff0fefbb6728edb1769c17139ef0fd93a`, and created an empty change on it.
  No primary/sibling checkout edits, mutating Git, commits or pushes.
- CPA archive SHA-256:
  `56c970726edbd07591b77c1b6be18f733368f8a2f52a2f0931c928b30c13b540`.
- Go `1.26.5 darwin/arm64`; `CGO_ENABLED=0`, `-mod=readonly`, `-trimpath`,
  `-buildvcs=false`, `-p=4`, target `./cmd/server`.
  Dependency acquisition preceded the `GOPROXY=off GOSUMDB=off` build.
  A repeat build with `GOENV=off GOFLAGS=""` produced the identical executable.
  Initial provenance/target manifests are retained alongside the hardened build;
  the latter also hashes Go's compile/link/asm tools.
- CPA executable SHA-256:
  `28d3d0a5174d0bf2298d8da8a3963179456e4587bd83029a398a3ca61f23b94f`.
  Binary prints `Version: dev, Commit: none`; revision attribution comes from
  verified source/build provenance, not a fabricated embedded version.
- Fresh private `0700` staging, generated fixture credentials only. CPA receives
  only its copied executable/config; MIMIC receives compiled `.beam/.app` files.
  No source checkout, home credentials, `.git/.jj` or Go cache readable by target.
- Seatbelt negative probes denied a repository read and connection to an
  unapproved **listening** local port. A separate positive test connected to the
  permitted local fixture port. System runtime files remain accessible.
  Ancestor directory metadata is permitted for MIMIC's no-symlink checks, not
  their file contents. Logs/CPU/file descriptors/timeouts are bounded.

## Actual execution observations

The **first strict run** invoked real CPA for two fixtures:

| Fixture | CPA observed client status | Result |
|---|---:|---|
| `messages-v1` | unauthenticated 401, authenticated 200 | Failed upstream body/auth expectations; correct fixture response body |
| `chat-v1` | authenticated 502 | CPA requested upstream streaming but historical fixture supplied buffered JSON; not a valid SSE conformance test |

MIMIC provisioning in that first run failed before requests because the sandbox
denied directory metadata required by its private-file validator. That failed
evidence is retained, not overwritten. After adding only ancestor `stat`
permission and creating `0700` state, the **second strict run** exercised:

| Fixture | Assembled MIMIC observed client status | Result |
|---|---:|---|
| `messages-v1` | unauthenticated 401, authenticated 200 | Auth isolation/response semantics true; historical path assertion false |
| `chat-v1` | authenticated 422, no upstream request | Failed; actual gateway does not satisfy this fixture |

The second run did **not** launch CPA: it reports the startup-policy blocker.
The final hardened gate rerun also returned exit 1 / 0 of 37 without launching
CPA. Its separate report and digest are recorded in the evidence index.
The two runs' Messages observations use exactly the same fixture SHA-256:
`2f409e3e6e6ce9427a353c6270d5a270cf99644609dfbedc903e65744c93c7f5`.
They are comparable raw observations, **not a passing paired release run**.

Measured Messages differences on this custom localhost upstream:

- Both targets send `/v1/messages?beta=true`; the historical fixture assertion
  expects `/v1/messages`. This is a fixture expectation gap, not target-to-target
  target-path drift. The old fixture was not rewritten to turn green.
- CPA uses `Authorization: Bearer synthetic-upstream-a`; MIMIC uses
  `x-api-key: synthetic-upstream-a`. This is observed custom-endpoint behavior,
  not a claim about direct Anthropic endpoints.
- CPA converts the user text to content blocks, adds ephemeral cache control and
  `stream:false`; MIMIC retains the original string content.
- Ordered header lists differ, including case, compression, generated request
  identifiers, CORS/trace response fields, dates and dynamic port values.
  No fields were normalized and duplicate fixture headers were not collapsed.
- Authenticated buffered response bodies match the synthetic Messages response.
  Agreement on that one body is not sufficient for parity.

All full plans, raw observations and target logs remain in the ignored result
directories named in the evidence index. They contain known synthetic values
only. Binary/protobuf fixtures were not executed or exported as claimed passes.

## Validation

- `mise exec gleam@1.18.1 -- gleam test`: **523 passed** (522 assembled-base
  tests plus one new callback-only/partial-envelope gate regression).
- `gleam format --check src test` through the installed mise toolchain: passed.
- Python parity regressions: **22 passed**, including 12 added binding,
  fake/stale/partial-artifact, unknown-check, restart, startup-policy and actual
  Seatbelt controls, persisted Go-overlay rejection and orphan/TERM-ignoring
  descendant cleanup. These are harness tests, not provider coverage.
- Strict37 release: **exit 1, 0/37**, source/mock/reference/differential/live
  axes kept separate. Gemini/Antigravity/Copilot remain excluded.
- Historical v1/v2 matrices and all historical fixture bytes are unchanged.
- No TLS fingerprint, native-client or real-provider success is asserted.
- Independent review verified all 1,663 source files, archive/executable/manifest
  hashes and negative tests. Findings fixed: persisted Go overlays, orphaned
  subprocess cleanup, stale MIMIC shipment attribution and alternate-manifest
  execution identity. Review did not execute CPA or establish parity.

## Next owner actions

1. Decide how the unconditional excluded updater can satisfy the requested
   background-disable policy without changing reference provider behavior.
   Keep the hard blocker until that decision is explicit.
2. Version the HTTP fixture contract to represent CPA's actual transport
   selection, retaining original fixtures/reports; do not normalize body/auth
   drift away. Scope denominator changes require a new scope, not relabeling.
3. Integrate provider-owned real-gateway hooks using the published tuple/fixture
   binding contract. Kimi raw-header observations, Codex HTTP/lite vs WS,
   xAI OAuth/Grok Build, and Devin binary Connect remain distinct.
4. Add a reviewed Linux no-egress launcher before using Linux release CI.
   Docker/Podman daemons were unavailable on this machine; no daemon/VM was
   installed or started outside the workspace.
