# Next parity wave: coordinator release audit

## Status

Audit and assembly are in progress. This document does **not** authorize a
parity claim or record a completed merge, destination test run, or push.
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

These are owner-reported frozen inputs, not evidence that every file has
already been imported or every feature connected to the assembled gateway.
The final destination inventory and test results must be recorded separately.

| Stream | Authoritative input | SHA-256 of source archive |
| --- | --- | --- |
| Claude policies | `claude-policy-v1.tar.gz` | `f70ba1c673b52c8928cd8d4e6589ad3b96c0b4f594a109cb679f0718e22a723d` |
| Claude enrollment correction | `claude-enrollment-v1.tar.gz` | `42846c04ca4464fb9bdd38e6c41743051c32ac7131d288d542c2bd1662a27361` |
| Codex HTTP | `codex-http/snapshot-2/source.tar.gz` | `332278d8bf6384d639f13929d081c18709c66799d86601f70135f160ced1a21a` |
| Kimi protocols | Final owner inventory pending coordinator verification | Not recorded yet |
| xAI | `xai-native/snapshot-v2/source.tar.gz` | `1fa25e82b69b45c8d435c918bc387427691e14fb7eb14d2d967e3d90fded5a92` |
| Devin | `devin-native/snapshot-1/source.tar.gz` | `be95cefb846f6bdc07dba16df27f8af68873b6299c856ef52e06405a31b9fe57` |
| Shared runtime, cumulative | `shared-core/snapshot-4/source.tar.gz` | `f318501aaaa1cbf5a8c477097b871387b6a85f30a9692c2f9cdda1dc524bb5bc` |
| Shared enrollment, incremental | `shared-core/snapshot-5/source.tar.gz` | `a663d946002aa8eeed255f8df4cde6c49faacf1b304b5ed370eef48cf2f04f5f` |
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
clients, Docker or network operations. Final destination tests remain required.

The Claude policy package alone is **not enrollment-safe**. Shared S4, then
S5, then the Claude enrollment correction are required. Kimi's gateway
enrollment consumer needs the same begin-before-network and exact-generation
commit/cancellation semantics. Historical red demonstrations are evidence,
not source overlays.

## Release review findings

- Assembly was incomplete at audit start: Codex HTTP was staged but not
  installed; xAI source was imported but its new gateway bindings were not
  connected; Devin was only partially imported. Owner suite counts cannot
  establish readiness of those assembled routes.
- Enrollment could overwrite a concurrent administrative credential change.
  S5 reservations and provider/gateway consumers must cover first enrollment,
  replacement, same-value replacement, deletion/recreation, cancellation and
  crash recovery. An unknown storage outcome is not permission to retry
  provider exchange or save unconditionally.
- Claude's header-only rejection hook classified every HTTP 429 as
  credential quota. The body classifier's request-scoped fast-mode result
  was only exercised in tests. An independent compiled probe confirmed both
  automatic retry and a separate unconditional quota-ledger cooldown.
  Changing the rejection reason alone cannot fix the latter. Production pool
  cooldown/failover must not misclassify a fast-mode entitlement refusal.
  A conservative provider-open interception before runtime observation is
  approved; implementation and assembled regression remain pending.
- CPA lab v2 failed source admission for writable policy/artifacts, implicit
  integration execution in default test discovery, and insufficient
  descendant-process cleanup. V3 is a separate candidate; safe source/unit
  admission must not be presented as permission to launch CPA or candidates.
- The native-client outer runner accepted a `passed` status without validating
  the required client exits, observations and fixture binding. Independent
  in-memory negative controls reproduced acceptance of both a status-only
  result and a wrong-client/wrong-workflow/wrong-fixture result with empty
  evidence. Process, network and write boundaries were mocked or prohibited;
  no client/container ran. The admission successor fixes both cases in the
  coordinator's focused checks. Tool, continuation and cancellation cannot
  qualify as passes until stronger workflow semantics exist; all eight rows
  remain in the inventory. Source admission is approved, destination testing
  and actual native execution remain separate.
- An independent compiled xAI probe found that a function-arguments-done event
  retained its top-level aliased tool name while output-item events restored
  it. The shared codec also accepted an optional top-level name inconsistent
  with the established item. Provider restoration and shared identity
  validation need separate, coordinated regressions.
- Gateway configuration accepted a trailing slash on an origin which xAI
  preparation then rejected after constructing a double-slash path.
  Configuration and selected-account preparation must agree on one rule.

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
  continuation is WS-scoped. Compact tool controls, media and custom/dynamic
  tool cases are not all supported. Actual gateway admission is a separate
  requirement from provider-only tests.
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
