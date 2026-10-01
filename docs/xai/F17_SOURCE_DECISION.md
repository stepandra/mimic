# F17: source-qualified unsupported HTTP state

**Supported scope: explicit input enforcement, not resumed HTTP conversations.**
The FINAL-v1 pin does not establish a qualifying ordinary Grok/xAI HTTP
continuation contract. MIMIC rejects top-level `previous_response_id` before
upstream inference, rather than silently discard it or replay full history as a
fallback. The root hook must run before credential acquisition so expired OAuth
state requests cannot trigger a refresh either.

This is a conservative MIMIC policy, **not a claim that CPA rejects the input
identically**. CPA's ordinary executor deletes the field. Compact's separate
executor restores a nonempty raw ID; that source capability remains documented
and is not converted into ordinary conversation or receipt authority.

## Pinned source boundary

F01 owns [FINAL-v1](../parity/FINAL_CONTRACT_V1.md#L14), CPA
`acdace936fa7df2905500c7f5e0a97d683138dea`. The reviewed later revision is comparison
only. Its operation inventory explicitly records:

- [`final-v1-grok-http-continuation`](../parity/final-v1/contract.json#L476):
  `source_presence: unsupported`, `applicability: unsupported_upstream`,
  `previous_response_id: deleted`; compact/WS do not qualify it.
- [`final-v1-grok-compact`](../parity/final-v1/contract.json#L484):
  `source_presence: present`, `applicability: conditional_scope_pending`;
  raw ID restored, standard API headers, ordinary continuation unqualified.
- [The source map](../parity/final-v1/SOURCE_MAP.md#L114) states the same boundary.
  These are source findings with `runtime_proof: not_run`, not paired results.

| Pinned path | Actual behavior | F17 consequence |
| --- | --- | --- |
| Ordinary API-key or OAuth `/responses`, buffered and SSE | `prepareResponsesRequestTo` deletes the ID; both HTTP execute paths send its resulting body. | No source-qualified previous-ID conversation continuation. |
| OAuth Grok CLI chat proxy | Backend selection changes the ordinary endpoint, not the deleting preparation rule. | No proxy exception or implicit stateless fallback. |
| Explicit `/responses/compact`, buffered | `executeCompactRequest` restores a nonempty raw ID after ordinary preparation, sends standard API/custom endpoint headers, not CLI proxy identity. | Separate source capability with pending applicability; not a scoped ordinary receipt. MIMIC already denied IDs in its HTTP bridge. |
| WebSocket preparation | Separately restores the ID; auto dispatch selects WS only for enabled downstream WS and denies required-WS fallback. | F18/shared WS ownership; no HTTP consumption of a WS receipt. |
| Optional reasoning replay | Reads model/session cache, returns unchanged input on miss/read failure; cache deliberately ignores selected credential. Rewrites `input`, not the deleted ID. | Not tenant/account/revision-bound receipt authority; do not copy it or call it continuation parity. |

Exact relevant F01 excerpts are
[`xai-previous`](../parity/final-v1/contract.json#L101),
[`xai-backend`](../parity/final-v1/contract.json#L99) and
[`xai-compact-previous`](../parity/final-v1/contract.json#L148).
Historical additional helper evidence was read from packet
`d6f307a72a395a137126016362297884e1061a8a`, in the read-only
`zmwgvk5bd03n/mimic` checkout. Its F17 packet already said
`BLOCKED/unsupported-reference-contract` and contained tests/docs/harness, not a
continuation implementation. Its old test totals are **not this gate's evidence**.
No historical commands, source fetching, CPA execution or real account calls
were performed in this recovery.

Relevant historical source-file hashes (recovered evidence, not newly fetched):

| File | SHA256 |
| --- | --- |
| `internal/runtime/executor/xai_executor_request.go` | `d8a3af4d9a9997bbdb67fe0c5f4dfba746fa4a36ad08103e06b77093704fb245` |
| `internal/runtime/executor/xai_executor_execute.go` | `5382a5bd27846aec8acc9501f1385155c2789c16cdfc64bd41ad79d97d7f3703` |
| `internal/runtime/executor/xai_executor_stream.go` | `c8f9a0fb1811fbbae86aa08d4f1a23fe655eb8de88e3438b3d8ec9a957a5c6a6` |
| `internal/runtime/executor/xai_reasoning_replay.go` | `883828b8e4f2e69c3b1aa5eeac4c5a4335e7e29bd44e2e4b84f1bc9ef0758a03` |
| `internal/cache/xai_reasoning_replay_cache.go` | `80bf4ac713b84d8ffa96716ae40d91a42069d0feec247f87d9f91f05845184af` |
| `internal/runtime/executor/xai_websockets_executor.go` | `d71ab69d9dc5a6391f46d93dba3bbebfb73bb288a73675890898455377e6940d` |

The reasoning evidence is `xai_reasoning_replay.go:29–50` (optional read),
`53–94` (model/session scope), `260–293` (completed-item cache), and
`xai_reasoning_replay_cache.go:229–241` (credential-independent key).
Ordinary preparation is `xai_executor_request.go:59–161` and deletes at line 88;
compact is `xai_executor_execute.go:144–185`; WS is
`xai_websockets_executor.go:1083–1091` and auto dispatch `1735–1752`.
These paths and bounds were recovered from the old source evidence/decision,
not observed by executing the reference.

## Coherent actual MIMIC rule

[`http_continuation.validate`](../../src/mimic/providers/xai/http_continuation.gleam#L15)
checks only top-level field presence. `null`, `""`, objects, arrays, numbers and
booleans are rejected too. A nested user-content/extension key is not an
instruction. Strict raw parsing still rejects malformed JSON and escaped
duplicate keys using the existing xAI guard.

1. Root uses [`guard`](../../src/mimic/providers/xai/http_continuation.gleam#L27)
   before `runtime.open`; sanitized JSON 422 on unsupported input. Root hooks
   are parent-owned and require execution against the assembled snapshot.
2. [`bridge.prepare_plan`](../../src/mimic/providers/xai/bridge.gleam#L96) applies
   the same rule after strict parsing and before adapter egress, yielding
   `Failure(Unsupported, NotSent, None)` for ID presence. Fixed, selected and
   configured HTTP adapter factories all funnel through this bridge.
3. [`request.prepare`](../../src/mimic/providers/xai/request.gleam#L21) rejects
   `Chat`, `Responses` and `Compact` IDs instead of dropping or forwarding them.
   Its WebSocket branch is unchanged.
4. Fully paired explicit history **without** an ID remains stateless input.
   Full history plus an ID is denied, not silently downgraded.

Current root xAI dispatch is Responses buffered/SSE and buffered compact.
Streaming compact and xAI Chat ingress already reject as unsupported.
F01's historical API-key Chat row remains required; this F17 packet neither adds
that translation route nor substitutes Responses success for a Chat parity pass.
F07's prepared `configured_http`/operation bindings are the scoped dependencies;
this packet changes no adapter, operations, OAuth, enrollment or UI file.

No cache, fake receipt implementation, continuation enable flag, shared runtime,
store/auth, WS transport/frame, vendor or root edits are owned by this packet.
The existing shared `protocol/continuation` and `runtime.open_scoped` APIs are
not invoked: their existence cannot supply absent provider semantics.

The actual read-only shared seams are
[`scope`](../../src/mimic/protocol/continuation.gleam#L40), using authenticated
tenant plus selected context and opaque generation;
[`locate`](../../src/mimic/protocol/continuation.gleam#L188), preselection only;
[`get`](../../src/mimic/protocol/continuation.gleam#L172), current full-scope
admission; and [`open_scoped`](../../src/mimic/providers/runtime.gleam#L559), the
authoritative revision callback after credential acquisition. The existing
[`attempt`](../../src/mimic/providers/runtime.gleam#L1032) acquires credentials
before calling the adapter, which is why an adapter-only denial cannot prove
zero OAuth refresh. The distinct xAI
[`WS adapter`](../../src/mimic/providers/xai_websocket.gleam#L22) retains a
connection-scoped Session, not an HTTP receipt store.

## Explicit product decisions, not denominator changes

The parent approved conservative presence rejection and keeping WS unchanged.
This closes F17 source/input enforcement after its focused actual-route gate,
**not the original positive “resume HTTP conversations” acceptance** and not a
differential, native or live qualification.

Compact raw-ID passthrough is a separate applicability decision, retained as
conditional in F01/F19; a future proposal needs exact receipt lifecycle,
authenticated tenant, actually selected account, authoritative revision, model
and operation-origin binding before enabling it. Forwarding a raw compact ID
alone does not meet that criterion.

Ordinary positive continuation would require a new versioned source/product
contract. Do not silently change the 37-row denominator, relabel synthetic
cursors or full-history replay, or treat local denial totals as a reference pass.
Validation status is recorded separately in [F17_VALIDATION.md](F17_VALIDATION.md#L1).
