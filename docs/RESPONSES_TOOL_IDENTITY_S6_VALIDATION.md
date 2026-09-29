# Responses tool identity snapshot 6 — final evidence

The exact S6 overlay on base
`3e00808ff0fefbb6728edb1769c17139ef0fd93a` plus frozen S4/S5 passed the full
local integration script: **567 Gleam tests, 10 Python tests, all scenarios,
source and shipment smokes; exit 0**.

```sh
ERL_FLAGS="+S 2:2 +A 2" mise exec gleam@1.18.1 -- \
  sh scripts/verify-integration.sh
```

The gate used a fresh log directory and atomic single-launch guard. S6 changes
one shared validator only; it introduces no public API or provider normalization.

## Artifacts

| Artifact | SHA256 |
| --- | --- |
| `build/shared-core/snapshot-6/source.tar.gz` | `f533762770c9cba6c7cd4b99c2ad1b46e9e8946ad9b7ab9d24c05dcea3afc7b3` |
| `build/shared-core/snapshot-6/SHA256SUMS` | `294ab6dd3ad3b2fc1ae5052bc05b2781e80f4d9b10f3f829e198d31e03835629` |
| `build/shared-core/snapshot-6-gate/output.log` | `5e793a01a82b1a11062377211716ed848e52b71ece76145522f4beff100742e1` |
| `build/shared-core/snapshot-6-red/output.log` | `1b63b305507fe2f95c21935322fdc87b1eb0f6f84f70edc41b916963294af6e3` |
| `build/shared-core/snapshot-6-focused/output.log` | `c821619aafe37dad0bb661e9716c35e4a2d81b4ad890bba7356d1170a0fd6028` |

All three source manifest entries matched after testing. The durable manifest is
`source-manifests/shared-core-responses-s6.sha256`. This final evidence document
and its durable manifest were added after testing, without changing the packet.
Frozen S4/S5 archive hashes were rechecked and remain unchanged. S6 intentionally
supersedes the S4 stream source when applying overlays in order.

## Regression evidence

Pre-fix execution of the six new tests produced four failures and two passing
controls, confirming that the actual shared validator accepted conflicting
names/call IDs and malformed optional identity fields. After the fix:

- All six tests pass for function/custom delta/done events.
- Absent and matching optional fields remain accepted and documents unchanged.
- Supplied null/wrong-type/mismatched identities fail.
- Existing item ID, function/custom event kind and duplicate-done controls pass.
- Every byte split preserves the complete valid SSE prefix and rejects the bad
  event before emission.
- All 53 focused shared protocol/HTTP/WS tests pass, followed by the full gate.

xAI separately reports its hash-verified S4+S5+S6 overlay passing raw-before-alias
validation through actual loopback buffered/SSE/WS tests, including a namespace
collision rejection with the preceding event prefix preserved. That is
provider-reported consumer evidence, not independently rerun in this worktree.
The provider owns top-level name restoration after raw shared validation.

No actual provider/target, live account, new CI or CPA differential run occurred.
Origin canonicalization, sparse Responses-lite hydration, broader cross-dialect
projection and remote binary/H2 qualification are outside this patch. Provider,
gateway/root and dependency sources were not edited. No commits, merges or pushes
were performed.
