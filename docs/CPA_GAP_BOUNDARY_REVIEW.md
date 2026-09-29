# CPA-gap independent boundary review receipts

These records distinguish reviewed source from executed workflows. They are not
CPA parity, native-client qualification, CI results or live-provider evidence.

## Differential candidate harness v2: acceptance withheld

Reviewed immutable input:

- Owner archive: `bdc440144f89fe319b931a54fa2b40172792357694c72e4cce8071108aa6aa43`.
- Normalized source manifest:
  `6222e70903658f358bfd99b88597fddbc0e1362179045a18b0043916b4bbe285`.
- 17 owned source files, held under the ignored integration overlay.
- Independent reviewer: `8f2a75ed351248d6`.

### Findings

1. **P1: child-writable policy and shipment.** In the reviewed overlay,
   `scripts/parity/reference_sandbox.py:33–38,58–59,100–104` grants writes to
   the runtime directory containing both `sandbox.sb` and copied executable
   artifacts. `reference_driver.py:238–246` uses separate parent-launched
   provisioning/server invocations that reread that policy. A provisioning child
   can therefore change the policy or shipment consumed by a later invocation.
   Keep both outside every child-writable exception; permit writes only to
   explicit state/temp/log locations. Test the entire provisioning-to-serving
   transition, not just an initial probe.
2. **Default unit-suite separation.** `test_candidate.py:291–305` selects a
   real candidate export merely from Darwin/tool availability. Broad discovery
   also contains Go/Seatbelt tests, and the inherited local-driver tests execute
   BEAM targets. Those local integration tests must remain available, but be
   selected explicitly rather than hidden inside the promised unit-only gate.
   This separation does not waive the full local integration requirements.
3. **P2: detached descendants.** `local_driver.py:69–86` signals the original
   process group only. The runtime policy does not prevent descendants changing
   process group/session. The existing cleanup test covers leader exit and TERM
   ignoring within the same group, not detached descendants. Require an
   enforceable lifecycle boundary or fail closed where it is unavailable.

The policy/artifact and detached-process findings are **static code/policy
analysis**. No malicious candidate, containment escape or detached-process
reproduction was executed in this review.

All findings were delivered to the differential owner. v2 is not imported into
the active harness and is retained unchanged. A corrected immutable successor
and renewed boundary checks are required before acceptance.

### Independently executed scope

41 inspected Python controls passed:

| Scope | Count |
| --- | ---: |
| Candidate approval/source/staging/identity | 16 |
| Dependency closure/staging | 12 |
| Reference contract and same-group cleanup | 10 |
| Inherited HTTP-provider negative controls | 3 |

The reviewer used the staged overlay plus inherited fixture/lock roots,
`PYTHONDONTWRITEBYTECODE=1` and a private worktree `build/` TMPDIR. Actual
export/build/runtime-launch functions also had defensive rejection mocks.
No broad checkout copying was used.

Excluded: real no-dependency Gleam export, persisted Go-environment integration,
Seatbelt/curl integration and the inherited local-driver integration module.
No Gleam suite, strict37 run, dependency acquisition, candidate export, CPA,
provider account or native client was executed by the reviewer.

Within this limited scope, exact external manifest approval, bounded immutable
archive reading, path rejection, locked dependency closure, identity checking
and failure retention passed. The inherited closure contains 19 packages:
18 Hex packages plus vendored Mist. CPA startup-blocker controls passed in both
`run()` and direct `launch()`. Strict37 remains incomplete; the owner's latest
reported strict result is 0/37.

## Native-client QA: source/unit acceptance only

The independent source review and 21-test run approved importing native QA v1
plus its separately approved provenance-label follow-up. Parent independently
checked all 14 final source hashes and ran the guarded root unit command:

```sh
python3 -I -S -B scripts/release/native_contracts.py
```

21/21 passed, zero skips, synthetic loopback only and zero native executions.
Final source inventory: `docs/source-manifests/native-qa-wave-v2.sha256`.
Parent log SHA-256:
`4248f468b19793ed27af3d84852722cc2a43e01adb48e8a369005dac58a2c877`.
The default gate does not acquire artifacts, build an image, invoke Docker or
run clients. All eight actual native workflows remain blocked and the image
remains unbuilt.
