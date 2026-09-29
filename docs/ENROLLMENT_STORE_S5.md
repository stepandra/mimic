# Shared enrollment store — snapshot 5 contract

Approved additive follow-up to frozen shared-core snapshot 4. Source base remains
`3e00808ff0fefbb6728edb1769c17139ef0fd93a`. This overlay requires snapshot 4's
shared `mimic/ir/json_guard`; it does not replace or modify snapshot 4 files.
Provider/gateway enrollment call sites remain with their respective owners.

## API

```gleam
begin_enrollment(Store, String) -> Result(Enrollment, String)
commit_enrollment(Enrollment, AuthMaterial) -> Result(Nil, String)
cancel_enrollment(Enrollment) -> Result(Nil, String)
```

`Enrollment` is opaque, private, bound to the store/key and an exact expected
slot. Never log it, expose it to a client, or include it in a grounding pack.
Existing tickets contain the private prior material needed for safe cancellation.

Call `begin_enrollment` **before** OAuth setup, callback announcement/waiting,
device-code initiation or any enrollment network I/O. A failed begin must not
start the workflow. Only use `commit_enrollment` to install the resulting grant;
there is no unconditional-save fallback on any error. Call `cancel_enrollment`
on ordinary cancellation/terminal workflow failure. Handle uncertain persistence
outcomes as unknown, not permission to retry the grant or overwrite the slot.

## First enrollment

Secure absence is represented by `storage.read_runtime_slot -> Ok(None)`.
It means `read_link_info` returned ENOENT under an owner-private directory.
Unreadable, nonprivate and symlinked slots (including dangling links) are storage
errors. Present raw data is decoded by begin; corrupt or ambiguous records fail
there. Neither kind of failure is treated as absence.

Begin atomically creates a private nonce-only `enrollment_pending` marker in the
**same runtime filename**, under the existing per-record mutation guard.
The absence check is repeated inside that guard. Two initial begins cannot both
reserve the slot. The marker is not an `AuthMaterial`; credential acquisition
and metadata APIs fail closed while it is present.

Commit compares the exact marker and replaces it with a validated Ready
credential record with a fresh generation. Cancel compare-deletes only that
marker. Administrative save/delete/replacement defeats the old ticket, including
insert/delete ABA. A new begin after explicit cleanup uses a different nonce.

The successful reservation is the begin linearization point. A delete before
reservation cannot cancel a future enrollment; network work must not start
before begin has returned success.

A process/VM exit does not erase the pending marker. Recovery requires explicit
admin deletion followed by a fresh begin; no clock/TTL cleanup, automatic takeover
or reconstructed ticket is provided. This inherits the existing filesystem
backend's durability: file data is synced before rename, but directory sync is
platform-dependent. Fresh-VM persistence is tested; power-loss durability is not
newly qualified.

## Existing credentials and cancellation

Begin captures a validated exact record, without mutating it. Commit is an exact
CAS to the enrolled material in Ready state with a new generation. Replacement,
delete, refresh, same-value save and delete/recreate ABA defeat stale commits.

Cancel is a competing exact CAS:

- Preserve credential material, private metadata and refresh gate exactly.
- Generate a fresh local revision, defeating late callbacks and stale refreshes.
- Invalidate generation-bound WebSockets and HTTP continuation receipts.
- **Do not revoke provider tokens or delete existing material.**

Commit and cancel have one winner. If commit or an admin mutation already won,
cancel fails; it never deletes/overwrites that grant. Concurrent begin attempts
against the same existing generation may each hold a ticket, but only one
mutation wins. A successful cancellation also fences those peer tickets.

The existing mutation primitive completes independently of caller process death.
A mutation timeout is unknown outcome, not rollback. Do not equate cancellation
request delivery with a successful durable cancellation acknowledgement.

## Compatibility

The existing `AuthMaterial`, credential record v1/v2, save/load/transition,
credential workers, refresh manager and provider adapter ABI are unchanged.
No fake credential, extra manager, second store or provider-specific mutation
logic is introduced. Existing unconditional `save` remains an administrative
operation, not an enrollment completion primitive.

Storage adds secure optional read, guarded create-if-absent and compare-delete.
The FFI preserves the previous `mutate_runtime/4` Option(String) calling ABI;
only its new create helper uses a private absence expectation tag.

Runtime record decoding now uses the existing shared ambiguity guard before
dictionary decoding: 2 MiB JSON, depth 32, 4096 values. This accommodates maximum
validated material/metadata even when control bytes require JSON escaping.
Malformed and duplicate decoded keys fail without mutation or secret-bearing
errors.

## Validation status at publication

New tests exercise first double-begin; initial/admin delete/save/ABA; existing
replacement, same-token save and delete/recreate; competing commit/cancel;
gate-preserving cancellation; noncredential markers; corrupt/ambiguous/nonprivate/
symlink distinction; invalid-grant admission; and process/VM restart cleanup.
All fixtures are synthetic and use private explicit state directories.

All 12 enrollment tests passed, including ambiguous decoded keys and maximum
escaped-material budgets. Existing runtime v4/v3 regressions also passed
(33 tests, for 45 distinct focused tests). The full integration gate and
independent review are pending. This early API snapshot is not itself a claim
of fixed provider enrollment routes; consumers must use the new hooks.
