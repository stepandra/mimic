# xAI v3: restore top-level argument-event identity

This is a **six-file superseding delta over frozen xAI v2**, not a replacement
for its complete handoff. The original archive is unchanged:

`1fa25e82b69b45c8d435c918bc387427691e14fb7eb14d2d967e3d90fded5a92`.

Base Git revision remains `3e00808ff0fefbb6728edb1769c17139ef0fd93a`.
No root, shared-core or Codex files are changed.

## Reproduction and fix

The v2 mapper restored names in `item` and terminal `response.output`, but
omitted top-level names on `response.function_call_arguments.done`. That made
one response expose inconsistent identities: `run`/`shell` in output items
but `shell__run` with no namespace in the argument event.

Before the production fix, all three new/extended drivers failed:

| Driver | Observed failure | Exit |
|---|---|---|
| `xai_argument_events_test` | `shell__run` instead of `run` | 1 |
| `xai_adapter_test` | `clientfn_web_search` instead of `web_search` in actual SSE | 1 |
| `xai_websocket_native_test` | `shell__run` instead of `run` in actual WS | 1 |

`request.restore_event` now applies the existing selected-request ref mapping
to top-level identity fields on **only**:

- `response.function_call_arguments.delta`
- `response.function_call_arguments.done`

It changes name/namespace, not call IDs, item IDs, sequence numbers, argument
or delta text, or arbitrary nested fields. Omitted names remain omitted.
Unrelated/custom event kinds and names absent from the selected request's ref
table are not guessed or rewritten. Both adapters still validate raw events
before applying this provider transform.

The HTTP fixture now carries the optional name/call ID on argument-done.
Existing buffered assertions and new SSE assertions check the same aliases and
namespaces for two selected accounts/origins, HTTP 200/201, and API-key/OAuth
separately. The WS/WSS fixture checks the same top-level restoration and
unchanged argument text. This extends the actual transport tests rather than
relying only on a standalone mapper probe.

## Shared raw validation is a separate dependency

Restoration is not evidence that a wire identity was valid. Import shared S6
as well before declaring the combined audit blocker resolved:

| Shared archive | SHA-256 |
|---|---|
| S4 | `f318501aaaa1cbf5a8c477097b871387b6a85f30a9692c2f9cdda1dc524bb5bc` |
| S5 | `a663d946002aa8eeed255f8df4cde6c49faacf1b304b5ed370eef48cf2f04f5f` |
| S6 | `f533762770c9cba6c7cd4b99c2ad1b46e9e8946ad9b7ab9d24c05dcea3afc7b3` |

S6 checks present raw `name` and `call_id` against the established item on
function/custom argument delta/done events. Omitted fields remain valid;
wrong types, null and mismatches fail. The provider patch does not duplicate
or weaken these checks.

`test/xai_shared_identity_s6_test.gleam.fixture` is a derived-test input:
compile it as `test/xai_shared_identity_s6_test.gleam` only after the exact
shared dependencies are present. It was run successfully in a generated
build-only overlay, without editing shared source in this or sibling worktrees.
It invokes all six shared identity regressions (including every SSE byte split),
the xAI mapper tests and actual buffered/SSE/WS positive scenarios. It also
proves a physical xAI WS response changing argument-done from `shell__run` to
`other__run` is rejected **before** both would restore to short name `run`.
The valid created/keepalive/item-added prefix survives, but the conflicting
argument event is not delivered.

## Exact verification

All commands used `mise exec gleam@1.18.1` and
`ERL_FLAGS='+S 2:2 +A 2'`.

- All three reproduction drivers above passed after the fix, exit 0.
- `sh scripts/verify-integration.sh`: exit 0, **532 Gleam tests**, **10 Python
  tests**, existing source scenarios/smokes and Erlang shipment/export/smokes
  passed. This includes the final synthetic peer fixture changes.
- In the S4+S5+S6 build-only overlay,
  `gleam run -m xai_shared_identity_s6_test`: exit 0.

Logs under `build/xai-native/v3/`:

| Log | SHA-256 |
|---|---|
| `release-gate.log` | `14cbbb1dafa38697947d906c235f0a7f4cc824b136ef6d3af08dcccda85f312b` |
| `red-xai_argument_events_test.log` | `98a53690fcb40174b6bab31168a9227c282f99569cf9dec5af864cba8865f809` |
| `red-xai_adapter_test.log` | `24de15110668795d8056bf042987833dad0b44466bb9db4735747f8838d7d2b2` |
| `red-xai_websocket_native_test.log` | `8f657145228260d25a3fc9bfd11cb0033146e78b3370f651bccc496e8a49a7ae` |
| `green-xai_argument_events_test.log` | `8213fb2583aac221a6986bb3148c3c7e2cf99227c699e8376453e82ee9ec4bf5` |
| `green-xai_adapter_test.log` | `3016b6affda16bd6ed4180536213848ce513d65dd0a98ba3f2b0ae6f06ff31ac` |
| `green-xai_websocket_native_test.log` | `e8fc0d820e3da75212b0cb77fd6a568ed2bac80cb3c546d7ea0d7fb9948dff23` |
| `s6-composition.log` | `5df5bf15737a13d220ab9451cd06456da01c297eb3ff23ff02b3611d087e3367` |

The source-only packet also supplies preimage and replacement hashes for
conditional import over v2. It must not overwrite unrelated integration edits.

## Not claimed or changed

- The trailing-slash origin configuration issue was routed to integration:
  accepted `http://127.0.0.1:1/` can become `//v1` and fail the provider's
  exact-origin comparison. Canonicalize once or reject at the trusted
  configuration boundary; this patch does not silently normalize/move a token.
- No assembled ALL9 gateway route validation, native Grok executable run,
  CPA differential or live-provider/OAuth/account behavior is claimed here.
- Existing HTTP-continuation/compact/media/custom-tool exclusions remain.
- No frozen archive mutation, automatic merge, commit or push.
