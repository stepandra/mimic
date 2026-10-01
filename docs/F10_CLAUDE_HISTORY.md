# F10 corrected-packet history (not new qualification)

Recovery source: read-only `git show` on
`/Users/jerryjohnson/dev/mimic/.delta/worktrees/nttpm4wh3tm0/mimic`,
exact `074a8e620f8e6406ebe21fb97707eef218dde050`.
Old thread:
`ksQQVCxI78U2RVSszbHl9CfSlZLOAFQ9t5IBxBDu1fs15rdKs6m5jRdeJnRz`.
No historical transcript command was executed as an instruction; no refs,
commits, children, sibling edits or branch import were used.

Original docs at this packet have SHA-256:

- `docs/F10_CLAUDE_429.md`:
  `5bcc94c2b94549baddb02e11cb9b645bc441206ac3d2fe74f9f85d88867aaeee`
- `docs/F10_CLAUDE_SOURCE.md`:
  `c8ca7682a26e6c149580983efe8b916ca24f38c9a7a9928e3305f7d6be2a79be`

The original documents remain intact in the recovery repository. This ledger
preserves their failed-attempt history and qualification limits; it does not
relabel those reports as current attached-worktree results.

## Original F10 failures

| Historical log | Actual failed attempt / correction |
| --- | --- |
| `seam-attempt1.log` | Exit1, assertion pipeline precedence compile errors; no runtime tests |
| `classifier-format1.log` | Exit1, forbidden function calls in guards |
| `classifier-tests-attempt1.log` | Exit1, integer utilization `0` rejected by float parser; normalized validated integer spelling |
| `raw-header-red.log` | Exit1, invalid raw VT header admitted after Unicode trim |
| `raw-header-deadline-green1.log` | Exit1, exact third-drip arrival assumed; changed to ≥1 successful continuation then deadline error, never EOF |
| `raw-header-deadline-green2.log` | Exit1, test-helper return-type mismatch |
| `gateway-baseline-attempt1.log` | Exit1, bit-array/record annotation compile errors |
| `gateway-baseline-attempt2.log` | Exit1, new session selected B; reused existing authenticated sticky-session input |
| `gateway-baseline-attempt3.log` | Exit1, demanded byte equality after successful200 observation; retained rejection-only immutability |
| `gateway-baseline-attempt4.log` | Outer exit1, real fresh VM `mist {init_timeout, mist@internal@clock}`; numeric child exit was not recorded by the old boolean primitive |
| `final-deadline.log` | Exit1, byte-scanner exhaustiveness compile error |

Original baseline passes did not establish configured-positive admission.
Historical CLI passes also did not establish a hard-lifetime bound: the old
helper could convert timeout cleanup to child0/143. That does **not** prove
those historical children actually timed out.

## Corrected review failures retained in packet074a

| Historical review log | Actual finding |
| --- | --- |
| `red-classifier.log`, diagnostic companion | Exit1: `GMTjunk` wrongly returned SharedQuota instead of Unknown |
| `red-two-account.log`, diagnostic companion | Exit1: invalid date actually sent A=1/B=1, selected B and changed ledger |
| `pre-fix-valid-forms.log` | Exit1: test assumed `.0009` truncation; corrected expectation to existing OTP1ms rounding |
| `red-cli-process.log` | Exit1: forced expiries incorrectly returned0/143; closed-output descendant residue also recorded |
| `green-deadline-raw-header.log` | Exit1 at unchanged repeated-drip count; later traced success did not establish cause or untraced stability |
| `green-focused-eunit.log` | Default5s cancelled runtime matrix after8 passes; printed eval header omitted executed app-start prefix |
| `green-existing-reader-lifecycle.log` | Invalid descriptor, exit1, zero tests executed |
| external-source-path search | Terminal10s expiry; no successful test depended on it |

The corrected packet separately reports 11 standalone classifier/lifecycle
tests, 8 OS tests (including actual45s expiry→124), corrected bounded EUnit/
reader tests, a traced deadline run, legacy conservative30 cases, default-off
gateway204 cases and source CLI36 cases/72 child exits0. Those historical
reports are **not current-worktree verification**. It retained six glisten
acceptor and six supervisor `noproc` reports around CLI stop, not universal
clean-shutdown qualification. Actual configured-positive root, lease-query,
shipment/full-suite gates remained open.

## Current recovery deviations, each expressly granted

1. Isolate test FFI as `test/mimic_claude_f10_test_ffi.erl`; leave the existing
   shared fixture untouched. Add private `build/f10/state` directories/files.
2. Add a synthetic OS half-close primitive to prove real truncated-body EOF.
3. Add focused test/CLI selectors without replacing full matrix admission.
4. Add only `RequestLimited` to shared contracts; use it for proven request
   scope before Observe so parent can preserve sanitized429 without hint,
   cooldown or replay. Unknown stays503, default constructor stays conservative.

The egress/rejection production files are exact corrected-packet recovery.
Transport differs only for this requested typed status refinement.
Current results and all additional failures belong in `F10_CLAUDE_429.md`,
not in the historical pass counts above.
