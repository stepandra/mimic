# Final CPA parity wave

**Status: implementation resumed on the published integration baseline
`dd15c610ec39e4f296c30fe02347d0d2b368a629`; the full parity release is not done.**

One numbered slice below means one internal child assignment and one observable
deliverable. There are **44 slices across the nine-umbrella plan**, including
the newly discovered F44 boundary defect, not 44 simultaneous jobs.
Each umbrella runs at most one implementation child at a
time. The target is closure of the remaining declared compatibility contract,
not another set of provider libraries waiting for an integration megathread.

## Current completion pass

The original umbrella history and source baseline below are retained. The
current parent integrates small, tested slices as isolated workers finish;
there are at most six active implementation assignments, not six additional
umbrella queues. Root gateway/configuration/CLI and acceptance remain parent-owned.

| Slices | Current implementation/admission state |
| --- | --- |
| F01 | Offline contract imported; parent guarded preparation 159 tests passed; eight source obligations and runtime qualification remain unresolved |
| F02 | Containment runner and native-QA hooks imported; kernel qualification blocked on daemon, approved launcher and pinned image; parent 31 contract tests passed, not native execution |
| F03 | Qualified reference execution still blocked on approved containment and actual identity/routing evidence |
| F04 | Review corrections imported; exact closure passed 8 offline + 20 execution tests and synthetic CLI; root/full composition pending, live/native admission blocked |
| F05 | Actual root operational source workflow passed; raw duplicate-Origin regression passed after F44; composed cancellation returned unexpected 409 and remains under diagnosis |
| F06 | Imported shared Codex enrollment; focused, source and synthetic browser workflows passed in worker; composed/shipment gates pending |
| F07 | Core build, 43 focused tests, full root socket workflow and corrected full browser pass; favicon regression 2/2; final scripts synchronized, shared CT fix and shipment pending |
| F08 | Bounded local workflow admitted in `dd15c610`; live/upstream qualification still outstanding |
| F09 | Composed focused tests and actual configured gateway/source CLI passed; shipment still pending |
| F10 | Corrected classification imported; isolated default-off gateway/CLI and fresh-process gates passed; parent classified hook applied but not yet executed |
| F11 | Corrected shared codec returned, 108 focused tests reported; consumer/destination qualification remains separate |
| F12 | Strict-stream regression reproduced and fixed in source/shipment; full HTTP-lite root source gate failed idle disconnect cancellation, shared lifecycle fix in progress |
| F13 | Root off; recovered diagnostic candidate builds, owner-death peer closure fails despite local DOWN; abort reports false success on noproc, hardening/custody design pending; historical 176 passes do not qualify current source |
| F14–F15 | Source/shipment routes admitted in `dd15c610`; differential/native/live not implied |
| F16 | Imported; current worker source workflow passed: 94 focused tests, 7 accepted requests and 85 pre-I/O denials; parent shipment pending |
| F17 | Imported HTTP state-ID enforcement, 31 Gleam + 7 harness tests passed; root pre-runtime guard applied, actual source/shipment zero-refresh proof pending |
| F18 | Compiled source synchronized, no runtime tests; static review found global-binding partition, explicit-destination/model admission, acquired-revision and oracle gaps; repairs in progress, root off |
| F19–F21 | Remaining Grok tools and qualified media scope; queued |
| F22 | Local safety admitted; remote transport qualification remains separate |
| F23 | Local experimental Chat SSE admitted |
| F24 | Independent review depth correction applied; 29 focused tests and actual root source workflow passed; shipment pending |
| F25 | Historical packet passed 90 focused tests; later schema/cardinality/deadline repairs are source-only/unvalidated; nullable standard usage/native-accounting contract awaits user decision |
| F26 | Queued: Devin enrollment through the shared UI |
| F27 | Actual parent source workflow passed after fixture corrections: 9 synthetic requests, JSON/SSE parity, selected-account mapping/failover and pre-I/O denials; shipment pending, see docs/devin/F27_ADMISSION.md |
| F28 | Imported after 105 focused passes; actual parent source status workflow passed 4 positives/12 failure cases, unchanged grants/no fallback/store-busy safety; shipment pending, see docs/devin/F28_ADMISSION.md |
| F29 | Queued: Devin payload mapping |
| F30–F34 | Guarded preparation admitted; executable paired acceptance still outstanding |
| F35–F38 | Native execution still outstanding; pinned artifacts and containment required |
| F39–F42 | Live acceptance still outstanding; no real-account request made in this pass |
| F43 | Final qualification/publication not satisfied by an implementation test count |
| F44 | Four review corrections imported; parent build and 19 socket assertions passed; current root/shipment and full-suite gates pending; see F44_REVIEW_ADMISSION.md for timing-evidence caveat |

Current environment check: the macOS Docker client cannot reach its configured
OrbStack socket. This is an execution prerequisite, not permission to launch
uncontained clients or silently weaken the runner. Development and synthetic
loopback tests continue independently.

## Baseline and scope

- MIMIC input: `ca86b531cea7e1a509ac8e6038604fe91819ac07`.
- Existing CPA reference: `acdace936fa7df2905500c7f5e0a97d683138dea`.
- Measured baseline: 698 Gleam tests, 92 Python tests, actual synthetic root
  and shipment workflows, and successful GitHub CI.
- Historical strict conformance: 0/37. Eight actual native-client workflows
  remain blocked/unperformed. These are not replaced by the local test total.
- Providers: Claude, Codex, native/generic Kimi, Grok/xAI and Devin.
  Gemini, Antigravity and Copilot remain excluded.
- F01 checks upstream drift and freezes the exact reference, client versions
  and capability matrix before qualification. A changed reference or matrix
  gets a new version; it never silently replaces historical results.
- The user permits Kimi, Codex and Grok live tests. Claude Code live testing
  requires the additional upstream CPA check first. Devin live testing needs
  separate authorization. All live cases still need explicit accounts,
  endpoints, data, limits and functioning containment.
- Permission to create an OAuth state directory outside the checkout and run
  the proposed `127.0.0.1:9091` UI is still pending. Building and testing that
  UI with synthetic private state does not imply permission to start it with
  real credentials.
- The operator reports CPA already running at `https://localhost:8317`.
  A credential-free root GET returned HTTP 200 with successful normal TLS
  verification (no insecure override or redirects). This establishes
  reachability only: its build, reference identity and upstream routing remain
  unqualified. F03 must assess reuse without stopping, restarting,
  reconfiguring or reading credentials from that service. No inference was
  performed by this check.

**“Final” is a gate outcome, not a promise about the number of tasks.** Newly
discovered required behavior creates an explicit additional slice. It is not
hidden in an “etc.” item, waived by a test count, or silently dropped.

## Rules that prevent another integration bottleneck

1. **One slice per implementation child.** Umbrella threads coordinate their
   listed queues and dependencies; they do not combine the queue into one
   unreviewable change or race-edit their child's files. Each child owns one
   row below, including its regressions and handoff.
2. **Done means the actual route/workflow works.** A feature slice includes its
   provider code, minimal registration/configuration patch, actual
   gateway/CLI test and documentation. Adapter-only output is an intermediate
   checkpoint, not completion.
3. **Root edits use a short exclusive integration slot.** The coordinator owns
   `gateway.gleam`, root config/CLI, dependencies, vendor and CI. A slice
   supplies a small reviewed patch, rebases on the current integrated revision,
   and gets that patch applied and tested before being marked done. There is
   no final backlog of “gateway wiring left to parent”.
4. Shared-code changes have one explicitly assigned owner. Additive APIs are
   compiled and tested before dependent threads start using them. No guessed
   signatures, duplicate codecs, second credential manager or stub imports.
5. Each new thread verifies its actual checkout and dependency revisions.
   The base above is a starting point, not permission to develop forever
   against a stale checkout after dependencies land.
6. Handoff uses a stable local JJ bookmark/revision, exact owned-path hashes,
   dependencies and test results. The coordinator fetches/merges through JJ
   and checks destination hashes. Frozen archives remain provenance, not an
   ever-growing queue for manual copying.
7. At most **six active implementation threads** and one serialized assembled
   heavy gate. Reuse declared dependencies; do not multiply build/state
   directories indefinitely. Materialization, disk and toolchain failures are
   explicit blockers, never passing evidence.
8. Each slice runs `gleam test`/format where applicable and its focused
   workflow. Run the full integration gate at shared-boundary milestones and
   before publication. F43 verifies a finished candidate; it does not start
   implementing missing features.

## A. Contract, execution and account connection

| ID | Thread / one deliverable | Dependencies | Acceptance |
| --- | --- | --- | --- |
| F01 | **Freeze the executable parity contract** | Baseline | Pin CPA and client versions; map every required route, auth mode, capability and error behavior to source and executable cases. Resolve 22 source-pending rows. Identify meaningful divergences, media applicability and missing rows. Keep the historical 37-row matrix; new scope is explicitly versioned. |
| F02 | **Contain local compatibility executions** | Existing execution contract; F01 at acceptance | One reusable local runner contains filesystem, network, resources and the entire process lifetime. Actual fault tests cover parent SIGKILL, timeout, early leader exit, `setsid` descendants and cleanup failure. An unavailable backend blocks execution before spawning targets. No installation or external-host use without operator approval. |
| F03 | **Run the pinned CPA reference** | F01, F02 | First qualify reuse of the operator's running `https://localhost:8317` instance: establish identity and approved fixture routing without changing its configuration or accessing stored credentials. Bind executable/source/dependency digests and containment scope to observations. If a separate reference is needed, request the necessary approval rather than restarting the existing service. Resolve the unconditional updater without pretending it is disabled. A reference-only patch needs explicit approval, its own digest and a “modified reference” label; no silent inference/auth changes. |
| F04 | **Execute budgeted live scenarios** | F01, F02 | Replace live preflight-only behavior with endpoint-allowlisted execution and hard request, input/output-token, cost and time budgets. Reserve worst-case cost before sending; unknown cost or route fails closed. Prove enforcement using synthetic endpoints before real accounts. |
| F05 | **Connect Kimi through local OAuth UI** | Current Kimi enrollment; F01 at acceptance | A loopback-only account page can start, cancel and finish Kimi device authorization and show usable credential metadata. S5 reservation precedes provider I/O. Test Origin/CSRF, expiry, admin races and 0700/0600 storage. Access/refresh/session tokens never enter DOM/logs; transient device codes are shown only to the operator. Real startup awaits path/port approval. |
| F06 | **Connect Codex through OAuth UI** | F05 UI contract | Add the Codex login button and complete its qualified PKCE/callback or source-backed device flow into the runtime store. A successful browser login must produce a usable configured Codex account, not an orphan token. Cover state, callback consumption, expiry, cancellation and CAS. |
| F07 | **Connect Grok OAuth to gateway** | F05 UI contract, shared operation bindings | Device authorization from the UI through persistence, refresh and a real gateway HTTP request. One grant serves explicitly configured API/proxy operation bindings through one manager. Test endpoint selection, rotation, unknown refresh outcome, cancellation and admin races. Merely acquiring a grant is insufficient. |

F02/F03/F04 are execution infrastructure, not production provider transports.
They must not use a Python harness as a replacement for Gleam domain logic.
No broad default test discovery may launch CPA, native binaries or live calls.

## B. Claude and Codex behavior

| ID | Thread / one deliverable | Dependencies | Acceptance |
| --- | --- | --- | --- |
| F08 | **Qualify Claude OAuth profile behavior** | F01; F03 for differential evidence | Source-backed identity/profile/roles companion behavior, including advisory failures and absent metadata, matches the approved CPA contract. Produce the explicit upstream-check report required before Claude live authorization can be used. No invented account/device identity or measured fingerprint. |
| F09 | **Complete Claude request policy normalization** | F01 | The actual Messages/counting pipeline implements the approved model/auth/client policy table for betas, thinking/tool choice, sampling and cache layout/TTL. Request wire vectors cover each branch and documented loss rule; client hints are never authentication. Full CPA cloak/telemetry behavior is not implicitly authorized. |
| F10 | **Classify Claude request-scoped rate limits** | F01 | Replace the conservative all-429 terminal workaround with bounded, source-backed request-versus-account classification before quota observation. Exact 429/status/retry behavior, byte/time/encoding bounds and two-account tests prove fast-credit refusals never penalize the pool and ambiguous responses never authorize replay. |
| F11 | **Validate sparse Responses event streams** | Existing pinned sparse fixtures; F01 at acceptance | Shared codec accepts source-qualified sparse native sequences and reconstructs only state justified by validated events. Reject identity/order conflicts; preserve reasoning/tool/usage data and valid-prefix delivery. No “accept everything” terminal fallback or implicit fabricated output. |
| F12 | **Expose native Codex HTTP-lite** | F11 | Catalog/route/preparation/terminal behavior works through actual HTTP gateway and shipment with the pinned native-lite vectors. Scope existing HTTP receipts correctly; never turn incomplete or reconstructed-ambiguously output into continuation authority. |
| F13 | **Expose native Codex WS-lite** | F11, F12 contract | Native-lite works on the real opt-in WS/WSS route, including same-socket continuation, reset, usage, malformed events, cancellation and client/provider credential revocation. HTTP-lite tests cannot satisfy this slice. |

F09 is one coherent request-normalization contract, not ownership of all Claude
work. F08 owns enrollment/profile reconciliation; F10 owns response error scope.
Shared file amendments between these threads use explicit serialized patches.

## C. Kimi and Grok/xAI behavior

| ID | Thread / one deliverable | Dependencies | Acceptance |
| --- | --- | --- | --- |
| F14 | **Stream native Kimi Messages** | Existing Claude stream codec | Own the small missing restoration seam and use it for `POST /v1/messages` Kimi streaming; do not wait for an unassigned API or duplicate the parser. Restore only protocol-owned identity fields and preserve tools/thinking/signatures/usage. Test byte splits, valid-prefix failure, cancellation and account isolation. |
| F15 | **Stream generic Kimi Chat** | Existing shared Chat codec | The separately registered generic adapter supports Chat SSE without native aliases, OAuth/device headers or thinking transformations. Actual source/shipment tests retain generic request fields and enforce nested media rejection. |
| F16 | **Complete native Kimi normalization** | F01 | Close the specifically inventoried schema/parameter/history differences at the native request boundary: bounded local schema references, model-qualified controls and explicit reasoning/tool-history policy. Unknown media and transformations remain explicit errors, not recursive rewriting of user data. |
| F17 | **Resume Grok HTTP conversations** | F07, existing scoped receipt API | Source-qualified HTTP continuation works through the actual API/proxy route with authenticated tenant, selected account, authoritative revision, model and operation-origin binding. No dropped IDs, automatic stateless fallback or reuse of WS receipts. |
| F18 | **Expose Grok WebSocket gateway** | F07, shared WS boundary | Real gateway model dispatch selects Codex or xAI without weakening handshake/auth rules. Test API-key/OAuth, official/proxy operation policy, WS/WSS continuation, alias restoration, rotation, revocation and no reconnect replay. Default-off remains explicit. |
| F19 | **Complete Grok tool contracts** | F01, F07 | The approved function/namespace/custom-tool and compact-tool forms pass request/response/SSE/WS round trips. Raw shared validation precedes restoration; aliases, call kinds and IDs cannot collide or silently change. |
| F20 | **Expose Grok image operations** | F01, F07 | Own any minimal typed media-transport extension needed by the qualified generation/edit routes. Supported forms and streaming are bounded and executable. Binary/multipart handling is explicit, never coerced into UTF-8 captures; URL inputs are not arbitrary server-side fetch authority. |
| F21 | **Expose Grok video operations** | F01, F04 budget contract, F07 | Implement the pinned video job lifecycle only if it is in CPA's approved surface: create/status/result/cancel and bounded polling. Mock tests prove accounting, terminal/error behavior and credential isolation. Live video requires an explicit media budget. |

Kimi compact is explicitly unsupported in the existing CPA pin; it is **not**
an automatic debt item. Opaque Kimi continuation, custom/media forms and any
changed upstream support are decided from F01 source evidence. A slice cannot
claim parity by replacing a required feature with “unsupported”. Conversely,
it must not invent an upstream capability just to expand the feature list.

If F01 proves an image/video route absent from the approved reference, record
that evidence and an explicit scope decision before dropping its slice. This
is not permission to silently shrink the required matrix.

## D. Devin behavior

| ID | Thread / one deliverable | Dependencies | Acceptance |
| --- | --- | --- | --- |
| F22 | **Qualify remote Devin transport** | F01, typed binary boundary | Establish the actual required HTTP/ALPN/Connect contract and implement the qualified transport with certificate/hostname checks, framing limits and cancellation. Local H1 tests do not enable remote access by inference. Remote qualification needs separate Devin authorization; the existing gate stays closed until then. |
| F23 | **Stream Devin Chat responses** | Existing Connect decoder | Real Chat SSE route projects validated native events with tool/reasoning/usage ordering, trailers, errors and cancellation. No direct forwarding of secret-bearing protobuf; partial native usage is not invented as exact usage. |
| F24 | **Expose Devin Messages route** | Existing native/Anthropic codecs; F23 lifecycle | Buffered and streaming Messages operate through actual gateway registration and authenticated selection. Preserve supported thinking/tool/media associations; reject unrepresentable native blocks rather than drop them. |
| F25 | **Expose Devin Responses route** | F11 where applicable, native projection | Responses JSON/SSE output is derived from validated native events with correct IDs, items, tool pairing, usage and terminal states. Explicit route tests prove this is not Chat JSON relabelled as Responses. |
| F26 | **Enroll permanent Devin sessions** | F05 UI contract, S5 | Source-backed PKCE/manual acquisition reaches the runtime via exact-generation enrollment. Session tokens remain permanent material, not fake API keys or expiring OAuth. Cancellation/admin races and restart behavior are executable. Live enrollment is separately gated. |
| F27 | **Expose configured Devin models** | F01 | Gateway discovery, aliases and capability metadata reflect the approved configured catalog and supported operations. Unknown models fail before I/O; static catalog data is not described as live discovery. |
| F28 | **Expose Devin status and quota** | F26 credential contract | A bounded authenticated status/quota path updates observations without rotating a permanent grant. Exact reset/error semantics are tested; token counts remain explicitly estimated where CPA uses a heuristic. |
| F29 | **Complete Devin native payload mapping** | F01 | Close the inventoried native input gaps at the Connect encoder/decoder boundary: tool/system normalization, supported media and signed/opaque blocks. Every added form has a preservation or explicit-loss test; no guessed signatures, implicit URL fetches or silent orphan-tool repair. |

F22 is a transport qualification slice, not a blanket request to enable H2 or
remote binary traffic. F23–F29 can develop against synthetic loopback transport
while the remote gate remains closed; their reports must retain that limit.

## File ownership and shared seams

- F01 owns the versioned contract/matrix and scope decision record.
- F02 owns reusable execution containment, F03 reference launch, F04 live
  enforcement. F30–F34 own separate provider drivers/fixtures, not forks of
  these common mechanisms.
- F05 owns the new account UI shell and Kimi connection panel. F06/F07/F26
  own separate provider enrollment modules/panels and request a root admission
  slot for registration.
- F08–F10 own distinct Claude profile/request/error modules. F14 receives the
  narrow Claude stream-restoration seam explicitly; it does not take over
  Claude authentication or policy files.
- F11 owns shared sparse Responses parsing. F12/F13 own distinct Codex
  HTTP/WS mode bindings. F16 owns native Kimi normalization; F15 owns only
  the generic adapter. No two threads edit the same request builder at once.
- F17–F21 split xAI state, WS, tools and image/video modules. If an existing
  monolithic file must be changed by two slices, one gets the exclusive slot
  and hands back a compiled revision before the other proceeds.
- F20 and F22 must serialize any amendments to shared egress/contracts.
  A provider-specific media or Connect rule must not silently loosen the
  other provider's transport gate.
- F23–F29 split Devin client projections, enrollment, catalog, status and
  native payload mapping. F35–F38 own separate native-client adapters and
  fixtures, preserving the common report validator.
- Root gateway/config/CLI, dependencies, vendor and CI always remain in the
  coordinator's serialized lane. Every thread records its exact granted
  paths before its first edit.

## E. Executed differential acceptance

Each row owns one provider's executable driver and report. F03 owns common
reference launch/containment; these threads do not create five harnesses.

| ID | Thread / one deliverable | Dependencies | Acceptance |
| --- | --- | --- | --- |
| F30 | **Measure Claude differential parity** | F03, F08–F10 | Execute CPA and assembled MIMIC on the same approved Claude cases. Compare wire headers/body, Messages/counting, SSE, policies, OAuth/refresh and scoped errors. Publish preserved mismatches and candidate-bound results. |
| F31 | **Measure Codex differential parity** | F03, F12–F13 | Execute HTTP/compact/lite/WS cases independently, including history/reasoning, usage, account scope and failure transitions. Explicitly classify the safe full-history replay difference; do not normalize it away. |
| F32 | **Measure Kimi differential parity** | F03, F14–F16 | Native and generic identities, both OAuth domains, Chat/Responses/Messages, tools/media controls and ordered headers are measured separately. Neither a generic endpoint nor a frozen local fixture impersonates a CPA result. |
| F33 | **Measure Grok differential parity** | F03, F07, F17–F21 | API-key versus OAuth, API versus proxy, tools, continuation, WS and approved media surfaces are actually executed. Compare error/failover behavior without conflating request and credential scope. |
| F34 | **Measure Devin differential parity** | F03, F23–F29 | Compare native Connect/protobuf and client projections using synthetic credentials and endpoints. Binary observations are bounded synthetic-only evidence; base64 is not redaction. Remote qualification remains a separate axis. |

Every result binds source/driver/fixture/dependency/executable/shipment hashes.
The denominator and source applicability come from F01. Missing cases,
unsupported required cases, skipped execution and mismatched bindings block
strict acceptance. Deliberate hardening differences need an explicit decision;
they cannot be counted as exact CPA matches merely because they are safer.

## F. Native clients and live qualification

One native slice means one pinned client's executable acceptance suite, not
implementation of that provider. Individual workflow verdicts remain separate.

| ID | Thread / one deliverable | Dependencies | Acceptance |
| --- | --- | --- | --- |
| F35 | **Qualify native Claude Code** | F02, F08–F10, F30 | Actual contained Claude Code executes conversation, tools, continuation and cancellation against assembled fixtures. Validate exact tool IDs/results, phase/session binding and request-bound disconnects. Complete login/refresh workflows where declared; no fixture-only or status-only passes. |
| F36 | **Qualify native Codex** | F02, F12–F13, F31 | Actual pinned Codex executes HTTP/WS/lite paths it advertises, tool and reasoning turns, continuation, cancellation and credential lifecycle cases. Bind output/events to the exact client and shipment. |
| F37 | **Qualify native Kimi Code** | F02, F14–F16, F32 | Pin the supported official client, not an archived package by name alone. Execute declared coding workflows with native/generic mode distinctions and per-workflow evidence. |
| F38 | **Qualify native Grok client** | F02, F07, F18–F21, F33 | Acquire and execute an available official pinned Grok CLI/Build client in containment. No consumer browser session or handwritten HTTP client substitutes for the named client. Unavailable artifacts block the row. |
| F39 | **Accept live Kimi integration** | F04, F05, F32, F37 | Using an explicitly selected account/endpoint and bounded budget, run the approved live Kimi acceptance cases. Report auth, model, workflow and observed outcomes separately from synthetic/differential results. |
| F40 | **Accept live Codex integration** | F04, F06, F31, F36 | Same bounded acceptance for the selected Codex account, including only the approved auth/transport/model cases. Unknown delivery never triggers blind replay. |
| F41 | **Accept live Grok integration** | F04, F07, F33, F38 | Same bounded acceptance for selected Grok API/subscription modes. Distinguish API/proxy entitlements; media incurs no unapproved spend. |
| F42 | **Accept live Claude Code integration** | F04, **F08 and F30 passed**, F35 | First satisfy the user's upstream CPA condition, then execute approved live Claude cases with explicit account/endpoints/budgets. No automatic “the other providers passed” permission. |

The historical eight Claude/Codex workflows remain visible. Adding Kimi/Grok
or refining workflow schemas creates a new versioned matrix, not an apparent
improvement obtained by deleting blocked rows.

No native pass is accepted from weak draft assertions such as a canary
appearing anywhere, a larger aggregate history, or a fixture-wide disconnect.
No live pass is accepted from authorization metadata or public discovery alone.

## G. Final release, not another implementation queue

| ID | Thread / one deliverable | Dependencies | Acceptance |
| --- | --- | --- | --- |
| F43 | **Publish the qualified parity release** | Accepted required slices, F44 and explicit scope decisions | Independently verify the exact integrated candidate, full Gleam/Python/root/shipment gates, strict paired differential report, native verdicts, live evidence/limits and absence of secrets. Publish through JJ only under current user authorization; verify remote SHA and CI. If a required gate is red, report the exact blocker rather than implementing it inside this thread or relabelling it passed. |

If the user requests an intermediate integration publication, that is possible
with its current honest capability matrix, as in the previous wave. It is not
the F43 qualified-parity outcome.

## H. Discovered boundary defect — explicit additional slice

| ID | Thread / one deliverable | Dependencies | Acceptance |
| --- | --- | --- | --- |
| F44 | **Preserve HTTP/1 request boundaries under coalescing** | F05 source-bound reproduction; exclusive coordinator vendor slot | Correctly consume two legal coalesced keepalive requests without treating the second request as the first body, throwing `FunctionClause`, losing bytes or hanging. Compare sequential and coalesced GET/GET and fixed-body POST/GET, byte splits, response order and exact handler bodies. Preserve strict rejection of ambiguous CL/TE and zero-dispatch closure, ordinary HTTP/1.0, single-body coalescing and WS upgrade rest bytes. Carry the known-red scenario until fixed; root and shipment regressions are required. |

F44 is **queued, not assigned or implemented**, under coordinator-controlled
vendor ownership. It uses an existing umbrella's single-child slot when
explicitly granted; no tenth top-level thread is created.

F05 owner supplied an exact pre/post parser control manifest,
SHA-256 `b999a8dbf847cecb2d641755fa8dc83073fa84d458cfe096c2c881e5106065a6`.
The coordinator verified that manifest's hash, not independently rerun its
tests. Both parser versions reportedly fail legal coalesced requests while
sequential controls pass. This supports an inherited boundary defect, not a
regression caused by the new singleton-header rejection. Exact affected
routes and a production fix still need qualification.

The narrow F05 security patch can be admitted with its passing boundary
tests and explicit limitations. Its known-red legal-pipelining scenario must
remain separately executable and visible; it is not waived, deleted or counted
as a pass. F44 blocks the final qualified release even if the narrower
security patch is published earlier.

## Launch order and practical concurrency

The user requested **six umbrellas first, then three remaining umbrellas**.
All first-six creation calls returned a started thread. The final three have
not been created.

| Umbrella | Slices | Thread / state |
| --- | --- | --- |
| Execution foundations | F01–F04 | [Started](delta://thread/ksQQlX4HR-jcQdm57gYjroBRwZLOAFQzY5IBxBDu1fs15rdKs6m5jRdeJnRz) |
| OAuth accounts and UI | F05–F07 | [Started](delta://thread/ksQQb9FLfzOvROCTHSjh0BOwgJLOAFQ2MZIBxBDu1fs15rdKs6m5jRdeJnRz) |
| Claude and Codex | F08–F13 | [Started](delta://thread/ksQQVCxI78U2RVSszbHl9CfSlZLOAFQ9t5IBxBDu1fs15rdKs6m5jRdeJnRz) |
| Kimi and Grok | F14–F21 | [Started](delta://thread/ksQQe6WNpjQbRLmI0CmtomhWrpLOAFRJJ5IBxBDu1fs15rdKs6m5jRdeJnRz) |
| Devin | F22–F29 | [Started](delta://thread/ksQQweRIpNx2Sm-sVPBOJ-0quJLOAFRc85IBxBDu1fs15rdKs6m5jRdeJnRz) |
| CPA differential acceptance | F30–F34 | [Started](delta://thread/ksQQ0-2cc-rQRPSRnNAPdQcn4JLOAFSj2ZIBxBDu1fs15rdKs6m5jRdeJnRz) |
| Native clients | F35–F38 | Pending client/protocol and containment contracts |
| Live acceptance | F39–F42 | Pending accepted runner, explicit live inputs and enforced budgets |
| Final release | F43 | Pending frozen integrated candidate and completed required reports |

Umbrellas choose one ready slice at a time rather than starting children just
to wait for unpublished APIs. Differential preparation may proceed now;
actual paired execution waits for F01–F03 and the relevant admitted route.
No final qualification uses an unconfirmed reference pin.

Root admission and heavy tests are serialized by the initiating coordinator:

- `READY_FOR_ADMISSION(slice, revision/bookmark, owned hashes, compiled API,
  minimal root patch/base/paths, focused commands/results)` requests a named
  exclusive root slot. The coordinator applies/reviews the patch and returns
  the destination acceptance result. A request is not permission to edit root.
- `READY_FOR_GATE(slice, revision, command, time bound)` requests a full Gleam
  or integration run. Focused module tests and independent source audits may
  continue; full runs wait for a grant.
- Peer messaging failures are relayed through the coordinator, not treated as
  delivered contracts. Do not create replacement threads to repair routing.
- F43 verifies a candidate whose slices are already integrated. It does not
  become the owner of accumulated missing gateway work.

## Mandatory handoff for every thread

1. Exact starting/dependency revisions and owned paths; no sibling edits.
2. One-sentence delivered capability and exact exposed route/CLI or gate.
3. Compiled API/root patch, not a hypothetical signature.
4. Positive and negative real-path tests; mode, commands, exits and hashes.
5. Failed-run history and root cause, not “preexisting flake” without evidence.
6. JJ handoff revision/local bookmark, source hashes and required import order.
7. Separate source, synthetic, differential, native and live evidence fields.
8. Remaining unsupported behavior and any operator decision still required.
9. Destination acceptance before the slice becomes **done**. An owner-only
   overlay, stopped tool call or unmaterialized checkout cannot satisfy it.

The six started umbrellas are authorized work. The three pending umbrellas
start in the subsequent phase when their dependencies are ready. No automatic
publication or successful parity qualification is implied by their creation.
