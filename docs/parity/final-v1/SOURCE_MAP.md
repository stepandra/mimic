# FINAL-v1 pinned route, auth and mode inventory

**Offline source review, not measured runtime parity.** All 37 historical rows
remain required. Their 22 historical pending markers remain unchanged;
14 are now bounded-mapped, 8 retain stronger unresolved proof/scope obligations.
There are 9 partial rows overall, including historically reviewed `codex-ws`.
Historical strict conformance remains **0/37**.

The [executable catalog](contract.json#L30) contains **118 exact excerpts from
54 public files** at CPA `acdace936fa7df2905500c7f5e0a97d683138dea`. Each entry
has a symbol, inclusive lines, full-file SHA256, verbatim UTF-8/LF quote and
quote SHA256. All were checked here against the actual hash-pinned archive,
including all 98 excerpts recovered from the corrected foundation packet.

`M` below means bounded source mapping, **not** approved complete applicability
or runtime success. `P` means an explicit source or scope gap. Every primary
case is `<row ID>.final-v1`, version 1; complete requests, variants, scenario
parameters, errors and assertions are in `cases`. Case plans retain *all*
historical checks, even when a source fact contradicts a stronger expectation.

## Historical inventory — none removed

Source names refer to keys in `contract.sources`, not mutable branch URLs.
Provider auth is distinct from local client-key authentication.

| Row | Selected provider auth/backend | Client route | Pinned source / case focus | Mapping |
| --- | --- | --- | --- | --- |
| `claude-models` | API key / Messages | GET `/v1/models` | `routes`; scoped discovery | M |
| `claude-messages` | API key / Messages | POST `/v1/messages` | `claude-url`, `native-fallback`; beta query, body/cache/auth | M; historical fixture blocker |
| `claude-chat` | API key / Messages | POST `/v1/chat/completions` | `claude-translation`; buffered Chat uses upstream SSE | M; historical fixture blocker |
| `claude-count` | API key / Messages | POST `/v1/messages/count_tokens` | `claude-count`; native count, distinct endpoint | M |
| `claude-oauth` | OAuth / Messages | POST `/v1/messages` | `claude-refresh`, `refresh-lock-full`, `expired-auth-selector` | P |
| `claude-tools` | API key / Messages | POST `/v1/messages` | `claude-tools`, `native-fallback`; correlated call/result | M |
| `claude-thinking` | OAuth / Messages | POST `/v1/messages` | `claude-replay-scope`; explicit history vs API-key auto replay | P |
| `claude-image` | API key / Messages | POST `/v1/messages` | `claude-image`, `native-fallback`; inline image/MIME | M |
| `claude-reject-media` | API key / Messages | POST `/v1/messages` | `claude-ingress`, `claude-content`; native pre-I/O rejection unproved | P |
| `codex-http` | OAuth / Codex | POST `/v1/responses` | `codex-http`, `codex-nonstream-hydration`; buffered upstream SSE | M |
| `codex-sse` | OAuth / Codex | POST `/v1/responses`, SSE | Executor-only fidelity vs downstream `codex-sse-completed` | P; transparent product difference |
| `codex-compact` | OAuth / Codex | POST `/v1/responses/compact` | `codex-compact`; compact nonstream/error scope | M |
| `codex-ws` | OAuth / Codex | GET `/v1/responses`, WS | `codex-ws-selector`, `codex-ws-forward`; selected auth + lite | P |
| `codex-alias` | OAuth / direct Codex alias | POST `/backend-api/codex/responses` | `aliases`; actual alias route | M |
| `codex-lifecycle` | OAuth / Codex | POST `/v1/responses`, SSE + separate WS probes | `codex-terminal`, `codex-cancel`, `failover`; EOF/cancel | M |
| `codex-isolation` | OAuth / Codex | GET `/v1/responses`, WS | `codex-scope`; auth/origin/proxy only, stronger scope unproved | P |
| `codex-quota` | OAuth / Codex | POST `/v1/responses` | `codex-quota`, `cooldown`; reset units and boundaries | M |
| `kimi-generic` | API key / named OpenAI-compatible | POST `/v1/chat/completions` | `generic-identity`, `generic-auth`; not native Kimi | M |
| `kimi-native` | OAuth / native Kimi | POST `/v1/responses` | `kimi-responses`, `kimi-urls`, `kimi-creds`, `kimi-normalize` | M |
| `xai-api` | API key / xAI API | POST `/v1/chat/completions` | `xai-backend`, `xai-auth-kind`; Chat translation to Responses | M |
| `xai-oauth` | OAuth / Grok Build | POST `/v1/responses` | `xai-backend`, `xai-previous`; origin/proxy, previous ID deleted | M |
| `runtime-persistence` | Synthetic credentials / mock | POST `/v1/messages` | `file-save`, `file-list`; two independent processes, no reseed | M |
| `devin-auth-pkce` | Permanent session token / Connect | POST Chat after acquisition | `devin-pkce`, `devin-permanent`; code/verifier then restart | M |
| `devin-auth-import` | Permanent session token / Connect | POST Messages after import | `devin-record`, `devin-permanent`; prefix once, no exchange | M |
| `devin-chat-http` | Permanent session token / Connect | POST `/v1/chat/completions` | `devin-basic`, `devin-rpc`; Basic token-token and protobuf | M |
| `devin-messages-http` | Permanent session token / Connect | POST `/v1/messages` | `devin-rpc`; protocol-specific mapping, not REST echo | M |
| `devin-responses-http` | Permanent session token / Connect | POST `/v1/responses` | Binary frame/EOS and buffered translation | M |
| `devin-responses-sse` | Permanent session token / Connect | POST `/v1/responses`, SSE | `devin-stream`, `devin-frame`; segmentation, EOS terminal | M |
| `devin-tools` | Permanent session token / Connect | POST `/v1/responses` | `devin-tools`; correlated result, separate orphan loss | M |
| `devin-thinking` | Permanent session token / Connect | POST `/v1/messages` | `devin-signature`, `devin-uid`; opaque bytes/type/replay | M |
| `devin-multimodal` | Permanent session token / Connect | POST `/v1/messages` | `devin-image-full`, `devin-omit-full`; strict difference | P |
| `devin-models` | Permanent session token / Connect | GET `/v1/models` | `devin-catalog`, `local-model-plan`, `devin-embedded-catalog` | P |
| `devin-count-estimate` | Permanent session token / Connect | POST `/v1/messages/count_tokens` | `devin-count`; floor(request payload byte length / 4), no count RPC | M |
| `devin-stream-lifecycle` | Permanent session token / Connect | POST `/v1/responses`, SSE | `devin-stream`, `devin-frame`, `devin-eos`; trailer/partial EOF/cancel | M |
| `devin-persisted-isolation` | Permanent session token / Connect | POST `/v1/chat/completions` | `devin-session-full`, `devin-record`, `file-save`; stronger account binding unproved | P |
| `devin-status-quota` | Permanent session token / Connect | POST Chat after status | `devin-status`; status enrichment, no token rotation | M |
| `devin-429-failover` | Permanent session token / Connect | POST `/v1/chat/completions` | `devin-retry`, `cooldown`, `failover`; seconds/date, isolation | M |

## Actual source findings, not lent transport capabilities

The [operation inventory](contract.json#L367) adds 25 versioned findings,
**not 25 admitted matrix rows**. `source_presence`, `applicability`,
`observation_boundary` and `runtime_proof` are independent.

### Codex HTTP / lite / WS

- [Executor source test](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/codex_native_fidelity_test.go#L31-L138):
  48 combinations, 16 native-lite / 32 compatibility. These are **source test
  cases, not executions here**. Invocation uses `Stream: true`, output format
  Codex. HTTP/WS in that matrix is **upstream** transport.
- Sparse events are metadata, `output_item.done`, then completed with `output: []`
  and unknown future fields; no created/added event. Native executor mode preserves
  exact terminal/metadata JSON. Compatibility hydration is a different projection.
- [HTTP SSE framer](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/sdk/api/handlers/openai/openai_responses_handlers.go#L320-L380)
  unconditionally backfills empty terminal output from done items, including Codex.
  Its private metadata selector uses Codex User-Agent/Originator, **not** the
  executor lite predicate. Source tests verify the framer/forwarder, not the
  entire configured auth/router/plugin/executor chain.
- [Downstream WS selector](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/sdk/api/handlers/openai/openai_responses_websocket.go#L683-L758)
  requires lite **and selected auth provider Codex**, resetting/recomputing the
  decision in selection callbacks. Its [forwarder](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/sdk/api/handlers/openai/openai_responses_websocket_forward.go#L153-L190)
  restores internal completed output independently of client wire preservation.
  Selected-auth websocket enablement also controls actual upstream transport.
- [Nonstream Execute](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/codex_executor_execute.go#L160-L199)
  unconditionally patches completed output before nonstream translation.
  Supplied-terminal-only buffered native behavior remains a proposed product
  extension, not historical CPA passthrough.
- Raw transparency, reconstructed output, HTTP receipts and WS cursor/history
  authority are separate. All authority qualifications remain `not_run`.

The validator prevents the operation inventory from disagreeing with the
validated primary Codex boundary or moving executor assertions to ingress.

### Kimi and xAI/Grok

- Native Messages SSE dispatches to Kimi's embedded Claude executor; generic
  Chat uses the explicitly named generic executor with API-key auth. Those are
  separate source paths, not aliases. Native Responses SSE separately dispatches
  to `executeResponsesStream`, not the Messages or generic Chat path.
- [Native Kimi compact](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/kimi_executor.go#L394-L397)
  rejects buffered requests with **501**; [streaming compact](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/kimi_executor.go#L505-L508)
  separately has an executor **400** guard. The actual [HTTP Compact handler](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/sdk/api/handlers/openai/openai_responses_handlers.go#L625-L645)
  rejects `stream: true` **before executor dispatch**, with 400 JSON
  `invalid_request_error` and `Streaming not supported for compact responses`.
  The different executor message is not a downstream SSE response. These are
  sourced expectations, not paired observations.
- [Ordinary xAI HTTP](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/xai_executor_request.go#L83-L91)
  deletes `previous_response_id`. [Compact](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/xai_executor_execute.go#L164-L180)
  separately restores it and uses standard API, not CLI proxy headers. WS or
  compact cannot qualify ordinary HTTP continuation.
- [Core routes](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/api/server_routes.go#L62-L116)
  include image generate/edit, native video create/generate/edit/extend/status,
  and separate `/openai/v1/videos/:video_id/content`. Media presence is not
  approved account/model/form applicability or binary transport qualification.
- [Image SSE](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/sdk/api/handlers/openai/openai_images_handlers.go#L1515-L1528)
  wraps buffered image execution with downstream keepalive/events; no upstream
  progressive-image capability follows.
- No DELETE/cancel video action is registered in those audited core routes.
  A `cancelled` job status is not a cancel action. Plugins/future source are not
  qualified by this absence finding. Do not invent successful cancellation.
- [xAI auto-executor](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/xai_websockets_executor.go#L1735-L1755)
  selects physical upstream WS only for downstream WS and selected-auth WS
  enablement. Required upstream WS cannot fall back silently to HTTP; nonstream
  requests remain HTTP. Full actual upgrade/close/session/config proof remains
  `grok-ws-chain-source`, not a loan from Codex lite selectors.
- [Tool normalization](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/xai_executor_request.go#L94-L128)
  collects namespace/declared-kind refs before normalization, normalizes
  custom/namespace input and prunes choices. Approved model/forced-tool/custom/
  namespace and response-restoration vectors remain
  `grok-tool-form-applicability`; source function presence is not round-trip proof.

### Remaining stronger obligations — not relabeled mapped

| Row(s) / blocker | Verified narrower fact | Still missing |
| --- | --- | --- |
| `claude-oauth` / `expiry-singleflight-applicability` | Expired known access tokens are blocked by `isAuthBlockedForModel`; per-auth lock/reuse is conditional on a replaced failed access token | One exchange/shared success or failure for eight **expiry-triggered** waiters; background refresh and serialized 401 recovery do not establish that |
| `claude-thinking` / `oauth-replay-applicability` | Automatic replay helper requires API-key-compatible auth, not OAuth | Explicit client-supplied history vs automatic reconstruction scope, complete OAuth request/response preservation proof |
| `claude-reject-media` / `native-media-rejection-applicability` | Native ingress/fallback and translated omission paths are sourced | Native 4xx + zero upstream sends for both historical malformed/unknown forms |
| `codex-sse`, `codex-ws` / `codex-full-chain-source` | Handler, routing, selection, after-auth rewrite, auto-executor dispatch, interceptors and forwarder source anchors are retained | Full effective configured chain/selection proof, not isolated framer/executor tests; HTTP transparent-terminal product difference also blocks |
| `codex-isolation` / `full-client-account-isolation` | Upstream auth/origin/proxy connection match | Full client/tenant/account/session separation, revocation and independent-process restoration |
| `devin-multimodal` / `intentional-media-difference` | Inline image/base64 string/MIME extraction; unsupported remote/audio parts without text are omitted; base64 content is not decoded/validated by this extractor | Strict loss/rejection applicability remains a blocking difference; no omission/rejection equivalence or waiver |
| `devin-models` / `catalog-background-policy` | `--local-model` disables all three catalog updaters; registry init loads the embedded Devin catalog | Exact approved fixture injection/provenance and actual startup/executable identity; Antigravity updater is still unconditional |
| `devin-persisted-isolation` / `full-client-account-isolation` | Permanent-token persistence and deterministic session/cascade UUID mapping | Effective account binding, same-label isolation, revocation/restart; UUID equality alone neither proves nor disproves upstream account isolation |

Historical HTTP Messages/Chat retain their separate fixture blocker: beta-query,
configured endpoint auth/cache/body differences and translated Chat's upstream SSE
cannot be erased by replacing the old fixtures.

## Authentication and operational evidence limits

Configured local client keys accept Bearer, x-goog-api-key, x-api-key, `key`
and `auth_token` candidates. Missing/invalid keys produce 401
`{"error": "Missing API key"}` / `{"error": "Invalid API key"}` with zero
provider sends in the specified configured-key probes. Provider OAuth grants
are a different credential dimension; no operator credential was read.

`--local-model` is **not** an all-network-off switch. Normal server startup
still unconditionally starts the Antigravity updater. Actual CPA identity,
updater/descendant containment, remote TLS/ALPN, approved media bindings,
native workflows and live/provider execution remain unverified. The existing
`8317` service was never contacted or changed by F01.
