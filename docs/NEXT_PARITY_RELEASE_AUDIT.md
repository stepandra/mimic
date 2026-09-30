# Next parity wave: coordinator release audit

## Status

All nine source streams have been merged locally. The final destination gate
passed: **698 Gleam tests**, **92 Python tests**, local scenarios, real root
CLI workflows and exported-shipment workflows. This is **not full parity**.
See [the destination validation ledger](NEXT_PARITY_MERGE_VALIDATION.md) for
failed attempts, corrections, exact source/log hashes and publication scope.
The published input is `3e00808ff0fefbb6728edb1769c17139ef0fd93a`;
the CPA reference remains `acdace936fa7df2905500c7f5e0a97d683138dea`.
Gemini, Antigravity and Copilot remain outside the agreed scope.

The user requested review of all nine streams, integration, validation and
publication to `main`, and reaffirmed publication after the integration
bottleneck is resolved.

The user subsequently granted standing permission for Kimi, Codex and Grok/xAI
live tests. Claude Code live tests remain conditional on an additional check
against upstream CPA. This consent does not identify a credential/account,
endpoint or spending budget, and does not waive containment. Before execution,
select explicit operator-provided accounts/endpoints and bounded request,
token, cost and time limits; never discover credentials in user profiles or
treat ambient credentials as test authorization. No live run is recorded here.

## Reviewed delivery inventory

These frozen inputs were checked against the imported source. Importing a
provider library does not imply every operation is connected to the gateway.
The destination ledger distinguishes imported code, admitted routes and
executed workflows.

| Stream | Authoritative input | SHA-256 of source archive |
| --- | --- | --- |
| Claude policies | `claude-policy-v1.tar.gz` | `f70ba1c673b52c8928cd8d4e6589ad3b96c0b4f594a109cb679f0718e22a723d` |
| Claude enrollment correction | `claude-enrollment-v1.tar.gz` | `42846c04ca4464fb9bdd38e6c41743051c32ac7131d288d542c2bd1662a27361` |
| Claude 429 correction | `claude-429-v1.tar.gz` | `93fcbfff8ab8196805b9bb9f86dc55df2a9fe56cc6e94175de37d6ed49a1283f` |
| Codex HTTP | `codex-http/snapshot-2/source.tar.gz` | `332278d8bf6384d639f13929d081c18709c66799d86601f70135f160ced1a21a` |
| Kimi protocols | `kimi-export/v1/source.tar.gz` | `bb17b35359aba919bc3224cc18b062964c1d9bcdc72522d92a24343c65e60905` |
| Kimi media correction | `generic-media-v1/source.tar.gz` | `78172207e387e516a2c8b6b40afa84fb6ce3742fad6a483f6cdc888a2a807d79` |
| xAI | `xai-native/snapshot-v2/source.tar.gz` | `1fa25e82b69b45c8d435c918bc387427691e14fb7eb14d2d967e3d90fded5a92` |
| xAI event-name correction | `xai-native/snapshot-v3/source.tar.gz` | `4122aa9a6599692384b6bb211514d2af172f50cedaf23ff9a3ecd436cd94d2de` |
| Devin | `devin-native/snapshot-1/source.tar.gz` | `be95cefb846f6bdc07dba16df27f8af68873b6299c856ef52e06405a31b9fe57` |
| Shared runtime, cumulative | `shared-core/snapshot-4/source.tar.gz` | `f318501aaaa1cbf5a8c477097b871387b6a85f30a9692c2f9cdda1dc524bb5bc` |
| Shared enrollment, incremental | `shared-core/snapshot-5/source.tar.gz` | `a663d946002aa8eeed255f8df4cde6c49faacf1b304b5ed370eef48cf2f04f5f` |
| Shared raw tool identity | `shared-core/snapshot-6/source.tar.gz` | `f533762770c9cba6c7cd4b99c2ad1b46e9e8946ad9b7ab9d24c05dcea3afc7b3` |
| CPA lab, source admission only | `source-handoff-v3.tar.gz` | `4a2353399c2ae5e69fe14cb6cc46805a4cec1a891d9faae5e7b6fc9b0cb2804e` |
| Native-client QA | `native-qa-source.tar` | `124421eaf3979cf5244476dcc3dba979b0f93b4be9a7cae77b2875c97d3d670b` |

Native QA also requires the five-file provenance/event-wording follow-up
`native-qa-followup.patch`, SHA-256
`2d9764c08aa8af06a6f296d316c37e09bf9302411609a9dc2e3f246144816ec0`.
It distinguishes source-base provenance from the measured candidate and
observed protocol events from actual rendered partial text.

The mandatory native report-admission successor is the complete 15-file
`native-qa-admission-source.tar`, SHA-256
`a0e38f41a4d0e99a90dc73bb6f67e7624981994e06017c99b71e5a058d058f50`.
It supersedes the earlier native source inventory. The coordinator verified
its archive hash, read the validator/runner/harness, and ran one canonical
synthetic positive plus ten in-memory negative controls without launching
clients, Docker or network operations. Its 31 guarded destination unit tests
also passed; no actual native client ran.

The Claude policy package alone is **not enrollment-safe**. Shared S4, then
S5, then the Claude enrollment correction are required. Kimi's gateway
enrollment consumer needs the same begin-before-network and exact-generation
commit/cancellation semantics. Historical red demonstrations are evidence,
not source overlays.

## Release review findings

- Assembly was incomplete at audit start: Codex HTTP was staged but not
  installed; xAI source was imported but its new gateway bindings were not
  connected; Devin was only partially imported. Owner suite counts cannot
  establish readiness of those assembled routes. All delivered source is now
  integrated; Codex HTTP is wired and tested. xAI OAuth/WS and broader Devin
  gateway operations remain explicitly unregistered, not implied by import.
- Enrollment could overwrite a concurrent administrative credential change.
  S5 reservations and provider/gateway consumers must cover first enrollment,
  replacement, same-value replacement, deletion/recreation, cancellation and
  crash recovery. An unknown storage outcome is not permission to retry
  provider exchange or save unconditionally. Shared/Claude regressions and
  real Kimi root/shipment enrollment races now pass.
- Claude's header-only rejection hook classified every HTTP 429 as
  credential quota. The body classifier's request-scoped fast-mode result
  was only exercised in tests. An independent compiled probe confirmed both
  automatic retry and a separate unconditional quota-ledger cooldown.
  Changing the rejection reason alone cannot fix the latter. Production pool
  cooldown/failover must not misclassify a fast-mode entitlement refusal.
  Conservative provider-open interception is wired to all Claude routes.
  Two-account API-key/OAuth root and shipment checks pass for buffered
  Messages, SSE and counting: one send, no cooldown, immediate/restart reuse.
  Genuine quota 429s also forgo automatic failover and return sanitized 503;
  this deliberate availability/status difference remains a fidelity gap.
- CPA lab v2 failed source admission for writable policy/artifacts, implicit
  integration execution in default test discovery, and insufficient
  descendant-process cleanup. V3 source and its 47 guarded unit tests are
  integrated; execution blockers remain enforced. Safe source/unit admission
  is not permission to launch CPA or candidates.
- The native-client outer runner accepted a `passed` status without validating
  the required client exits, observations and fixture binding. Independent
  in-memory negative controls reproduced acceptance of both a status-only
  result and a wrong-client/wrong-workflow/wrong-fixture result with empty
  evidence. Process, network and write boundaries were mocked or prohibited;
  no client/container ran. The admission successor fixes both cases in the
  coordinator's focused checks. Tool, continuation and cancellation cannot
  qualify as passes until stronger workflow semantics exist; all eight rows
  remain in the inventory. The corrected destination unit gate passes;
  actual native execution remains unperformed.
- An independent compiled xAI probe found that a function-arguments-done event
  retained its top-level aliased tool name while output-item events restored
  it. The shared codec also accepted an optional top-level name inconsistent
  with the established item. S6 raw validation plus xAI v3 restoration and
  their composed local WS regression now pass.
- Gateway configuration accepted a trailing slash on an origin which xAI
  preparation then rejected after constructing a double-slash path.
  Configuration now removes only an already-validated root slash before
  runtime/provider admission. Paths, userinfo, queries, fragments and the
  Devin nonnumeric/nonloopback cases retain explicit rejection.
- The third destination gate exposed client-key revocation checking only at
  WebSocket upgrade. Current authorization is now mandatory for every new
  inference, before acquisition and again before send. Thirteen WS tests and
  real root/shipment live-connection revocation checks pass. This is not an
  atomic/proactive interruption guarantee for an already-admitted response.

## Remaining parity proof and functionality

- **Claude:** full client feature/beta baseline, some registry-dependent
  thinking conversion, companion profile/usage workflows, and CPA's lossy
  cache repairs are not established. No fabricated device identity, billing
  signature or transport fingerprint may substitute for evidence.
- **Codex:** native Responses-lite sparse event/terminal hydration remains
  unsupported. Safe server-history HTTP replay intentionally differs from
  blindly deleting `previous_response_id`. Physical WS support must not imply
  native WS-lite support.
- **Kimi:** native Chat streaming, tools, model-specific thinking and supported
  image forms have source/mock coverage, distinct from generic buffered Chat.
  Messages streaming needs the Claude-owned restoration hook. Compact is
  explicitly denied by pinned CPA, not an automatic implementation target.
  Continuation, unsupported media, schema-reference inlining, legacy/custom
  tools and CPA's lossy repairs remain outside the delivered bounded slice.
  Captured synthetic header order is not a CPA differential comparison.
- **xAI:** the delivered provider keeps HTTP `previous_response_id` rejected;
  its library continuation is WS-scoped. Gateway OAuth and physical WS are
  still not exposed. Compact tool controls, media and custom/dynamic tool
  cases are not all supported.
- **Devin:** remote binary transport/H2/ALPN qualification remains blocked.
  Shared client streaming projections, Responses conversion, complete media,
  tools, catalog and tokenizer behavior are incomplete. Numeric-loopback TLS
  tests do not qualify a real Devin endpoint.
- **CPA differential:** historical execution of the actual pinned executable
  produced failed observations, not parity. Strict37 remains incomplete.
  An unconditional excluded-provider updater and lack of enforceable
  detached-descendant containment block further reference/candidate runs.
- **Native clients:** official pinned Claude Code and Codex Linux artifacts
  were acquired and integrity-checked; all eight actual client workflows are
  blocked. Native executions and image builds are zero. Unit fixtures do not
  count as a client workflow. Parent-death/forced-termination cleanup of the
  actual container is also unverified; a `finally` cleanup path alone does not
  prove containment survives loss of the controlling process.
- **Live:** no live qualification. The native live command is an authorization
  preflight, not an executor: endpoint-only egress and request/token/cost
  enforcement remain missing. Kimi/Codex/Grok have standing user consent, but still
  need explicit account, endpoint, model, test data and bounded budgets.
  Claude Code additionally needs the requested upstream CPA check before live
  execution.

Source review, synthetic transport tests, assembled workflows, CPA
differential, actual native clients and live providers are separate evidence
axes. Neither test totals nor imported-file counts provide a parity percentage.
