# Candidate mode validation checkpoint

**Historical v2 checkpoint; source-only acceptance was withheld after independent
security review.** The observations below are preserved, not reclassified as
passing safety evidence. Current v3 blocks candidate execution and separates safe
unit tests from selected integrations; see [REVIEW_FIXES_V3.md](REVIEW_FIXES_V3.md).
The frozen v2 archives and their original contents are unchanged.

This checkpoint validates the new candidate preparation/identity mechanism.
It does **not** claim that the integration owner's assembled provider candidate
was imported or that any CPA/provider parity row passed.

## Actual complete-source test

The test archive contains 156 production/config/resource/local-dependency files
from the pinned base, with an explicitly synthetic comment added to
`src/mimic.gleam` **inside the test archive only**. This makes the candidate
source different from the base without changing the production worktree.

- Manifest:
  `build/parity-candidate-test-v2/candidate.json`
- Manifest-byte SHA-256:
  `48ce6c0e7752cdea5de00ce44d22d12818953eeb270f5800590f8e01c1575fde`
- Source archive:
  `build/parity-candidate-test-v2/source.tar.gz`
- Source archive SHA-256:
  `30e3fbd769164a4681022d81fcea5d475b030098653b404074d8b96d6b6d1746`
- Derived lock closure: **19 packages: 18 pinned Hex archives and local `mist`**.

Observed sequence:

1. `--prepare` with no candidate dependency store failed at
   `offline-dependency-staging`, naming the missing `argv` archive. No compiler
   or acquisition fallback ran. The failed attempt remains preserved.
2. Explicit `--candidate-acquire` downloaded and checksum-verified those public
   archives into this candidate's own dependency store. No caller cache copied.
3. `--prepare` freshly extracted/verified the same approved source, staged
   immutable verified dependency bytes, and exported the real MIMIC shipment
   under the network-denying build sandbox. Source inventory checks passed
   before and after export. A repeat preparation also passed.
4. The existing strict runner executed the freshly built candidate's real
   gateway. Messages returned 200; Chat returned 422. Both fixtures remained
   failed under their unchanged assertions.
5. Every CPA result remained startup-blocked. **No CPA executable was launched
   during candidate-mode development or validation.**

The driver configuration, plans/results and execution record use:

```text
candidate-sha256:48ce6c0e7752cdea5de00ce44d22d12818953eeb270f5800590f8e01c1575fde
```

The published base is recorded separately. No clean-base identity is assigned to
this modified source package.

## Reproducible artifact index

Candidate attempt paths below are relative to:

```text
build/parity-reference/candidates/48ce6c0e7752cdea5de00ce44d22d12818953eeb270f5800590f8e01c1575fde/
```

| Artifact | SHA-256 |
|---|---|
| `prepare-pezt2nhr/failure.json` | `1806d5dae742a42478f2b39c30338e468626713522a1cdc2a574a12c2f2a60d8` |
| `acquire-ex692qb8/acquisition.json` | `39bb854559aedf0b41c1cf83823b223859650ed3f632081956f947c2f0f788ae` |
| `prepare-_rdq3ejf/candidate-build.json` | `f6b6425cb4bc22504e5a1ac3730a586fb99d95b47bdf547200c70e72c997061c` |
| `prepare-_rdq3ejf/targets.json` | `78136f74fe7e9085ed27c4e7e001fbeb2af9797d3d6b726d2ce362dc793b6b6f` |
| `prepare-_rdq3ejf/build-containment.json` | `814ed34cd0c860b2b06704c99533590f77a0a38c50b33a528cc7d28470469f49` |

Final strict report:
`build/parity-results/mimic-parity-793269CB9BBE129B673B9C8E/report.json`

SHA-256:
`2c544f628e91096f9f409ecab2e61f1c5ad5c47e4eddece84e3adbf3fabfa640`

The report retains per-row result directories. Their plans, raw synthetic
observations and execution metadata are not rewritten. A separate whitelisted
candidate evidence bundle preserves these small files, target/build/source
manifests and test logs without copying runtime state, executables, dependency
archives, source trees, `.git`, `.jj` or operator files. Do not use the legacy
v1 evidence exporter to relabel a candidate run with the global v1 target
manifest; candidate execution must retain its own exact target manifest.

## Checks

| Check | Observed outcome |
|---|---|
| Full Gleam tests | **523 passed**, unchanged from the reference-driver checkpoint |
| Python parity suite | **51 passed**: prior 22 plus 29 candidate/dependency controls |
| Format and diff checks | Passed |
| Actual minimal no-dependency compiler sandbox test | Passed |
| Actual complete-source export with all locked dependencies | Passed twice |
| Actual candidate runtime identity through strict runner | Preserved candidate digest and separate base |
| Strict37 release | **Exit 1, 0/37** |
| CPA launch during this checkpoint | **Not run; hard-blocked** |
| Live verification | **Not run** |

Negative coverage includes exact approval bytes, duplicate JSON keys, missing
inventory, archive mutation after verification, traversal/links/special entries,
source mutation during export, stale artifact hashes, candidate/base confusion,
precreated staging symlinks, linked shipment roots, no unsandboxed tool-manager
fallback, missing/corrupt dependencies, lock/local-path drift, malicious Hex
members and dependency archive mutation between verification and extraction.

Independent read-only review identified archive snapshot, parent-side staging
and tool-discovery issues; these were fixed and regression-tested. The legacy
v1 trusted-artifact-writer limitation is documented, not represented as signed
attestation. No production/gateway/provider or root CI file changed.

## Frozen history

These original artifacts remain byte-identical:

- `source-handoff-v1.tar.gz`:
  `d0b4f60ec61e5cadd9fac7c86c3dc686430dad100783a0ecbab629609cda0c3f`
- `evidence.tar.gz`:
  `e7ff131c6c9919cb0fc8ca850e1893b82d3c3e616d1ea3dcd9c1512c91fdfe1f`

The successor source-only handoff is an update to the owned harness namespace.
It is **not** a complete production candidate archive to feed to `--candidate-source`.
The integration owner must assemble and review that separate complete-source
package, then supply its exact manifest-byte digest to the new CLI.
