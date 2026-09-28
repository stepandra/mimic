# Next CPA parity wave: per-thread slices

This is an implementation plan, **not evidence that its gates have passed**.
Nine independent threads have been started. Five own provider behavior; the
other four own shared mechanisms, differential testing, native-client testing,
and assembly. Gemini, Antigravity and Copilot remain outside scope.

- Published MIMIC base: `3e00808ff0fefbb6728edb1769c17139ef0fd93a`.
- CPA reference: `acdace936fa7df2905500c7f5e0a97d683138dea`.
- Historical base gate: 522 Gleam tests, 10 Python tests, local CLI/shipment
  workflows and CI. These are not the results of this new wave.
- Fresh threads must fetch and verify that exact published base rather than
  build on a stale or empty `local` checkout.
- No automatic commits, merge to `main`, push, package publication or live
  provider calls are authorized by this plan.

## Threads and vertical slices

### T1 — Claude compatibility policies

[Implementation thread](delta://thread/ksQQcdKWtLdBQFyZROmB7NVeS5LOAEoYHpIBxBDu1fs15rdKs6m5jRdeJnRz)

1. Source-backed model/auth/request-kind policy table.
2. Thinking/tool-choice/sampling, managed and unmanaged betas, cache
   breakpoints and TTL normalization.
3. Native client/session/device profiles and distinct count_tokens behavior.
4. Real local wire scenarios and fixtures for differential/native-client tests.

Owns `src/mimic/providers/claude/**` and Claude-specific tests/docs.
Does not replace the already implemented Messages/SSE/OAuth baseline.

### T2 — Codex HTTP continuation and Responses-lite

[Implementation thread](delta://thread/ksQQti9t21AhRN2Mne5xYqQJD5LOAEofLZIBxBDu1fs15rdKs6m5jRdeJnRz)

1. Pin actual HTTP, compact, lite and WebSocket continuation contracts.
2. Trusted bounded HTTP receipt/history resolution with explicit lifetime,
   tenant/account/model/origin scope and revoke/restart behavior.
3. Source-backed Responses-lite catalog, preparation and response semantics.
4. Multi-turn tool/reasoning/usage scenarios and negative receipt tests.

Owns Codex provider/session adapters, tests and docs, including
`providers/codex_websocket.gleam` when needed for Codex receipt compatibility.
Shared codecs and storage mechanisms belong to T6. Client-provided history
claims are not trusted proof; HTTP and socket-generation-bound WS receipts
must not be interchangeable.

### T3 — Native and compatible Kimi

[Implementation thread](delta://thread/ksQQ39AmbQbqR16nPDnRk2LcnpLOAEosapIBxBDu1fs15rdKs6m5jRdeJnRz)

1. Tool calls/results, thinking and supported parameter transformations.
2. Chat SSE, then source-qualified compact/continuation.
3. Supported media and Anthropic delegation through shared codecs.
4. A separately identified generic-compatible mode where required by CPA.
5. Ordered raw header/body/event observations and real local workflow fixtures.

Owns `providers/kimi/**`, a distinctly named Kimi-compatible namespace if
needed, and Kimi tests/docs. Native and generic modes must not accidentally
share credentials, device policy or session state.

### T4 — Grok/xAI OAuth, tools and WebSocket

[Implementation thread](delta://thread/ksQQppvXZHpGSpWWIBXmpW7B25LOAEo315IBxBDu1fs15rdKs6m5jRdeJnRz)

1. Gateway-ready OAuth enrollment/refresh hooks using the existing runtime.
2. Tool schemas, collision-free aliases and request-bound reverse restoration.
3. Continuation and WS/WSS adapters with official-API versus OAuth-proxy
   routing kept explicit.
4. API-key/OAuth local scenarios, rotation, errors, cancellation and isolation.

Owns `providers/xai/**`, xAI-specific WS adapters, tests and docs. T6 owns
neutral transport/session changes. One OAuth grant must not be duplicated
under independent refresh managers to work around endpoint selection.

### T5 — Native Devin beyond one-shot loopback

[Implementation thread](delta://thread/ksQQVrGk5ZuTTLC4L05RPP31kpLOAEpKWZIBxBDu1fs15rdKs6m5jRdeJnRz)

1. Source-backed permanent-session enrollment and Connect/protobuf contracts.
2. Conversation history, tools/results, thinking and supported media/models.
3. Incremental Connect-to-client streams, terminal trailers, usage and cancel.
4. Status/quota observation and explicitly labeled token estimates.
5. Transport qualification and a separately approved remote-endpoint policy,
   coordinated with T6; no blind removal of the loopback gate.

Owns `providers/devin/**`, Devin-specific primitive FFI, tests and docs.
Implemented, locally tested, remote-enabled and live-qualified are distinct
states. The token-bearing protobuf body is secret; base64 is not redaction.

### T6 — Shared protocol/runtime support

[Implementation thread](delta://thread/ksQQfrCkbvM5QAS8eUbGJL4qhZLOAEn30JIBxBDu1fs15rdKs6m5jRdeJnRz)

1. Publish the usable baseline API map and required additive hook contracts.
2. Shared IR/codec projections, tool/media/reasoning and stream lifecycle
   primitives required by provider slices.
3. Neutral continuation/session, endpoint-binding and qualified binary/WS
   transport extensions where genuinely necessary.
4. Cross-provider regression coverage for refresh fences, CAS, cancellation,
   byte limits, TLS, ownership and no replay of uncertain/started requests.

Owns shared `ir`, `types`, `dialect`, `protocol`, `egress`, `fleet`, `quota`,
runtime contracts/registry/transport and runtime credential-storage primitives.
Does not own provider namespaces, gateway/root files or dependency changes.
No speculative replacement of working abstractions and no second scheduler.

### T7 — Executable CPA differential lab

[Implementation thread](delta://thread/ksQQMFQ3XdWrSueiDWTyFPoDPpLOAEoFApIBxBDu1fs15rdKs6m5jRdeJnRz)

1. Reproducibly build the actual unmodified pinned CPA executable.
2. Run CPA and MIMIC against the same network-contained synthetic upstreams.
3. Compare targets, ordered headers, body semantics, tools, usage, SSE/WS
   lifecycle, errors, refresh/failover and restart.
4. Replace absent scenario drivers with measured implementations; keep
   unsupported/missing cases red and historical matrices intact.
5. Deliver runnable reports and root CI hooks to T9.

Owns `test/parity/**`, `scripts/parity/**`, `docs/parity/**` and their helpers.
Normalization may remove only explicitly justified volatility, not meaningful
differences. Source inspection and mocked callback output cannot impersonate
an executed CPA result.

### T8 — Actual native-client workflows

[Implementation thread](delta://thread/ksQQkKIaLS5YQUSt8nrHWfEitpLOAEoSjpIBxBDu1fs15rdKs6m5jRdeJnRz)

1. Pin official client binaries/package versions and integrity evidence.
2. Run actual Claude Code/Codex first, then Kimi and other available native
   clients, in disposable projects and isolated HOME/environment.
3. Exercise real gateway login/conversation/tools/stream/cancel/refresh/
   continuation workflows against contained local fixtures.
4. Prepare a separate opt-in live runner with explicit operator prerequisites.
5. Publish per-client/version results independently of the CPA differential.

Owns `scripts/native-clients/**`, `test/native_clients/**` and
`docs/native-clients/**`. MIMIC's own CLI or a hand-written HTTP client does
not count as native-client evidence.

**Live prerequisite:** approved account, endpoint, model and test data,
private credential provisioning, and request/token/spend/time budgets.
Without these, live tests remain `not_run`/blocked. Do not inspect ambient
credentials or user HOME, install clients globally, expose private code to
clients/upstreams, or run without adequate filesystem/network containment.

### T9 — Single integration and release owner

[Implementation thread](delta://thread/ksQQXKrKkoXtTP2U9L9D6xZWG5LOAEny5ZIBxBDu1fs15rdKs6m5jRdeJnRz)

1. Publish gateway/registry/config/private-provisioning integration contracts
   and a hash-verified input queue.
2. Assemble compiled owner-approved provider/core checkpoints incrementally.
3. Wire actual routes and CLI/shipment workflows; preserve auth-before-effects,
   selected-account binding, synchronous stream adoption and safe cancellation.
4. Run the complete merged gate, integrate T7/T8 evidence without waivers,
   arrange independent boundary review and prepare a final source handoff.

Owns root CLI/build/dependency/CI files, gateway/config/refresh/enrollment,
legacy callback/CLI seam, `vendor/mist`, root examples/docs and assembled
workflow tests. Providers submit hooks; they do not concurrently edit these
files. Publication requires a later explicit action by the coordinator/user.

## Coordination and done criteria

- T1–T5 publish provider contracts to T6/T9 and fixture/driver contracts to
  T7/T8 early. Existing base APIs remain usable while extensions are discussed.
- T6 publishes small **compiled** versioned source snapshots with exact hashes;
  peers must not wait for a hypothetical all-or-nothing API.
- T7/T8 can start baseline observation immediately and add delivered features
  incrementally. T9 can prepare assembly, configuration and route tests early.
- No peer edits another owner's files. Shared changes require an agreed owner
  and exact contract. Source-only ignored overlays may use explicitly
  manifested inputs, never arbitrary sibling metadata/state/cache copies.
- Every slice needs a real request-to-result path for its supported capability,
  positive/negative regressions, safe cleanup, source provenance and explicit
  limits. Pure adapters do not close an assembled-ingress gate.
- Preserve separate evidence axes: source-reviewed, local-mock,
  CPA-differential, native-client/local and live-provider. Never add counts
  from different snapshots or turn an unsupported row into a pass.
- A completed thread delivers base revision, changed-file list, immutable
  source hashes, exact commands/exits, failed-run history and remaining gaps.
  Thread completion does not automatically merge or publish its changes.
