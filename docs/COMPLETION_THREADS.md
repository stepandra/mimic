# Completion threads after the integration checkpoint

## Current truth

This branch is a **work-in-progress checkpoint**, not a release. Published main
remains `dd15c610ec39e4f296c30fe02347d0d2b368a629`. Start new implementation
threads from this checkpoint, not from main or old isolated worker checkouts.
No new user-facing threads were created by this checkpoint operation.

Before publication: Gleam 1.18.1 build passed; `gleam format src test` and the
subsequent format check passed. Full `gleam test` on OTP29 produced **1209 passed,
4 failures**, exit 1. No failing assertion was removed to obtain a green result.

Actual failures:
1. `account_ui_xai_test.strict_discovery_and_explicit_operation_forms_test`:
   expects WS binding rejection, whereas F18 adds explicit WS bindings. Reconcile
   UI/HTTP configuration and advertised capabilities with the intended WS gate.
2. `codex_ws_lite_test.f13_actual_owner_death_stops_blocked_sender_and_success_leaves_no_helpers_test`:
   blocked-owner TCP peer times out after local/helper DOWN. Known production
   cleanup blocker; absent local handle does not prove physical peer closure.
3. `gateway_test.devin_experimental_buffered_chat_real_mist_test`: boolean
   expectation failed. Reproduce and identify the exact changed route/capability;
   do not label it a stale test without checking the intended contract.
4. `xai_shared_identity_test.ws_argument_identity_is_validated_before_restoration_test`:
   adapter open now returns Unsupported/NotSent. Verify explicit WS destination
   configuration and keep the raw-identity-before-restoration assertion intact.

Retained local logs: `build/checkpoint-validation/{build,format,tests}.log`.
The initial format check failed on 15 files; only formatting was applied before
running the full suite. Current source warnings include unused diagnostic helpers
and transitive glisten imports. Frozen worker hash manifests are historical;
formatting and later integration can intentionally supersede them.

Zig launcher: implemented and cross-built for ARM64/x86_64. Actual ARM64 Linux
kernel suite and required-path/alias refusal tests passed. See
`containment/ZIG_LAUNCHER_VALIDATION.md`. Full BEAM PID1 containment, x86_64 kernel
execution and native/CPA qualification remain separate unfinished gates.

## Execution rules

- At most four independent implementation owners initially. One integration owner
  owns root gateway/config/CLI/build/vendor changes and one serialized runtime-test
  slot. Use the shared atomic validation lock; no simultaneous heavy test loops.
- Recover current code and retained evidence rather than start duplicate engines.
  Do not copy old whole branches over this checkpoint.
- Each thread delivers implementation + actual route/CLI test + source/shipment
  evidence + precise limitations. A library-only packet is not completion.
- Integrate each accepted slice immediately; do not build another unmerged queue.
- Source facts, synthetic tests, paired CPA runs, native clients and live accounts
  are separate evidence categories. Never convert skipped/unsupported into passed.
- Root WS-lite/xAI WS enablement stays off until transport, revision fences and
  root tests qualify. No real account secrets in Git/chat/logs/fixture packs.

## Threads to open, with dependencies and acceptance

| ID | Thread | Concrete deliverable / acceptance | Depends on |
| --- | --- | --- | --- |
| T01 | Close the integration checkpoint | Resolve all four listed failures on their actual contracts, remove temporary diagnostics safely, fix declared dependency warnings, run full Gleam/Python/integration/source/shipment gates. Own root wiring and admit other threads incrementally. No disabling tests or capability inflation. | Current checkpoint; T02 for final green |
| T02 | Fix WebSocket socket lifetime | F13: enforce real bounded abort on caller death, including connect, blocked send and idle intervals; propagate failed close/noproc instead of false success. Choose/review whole-connection custody design. Prove peer EOF/reset, helper cleanup, no replay and bounded TCP/WSS failure; then qualify Codex WS-lite. | Current F13 diagnostic and proposal |
| T03 | Qualify full F02 containment | Package approved Zig artifact with an explicitly pinned BEAM/target runtime image; run actual parent-SIGKILL, lease, timeout, early-exit, setsid and cleanup-failure scenarios. Verify kernel/image/build identity. No image acquisition or private artifact publication without approval. | Zig launcher already implemented |
| T04 | Finish Devin Responses schema | F25: resolve usage representation decision, populate only request-grounded required SDK fields, flat error events, depth/item/native-byte bounds and post-EOF deadline semantics; strict pinned SDK/schema + actual JSON/SSE reconstruction/root/shipment tests. | Product decision below; existing F24/F28 |
| T05 | Run a qualified CPA reference | F03: bind actual CPA executable/source/config/fixture routing and containment; reuse existing service only if qualified without reading its secrets/reconfiguring it. Resolve unconditional updater honestly; any modified reference requires approval and a separate digest. | T03; F01 source map |
| T06 | Close remaining source/applicability gaps | F01: resolve eight open source obligations and effective-chain/media/tool scope, freeze versioned executable case inventory. Preserve historical 37 rows and their result, record hardening differences explicitly. | Parallel with T02–T04; T05 supplies runtime identity |
| T07 | Admit Codex/xAI WebSocket routes | Complete F13/F18 root shared dispatcher, trusted acquired revision, actual account/model/operation bindings, callback publication priority and revocation under backpressure. Prove same-token acquisition race, success/reset, WS/WSS, fixed safe close/error behavior; preserve strict HTTP behavior. | T02; T01 integration owner |
| T08 | Complete Grok tool contracts | F19: source-qualified function/namespace/custom tools and compact forms across HTTP/SSE/WS; raw validation before restoration, collision/pairing/ID tests and real routes. | T06, T07 |
| T09 | Implement Grok image operations | F20: approved generation/edit surfaces, typed bounded binary/multipart transport, one account manager, exact route and cancellation tests; no arbitrary URL fetching or UTF-8 coercion. | T06, F07 operation bindings |
| T10 | Implement qualified Grok video lifecycle | F21: source-qualified create/status/result/download and bounded polling/budgets. Do not invent absent cancel/delete routes; absent operations require explicit scope decisions, not silent omission. | T06, T09/shared media seam, T14 budget contract |
| T11 | Enroll permanent Devin sessions | F26: source-backed acquisition/manual private-file flow in shared UI/S5 coordinator, permanent-session semantics, admin/cancel/restart races and a usable configured gateway grant. No fake expiry/refresh manager. | Existing F05–F07 UI; T06 |
| T12 | Complete Devin payload mapping | F29: inventory and implement representable native system/tool/media/signed-block forms; preserve or explicitly reject loss; actual encoding + Chat/Messages/Responses routes and pairing tests. | T04, T06 |
| T13 | Qualify remote Devin transport | F22 remainder: actual HTTP/ALPN/Connect contract, verified cert/hostname, binary bounds/cancel; enable remote only on qualified evidence and explicit operator authorization. Local H1 success is insufficient. | T06, T12; separate Devin authorization |
| T14 | Finish real bounded execution admission | F04: connect budgeted execution core to qualified containment/identity, approved endpoints/accounts/models/prices and exclusive account-ledger ownership; hard aggregate request/token/cost/time enforcement. Synthetic core already implemented; no caller boolean can authorize live. | T03, T05 |
| T15a–e | Execute provider CPA differentials | Five independent provider threads: Claude, Codex, Kimi, Grok, Devin. Turn F30–F34 preparations into actual paired reference/candidate runs with fixed identical synthetic stimuli and hash-bound outputs; retain/classify mismatches. | T05/T06 plus relevant admitted provider slices |
| T16a–d | Execute native-client acceptance | Four independent threads: actual pinned Claude Code, Codex, Kimi Code and available official Grok client. Conversation/tools/reasoning/continuation/cancel/login-refresh where supported; no handwritten HTTP replacement. | T03, corresponding T15 and actual artifact availability |
| T17 | Run bounded live acceptance | Selected Kimi/Codex/Grok accounts; Claude only after extra CPA check. Actual endpoint/model/data/cost budgets, zero secret leakage, separate per-mode verdicts. Devin remote/live requires its own permission. | T14, T15, T16, operator inputs |
| T18 | Publish the finished release | Freeze integrated tree, independent review, full source/shipment/CI, differential/native/live matrix, versioned explicit deviations and deployment smoke. Publish verified main only after required gates are satisfied. No implementation backlog hidden in this thread. | All applicable preceding acceptance |

This is **25 bounded assignments** if the five differential and four native-client
lanes are each separate threads, not 25 simultaneous workers. Start T01–T04;
then use freed slots for T05/T06 and provider implementation. Do not create all
threads in advance with stale snapshots or idle waits. T01 remains the integration
owner until T18, so route wiring is not postponed to the last day.

## Product/operator decisions that must not be guessed

1. Devin Responses `usage`: recommend standard `usage: null` plus exact native
   counters in explicit `devin.native_usage` extension, because native output lacks
   the schema-required reasoning/cache breakdown. This choice was proposed, not
   approved. Never fabricate zero counts or return schema-invalid partial fields.
2. Grok ordinary HTTP continuation is not source-qualified in the pinned CPA.
   F17 now rejects top-level previous IDs before credential acquisition. Decide
   whether an independently designed replay feature is desired; do not call it CPA
   parity or silently remove ID semantics.
3. Select explicit live accounts/endpoints/models/data and numeric budgets through
   private operator configuration, not chat/Git. Prior generic live permission is
   not an account configuration or unlimited spend authorization.
4. Identify/approve the immutable complete F02/native runtime image and any needed
   downloads. The implemented launcher/probes alone are not that image.
5. Decide operational deployment topology and real Devin transport authorization.
   Root listeners remain loopback by default.

## Definition of finished

All approved required routes work through the actual shared gateway and shipment;
full tests/format/CI are green; declared reference cases really execute; actual
native clients are exercised; authorized live modes have bounded recorded results;
unsupported upstream features and deliberate deviations have explicit decisions.
A large passing unit-test count, source inventory, local fixture or successful push
alone never satisfies this definition.
