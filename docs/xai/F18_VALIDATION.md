# F18 validation hold and bounded admission plan

**SCOPED ADDITIONS UNVALIDATED / RUNTIME UNEXECUTED / ROOT BLOCKED / QUIESCENT.**

The recovery HTTP-cancellation/Content-Type/F44 lane holds the next shared
validation slot. Narrowly granted formatting/build-only attempts are recorded
below; no test, BEAM application, socket, browser or root workflow was run.
No child agent, native client, live/account/CPA call, Git/JJ
mutation or root/shared transport/Codex edit was made. Root default-off remains.

## Current evidence, separated from preparation

| Gate | Result |
| --- | --- |
| Read F18, F01 FINAL-v1 inventory, current F07 operations, F17 HTTP guard and actual provider/runtime code | Source review only |
| Read historical d6f307… source/docs in the named checkout | Read-only reference; no old results adopted |
| Approved provider/API/operation/test scope | Parent approved; source implemented |
| Original Gleam 1.18.1 owned format/check | PASS for the previous checkpoint; current review corrections NOT RUN |
| Original exact composed build/signature check | Historical PASS; current review corrections NOT RUN |
| Dedicated operation/fence/runtime tests | NOT RUN |
| Corrected legacy xAI WS/WSS/OAuth tests | NOT RUN |
| Actual root source dispatch/terminal gate | NOT RUN; root parent-owned |
| Actual exported shipment from another cwd | NOT RUN; no export created |
| Physical abort/owner-death/WSS cleanup | UNQUALIFIED F13 dependency; diagnostic failure retained |
| Full test suite / compiled destination | NOT RUN |
| Differential, native, live or effective source chain | NOT RUN / not claimed |

### First explicit signature slot: stopped at dependency preflight

The parent granted one 180-second format/check/build-only composed-source slot.
The lock was acquired and released in 0.002 seconds, with no compiler,
formatter, child process or runtime started. `ws_transport` and `frames` matched
the authorized hashes. The grant named “WS FFI” without its path; checking
`mimic_provider_ws_ffi.erl` produced `0004887c…`, not `c0fb878d…`, so the
worker stopped rather than substitute or retry. Read-only follow-up identified
the separate new `mimic_ws_transport_ffi.erl` import; exact-path reconciliation
and a renewed slot are still required.

```text
build/closure/f18/signature-1790888134858322000/receipt.json
SHA256 76e9d126aec629f740d3ea1fcb52efaa2e8a492f995670e4ed0def4557272037
```

This is a stopped preflight receipt, not compiled-signature or cleanup-security
qualification. Only the worker's owner file/directory lock was removed.

### Renewed exact-path slot: test-source compilation failure

The exact new FFI path is `src/mimic_ws_transport_ffi.erl`, not the existing
`mimic_provider_ws_ffi.erl`. All three authorized F13 hashes matched. Gleam
1.18.1 owned formatting/check passed. The copied current parent project and
dependency cache plus approved F18 overlays contained 1,144 recorded inputs;
parent bytes were rechecked across the copy. No stubs or unowned rewrites.

The composed build failed at exactly three owned test typing sites:

1. The unknown-status assertion branch returned `CredentialRecord`, whereas
   the other branches returned Nil. The success assertion is retained and the
   branch now explicitly returns Nil.
2. `notified` needed an explicit `SessionAdapter(Handle)` annotation.
3. `next` needed the same annotation.

The worker stopped at that first build result and released only its own lock
after 4.434 seconds. These are test-source compile failures, not provider
runtime failures or a transport qualification.

```text
build/closure/f18/signature-1790888424133856000/receipt.json
SHA256 9d22d88541acaa4c476e95ce4f258d984e3d66617dfb3de0010bdf3b6039767b
Composed manifest fbdaa08f45d65456dfea8d7713361fb474cd7ac7608636aebd67188e1fca5b7b
```

### Correction slot: generated metadata preflight refusal

The three authorized typing corrections were source-applied. Before any new
formatter/compiler, exact revalidation found the prior build had reordered the
generated `build/packages/packages.toml` cache index. Package names/versions
were unchanged. Because the original manifest included it among source inputs,
the worker stopped rather than silently exclude the difference. All recorded
parent bytes matched. The lock was released after 0.229 seconds.

```text
build/closure/f18/correction-1790888507826408000/receipt.json
SHA256 c026c8075fe15e6ed0f6a51dc81538f45741a51de3c7df696d8535dee8ad8922
Parent cache index efe1a9b6119a4992c5f44c06ec93e7f4d5628453e24a012101b3b6f200a70bd5
Generated index 77c92a4afc59ded6a9ccdf502e8c50019d133f663b9a4726cb83029b09d848d1
```

This is a zero-compiler preflight refusal. A renewed slot must explicitly
classify that index as generated metadata, record pre/post hashes and version
equality, and continue exact verification of every actual source/dependency.

### Reconciled correction slot: exact composed build passed

The parent explicitly reclassified **only** `build/packages/packages.toml` as
generated cache-index metadata. Its before/after hashes and full parsed
package/version maps were recorded separately and remained semantically equal.
Every other source/dependency, including `manifest.toml`, package source and
checksums, was verified before and after the build; all recorded parent bytes
also remained exact. Only the two files containing the three approved test
typing corrections were overlaid onto the preserved project.

Gleam 1.18.1 correction formatting/check and the composed build passed. The
entire slot, audits and own-lock cleanup took 9.903 seconds. The lock is released,
with no remaining validation child and no deferred runtime.

```text
Actual composed source:
build/closure/f18/signature-1790888424133856000/project

Passing receipt:
build/closure/f18/reconciled-1790888621868686000/receipt.json
SHA256 c2a00bb3936a8c01e74beefb1b7717cd50ce3116389accd6e8f99ab34bf7baf9

1,143 exact source/dependency inputs:
9fb0186a6b8a152bfa0d327136216313dc51da4e697a8831a5ec1faec15bf508

Recorded input-manifest.json file:
build/closure/f18/reconciled-1790888621868686000/input-manifest.json
SHA256 fec7b8d5964170fbcde15c4327468d4a984d6f2b8d1f4f518f6f9b953b56f9b4

Passing composed-build.log:
SHA256 b88a88c3cc9ce34eee46e1f72d3d242d8ecd1a93939e8371f092067cde1e166c
```

Commands were direct, serialized and run with `ERL_FLAGS='+S 2:2 +A 2'`:

```sh
/opt/homebrew/bin/mise exec gleam@1.18.1 -- gleam format \
  test/xai_f18_fence_test.gleam test/xai_f18_runtime_test.gleam
/opt/homebrew/bin/mise exec gleam@1.18.1 -- gleam format --check \
  test/xai_f18_fence_test.gleam test/xai_f18_runtime_test.gleam
/opt/homebrew/bin/mise exec gleam@1.18.1 -- gleam build
```

The build command ran in the recorded composed project, not the parent checkout.
Earlier owned formatting covered all seven owned Gleam files. Inherited
Codex unused-FFI and Mist transitive-dependency warnings were retained; no
dependencies or unowned files were rewritten to suppress them.

The original configured adapter and terminal signatures compiled. Subsequent
review corrections preserve that public ABI but supersede the implementation
hashes; no new compile was authorized. Python harness syntax/behavior, focused tests, physical abort, root
dispatch/publication, shipment and security are **not qualified by this build**.
Documentation status/handoff receipts were updated after compilation; their
current hashes are not substituted into the compiled input manifest.

## Prepared test coverage, not passing totals

- `xai_f18_operations_test`: WS-only explicit registration, unchanged HTTP rows,
  API-key/OAuth auth partition, canonical base, exact selected Context membership,
  proxy/Build/composer denial, no destination override.
- `xai_f18_fence_test`: actual durable record revision, same-value replacement,
  material/read race, deletion, blocked refresh status, current client callback,
  and injected-time expiry on an unchanged record/material/revision. Production
  admission always uses real time. Added supplied-acquired-revision binding
  tests requiring revision AND material/Ready/expiry/current-client.
  No refresh or Codex metadata.
- `xai_f18_runtime_test`: actual configured xAI adapter plus shared runtime,
  full aggregate bindings, API-key/OAuth tools/usage/continuation/reset,
  mixed-auth selected accounts and order permutations, missing partition,
  selected duplicate/origin/pin denials, direct model-qualification denial,
  idle-poll revoke/rotation and valid prefix. Non-success notification now goes
  through actual runtime polling/lease checks, not only direct adapter calls;
  callback arrival order is not inferred from the runtime reply.
- Added actual-runtime scoped-open unchanged-R1 success and same-/different-
  material replacement between acquisition and provider bind. API-key/OAuth
  requests pin the sole viable selected account, eliminating failover as an
  oracle confounder. A numeric-loopback TCP accept counter observes unexpected
  opens; race replacement is synchronous in the acquired callback, never sleeps.
- `xai_websocket_native_test`: granted legacy test-only correction preserves
  actual WS/WSS/OAuth/tool behavior, explicitly configured base, separate
  rejected-send handles and no missing/conflicting-destination inference.
- `smoke-xai-ws.py`: actual root source/shipment launch, default-off and
  Codex-only enablement, both configured Codex and xAI selection, API-key/OAuth,
  expired proxy denial before refresh, strict auth/Origin/negotiation/header
  denials, same socket continuation/reset, namespace/alias/raw-identity checks,
  HTTP/WS receipt separation, malformed prefix/error suppression, cancellation,
  held-acquisition/client revocation and exact provider revision mutation.
  Numeric loopback only; upstream WSS uses a temporary CA in child VMs, never
  host trust. The downstream root harness is WS; it does not qualify a separate
  downstream root TLS listener. Error close checks code 1008/1011 and empty reason.
  Timeout is not accepted as physical or downstream close evidence.

## READY bounded validation request

Only after an explicit parent grant and selected dependency synchronization:

1. Verify actual scoped input hashes, F07/F17 seams and the parent-selected F13
   `ensure_idle`/`abort` revision. Do not replace the shared transport with old
   code, a stub, or a duplicate. Root admission remains blocked on qualification.
2. Use Gleam 1.18.1 and `ERL_FLAGS='+S 2:2 +A 2'`. Atomically acquire the one
   shared directory lock:

   ```text
   /Users/jerryjohnson/dev/mimic/.delta/worktrees/rz87rbwdwjd8/mimic/build/closure/validation.lock
   ```

   Do not steal/remove another lane's lock. No polling/runtime starts without
   the grant. Stop and clean all fixture/VM/server processes before release.
3. Format/check owned Gleam files, build and deliver compiled source signatures
   early. Then run the explicitly selected focused modules and F07/F17/shared
   WS regressions, retaining failures instead of broadening source claims.
   A full `gleam test` is a separate parent-approved assembled gate.
4. Parent integrates one root dispatcher and priority fenced terminal seam.
   Run actual source workflow, then an approved exported shipment from a
   different cwd:

   ```sh
   python3 scripts/smoke-xai-ws.py --transport both
   python3 scripts/smoke-xai-ws.py --shipment /absolute/approved/shipment --transport both
   ```

   These are proposed commands, **not executed receipts**. No package export,
   root overlay or CA flag is authorized by their appearance in documentation.
5. Record exact input/output hashes and actual results, including unverified
   F01 `grok-ws-chain-source`, error-exposure/product differences, F13 cleanup
   defects and all source/shipment/destination gates.

The final packet must be quiescent with no deferred runtime. An uncompiled
packet must not autoimport; only explicit parent synchronization can admit it
as a clearly labeled source-only checkpoint.

## Original compiled-source synchronization packet — superseded

The parent previously authorized synchronization of exactly the eleven
approved paths, **compiled source only**. These hashes identify that original
checkpoint, not the corrected bytes below. No runtime tests, security/root
admission, further semantic changes or enablement are authorized. The root
remains default-off and F13 abort remains unqualified.

The source worktree is
`/Users/jerryjohnson/dev/mimic/.delta/worktrees/w54azzv8k4rk/mimic`.
Its unchanged Git HEAD is `dd15c610ec39e4f296c30fe02347d0d2b368a629`; no commit,
bookmark, Git/JJ mutation or history operation was made during parallel work.
The named exact file bytes, not HEAD alone, identify this packet.

| Original non-documentation path | Historical SHA256 matching old compiled input snapshot |
| --- | --- |
| `src/mimic/providers/xai_websocket.gleam` | `fa7adac5c1c993acfb650814a77afa4b977d98d65ca0092f93eca94c499b686d` |
| `src/mimic/providers/xai_websocket/fence.gleam` | `4a50b563a0edcecf1491e686d4f73c86d1656d0f6c6536805dc29e6015cce559` |
| `src/mimic/providers/xai/operations.gleam` | `dda7a46b2bfaf92e33b3a90e42331e1da1912111e5480b5e7c68a03f7931d16f` |
| `test/xai_f18_operations_test.gleam` | `e10242c8dd89226abdec66149a22354f3356c8d6a5f1cb4b7e494be2ed56e359` |
| `test/xai_f18_fence_test.gleam` | `c17aef42657a46204ce88e146b429e1e967e5cb36ac6be7f26e08acf703ce1fc` |
| `test/xai_f18_runtime_test.gleam` | `bace52931561917a57a3d3fb3fda0fffb96ac352beb62761a65dd1f11d2b9949` |
| `test/xai_websocket_native_test.gleam` | `5d4f88b851199a5dd7715ae21c45b995975499051da7b93205eeadbd747049dc` |
| `test/mimic_xai_f18_test_ffi.erl` | `8e24eb92621c7e8bcd5ce5fe4de327ad81a94bf9907970db1b1edde09c78bf13` |
| `scripts/smoke-xai-ws.py` | `25b7ae4b4f37f23d43b0086a780c34a229edb872b21bfc57e14c15c88d2b35c4` |

The final two approved paths are `docs/xai/F18_CONTRACT.md` and this
`docs/xai/F18_VALIDATION.md`. Their final exact hashes are delivered in the
parent handoff, avoiding a recursive self-hash and distinguishing post-build
documentation updates from the recorded compiled input manifest.

Exclude every composed project, copied parent file, generated metadata/package,
build artifact, log directory and unowned F13 transport file from synchronization.
The local ignored receipts remain read-only evidence references, not source
overlays. All earlier setup refusals and the test-source build failure above
remain distinct from the successful compile and from unexecuted runtime gates.

That checkpoint's read-only audit found the shared validation lock absent and no F18
compiler/formatter/runtime child running. No delayed application/harness was
scheduled. Parent static review of explicit operation authority, exact revision/
client/terminal fences and intentional legacy tightening precedes any runtime
grant.

## Independent source review and finite unvalidated correction checkpoint

Reviewer `a4c7df1983424507` found concrete source gaps in the original packet.
Parent granted narrowly scoped source corrections and tests, then explicitly
authorized a finite **UNVALIDATED synchronization checkpoint**. The reviewer's
attached snapshot still contained the original source: reported implementation
changes are not independent review approval. Parent must synchronize exact
corrected bytes before requesting re-review.

| Finding | Approved correction / current disposition |
| --- | --- |
| Aggregate binding list was passed to per-account `select` | Added `select_configured`: partition by actual Context account/auth, delegate unchanged per-account selector, preserve selected duplicates/conflicts and exact checks. Existing startup account validation and F07 HTTP selection remain unchanged. |
| Singleton test lists masked the aggregate mismatch | Tests now pass full absent/selected lists. Added actual configured-adapter mixed-auth accounts, both selected accounts, reversed order, missing partition, selected duplicate, origin-switch and pin denials. UNEXECUTED. |
| Missing base fell through to official API; LocalMock negative masked it | Selected/configured factories explicitly require a base. VerifiedTls/default-origin test uses incompatible material and exact Unsupported classification to stay incapable of public I/O even if the guard regresses. Legacy fixed-config default policy is separate/documented. |
| Composer could pass direct adapter preparation with nonempty session | Direct adapter open repeats model WS registration qualification before transport; composer/Build denials have actual configured-adapter regressions. UNEXECUTED. |
| `notify -> Ok(None,closed)` idled with a runtime lease | Notifying termination now returns sanitized Error after notification. Runtime attempts cancel/release independently; normal completion unchanged. Actual runtime callback/lease regression prepared. No bounded cleanup/physical-close proof; F13 still unqualified. |
| Error cannot return updated immutable handle | Removed the dormant closed-handle state; direct callers must discard every errored handle. Old retained copies are not claimed globally one-shot. Root consumes at most one fenced terminal, drains after every blocking return, suppresses/stops if absent/stale; no generic/unfenced fallback or cross-sender ordering assumption. |
| Expiry assertion also replaced revision/material | Injected test clock advances on one unchanged persisted record and asserts revision/material equality. Production factories use only real clock. UNEXECUTED. |
| Root close oracle accepted arbitrary opcode8 | Now requires code 1008/1011 and empty reason; timeout remains failure. Harness UNEXECUTED. |
| Material equality cannot bind the runtime-acquired revision | Blocking at that checkpoint: unscoped open discarded the acquisition. Later source-only parent/scoped-provider follow-up below addresses the handoff structurally; composition/runtime proof remains blocked. |

At that checkpoint source corrections had not been formatted, compiled or executed.
Original setup refusals, test-source compile failure and successful old build
remain historical receipts above; none qualifies current corrected hashes.
Only the approved eleven paths belong to this checkpoint. No composed project,
generated package/metadata, copied parent file, unowned/shared transport/runtime,
root patch or enablement is included.

## Scoped-revision source follow-up and P2 closure-oracle correction

Parent reported corrected-byte static review of the previous `8180178…`
provider packet: global-list/base/model/expiry/terminal-return defects were
structurally addressed, **not runtime-qualified**. That review did not include
the following scoped additions. One remaining P2 test oracle defect was fixed
under a named source-only grant: the legacy rejected-send test now observes
actual peer closure immediately after its **first** Error, before a second
send, cancel or fixture teardown can supply closure evidence. The errored handle
is discarded; no retained-copy one-shot guarantee is asserted.

Parent subsequently implemented `runtime.open_session_scoped` SOURCE-ONLY.
The exact read-only dependency was verified and inspected:

```text
/Users/jerryjohnson/dev/mimic/.delta/worktrees/rz87rbwdwjd8/mimic/src/mimic/providers/runtime.gleam
SHA256 90fd116141c7a47abdfa556a627cc0f66674b008e7e49ba0bd321b345e57fdb5
```

Its scoped callback is passed unchanged to existing Driver.open; the legacy
open_session delegates with its original adapter.open wrapper. No runtime,
contracts, parent source or transport was edited/copied into this owned packet.
This dependency is uncompiled, not observed runtime behavior.

Owned source additions:

- `configured_scoped_open` and `_notifying` return an additive ScopedOpen
  callback for the parent API; old public SessionAdapter signatures remain.
- `fence.bind_acquired` rejects any current record whose revision differs from
  the supplied acquisition, additionally checks exact material/Ready/real expiry/
  current client, and retains exactly the supplied revision on success.
- Both existing and scoped factories share the same full-binding partition,
  explicit-base and model admission pipeline; root must use scoped admission.
- Actual-runtime regression wrappers receive R1 from the real runtime, replace
  the record synchronously with same material or different material/R2, then
  call the real scoped provider callback with R1. Expected NotSent, zero accepts/
  inference and released lease; unchanged R1 opens/sends successfully.
- Requests explicitly pin `Some("selected")` so failover cannot hide denials.
  The dedicated test TCP probe increments its count before closing any unexpected
  connection, captures no bytes, implements no WS/HTTP codec, and has explicit
  listener/worker cleanup. Zero accepts implies no transport/inference.

All scoped additions, new regressions, P2 correction and fixtures are
UNFORMATTED/UNCOMPILED/UNEXECUTED. No new compiler, socket, BEAM application, test,
root, browser, native, live or CPA workload was started or scheduled. No review
approval for these new bytes is inferred. Root remains unwired/off; F13 abort,
full composed acquired-revision/cleanup proof and F01 effective-chain obligations
remain qualification blockers. The original successful build/failure receipts
above remain historical, not qualifying this follow-up.
