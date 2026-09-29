# Enrollment store snapshot 5 — final evidence

## Result

The exact published S5 overlay on frozen S4 passed a clean, single-launch full
`scripts/verify-integration.sh` run: **561 Gleam tests, 10 Python tests, all
scenarios, and source plus shipment smokes; exit 0**.

Command:

```sh
ERL_FLAGS="+S 2:2 +A 2" mise exec gleam@1.18.1 -- \
  sh scripts/verify-integration.sh
```

Local runtime was OTP 29 / ERTS 17.0.4. No new CI, live-provider or CPA
differential run was performed.

## Frozen artifacts

- Published base: `3e00808ff0fefbb6728edb1769c17139ef0fd93a`.
- S5 is an incremental overlay requiring shared-core S4; it does not change
  any of the 17 S4 manifest entries. Both manifests were checked after the gate.
- Archive: `build/shared-core/snapshot-5/source.tar.gz`, SHA256
  `a663d946002aa8eeed255f8df4cde6c49faacf1b304b5ed370eef48cf2f04f5f`.
- Manifest SHA256:
  `5eb52b8c1ef26466a851ef3ff1e2e72a819e4d93d056914b6e682435d6620a40`.
  Durable copy: `source-manifests/shared-core-enrollment-s5.sha256`.
- Clean gate log: `build/shared-core/snapshot-5-clean-gate/output.log`, SHA256
  `78910ce845dc150057b9434fb6a135f94b5fa5be4b87f66f1a93232e6ee5da2a`.

The six-file source-only archive contains three shared source files, two test
files and `ENROLLMENT_STORE_S5.md`. No dependency trees, repository metadata,
credentials, runtime state or build output are included. This final evidence
document and durable manifest were added afterward without source changes.

The first full-gate attempt had overlapping invocations sharing a log and
shipment build directory; export failed with missing generated argv Erlang files
while another invocation completed. That mixed log remains at
`build/shared-core/snapshot-5-gate.log` and is **not accepted as clean evidence**.
The successful rerun used a fresh log directory and atomic single-launch guard.

## Review and tests

Independent read-only review found no production correctness defect. An initial
duplicate-key fixture concern was retracted after the reviewer saw the added
otherwise-valid v2 escaped-equivalent-key regression. Maximum JSON-escaped
material/metadata compatibility is also directly covered.

The 12 enrollment regression tests cover:

- Initial reservation never loading as credentials or metadata.
- Concurrent first begin, one-shot commit and winning cancellation.
- Administrative deletion/save/ABA against initial tickets.
- Existing replacement, same-value save, deletion and recreation.
- Existing cancellation preserving material, private metadata and refresh gates
  while rotating local generation and defeating stale refresh/commit.
- Commit/cancel races with no cancellation deletion of an already committed grant.
- Corrupt/ambiguous/nonprivate/unreadable/symlink distinction from absence.
- Invalid-material rejection without consuming the reservation.
- Valid records with duplicate decoded keys and maximum escaped material.
- Pending markers surviving VM exit until explicit administrative cleanup.

The existing 33 runtime v3/v4 tests also passed before the full gate. All tests
use synthetic material and private explicit state directories.

Reviewer-suggested supplementary probes ran successfully against the exact
compiled snapshot, without changing frozen source:

- Deterministic absent read, intervening admin/corrupt write, rejected
  create-if-absent, unchanged bytes, then successful mutation proving guard cleanup.
- Valid v1 record enrollment.
- Successful reenrollment from Deferred and NeedsReauthorization to Ready with
  a fresh generation and preserved submitted material.

These probes are additional local evidence, not added permanent test cases.
Their output is `build/shared-core/snapshot-5-supplemental.log`, SHA256
`1978f8ca25bcb60873afdd5755042850165bc9bc7a74410449db3a170a6d44f7`.

## Consumer requirements and limits

Use the exact begin/commit/cancel APIs documented in `ENROLLMENT_STORE_S5.md`.
Begin must succeed before any enrollment announcement, callback wait or provider
network operation. Never fall back to unconditional save.

Cancelling existing reenrollment preserves material and refresh gate, but rotates
the local generation: WS/HTTP receipts invalidate. It does not revoke provider
tokens. A first-enrollment crash marker requires explicit admin cleanup; no TTL
takeover is implemented. Persistence timeout remains unknown outcome.

Provider/gateway call sites were not edited here. Their owners must adopt the
hooks and validate assembled enrollment races. Passing the shared gate does not
claim those independent call-site fixes are already integrated.

No commits, pushes, automatic merges, provider calls, home/environment credentials
or primary/sibling checkout edits were performed.
