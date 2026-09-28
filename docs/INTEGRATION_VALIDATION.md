# Combined application validation

## HTTP providers and opt-in WebSocket follow-up

The integration on published base
`f809b8c8a51939383792e6e88d5eb4f98b7ddcc2` now includes native Kimi
API-key/OAuth Chat/Responses, Claude Messages SSE/OAuth with configured login
and refresh, the frozen peer Codex WS implementation, and a checksum-pinned
Mist 6.0.3 parser patch. The complete expanded
`mise exec gleam@1.18.1 -- sh scripts/verify-integration.sh` exited **0**:
**522 Gleam tests**, **10 Python tests**, strict raw WS handshake tests,
all existing scenarios, actual root HTTP/WS CLI workflows, and both exported
shipment workflows passed.

See [HTTP_PROVIDER_VALIDATION.md](HTTP_PROVIDER_VALIDATION.md) for exact scope,
log hashes, the first failed 520/1 integration run and its test-only correction,
frozen input provenance and remaining gaps. This follow-up is local synthetic
evidence, not a new GitHub CI result, live compatibility or CPA certification.
The strict 37-row release gate was rerun independently: **exit 1, 0/37**, with
no live evidence. Missing required cases remain red.

## Historical published-base validation

This is evidence from the assembled worktree, not a sum of isolated handoffs.
The tested implementation includes runtime v4, Responses v2, Codex v4,
corrected Claude OAuth parsing, the xAI integration, the experimental Devin
adapter, and the authenticated provider gateway.

Environment: Gleam 1.18.1, Erlang/OTP 29, macOS. Linux CI is configured to run
the same local integration script, but local results do not establish its
remote result.

## Final local gate

Command:

```sh
GLEAM=/path/to/gleam sh scripts/verify-integration.sh
```

The final complete invocation exited **0**.

| Check | Observed result |
|---|---|
| Gleam format check | Passed |
| Full assembled `gleam test` | **463 passed, no failures** |
| `doctor` | Required tools found |
| Conformance-v2 matrix/fixture schema | Valid; no parity claim |
| Python local-driver regressions | **7 passed** |
| Runtime scenario command | **52 synthetic scenarios passed** |
| Claude provider scenarios | Four groups passed |
| Claude/runtime consumer scenarios | Six groups passed |
| Codex policy and real-loopback commands | Both passed |
| Shared Responses HTTP scenario | Passed |
| Devin runtime scenario | Six cases passed; loopback only |
| Actual root CLI gateway smoke | Passed |
| Separate-VM Claude state seed/restore | Passed without reseeding or token exchange |
| Erlang shipment export | Passed |
| Shipment gateway smoke from a different working directory | Passed |

The CLI/shipment smoke imports synthetic credentials through private files,
starts the actual listener, checks authentication, models, Messages and
count_tokens, stops via SIGTERM, and restarts the same store without reseeding.
It verifies key revocation prevents the next upstream call, the upstream Host
matches the configured origin, and client/provider credentials are isolated.
This is a real loopback workflow, not a callback-only test.

The Gleam suite also exercises actual gateway Codex/xAI buffered and SSE
requests, compact responses, malformed-prefix stream termination, and
experimental Devin binary-to-Chat handling. Standalone/shared WebSocket tests
do not establish a physical provider WebSocket gateway route.

## Defects found during assembly

- xAI initially captured the first configured account's origin before runtime
  selection. A two-account real-socket regression failed when the first account
  lacked credentials and the selected account had a different origin. The
  endpoint plan now uses the selected `Context.origin`; the regression passes.
- The TLS recorder fixture timed out before its own allowed certificate
  startup work and started the upstream accept window too early. A delayed
  real TLS regression failed before the fixture fix and passed afterward.
  Production TLS verification/timeouts were not relaxed.
- The first integration-script invocation omitted the Codex scenario's required
  private state-directory argument. The runner now creates one explicitly.
- A subsequent run reached shipment export but Python could not directly
  execute Gleam's generated POSIX script without a shebang. The smoke now
  invokes it with `sh`, and both the targeted shipment check and the entire
  integration script pass.

Cold shipment compilation reports dependency deprecation warnings in `gramps`
and `mist`. Negative TLS tests intentionally produce Unknown CA/hostname
rejection notices. The corrupted-SSE test intentionally produces a fixed
`upstream stream failed` supervisor reason. These are not silently suppressed.

## CPA scope is still not satisfied

The checked-in **baseline** driver targets the older laboratory ingress; it
does not replace missing provider-specific conformance drivers with the new
gateway smoke. A measured baseline report still records **3/37** narrow mock
successes. The shell wrapper's first combined baseline/release attempt exceeded
its 60-second tool allowance after the baseline report was written; it is not
counted as a completed strict run.

A separate strict invocation completed with the expected **exit 1, 0/37**:

```sh
gleam run -m parity/runner -- release scripts/parity/baseline-drivers.json \
  --manifest test/parity/v2/manifest.json
```

There is no configured CPA executable driver, required capability gaps remain,
and no live evidence was collected. A green local build does not turn that
strict failure into a pass. The supported gateway modes and outstanding
features are listed in [PROVIDER_INTEGRATION.md](PROVIDER_INTEGRATION.md).

The publication is an integrated development snapshot, **not a certification
of full CPA parity**, native-client compatibility, performance, or live OAuth.
Gemini, Antigravity and Copilot remain excluded. Kimi was not registered in
this historical baseline; its newer bounded native integration is documented
in the follow-up above.
