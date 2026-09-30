# CPA-gap wave: integration contract and queue

## I1 checkpoint

Integration parent: `3e00808ff0fefbb6728edb1769c17139ef0fd93a`.
Reference CPA: `acdace936fa7df2905500c7f5e0a97d683138dea`.
Origin: `https://github.com/stepandra/mimic.git`.

This is a source integration candidate, not publication authorization.
No commits, pushes, movement of `main@origin`, sibling-checkout edits, or
automatic independent-thread merges are permitted during this wave.
Gemini, Antigravity and Copilot remain excluded. The strict 37-row matrix
remains required; missing rows cannot be waived by local test success.

Integration alone owns gateway/config/enrollment/refresh/WebSocket routing,
`src/mimic.gleam`, root dependencies, vendored Mist, release scripts and assembled
workflow tests. Shared-core owns wire/IR/dialect/protocol/runtime/auth-runtime
internals. Provider owners own their provider namespaces and specific tests/docs.
Differential and native-client owners retain their named scripts/tests/docs.

## Existing typed boundary

These are baseline APIs, not promises that proposed features have landed:

- `contracts.Request` declares provider, auth mode, model, protocol, operation,
  mode, required capabilities, session and optional pinned account.
- `registry.Model` declares auth modes, protocols, operations and capabilities.
  `registry.resolve` must fail unsupported requests before acquisition/I/O.
- `contracts.Adapter(handle)` has `open(Context, Request)`, `next(handle)`,
  `cancel(handle)` and `rejection(status, headers)`. `Context` supplies the
  runtime-selected account, origin, session key and private auth material.
- `contracts.SessionAdapter(handle)` has `open(Context, Request)`,
  `send(handle, Request)`, bounded `receive(handle)` and `cancel(handle)`.
- `runtime.open` and `runtime.open_session` own leases/credentials; response
  processes synchronously call `runtime.adopt` or `runtime.session_adopt`.
  One owner releases/cancels once. Do not replay Started/Uncertain requests.
- Gateway config translates explicit operator accounts to runtime accounts.
  Gateway refresh transports provider-owned token plans; runtime owns refresh
  singleflight, CAS, durable recovery fences and credential mutation.

Provider factories must not capture a token or the first configured account's
origin. All selected-account-dependent plans are built inside `open(Context,
Request)`. Matching an HTTP transport is not evidence of provider readiness.
Config must not advertise a capability until its registered operation, adapter,
codec and actual route work together.

## Proposed hooks: integration direction, awaiting owner checkpoints

| Owner | Integration direction | Admission condition |
| --- | --- | --- |
| Claude | Preserve `adapter.prepare(Context, Request)` and shared runtime ownership | Policy normalization tests plus actual messages/count-tokens route evidence |
| Codex | Lite stays on the Responses upstream path; explicit marker/metadata normalization belongs to provider | Compiled operation/capability hooks, typed receipt handling, header/body precedence tests |
| Kimi | Byte-native bounded Chat streaming; reversible model/tool restoration; provider-owned Anthropic delegation | Exact prepared-plan/stream signatures and codec evidence; compact/continuation remain denied |
| xAI | Selected-context HTTP factory, OAuth policy, explicit operation origins | Exact config/registration types and refresh contract; no factory origin or token capture |
| Devin | Broader provider codecs on existing binary-plan boundary | No remote/H2 gate relaxation; capability-specific actual-route tests |
| Shared-core | Additive bounded protocol helpers and operation binding hooks | Preserve single credential runtime; resolve binding after account selection |
| Differential lab | Existing versioned driver contract, explicit executable containment | Real CPA/reference and MIMIC outcomes, missing cases fail |
| Native clients | Separately acquired pinned clients; fail-closed offline containment | Actual client runs or explicit blocked result, never fixture-only success |

### Additive shared hooks approved by integration; peer agreement pending

Integration approves implementing the proposed additive
`auth.runtime.acquire_versioned -> #(AuthMaterial, opaque Revision)` and
`runtime.open_scoped` callback, leaving existing acquisition/open APIs intact.
The revision must describe the exact acquired credential, not a later reread.
Provider-computed access/refresh-token hashes are not the agreed generation API.

Integration approves a bounded, expiring, **in-memory** receipt store for this wave.
Gateway supplies authenticated tenant identity; runtime/provider preparation
supplies selected account, model, origin and credential-generation binding.
Only server-observed successful output creates a receipt. Clients cannot assert
receipts, scope, account or origin. Resolve IDs before I/O and pin the producing
account. Cancellation, invalid terminal output and uncertain delivery must not
mint reusable receipts. Expiry, credential change, revocation and restart
invalidate old receipts; restart requires full-history recovery, not reseeding.

The shared helper can be pure; integration will supply the single lifecycle
owner. A pure helper alone is not assembled continuation support. Before wiring,
owners must agree exact types for trusted scope, lookup/commit/invalidate and
credential generation. Durable receipts are a separate product/security decision
because they persist conversation content. No new persistent store by inference.

Additive Responses `run_fold` is approved; accumulator return does not itself
authorize a receipt. Incomplete/failed/cancelled/malformed results never commit.

Integration approves additive `start_with_bindings(store, registry, accounts,
List(EndpointBinding(provider, auth_mode, account, protocol, operation, origin,
egress)))`, with startup validation of explicit operator bindings and lookup
after account selection. Duplicate/conflicting/unknown-account registrations
must fail. It reuses the single credential worker, never duplicate accounts to
represent an OAuth proxy and API origin. No request-supplied origin or silent
factory substitution. Gateway config wiring awaits compiled exact signatures.

Separate native
`kimi` and generic `openai-compatible-kimi` registration is a provider proposal,
not yet an integration-approved new namespace or capability.
Kimi Messages delegation requires a Claude-owner-approved stream observer hook.
Devin remote binary/H2 restrictions remain unchanged. Differential owner reports
an unconditional excluded-provider background updater in CPA: further launches
remain paused, not silently approved by the existence of a network sandbox.

## Source-only handoff format

Use `scripts/release/checkpoint.py` with a versioned `manifest.json` and a
`source/` directory containing **only** the exact listed files. No archive
extraction or broad checkout copy. A manifest includes:

```json
{
  "schema": 1,
  "checkpoint": "provider-feature-v1",
  "owner": "provider-owner-thread-id",
  "owner_approved": true,
  "base": "3e00808ff0fefbb6728edb1769c17139ef0fd93a",
  "cpa": "acdace936fa7df2905500c7f5e0a97d683138dea",
  "dependencies": [],
  "files": [{"path": "src/mimic/providers/example/feature.gleam", "sha256": "64 lowercase hex digits"}],
  "tests": [{"command": "mise exec gleam@1.18.1 -- gleam test", "exit_code": 0, "scope": "owner overlay", "log_sha256": "64 lowercase hex digits"}],
  "axes": {"source": "reviewed", "mock": "passed", "differential": "not_run", "native_lab": "not_run", "live": "not_run"},
  "limits": ["Exact unsupported cases; original failed runs are separate test entries"]
}
```

All fields are required. `dependencies` lists prerequisite manifest SHA-256s,
not moving worktree references. Ownership grants are supplied independently by
integration using repeatable `--allow-file` exact paths or `--allow-dir`
recursive directories. Grant kind is never inferred from incoming source.
A provider may not grant itself gateway/root/shared paths. File removal requires a
separate
reviewed deletion plan; this first format does not perform deletions.

The verifier checks base, schema, regular files, path safety, exact inventory,
hashes and explicit grants. It never executes manifest commands or imports
metadata, build output or private state. Owner approval/test entries are
**attestations**, not independent validation. Source review is still required
to rule out embedded secrets or malicious code.

```sh
python3 scripts/release/checkpoint.py verify /path/to/checkpoint \
  --allow-dir src/mimic/providers/OWNER --allow-file test/OWNER_test.gleam
python3 scripts/release/checkpoint.py stage /path/to/checkpoint \
  --allow-dir src/mimic/providers/OWNER --allow-file test/OWNER_test.gleam
```

Staging creates a new content-addressed directory below ignored
`build/integration/cpa-gap/overlays/`, never overwrites a checkpoint, and does not
install source into the checkout. Integrator reviews and applies exact approved
source with `apply_patch`, then independently builds/tests the assembled inputs.
Overlays must not be mistaken for validated assembled application trees.

## Integration queue

| Slot | State | Approved immutable manifest |
| --- | --- | --- |
| Shared protocol/runtime | S4 imported; parent stable gate passed; additive enrollment S5 import pending | `420cb193f1275ffdad89cf6d61fae9cbbae03b8cdeb677a6bf08c6d98338943f` |
| Claude policy | All 15 v1 files imported; enrollment CAS follow-up pending | `c42c4004b65511b73254080f24406896295ea0d0865ae6b7ec326046159f96f3` |
| Codex HTTP/lite | S4-based snapshot 2 verified/staged; opt-in decision pending | none |
| Kimi | v1 plus wire-v2 imported; native/generic/Chat/Responses/buffered Messages CLI + shipment passed | see wire-v2 below |
| xAI | All 19 v2 files imported; selected native adapters/OAuth/bindings not wired yet | `7391b1175a133abcfcdcd9068281b88bc2b8582231119acf9c9f5eada9c477e7` |
| Devin | Partial only: six changed files, 10/32 owner paths match; remaining import pending | none |
| Differential lab | v2 staged but rejected pending containment/default-discovery fixes; CPA startup blocked | none |
| Native clients | Source + follow-up imported; root unit gate 21/21; native execution blocked | `docs/source-manifests/native-qa-wave-v2.sha256` |
| Integration I1 | Base and local gate independently measured | see below |

No peer input is staged, compiled, or integrated merely because it sent a
progress message. Each accepted checkpoint will record its manifest digest,
prerequisites, changed paths, integration test run and any superseding digest.

### Post-I1 verified staging, not installed

These normalized manifests live at
`build/integration/cpa-gap/overlays/<manifest digest>/manifest.json`, with
the exact approved inventory beneath `source/`. Archive members, individual
hashes, base and ownership grants were independently verified before staging.
Owner test reports remain labeled attestations, not local execution logs.

| Input | Files | Archive SHA-256 | Normalized manifest SHA-256 |
| --- | --- | --- | --- |
| Shared-core S3 | 17 | `f6c39981bd331612b67e5bd21dd582f138facd2767b4479ba09d84a7cf9d85e8` | `6df12427747a35b5bb7c60772dc9ff7db2778be1779aa593babb1def1c158b19` |
| Shared-core S4 | 17 | `f318501aaaa1cbf5a8c477097b871387b6a85f30a9692c2f9cdda1dc524bb5bc` | `420cb193f1275ffdad89cf6d61fae9cbbae03b8cdeb677a6bf08c6d98338943f` |
| Codex HTTP snapshot 2 | 16 | `332278d8bf6384d639f13929d081c18709c66799d86601f70135f160ced1a21a` | `97d47444e3f1743261330bbd56da115345038a4421334478410c310574b88588` |
| Claude policy v1 | 15 | `f70ba1c673b52c8928cd8d4e6589ad3b96c0b4f594a109cb679f0718e22a723d` | `c42c4004b65511b73254080f24406896295ea0d0865ae6b7ec326046159f96f3` |
| Kimi wire-v2 follow-up | 4 | `f7aee059133ffbd54d1a439e68976a47db01e9c17e46831c42d10a234251c1ae` | `4fbe48ca5d23160188c3bf1385e7649b3733c91d6afb117ee04b65a637e1dc95` |
| Native QA v1 | 14 | `124421eaf3979cf5244476dcc3dba979b0f93b4be9a7cae77b2875c97d3d670b` | `ce9aa030f96d3594b153a48649af9f9b8ae67a038f2e99fcde8f65bb976c6788` |
| CPA differential v1 | 11 | `d0b4f60ec61e5cadd9fac7c86c3dc686430dad100783a0ecbab629609cda0c3f` | `4c74701394d91c189615d43874a58e75d27fd0817be4fc1f1a8efa4d25313f09` |
| CPA differential v2 (blocked) | 17 | `bdc440144f89fe319b931a54fa2b40172792357694c72e4cce8071108aa6aa43` | `6222e70903658f358bfd99b88597fddbc0e1362179045a18b0043916b4bbe285` |
| xAI native v2 | 19 | `1fa25e82b69b45c8d435c918bc387427691e14fb7eb14d2d967e3d90fded5a92` | `7391b1175a133abcfcdcd9068281b88bc2b8582231119acf9c9f5eada9c477e7` |
| Devin native snapshot 1 | 32 | `be95cefb846f6bdc07dba16df27f8af68873b6299c856ef52e06405a31b9fe57` | `be4ca60c3509c92724b216d236cbeb58d31dfa199b8b014094458b823b8e2f39` |

- Shared S3 owner reports full local gate 543 Gleam +10 Python and scenarios/
  shipment passed. S4 will include a reviewer-found Chat named-error fix,
  expanded boundary tests and the preselection lookup below. S3 is retained
  as an input artifact, not promoted to assembled support.
- Native owner reports 21 Python contract tests, baseline 522 Gleam tests and
  export passed. **Zero native-client executions**: all eight workflows are
  blocked by unavailable Docker; runtime image is unbuilt. The integration
  reviewer may run synthetic loopback unit tests only, not acquisition,
  containers, client binaries or external requests.
- Differential owner reports 523 Gleam +22 Python tests, strict37 exit 1,
  **0/37**. Its separate 502-file evidence archive is not imported here.
  The unconditional CPA background updater remains a launch blocker; no
  additional CPA run is authorized. Its current preparation command only
  accepts clean published-base production sources, so the owner is designing
  an explicit hash-bound candidate-identity input before assembled use.
- xAI v2 owner reports 530 Gleam +10 Python and source/shipment checks passed.
  Integration independently verified its 19 source hashes and the separate
  gate/native/S3-binding log hashes, but has not executed that source here.
  HTTP tools require `selected_http`; WS requires `selected_adapter` and the
  dedicated operation. The versioned S3 binding fixture remains a fixture until
  explicitly compiled/tested against the assembled shared source.
- Shared S4 owner reports its exact full gate passed, 549 Gleam +10 Python;
  integration independently verified raw gate-log hash
  `2a96a5d22d10a7d022db35751843a2d127b12c20828330132b8d7effd919af7d`.
  Codex snapshot 2 reports an exact-base +S4 +Codex assembly passed 567 Gleam
  +10 Python plus source/shipment checks. Its normalized manifest explicitly
  depends on the S4 manifest above. These are owner execution results, not a
  rerun of the current integration checkout. Snapshot 2 supersedes snapshot 1
  for the remaining Codex import.
- Differential v2 implements candidate identity, but independent review found
  a blocking runtime-containment flaw: the child-writable runtime directory
  includes `sandbox.sb`, which the parent rereads for later provisioning/server
  launches. The default discovered tests also conditionally execute a real
  Gleam export on Darwin. **Do not import or execute v2.** Owner has been asked
  for parent-controlled immutable policy plus cross-launch regression tests and
  explicit separation of build/integration tests from default unit discovery.
  The reviewer ran 41 inspected controls, not the excluded build/acquisition/
  Seatbelt integration cases. No candidate or CPA process was launched here.
  The final review also identifies child-writable copied shipment bytes and a
  static detached-descendant cleanup gap. Exact scope, locations, exclusions and
  source-only findings are retained in `CPA_GAP_BOUNDARY_REVIEW.md`.
- Devin's 32-file snapshot is hash/base/CPA-pin verified. Owner reports a
  561 Gleam +10 Python full gate followed by additional independently compiled
  and exercised fresh-VM persistence scenarios. The original 556+1 failure is
  preserved in owner documentation. No combined gateway execution is claimed.
  Default Buffer/Tools/configured Images does not enable Stream, Responses,
  continuation, remote binary or H2. Its pure continuation API is not an
  approved replacement for runtime-issued Revision or the agreed nonpersistent
  gateway state policy.

The Claude normalized manifest preserves the owner's 300-second full-gate
timeout in its report/limits without inventing an exact process exit code.
The earlier local normalization `13b0d03d8bc57dfb803695c853998c4becf2fd12536b303eb841ce3d7fdda889`
used a conventional timeout code; it is superseded by `c42c...` above. Source
bytes are identical. Owner reports 536 tests and focused scenarios passed;
there is no owner final whole-script/shipment/CI claim.

#### Source-only assembly and accepted partial scope

Internal integration workers are mechanically applying exact approved source,
not implementing new provider behavior or creating new feature owners:

| Frozen source | Archive SHA-256 | Relationship |
| --- | --- | --- |
| Shared S4 | `f318501aaaa1cbf5a8c477097b871387b6a85f30a9692c2f9cdda1dc524bb5bc` | Cumulative S1/S2/S3 plus reviewed Chat fixes and same-cache locate |
| Claude policy v1 | `f70ba1c673b52c8928cd8d4e6589ad3b96c0b4f594a109cb679f0718e22a723d` | Existing default prepare retained; no Kimi restoration hook |
| Kimi v1 | `bb17b35359aba919bc3224cc18b062964c1d9bcdc72522d92a24343c65e60905` | Requires shared S2; owner additionally retested against S4 |
| Codex HTTP v1 | `9b081a258d424a6e1a7d7f7ea88dadae9da02cef47cf536c408f1a66c87c24df` | Requires shared S3; ingress pin/locate integration is not yet enabled |

The importer has been directed not to start the old Codex v1 batch: the verified
snapshot 2 above is the current target, after completing S4/Kimi first.

Each batch must match all owner hashes after literal `apply_patch` import,
then compile/test. No terminal `patch`, broad source copying or modifications
to frozen owner bytes are authorized. Parent retains gateway/root ownership.
S4 and all 21 Kimi v1 destinations were independently checked in the parent
against their 38 original owner hashes. The Kimi wire-v2 follow-up then replaced
only its declared test expectations and added an actually observed v2 fixture;
the original v1 fixture remains unchanged. All 15 Claude policy and 19 xAI
destinations also matched their approved manifests.

Root Kimi Chat SSE, buffered Messages, requested-model restoration and expanded
actual-CLI/shipment tests have passed the stable gate below.
Distinct `openai-compatible-kimi` API-key/buffered-Chat routing and config are
included. Generic paths are API prefixes (default `/v1`), not native coding
prefixes. The generic path never applies native model/thinking/device policy.
CLI tests cover native/generic coexistence in either account order, a missing
first-account credential, exact generic request preservation, separate
credentials, restarts without reseeding and unsupported auth/route/stream/state
rejection. Generic streaming, Kimi Messages streaming, compact and continuation
remain explicitly rejected.

The Devin importer returned only six changed exact-owner files:
`auth.gleam`, `continuation.gleam`, `models.gleam`, `status.gleam`, `tokens.gleam`
and `test/devin_status_test.gleam`. Four pre-existing files also match the
snapshot, giving 10/32. This is not Devin snapshot acceptance. It did not import
the expanded bridge/request/response, 12-scenario runner or fresh-VM persistence
scenario; its inherited six scenarios and four direct status tests are not
evidence for those missing parts.

#### Stable parent gate and preserved failures

- Parent `gleam test` initially passed 576 after exact S4/Kimi import.
- `s4-kimi-http-cli-001.log`: expanded root HTTP CLI passed, SHA-256
  `274d978bdd8fd8d857d06b88929f4ce25b4c9af1c67eebe1f11995a3a0293887`.
- `s4-kimi-native-full-001.log`: failed the owner wire-v1 test, which still
  expected upstream model names downstream. SHA-256
  `30fa83f3b5829d3bb1d811e25c364c9f1f18f448853bea9c13ba2d7b15733e80`.
  The owner reproduced it and generated wire-v2 from real synthetic loopback
  observations, retaining the immutable v1 fixture.
- `s4-kimi-native-full-002.log`: script exited 0, but the before/after source
  guard detected all 19 xAI files arriving during execution and rejected the
  overall attempt with exit 2. This mixed-source run is **not** a clean gate.
  Log SHA-256 `928efb39a804a4000ae7eeceed264155bd250665ba7b1afdf0c5f20bf831cea4`.
- `s4-kimi-native-full-003.log`: script and source guard both exited 0,
  **602 Gleam tests**, 10 parity Python, 13 release-tool Python, 21 native-QA
  unit contracts and one Kimi wire test exercising three CLI modes. All source
  and shipment workflows passed. **442 source inputs were unchanged** across
  the run. Log SHA-256
  `ff3e45cbd4f21ba7476c4898e88b812cd09f11836b69d9ffc86508fde3a0e161`.

These logs and the source-before/source-after/result JSON receipts remain in
`build/integration/cpa-gap/`. This is a clean local gate for that checkpoint,
not completion of all nine threads. Subsequent enrollment changes below still
require their own assembled validation.

#### Enrollment race: reproduced release blocker, fix in progress

Inspection found async Kimi and Claude enrollment ended in unconditional
`runtime_store.save`, allowing a later callback to overwrite intervening admin
replacement/deletion. Claude owner independently reproduced 12 cases.
The parent added actual Kimi root-CLI races:

- First fixture attempt stopped on deleting a still-absent slot
  (`kimi-enrollment-red-001.log`, SHA-256
  `ad447449f580aeb743c73b79518c93c3fbf88103e792e1abce92d885b9e60682`).
- The corrected test records whether admin mutation was accepted rather than
  hiding that missing reservation. It reproduced clobber/resurrection in all
  six cases; five admin mutations succeeded, and first-absent deletion could
  not succeed without a pending marker. `kimi-enrollment-red-002.log`, exit 1,
  SHA-256 `b2fc35fd9f7203a33503c42a5686f052a90c13a668aa411c3f74e75837589506`.

Approved shared S5 uses an opaque exact-slot enrollment ticket, a nonce-only
same-slot first-enrollment marker, exact CAS commit and durable cancellation.
Existing cancellation preserves material/gate but bumps the local revision,
invalidating generation-bound receipts/sessions; it does not revoke upstream
tokens. A crash marker requires explicit admin deletion, never TTL takeover.

S5 archive `a663d946002aa8eeed255f8df4cde6c49faacf1b304b5ed370eef48cf2f04f5f`
and Claude enrollment follow-up
`42846c04ca4464fb9bdd38e6c41743051c32ac7131d288d542c2bd1662a27361`
are queued for exact import. The parent Kimi call-site patch and source/shipment
race-gate wiring are drafted against those APIs, not yet validated. No fallback
to unconditional save or automatic replay is permitted.

Native QA independently passed all 21 contract tests with guarded synthetic
loopback traffic, zero skips, zero subprocess launches and no external traffic.
The reviewer approved source import and default **unit-only** wiring, not
native-client execution. An owner-published five-file follow-up patch
`2d9764c08aa8af06a6f296d316c37e09bf9302411609a9dc2e3f246144816ec0`
labels the original base as `source_base_revision` and narrows cancellation
evidence to native event observation, not rendered text/latency. The exact
v1-then-patch import is accepted. All 14 destination files independently match
the original nine unchanged hashes and five owner-approved follow-up hashes;
the final inventory is `docs/source-manifests/native-qa-wave-v2.sha256`.
Root gate wiring uses
`scripts/release/native_contracts.py`, never acquisition/build/client commands.
The actual parent command `python3 -I -S -B scripts/release/native_contracts.py`
exited 0: 21/21 tests, zero skips, synthetic loopback only, zero native-client
executions. Log `build/integration/cpa-gap/native-root-contracts-001.log`,
SHA-256 `4248f468b19793ed27af3d84852722cc2a43e01adb48e8a369005dac58a2c877`.
This does not make the pending provider/gateway assembly or native runtime green.

#### Agreements and remaining typed gaps

1. **xAI operation binding:** protocol `responses`, internal operation
   `responses/websocket` for xAI WS, while the wire endpoint stays
   `/v1/responses`. Bind HTTP `responses` to the configured proxy origin,
   `responses/websocket` and `responses/compact` to configured API origins.
   Advertise WS operation only when enabled. Codex operation labels are
   unchanged. Legacy adapter aliases must not bypass the selected binding.
2. **Continuation preselection:** registry admission needs the server-pinned
   account before runtime selection, while `get` needs the full selected
   Context/Revision scope. Shared owner agrees to additive
   `locate(cache, tenant, request, receipt_id) -> Result(String, String)` from
   the same cache. Match authenticated tenant/provider/auth/model/protocol/
   operation/client session/id; expire first; reject missing or distinct-account
   ambiguity. `request.pinned_account` must be absent for lookup. Returned
   account is routing metadata only; `open_scoped` plus `get` must validate
   current revision/origin before I/O. No second receipt registry.
3. **Stable client session:** a random request-local fallback cannot resume.
   Codex and integration agree continuation requires a stable,
   authenticated-tenant-namespaced session identifier, not an authorization
   credential. Native QA source research pins Codex 0.158.0 to commit
   `064c6b8c737f5b41d171fdda80bd9ef10ad06eb3`: `thread-id` and
   `x-client-request-id` derive from the stable thread ID, whereas `session-id`
   is root/cache affinity and turn-state is turn-local. Codex owner is adding
   `routes.client_session_hint` with agreeing thread/request-ID fields and
   duplicate/conflict rejection. Gateway will require a valid stable hint for
   continuation and retain parser-level singleton protection. This is
   source-backed expectation, not an observed native-client run.
4. **Receipt publication:** cache removal is not a permanent tombstone.
   Integration must fence in-flight completion against cancellation/shutdown
   and publish only validated Completed plus clean EOF. Provider receipt
   policy remains provider-owned; current generation is runtime-issued.
5. **Differential candidate identity:** approved additive
   `--prepare --candidate-manifest FILE --candidate-sha256 DIGEST
   --candidate-source ARCHIVE` over a complete explicit source inventory, not
   overlay/dirty-checkout inference. Schema `mimic.parity-candidate/v1` records
   base revision, archive SHA-256 and all input-file hashes. Verify locked local
   dependency closure, reject missing/extra/unsafe inputs, export fresh offline,
   and recheck sources afterward. Acquisition remains separate. Record target
   as `candidate-sha256:<digest>`, never falsely as the published base.
   The CPA startup blocker remains unchanged in both old and new paths.

#### Coordinator decision requested: HTTP receipt opt-in

Problem: `codex/http.open` always publishes a successful receipt. Routing
header-less requests through it would retain unresumable random-session entries
and introduce cache-capacity failures into ordinary stateless traffic.

Options:

1. Cache every HTTP Responses request. Simple routing, but unnecessary history
   retention and new capacity failures for requests that cannot resume.
2. **Recommended:** explicit `codex_http_continuation` operator opt-in,
   default false. When enabled, route only valid stable authenticated thread
   sessions through one bounded, nonpersistent cache; ordinary stateless and
   compact requests stay cache-free.
3. Implicitly enable whenever a stable header is present. Convenient for native
   clients, but makes history retention and memory policy depend on request
   metadata rather than an operator choice.

Proposed limits for option 2: 32 entries, 8 MiB total, 2 MiB per entry and
15-minute expiry. The Codex owner agrees with this direction; coordinator
approval is pending. In all options, `previous_response_id` with receipts
disabled or no valid stable hint must fail before I/O. A request already on the
stateful path must never fall back after cache missing/stale/full/duplicate or
Started errors. No source changes to the frozen provider are needed.

### Accepted shared-core snapshot 1

Owner: `ksQQfrCkbvM5QAS8eUbGJL4qhZLOAEn30JIBxBDu1fs15rdKs6m5jRdeJnRz`.
Owner-announced immutable `snapshot-1/{BASE,SHA256SUMS,source.tar.gz}`:

- Archive: `e007264b76923ff4701cd26805057e12d427845d8a155a692b09e142c84dbdcc`.
- Original sums manifest: `4bc482ae594b7fd5148beaa8d2f7ffb3918f6bc653e177a1622bb74acaaca5fa`.
- Normalized local manifest: `fd2d703249cc22b5360f7542a955b3a45a287f61606cc7e66267f076f564a0dd`.
- No dependencies. Four exact regular-file inputs, staged independently under
  `build/integration/cpa-gap/overlays/<normalized manifest digest>/`.

| Source path | SHA-256 |
| --- | --- |
| `src/mimic/ir.gleam` | `c69873679d84052f072d0e06fc141140cacd5be1895fda28e3709e5bc83244cd` |
| `src/mimic/ir/json_guard.gleam` | `7901d278c3273b266b5ab83bab79a1d7570ce1098b5518901e558746eba7275a` |
| `test/ir_boundary_test.gleam` | `c1ee75b27cc9853a0ecf89be137eaf7877820a2c3c4a74bb96e3cae613194f9b` |
| `docs/SHARED_CORE_PARITY_WAVE.md` | `a069c7b72ccfb45b5144fa0e5d2e85622d337bf42b384e98206b052dad44e145` |

The legacy owner format was normalized locally after verifying archive hash,
exact member inventory, base and individual hashes, without broad extraction or
checkout copying. Its `tests` entry explicitly identifies the 44-test owner
attestation; that entry's hash is the saved message receipt, not a claimed raw
execution log. Independent assembled execution followed below. The imported
owner document is frozen historical evidence and has not been rewritten to
pretend its then-running baseline had already finished.

## Baseline evidence

Both runs used the unchanged published base and Gleam 1.18.1 on macOS.
Logs remain in ignored `build/integration/cpa-gap/`; do not import their
synthetic credential stores with the source package.

1. `baseline-001.log`: full `scripts/verify-integration.sh` exited 1 at Kimi
   CLI `credential status`: Mist application clock `init_timeout`.
   Earlier completed tests are not a full successful gate.
   SHA-256: `ad4645465c98a6f2183bb00b4d51b2ff4fc4d1543be62cb0fedcb39461478cbe`.
2. `baseline-002.log`: same script, with
   `ERL_FLAGS='+S 2:2 +SDcpu 1 +SDio 1'`, exited 0. This is an explicit
   host-resource setting, not a production timeout change. It supports but
   does not prove scheduler contention as the first failure's root cause.
   SHA-256: `cfa0ce7b21bf2782d718ddbc9ba88b04885a21d2d350c4f17ed32e7c39cd0b15`.

The successful run includes 522 Gleam tests, 10 Python driver tests, actual root
CLI HTTP/WS workflows, fresh-VM restoration without reseeding, and Erlang
shipment export/HTTP/WS smokes. This is local synthetic evidence only.
The parity runner's manifest `check` validates the manifest; it does not execute
or pass the strict 37-row differential matrix. No live requests/logins occurred.

The pinned Mist parser/version/singleton protection remains unchanged.
Format application/tests with `gleam format --check src test`; unchanged upstream
vendor formatting exceptions remain documented in `MIST_VENDOR.md`.

## I2 checkpoint evidence and independent review

`shared-core-1-gate-001.log` exited 0 with the same scheduler setting:
526 Gleam tests, 10 existing Python driver tests, 10 then-current release-tool
tests, all local scenarios/root CLI workflows/restart and shipment smokes.
SHA-256: `05724967d7c54b0ce32453809cd1e450b59e7024370c9f1556b0018ae4de7138`.
The three code/test files matched before execution. The initial hash command
also reported a documentation mismatch, but its shell did not stop the following
gate. A final export review caught the omitted `PendingCall` sentence in the
owner API table; it was restored exactly. The earlier claim that all four files
matched before the gate was incorrect. This correction changes no executable
code. `source-integrity-001-failed.log` preserves the failed check (SHA-256
`f93e73f1094bae3a84728f8f2d199b52d68f91756784d38a98c5f59864b25580`).
Future export assembly verifies inherited hashes as a prerequisite in the same
process, rather than an unchecked earlier shell command.

Independent I1 reviewer reproduced two release-tool defects: suppressed walk
errors and exact-file grants authorizing descendants. Both new regression tests
failed before fixes (`checkpoint-tests-002-red.log`, exit 1, SHA-256
`cb2e05618142d61bfdee35e79d9826a1c909b7ac4297b0f4ca9e5211ac4fa6da`).
The tool now raises traversal errors and distinguishes explicit file/directory
grants. All 13 release-tool tests pass (`checkpoint-tests-003-green.log`,
SHA-256 `41bc43476543362447f832decc4a2b4b28c04eb00d48ef4ef50d943132337dbb`).
The staged shared checkpoint was reverified using exact-file grants.
The reviewer also verified the documented baseline typed signatures against the
pin; this was not an independent review of new provider implementations or a
repeat of the historical/full gate.

Final I1/S1 source gate after the release-tool fixes:
`checkpoint-i1-s1-gate-001.log`, exit 0, SHA-256
`172645c2e445a94f2111818d07facdac9e25be9eeb459880a7c1462c4a0765fd`.
526 Gleam tests, 10 parity-driver unit tests and 13 release-tool tests passed,
along with the entire existing CLI/scenario/restart/shipment gate.

Reproduce with:

```sh
ERL_FLAGS='+S 2:2 +SDcpu 1 +SDio 1' mise exec gleam@1.18.1 -- \
  sh -c 'GLEAM="$(command -v gleam)" sh scripts/verify-integration.sh'
```

The I1/S1 source-only export is
`build/integration/cpa-gap/exports/integration-i1-s1-v2/`: `manifest.json`
and `source/` contain exactly the eight changed source/documentation files.
Its manifest records the original failure, green baseline, review regressions
and final assembled test log hashes. No Git/JJ metadata, build outputs,
credential state or test logs are included. This is a small checkpoint, not
the final nine-thread merge candidate.
The immutable `integration-i1-s1-v1` export is retained but **superseded**:
manifest `57c35aa60b1f42f183e6f0919a0daa11e2901f3a5d2018cf4dc2581c14854a58`
contained the documentation-only import mismatch and must not be installed.

## Remaining release gates

- Exact approved source manifests and dependency closure, no namespace races.
- Actual root CLI and shipment tests for every delivered capability, with
  negative auth, model/operation pre-I/O rejection, selected-account origins,
  refresh/revoke/429/CAS/restart and SSE/WS prefix-error/cancel/rotation coverage.
- Original failed logs preserved next to later fixes/reruns.
- Separate source/mock/differential/native-lab/live report axes.
- Full assembled local gate and independent boundary review.
- Honest capability matrix; strict CPA gaps remain blocking.
- Source-only final export and separate coordinator/user publication approval.

Direct peer replies initially failed with "no thread ... known to this
workspace." Routing subsequently recovered: S3 was delivered to Codex/xAI/
Devin; shared-core approvals, Kimi/Claude delegation, and native/differential
artifact requests were delivered successfully. Recorded approvals are scoped
to the specific hooks above, not wholesale acceptance of unreviewed inputs.
