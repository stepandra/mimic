# Kimi wire-v2: request-bound model restoration

This fixture supersedes the downstream expectations in wire-v1 **without
modifying the original v1 snapshot, manifest, or export**. It is an actual
synthetic loopback observation, not a live capture or CPA differential result.

## Reproduced failure and correction

The integration owner switched dispatch to `adapter.collect_for` and
`adapter.run_for`. The old wire test failed at its buffered Responses assertion:
it incorrectly expected the upstream response model downstream too.

The corrected test distinguishes:

- Upstream request and mock response model: `kimi-for-coding`, unchanged.
- Downstream buffered Chat/Responses and Responses SSE envelope model:
  requested `kimi-k2.7-code`.
- Buffered downstream Content-Length: checked against the actual UTF-8 body
  bytes, not copied from the upstream response. Observed lengths are 163
  (Responses) and 175 (Chat).

The raw upstream ordered header pairs, selected-account fallback, redaction,
API-key checks, and OAuth `.com`/`.ai` checks remain active. The test checks
model restoration independently of the snapshot comparison.

## Actual generation provenance

The integration owner's two source files were read, hash-verified, and staged
**only** into this owner's ignored `build/kimi-overlay`. No sibling builds or
edits and no tracked gateway/shared edits were made.

- Base: `3e00808ff0fefbb6728edb1769c17139ef0fd93a`
- Kimi v1 source archive:
  `bb17b35359aba919bc3224cc18b062964c1d9bcdc72522d92a24343c65e60905`
- Shared-core S4 archive:
  `f318501aaaa1cbf5a8c477097b871387b6a85f30a9692c2f9cdda1dc524bb5bc`
- `src/mimic/gateway.gleam`:
  `d9676d4b0228c1b0ba91bc340f5a279dac5b184e5fddd2cc5b0fb45347b33024`
- `src/mimic/gateway/config.gleam`:
  `cac362318cc2dfe7ae7b500f0dd36569c31c13bc0e7a9ec9012c0219e00661f7`

After reproducing the failure, the corrected `observe("api_key", None)` was run
against real gateway/upstream loopback processes. Its sanitized result was
serialized with `json.dumps(result, indent=2, ensure_ascii=False) + "\n"`.
The checked-in v2 snapshot is byte-identical to that generated output:

`63bfc7c7ed4f805a9ecd03fd4c69e9d16f385ba4466f33979ba2529daaabebe5`

Actual OAuth observations for `kimi.com` and `kimi.ai` separately produced the
same downstream bodies/events. The fixture was not made by editing v1's model
or length fields. The final unittest compares a new observation to the immutable
v2 fixture and verifies all three auth/domain sessions.

Run in the approved source assembly:

```sh
PYTHONDONTWRITEBYTECODE=1 GLEAM="$(mise where gleam@1.18.1)/gleam" \
  python3 -m unittest discover -s test -p 'kimi_wire_test.py' -v
```

This successor does not claim full integration, new live-provider coverage,
generic Kimi wire coverage, or Messages streaming. The integration owner
remains responsible for rerunning the full gate without skips.

## Validation

- Reproduced the original assertion failure against the two hash-pinned root
  files before changing the test.
- `cmp` confirmed the successor fixture bytes exactly match the actual
  generated observation.
- Updated wire unittest: **1 test passed in 6.866s**, exercising three
  independent CLI/loopback sessions (API key, OAuth `.com`, OAuth `.ai`).
- `mise exec gleam@1.18.1 -- gleam test` in the approved overlay:
  **576 passed, no failures**.
- `gleam format --check src test`: passed.
- Original v1 snapshot and source archive hashes remain unchanged.
