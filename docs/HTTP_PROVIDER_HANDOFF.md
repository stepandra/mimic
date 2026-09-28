# HTTP/provider assembled handoff

## Apply boundary

The final source-only snapshot is packaged under
`build/final-http-integration-v1/`. Its `CHANGES.tsv` and `SHA256SUMS` are the
authoritative changed/added/deleted path list and final byte hashes.
`source/` contains only those source files, rooted relative to the repository.
`BASE.json` records baseline, evidence identities and dependency inputs.
`OWNER_SHA256SUMS` separately identifies HTTP-owner/coordinator-approved
integration files, excluding unchanged peer-owned WebSocket inputs and the
recipient-tested guardian candidate. No `.git`, `.jj`, build output, runtime
state, credentials or shared caches are included in `source/`.

Apply to **exact published base**
`f809b8c8a51939383792e6e88d5eb4f98b7ddcc2`, not the stale local
`c3ca7e80` checkout. Verify every manifest hash before applying. Preserve any
pre-existing work; this snapshot is for an explicit later merge, not permission
to overwrite another checkout, commit, push or move `origin/main`.

## Dependency and ownership layers

1. HTTP/Claude/Kimi source, gateway/config/refresh/enrollment, callback-only
   auth extraction, docs/examples, local drivers and fresh-process smokes.
2. Frozen WS V2: original 14-file provenance is in
   `source-manifests/WEBSOCKET_V2_SHA256SUMS`. All **eight production files**
   remain byte-identical. It supplies the tested
   `websocket.upgrade_authenticated(req, runtime, tenant, Settings)` API.
3. The approved two-file WS guardian test candidate is in
   `source-manifests/WEBSOCKET_RUNTIME_TEST_CANDIDATE_SHA256SUMS`.
   It is independently run by the recipient, not an owner-certified V3 release.
4. Approved integration-test adjustment:
   `source-manifests/WEBSOCKET_INTEGRATION_TEST_SHA256SUMS`. Only the imported
   `gateway_websocket_test.gleam` differs from V2; one new reader FFI
   distinguishes confirmed close from fixture timeout. Positives require
   101 and exact Accept. Single version rejection, both duplicate orders,
   zero upstream effects/leases and timeout-not-close are explicit tests.
   The original WS test FFI and all WS production remain unchanged.
5. Pinned local `vendor/mist` 6.0.3, with root dependency/lock changes.
   `MIST_VENDOR.md` records official archive checksum, Apache license and
   original source hashes. Only its HTTP parser is patched. Unrelated
   dependency pins are unchanged; no mutable build-cache patch is required.

The complete snapshot already includes all five layers in their final order.
Do not overlay the original V2 test file afterward: that would undo the
documented test-only integration correction.

## Reproduce

```sh
mise exec gleam@1.18.1 -- sh scripts/verify-integration.sh
```

Observed final result: **exit 0**, **522 Gleam tests**, **10 Python tests**,
all local scenarios, strengthened raw WS gate, and actual root HTTP/WS CLI
and shipment workflows passed. `HTTP_PROVIDER_VALIDATION.md` preserves
the exact log SHA, earlier 520/1 failed run, source and environment scope.
The first published-base gate had 463 tests; it is historical, not the final
combined count.

The vendored upstream `http2/frame.gleam` is not reformatted. A single original
trailing space at `vendor/mist/src/mist.gleam:752` remains byte-identical to
Hex; `git diff --check` reports it. Application/test formatting passes.

## Operator entry points and limits

See `PROVIDER_INTEGRATION.md` and
`../examples/providers-http.synthetic.json` for secret-free configuration.
Private provisioning uses `providers credential import/login/status/delete`;
no token values go on argv. `serve providers <config>` uses the existing root
CLI dispatch. Claude uses configured PKCE/callback and native JSON exchange;
Kimi uses configured device enrollment. Both persist only through the shared
runtime store. API-key credentials have no invented expiry.

Codex WS is **off by default** and enabled only by `codex_websocket: true`.
Claude/Kimi/xAI WS are not advertised. Kimi is a bounded native provider, not
generic OpenAI compatibility: text-only Responses JSON/SSE and buffered Chat;
Chat SSE, native tools/media/thinking transforms, compact, continuation and
Anthropic delegation fail explicitly. Devin scope is unchanged.

Strict CPA release still returns **exit 1, 0/37 required rows**, no live
evidence. The native Kimi driver intentionally leaves ordered-header fidelity
unverified/red. No live provider, native-client, fingerprint, performance or
GitHub CI result was fabricated. Gemini, Antigravity and Copilot remain excluded.
