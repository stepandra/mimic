# Claude enrollment CAS handoff v1

Narrow follow-up to frozen Claude policy v1. Only production change:
`src/mimic/providers/claude/login.gleam`.

Base: `3e00808ff0fefbb6728edb1769c17139ef0fd93a`.
Policy v1 manifest and source archive remain byte-identical. No shared-core,
gateway, root, vendor, CI, sibling, or primary source files were edited.

## Required dependency order

Import shared-owner S4, then additive S5, then this Claude-owned follow-up.
Do not apply the login file to a tree missing the S5 API.

| Snapshot | Archive SHA256 | Manifest SHA256 |
|---|---|---|
| Shared S4 | `f318501aaaa1cbf5a8c477097b871387b6a85f30a9692c2f9cdda1dc524bb5bc` | `60bad0938ecf160fc199f9c707821a6552dd72aa8b5cda9e13900ad0af7ba384` |
| Shared S5 | `a663d946002aa8eeed255f8df4cde6c49faacf1b304b5ed370eef48cf2f04f5f` | `5eb52b8c1ef26466a851ef3ff1e2e72a819e4d93d056914b6e682435d6620a40` |

Shared snapshots were read from their owner's frozen archives and verified,
including every member hash. They are staged **only** in generated private
`build/claude-enrollment-v1-*` validation overlays. The main checkout intentionally
does not contain the shared dependency edits: standalone compilation there
requires the integration owner to assemble S4/S5 first.

## Behavior

Public `login.run` signature is unchanged. Local operator identity validation
still precedes enrollment.

1. `begin_enrollment(store, key)` succeeds before PKCE creation, announcement,
   callback listening, or token exchange. Failure starts none of that workflow.
2. Successful exchange/identity checks use only
   `commit_enrollment(ticket, material)`, never unconditional save/value-CAS.
3. Ordinary workflow or commit failure attempts exactly one ticket-scoped
   `cancel_enrollment(ticket)`. If cancellation succeeds, return the original
   sanitized failure. If it fails, return the fixed
   `Claude OAuth enrollment failed; cancellation unconfirmed` message.
4. No retry, fallback save, second manager, token seed, or background cleanup.

S5 owns all atomicity/generation rules. A winning commit or administrative
mutation cannot be undone by cancellation of the old ticket. An unacknowledged
mutation is not assumed rolled back. Existing-ticket cancellation preserves
material/private metadata/refresh gate and creates a fresh generation,
intentionally invalidating generation-bound sessions/receipts; it is not
provider token revocation.

Panics/process death leave first-enrollment pending markers fail-closed.
Explicit operator recovery is required; no TTL cleanup or automatic takeover.
The consumer does not add new power-loss durability guarantees.

## Reproduction and tests

Runner:

```
python3 test/fixtures/claude/enrollment_v1/run.py \
  /path/to/shared-core/snapshot-4 \
  /path/to/shared-core/snapshot-5 --full
```

It verifies pinned base/archive/manifest/member hashes, stages tracked local
source plus the dependency overlays, formats/checks, and runs Gleam 1.18.1
with bounded BEAM schedulers. No source/build/state is copied from sibling
checkouts except the explicitly approved frozen source archives.

Add `--baseline-login` to substitute the exact base login source, keeping
everything else identical. Expected result: exit 1 with twelve
`#(False, False)` pairs for `(login_rejected, admin_state_preserved)`.

Final corrected overlay:
`build/claude-enrollment-v1-wzg1qmxk`.

- The unchanged old login reproduces all twelve races even with S4/S5 present.
- Fixed consumer passes all twelve races: replacement/same-value/delete against
  existing credentials, and replacement/delete/insert-delete ABA for initially
  absent credentials, at announce-before-callback and during token exchange.
- Successful first and replacement enrollment pass.
- Timeout, invalid configuration, token transport failure, identity mismatch and
  invalid grant-material persistence admission all retire the current ticket.
  Existing credentials retain their refresh gate/material with a new revision.
- Corrupt records and another pending enrollment fail before announcement or
  token exchange. Deletion assertions require secure `Ok(None)` absence;
  decode/read failure or pending markers do not count as absence.
- Final full overlay `gleam test`: **579 passed, no failures**.
- Formatting passed for assembled source/tests.
- Read-only review found no unsafe overwrite/cancellation path in the consumer.
  Runner clean-checkout setup and deletion-oracle findings were addressed.

Evidence:

```
210082267c693dba9725924448345414ed483bda7345b13b5e1013f706d093b7  build/claude-enrollment-overlay-red-v1.log
56d14a09d333fd677c359ce928d1e41f15973445d7e9642fcfdba6d9643c88e7  build/claude-enrollment-green-v2.log
```

Original red source, original login, raw failing logs and frozen red document
are additionally preserved in `build/claude-enrollment-red-evidence-v1.tar.gz`,
SHA256 `90edc2a518acdba5a579b15dbfb3cc5e83fded4319c67c85ae0b7360e56a7ef2`.
Do not confuse this historical evidence bundle with the final source overlay.

## Import and remaining gates

Final source-only follow-up: `build/claude-enrollment-v1.tar.gz`.
Exact owned-file hashes: `CLAUDE_ENROLLMENT_V1_SHA256SUMS`.
The archive hash is delivered separately to the integration/shared owners.
It excludes shared dependencies, build products, logs and credentials.

After dependency assembly, import only manifested paths and verify hashes.
Retest the actual configured gateway/CLI enrollment route, including pending
admin replacement/deletion and same-value saves. This thread tests the real
loopback callback plus injected token protocol, not the final integration
owner's assembled enrollment route.

Storage mutation timeout/lost acknowledgement, power loss, and provider token
revocation are not independently fault-injected by these consumer tests.
Existing S5 semantics handle CAS winners; this is not a claim of new proof for
all uncertain persistence outcomes. Full integration script, shipment, native
client and live provider validation were not run for this follow-up.
No live login, credential discovery, publication, commit, or push occurred.
