# HTTP/provider and WebSocket merge validation

The final handoff was applied to the coordinator's clean working copy at
`f809b8c8a51939383792e6e88d5eb4f98b7ddcc2`. This report records validation
in that actual merge destination, not a sum of independent thread results.

## Input integrity

- Source-only handoff: 73 files, 58 additions and 15 modifications.
- `SHA256SUMS` digest:
  `ac8212fe7cb8171733b1678f538163150574ee2131de700a61d121abdde11e17`.
- All 73 destination file hashes matched before and after the integration
  gate. The snapshot's declared base, path safety and regular-file checks
  passed; no credential stores, caches or build outputs were imported.
- README and third-party notices were updated separately to describe the
  newly exposed modes and the vendored Apache-2.0 Mist dependency.
- The pinned upstream Mist trailing space was retained deliberately. The
  application/test formatting gate and the diff check excluding `vendor/mist`
  passed; the one upstream whitespace exception remains documented in
  [MIST_VENDOR.md](MIST_VENDOR.md).

## Executed gate

Environment: Gleam 1.18.1, Erlang/OTP 29, macOS.

```sh
GLEAM=/absolute/path/to/gleam sh scripts/verify-integration.sh
```

The complete invocation exited **0**:

- **522 Gleam tests**, no failures.
- **10 Python driver tests**, no failures.
- Existing runtime/provider/Responses/Devin scenarios passed.
- Strengthened raw WebSocket handshake gate passed: the normal request
  upgraded, ambiguous singleton headers and HTTP/1.0 upgrades were rejected.
  Its negative helper distinguishes confirmed peer closure from timeout,
  reset, partial headers and other failures.
- Actual root HTTP and WS CLI workflows passed, including Claude OAuth/SSE,
  Kimi enrollment/refresh/streams, client-key revocation, selected-account
  origin/authentication and coalesced WebSocket upgrade/create.
- Separate-VM credential fence restoration passed without reseeding.
- Erlang shipment export passed. Base, HTTP-provider and WebSocket shipment
  smokes passed from separate working directories.
- Vendored management and Autopilot shipment assets were byte-identical.

The local log is `build/integration/http-ws-merge-gate.log`, SHA-256
`e634463ab894ec6dbcb0c9ee74929a19adda992a48bec071b2f2820e95325367`.
Negative tests intentionally emit fixed malformed-request, TLS-certificate
and stream-failure diagnostics. Dependency deprecation warnings remain.

The earlier independent reviewer result is separate: strengthened WS
`--strict` and 11 targeted tests passed without production source changes.
Historical failed runs remain recorded in
[HTTP_PROVIDER_VALIDATION.md](HTTP_PROVIDER_VALIDATION.md).

## What this does not establish

The strict CPA reference gate remains incomplete; this merge does not waive
missing reference-driver cases or promote synthetic evidence to live evidence.
No real provider account or native-client login was used. Codex WebSocket
remains opt-in and does not imply WebSocket support for other providers.
Current functionality and deliberate limitations are in
[PROVIDER_INTEGRATION.md](PROVIDER_INTEGRATION.md).

Remote CI is a separate run after publication, not inferred from this local
result. No generated test state or raw provider credentials are committed.
