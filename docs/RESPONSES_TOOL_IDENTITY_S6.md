# Shared Responses raw tool identity — snapshot 6

Bounded audit follow-up on published base
`3e00808ff0fefbb6728edb1769c17139ef0fd93a` plus shared snapshots 4 and 5.
The frozen S4/S5 archives are unchanged. This incremental overlay supersedes
only S4's `src/mimic/protocol/responses/stream.gleam`, adds a regression module,
and includes this document.

## Finding and rule

The shared argument-event validator checked output index/item ID and the
function/custom event kind, but ignored optional top-level tool `name` and
`call_id`. Consequently a `response.function_call_arguments.done` document
could name `other__run` after the item was established as `shell__run`.
Provider namespace restoration could hide that mismatch if applied first.

The same rule now applies to function-argument and custom-input delta/done:

- Omitted `name`/`call_id` remain valid.
- Supplied fields must be strings exactly matching the raw established item.
- Null, wrong types, empty or different identities fail closed.
- Existing item ID, event kind, closed-item and duplicate-done checks remain.
- The event's top-level `type` is the event discriminator, not a tool-kind
  field; the existing function/custom kind check remains authoritative.
- Matching documents and unknown native extension fields remain unchanged.

No public API change, content reconstruction, alias normalization, sparse
terminal policy or origin rewrite is introduced. Shared validation must run on
raw wire identities before provider-owned alias restoration. xAI owns the
separate fix that restores optional argument-event names afterward.

## Regression evidence at publication

The six new synthetic tests were run against pre-fix source: four failed and
two controls passed. They reproduced acceptance of conflicting name/call ID,
invalid optional identity types, and the resulting SSE emission.

After the narrow patch, 53 focused tests passed: the six new tests plus existing
Responses protocol, real loopback HTTP, and WS protocol tests. Coverage includes
function/custom delta/done, absent/matching optional fields, exact document
preservation, wrong item/kind controls, and delivery of only the valid prefix
before the bad event at every byte split.

Red log: `build/shared-core/snapshot-6-red/output.log`.
Focused green log: `build/shared-core/snapshot-6-focused/output.log`.
The full integration gate is pending at this early immutable checkpoint.
No actual provider/target, live account or CPA differential was run.

## Out of scope

This does not change origin canonicalization or qualify remote binary/H2
transport. Those require a separate trusted configuration decision. Native
Responses-lite sparse hydration and broader cross-dialect projections remain
explicitly deferred. Provider/root namespaces and dependencies are untouched.
