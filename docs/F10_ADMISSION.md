# F10 destination integration

Base: `dd15c610ec39e4f296c30fe02347d0d2b368a629`. This is a working-copy
integration record, not a release or parity result.

## Applied root boundary

- Optional root `claude_quota_classification` is a strictly typed boolean,
  defaulting to `false`. The existing conservative adapter remains the default.
- The classified branch uses the same selected-account F09 preparation closure.
  It branches at `runtime.open`, preserving each adapter's opaque handle type.
- Proven `RequestLimited / Rejected / None` becomes sanitized HTTP 429 without
  a retry hint. It is not converted to an account cooldown by the gateway.
- Proven `Quota / Rejected / Some(ms)` becomes sanitized HTTP 429 with a rounded-up
  seconds hint only within the classifier's positive bounded timing contract.
- Other runtime failures retain HTTP 503; response bodies or secret headers from
  a rejected provider response are not copied downstream.
- `gateway.active_leases` reads the actual running runtime for composed tests.

Dedicated root configuration regressions are in
`test/gateway_claude_limits_test.gleam`.

## Evidence separation

The isolated worker reported a successful 185.234-second serialized sequence:
17 F10 tests, 15 existing reader/lifecycle tests, the legacy 30-case conservative
control, 30 default-off gateway cases plus 12 fresh VMs, and 18 source-CLI cases
with 36 child starts/restarts. These predate this root hook.

Earlier Persistence, elapsed-time and fresh-VM failures remain unexplained.
Six shutdown crash/supervisor report pairs were retained even though child exits
were zero. Neither the rerun nor this integration claims clean shutdown stability.

## Outstanding destination gates

The root edits have **not yet been compiled or executed**. Validation is
serialized with other workers; no worker's focused result substitutes for the
actual configured gateway and source/shipment CLI matrices.

Run the commands in `docs/F10_CLAUDE_429.md`, using the actual
`gateway.active_leases` callback, then the root configuration tests and the
assembled full suite. Preserve any first failing run before correcting it.
The full classified matrix is 240 gateway cases and 42 CLI cases.

CPA differential, installed native clients, real-account OAuth and live
inference remain unperformed by this slice.
