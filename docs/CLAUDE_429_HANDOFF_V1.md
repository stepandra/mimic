# Claude 429 conservative release fix v1

This is a mandatory additive release fix, not a claim of full CPA rate-limit
fidelity. It supersedes **all earlier Claude generic-transport construction
examples**, including the example in frozen `CLAUDE_POLICY_HANDOFF_V1.md`.
Policy v1 and enrollment v1 source/manifests remain byte-identical.

## Root cause and boundary

The generic runtime observes every `Ok(Opened)` status/header set before
applying its rejection decision. Quota observation cools credentials on any 429.
Therefore changing only `claude/adapter.rejection` cannot prevent cooldown.
That callback also marks every 429 retryable quota, potentially walking the
pool for a fast-mode entitlement refusal belonging to the request.

New `mimic/providers/claude/transport.http(prepare, ca_file)` wraps the existing
shared HTTP adapter. After valid response headers arrive, but before returning
`Opened` to runtime:

- For 429, close the handle once and return
  `Failure(Unsupported, Rejected, None)`.
- No response body is read, buffered, parsed, logged, or forwarded.
- No handle is transferred to runtime on this error; runtime cannot close it
  again. Its error path releases the lease, skips observation and does not retry.
- All other statuses and the existing origin/auth/TLS/framing rules are unchanged.

**Availability tradeoff:** genuine credential-quota 429s also receive this
terminal, non-quota result. They do not automatically cool down or fail over.
Bounded body-aware scope classification is a separately qualified future change.
No private body/header or unqualified Retry-After is exposed in this failure.
This does not change OAuth token-endpoint refresh handling.

## Mandatory T9 gateway wiring

For every Claude path—buffered Messages, streaming Messages and count_tokens:

```gleam
import mimic/providers/claude/transport as claude_transport

let provider = claude_transport.http(claude_adapter.prepare, ca_file)
```

For the approved native/translated policy callback, retain its prepare closure
and pass that closure to `claude_transport.http`. Do not construct a Claude
provider using shared `transport.http(prepare, claude_adapter.rejection, ...)`.
The old rejection helper is insufficient on its own, even if changed to return
a non-quota reason.

T9 owns all gateway imports/call sites and the sanitized downstream mapping.
Do not return upstream rejection bodies, private headers, or automatic retry
hints. Do not modify shared ABI or invent a provider-independent rate-limit
rule. **The merge blocker remains open until actual gateway wiring and its
assembled route regressions pass.** This package does not edit the gateway.

## Artifacts and dependencies

Source-only archive: `build/claude-429-v1.tar.gz`; exact members/hashes:
`docs/CLAUDE_429_V1_SHA256SUMS`. Only new Claude-owned files are added:

- `src/mimic/providers/claude/transport.gleam`
- `test/claude_429_test.gleam`
- `test/mimic_claude_429_test_ffi.erl`
- This handoff and its manifest.

Retain the authoritative policy and enrollment exports, and their S4/S5
dependency order. This fix uses the existing `Adapter` ABI, not a new shared
snapshot. Validation used base `3e00808ff0fefbb6728edb1769c17139ef0fd93a`,
Claude policy/enrollment v1, and the same verified shared archives:

- S4 `f318501aaaa1cbf5a8c477097b871387b6a85f30a9692c2f9cdda1dc524bb5bc`
- S5 `a663d946002aa8eeed255f8df4cde6c49faacf1b304b5ed370eef48cf2f04f5f`

No shared, root, gateway, vendor, CI, sibling or primary source was edited.

## Executed evidence

Validation overlay: `build/claude-enrollment-v1-b7ala27s`. Stage current owned
source and verified dependencies using the frozen enrollment overlay runner.
Then, in that overlay:

```
ERL_FLAGS='+S 2:2 +A 2' mise exec gleam@1.18.1 -- gleam run -m claude_429_test -- --baseline
ERL_FLAGS='+S 2:2 +A 2' mise exec gleam@1.18.1 -- gleam run -m claude_429_test
ERL_FLAGS='+S 2:2 +A 2' mise exec gleam@1.18.1 -- gleam test
```

- Baseline selects the old generic adapter and **fails all 30 cases**.
- New wrapper passes **30 real two-account HTTP wire cases**:
  API key/OAuth × buffered Messages/streaming Messages/count_tokens × fast-mode
  credit refusal/ordinary quota/malformed JSON/large body/stalled body.
- For each rejection: exactly one upstream request to A, none to B, zero
  remaining leases and byte-identical persisted quota ledger—even with explicit
  Retry-After and rejected unified-rate-limit headers.
- A normal request pinned to A succeeds immediately, then again after runtime
  restart without reseeding. The fixture observes the expected peer closes.
- The stalled fixture sends complete headers but never sends its advertised
  body. The wrapper closes without waiting for it; this is a no-body-read test,
  not a claim of new timeout behavior.
- Logger-capture assertions contain no synthetic access/refresh/API tokens,
  private upstream marker or request-body marker.
- Full assembled consumer-overlay suite: **580 passed, no failures**.
- Source/test formatting and scoped whitespace checks pass.

Raw evidence hashes:

```
127827b4262af760fdec5e0ba5973194293bcc2811524875960abc5b60dd9d87  build/claude-429-red-v1.log
49a87ca4917944014460b16bd65ad69639a260d373c7d524a8719fcca379c907  build/claude-429-green-v1.log
06503fbcf8fe4e701ab279837c11001a9073d5dd12acf43b684d91ce9130f48e  build/claude-429-full-v1.log
```

These are synthetic local wire tests, not executed CPA differential, native
client, live account/provider, final gateway wiring, shipment or CI proof.
No live calls, credential discovery, publication, commits or pushes occurred.
