# F12: catalog-qualified native Codex HTTP-lite

**Provider consumer implemented and compiled against completed F11. Root admission
and configured source/shipment execution are parent-owned, not claimed here.**

Owned source: `providers/codex/{adapter,http,models,request,response,local}.gleam`.
Dedicated acceptance: `test/codex_http_lite_test.gleam`,
`scripts/smoke-codex-http-lite.py`. One legacy provider test was corrected:
`codex_http_runtime_test` can no longer manufacture lite support on the pinned
`gpt-5.5` catalog entry (`use_responses_lite:false`). Its new negative test proves
rejection before I/O; positive lite coverage uses source-flagged `gpt-5.6-sol`.
The old local lite scenario also uses that flagged model; ordinary local/strict
behavior stays unchanged.

No shared Responses, WS/F13, auth/runtime/store, vendor, root gateway/config/CLI
source files were edited. `F12_ROOT.patch` is an **unapplied parent artifact** in
`apply_patch` tool format; it is not a Git patch or evidence of gateway admission.

## Pinned source and the two different projections

CPA reference: `router-for-me/CLIProxyAPI`
`acdace936fa7df2905500c7f5e0a97d683138dea`. The following public files were fetched
read-only and their **full-file SHA-256** verified in this implementation pass:

| File | SHA-256 |
| --- | --- |
| `internal/util/codex.go` | `9986e4b36056366ad7db83d5cc2f004c0d284b326b50dfd2e7b4b1b6d535cecc` |
| `internal/runtime/executor/codex_executor_request.go` | `dd6638b57396c82070b64c53e9f9867d89567ed1cb11db66cb8d7c089ebc6c4e` |
| `internal/runtime/executor/codex_executor_execute.go` | `44c07b9ea934c917fe48e7448109682559c8aacb397c4ae9740583404ed2ef2d` |
| `internal/runtime/executor/codex_executor_stream.go` | `94cde12304dc85f056ce2bdae316e7c2f82a88900c31bb48419274bc51e4e6c2` |
| `internal/runtime/executor/codex_native_fidelity_test.go` | `5599b79aa51038c4b5f53054124510b9a31de9aedd01f144a9fcf5fe138288cc` |
| `internal/registry/models/codex_client_models.json` | `7b15fec55ed279c2a0f4b6dfd1f7d2617d7c9f22e94d385242a8cd9534411d38` |
| `sdk/api/handlers/openai/openai_responses_handlers.go` | `44425e6550b54e39a5305441be7037bd32d78126926b2a317bca6a9aca86144d` |

Source behavior, not executed CPA results:

- [Marker grammar](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/util/codex.go#L10-L16):
  HTTP header `X-OpenAI-Internal-Codex-Responses-Lite` with trimmed,
  case-insensitive string `"true"`; or **exact body location**
  `client_metadata.ws_request_header_x_openai_internal_codex_responses_lite`
  with JSON boolean `true` or trimmed, case-insensitive string `"true"`.
  A similarly named top-level field, arbitrary numeric truthiness, event metadata
  header, model-name prefix, or `Session-Id` is not this selector.
- [Native fixture/classification](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/codex_native_fidelity_test.go#L25-L137):
  source format Codex/OpenAIResponse plus an explicit lite selector is native.
  Its request is `gpt-5.6-sol`, `input:[]`, `parallel_tool_calls:false`.
  All executor combinations use `Stream:true`; bootstrap buffering is not
  nonstreaming HTTP. The fixture's three event-data strings are reused verbatim
  from F11 and independently hash-checked by the CLI harness.
- [Native executor guard](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/codex_executor_stream.go#L248-L266):
  native executor streaming is transparent; compatibility execution hydrates.
- [Public HTTP handler](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/sdk/api/handlers/openai/openai_responses_handlers.go#L203-L211)
  and [its hydration helper](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/sdk/api/handlers/openai/openai_responses_handlers.go#L320-L379)
  hydrate absent/empty completed.output even for Codex clients.
- [Nonstream Execute](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/codex_executor_execute.go#L160-L199)
  collects item.done and hydrates at line 188 without a native guard.
- [Request rules](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/codex_executor_request.go#L460-L549):
  native instructions are not injected; lite suppresses automatic image-generation
  injection and forces parallel_tool_calls false. F12 retains existing explicit
  image-generation/audio/file rejection; it does not implement unsupported media.

Accordingly, `response.executor_policy(plan)` is `Transparent`, while
`response.http_policy(plan)` is `HydrateCompleted` for public SSE **and**
buffered JSON. Both are F11 policies, not provider-owned repair codecs.
F11's documented conservative bounds/contradiction rules still apply.
CPA's private-event filtering, cloak/identity aliases and error rewriting are
separate behavior and are not inferred from these source fixtures.

The nine entries in `models.pinned()` were checked against the source catalog
for exact reasoning effort/default, context, modalities, lite/parallel/WS flags
and visibility. This is a deliberately small metadata subset, not live discovery
or a complete clone of that 535909-byte catalog.

## Trusted policy versus untrusted request intent

`adapter.classify_http(request, headers)` validates marker syntax and returns
internal operation `responses/lite` on the ordinary Responses route. It neither
authenticates a client nor enables a model.

- Singleton header; duplicates, malformed strings, wrong metadata types,
  ambiguous JSON keys and lite+compact fail explicitly. Boolean/string `false`
  disables a marker. This is intentionally stricter than CPA's false fallback.
- `adapter.prepare_native` looks up the **selected configured catalog** entry
  after selected-account context is available. Lite on `responses_lite:false`
  or a missing entry is `Unsupported/NotSent`, before provider I/O.
- Merely advertising `responses_lite:true` does not force a normal request into
  lite mode. No caller marker alone selects a sparse decoder.
- Low-level `request.prepare` and all preexisting strict collector constructors
  remain strict. Its new `Prepared.response_mode` is qualified only by the
  selected HTTP adapter; a raw Lite intent has no sparse policy authority.
- `adapter.registration` advertises `responses/lite` only for catalog-flagged
  models. `models.available_http` intersects configured Codex model IDs and
  masks WS preference for lite entries until F13. Ordinary models still require
  the existing WS opt-in; generic `models.available` stays unchanged.

Native aliases `/responses` and `/backend-api/codex/responses` must select
**Codex only**, not wildcard Kimi/xAI Responses dispatch. There is no
`/responses/lite` endpoint. Compact aliases remain a distinct JSON path.
Native `/models` and `/backend-api/codex/models` expose only configured Codex
metadata. `/v1/models` remains generic discovery.

## Compiled HTTP consumer contract

```gleam
// mimic/providers/codex/adapter
classify_http(contracts.Request, List(Header)) -> Result(contracts.Request, String)

// mimic/providers/codex/response
http_policy(request.Prepared) -> stream.Policy
executor_policy(request.Prepared) -> stream.Policy
consume_http(runtime.Response, request.Prepared) -> Result(Delivery, contracts.Failure)
forward_http(runtime.Response, request.Prepared,
  fn(stream.WireEvent) -> Result(http.Control, String))
  -> Result(Delivery, contracts.Failure)
delivery_body(Delivery) -> Result(String, String)
delivery_completion(Delivery) -> Option(Completion)
delivery_report(Delivery) -> Option(sparse.Report)
delivery_outcome(Delivery) -> stream.Outcome

// mimic/providers/codex/http: private cached gateway composition
http_policy(Opened) -> stream.Policy
consume_http(Opened) -> Result(response.Delivery, contracts.Failure)
forward_http(Opened, fn(stream.WireEvent) -> Result(pump.Control, String))
  -> Result(response.Delivery, contracts.Failure)
```

`Delivery` is opaque and created only after `http.run_wire_fold` returns
successfully at clean transport EOF. Limits: 8 MiB observation data, 32768 events;
F11 default frame/item/part bounds remain intact.

The streamed event accumulator never constructs a sparse receipt or invokes
strict `terminal_response` on sparse documents. It retains only the projected
wire terminal, and checks supplied response model against the selected request
before emitting that event. Errors preserve the already validated prefix.

`delivery_body` returns projected wire JSON. It does **not** serialize F11's
reconstructed document, which may contain protocol-derived object/status values.
Only `ContinuationEligible` from the fold's final report enters existing complete
history/tool-pairing/bounds checks. `Reconstructed` alone, `MissingCreated`, unknown
empty output, id-less/open items, unknown native types and noncompleted outcomes
are successful deliveries where appropriate, **without a receipt**.
Neither projection supplies missing usage, ids, output/history or signatures.

Cached publication occurs only from `delivery_completion`, after that clean-EOF
consumer return. Cancel, protocol/transport/downstream failure or trailing
corruption returns no Delivery/receipt, even after Completed was emitted.
All post-open failures remain `Started`; upstream reason/retry metadata is retained.
No uncertain-send replay or stateless fallback is introduced.

HTTP continuation stays default-off. Existing private cache scopes still bind
tenant, stable authenticated session, selected account, authoritative credential
revision, model, origin, protocol and operation. Classification runs before
locate/scope selection, so header and body lite selectors share the same operation
fence. Unsupported/missing/cross-scope prior IDs reject; they are never silently
dropped. Restart loses all receipts; revocation/same-value reenrollment makes old
revision receipts inaccessible. No WS receipt is accepted as HTTP history.

## Parent admission and real gateway harness

Apply `F12_ROOT.patch` in the parent's serialized root lane. Its preflight uses
the **same plan-qualified policy as the real consumer**, not a discarded strict
stream. Both stateless and opt-in cached forwarding encode `WireEvent` with
`encode_wire_event`. Sparse buffered delivery uses `delivery_body`, never the
strict reconstructed Completion document.

`scripts/smoke-codex-http-lite.py` supplies real loopback upstream sockets and
fresh root CLI processes; it supports source and exported Erlang shipment:

```sh
ERL_FLAGS='+S 2:2 +A 2' mise exec gleam@1.18.1 -- \
  python3 scripts/smoke-codex-http-lite.py
ERL_FLAGS='+S 2:2 +A 2' mise exec gleam@1.18.1 -- \
  python3 scripts/smoke-codex-http-lite.py --shipment <export-directory>
```

It checks native aliases, configured catalog filtering, boolean/header/metadata
selectors, adapted pinned request/event vectors, native tools/image preservation,
SSE/JSON hydration, missing-created/empty/idless/open/extension and failed/error
no-receipt cases, model/id mismatch and trailing valid-prefix errors.
An actual chunked upstream **holds EOF after downstream Completed**; continuation
must reject before release and work afterward. Scope/operation/client isolation,
available-backup account revocation, same-value credential revision, cancellation,
default-off/headerless paths, restart and ingress-key revocation are checked.
A configured credentialed Kimi negative account proves native Codex aliases never
fall through to another provider. Strict and compact checks are regressions only,
not counted as native-lite acceptance.

## Verification and explicit unverified gates

Toolchain: Gleam 1.18.1 via mise; `ERL_FLAGS='+S 2:2 +A 2'`.

- Build and scoped formatting/check passed.
- **149/149 focused EUnit tests passed:** 11 new F12 tests plus existing Codex
  request/response/adapter/catalog/HTTP continuation/streaming/helper and
  Responses strict/S6/HTTP/fold/F11 tests. The new real runtime positives are
  distinct from legacy strict full-document tests.
- CLI harness syntax and **3/3** exact pinned synthetic event-data hashes passed.
  Its 12 synthetic event-sequence shapes also passed shared-codec preflight;
  that is not a root workflow or CPA execution.
- All 13 root artifact hunks matched current source **in memory only**.
  Owned-file diff whitespace check passed; root files were not changed.
- Actual **configured root source/shipment harness was not run in this worker**;
  the parent applies the root artifact and runs it after module delivery.
- Full/heavy `gleam test`, full integration, CPA executor execution (including its
  48 combinations), differential pairing, installed native clients, WS/WSS/F13,
  remote TLS qualification, live providers and ambient credentials were not used.

Focused reproduction:

```sh
ERL_FLAGS='+S 2:2 +A 2' mise exec gleam@1.18.1 -- \
  gleam run -m codex_http_lite_test
```

The broader focused gate used the same toolchain with:

```sh
ERL_FLAGS='+S 2:2 +A 2' mise exec gleam@1.18.1 -- gleam build
ERL_FLAGS='+S 2:2 +A 2' mise exec gleam@1.18.1 -- erl -noshell \
  -pa build/dev/erlang/*/ebin \
  -eval 'case eunit:test([codex_http_lite_test,codex_request_test,codex_response_test,codex_adapter_test,codex_models_errors_test,codex_http_continuation_test,codex_http_runtime_test,codex_lite_test,codex_streaming_test,gateway_codex_http_test,responses_protocol_test,responses_http_test,responses_fold_test,responses_tool_identity_test,responses_sparse_test], [verbose, {scale_timeouts, 10}]) of ok -> halt(0); _ -> halt(1) end.'
```

Development failures were corrected, not counted as passing: two initial test
branch return-type errors; then the broader gate exposed a local lite scenario
whose newly qualified request model differed from its old `gpt-5.5` response
fixture (148 passed/one failed). The fixture now consistently uses the selected
source-flagged model. The model fence was not relaxed; final 149/149 passed.

Earlier historical `codex-http-continuation.md` describes the pre-F11 sparse gap
and old mode-only support. This document supersedes those sparse-admission claims;
its historical test counts are not F12 evidence.
