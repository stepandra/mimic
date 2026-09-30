# Devin source contract — CPA pin, not measured parity

> Historical first-slice notes. Current behavior and deliberate differences are
> in [EXPANSION.md](EXPANSION.md); immutable inputs are in `CPA_SHA256SUMS`.
> One-shot-only statements below describe v1, retained as provenance.

CPA revision: `acdace936fa7df2905500c7f5e0a97d683138dea`.
MIMIC base: `c3ca7e805b8e4c3f8271468fbbe46271a5b0e8f4`.

Only Devin provider compatibility is in this stream. Gemini, Antigravity and
Copilot integration are excluded. Claude Code, Codex, Kimi and xAI are owned by
other streams. A model served through Devin does not imply integration of that
model vendor's provider.

## Evidence boundary

The sources below were read at the pin. Upstream comments claiming native
captures/live probes are **not MIMIC measurements**. Upstream tests were read,
not run. Synthetic tests in this stream do not satisfy CPA differential or live
gates. No account, browser login, real token, provider call or code upload was
used. The implementation is an intentionally narrow, local-only vertical slice,
not full Devin parity.

All links below are relative to this immutable source tree:
https://github.com/router-for-me/CLIProxyAPI/tree/acdace936fa7df2905500c7f5e0a97d683138dea

## Authentication and identity

| Pinned source / symbol | Contract |
|---|---|
| `sdk/auth/devin.go`, `DevinAuthenticator.Login`, `parseDevinManualPaste` | Browser loopback callback PKCE, headless manual authorization code/callback URL, or pasted session token. Callback state is validated by authenticator. |
| `internal/auth/devin/pkce.go`, `GeneratePKCECodes` | 64 random bytes -> unpadded base64url verifier; SHA256(verifier) -> unpadded base64url challenge. |
| `internal/auth/devin/devin_auth.go`, `BuildAuthorizationURL` | `https://app.devin.ai/auth/cli/continue`; ordered redirect_uri (if any), state (if any), prompt=select_account, code_challenge, code_challenge_method=S256; headless cli_pkce_marker=1. |
| same, `ExchangeCodeForToken` | POST `https://api.devin.ai/auth/cli/token`, JSON `{code,code_verifier}`, JSON `token` result. |
| same, `FormatSessionToken` | Trim; preserve prefixed token; prefix `eyJ...` with `devin-session-token$`; leave other opaque tokens unchanged. This is not JWT verification. |
| same, `FetchSelfProfile` | GET `https://api.devin.ai/v3/self`, Bearer session token; optional user_name/user_id/org_id. |
| `internal/auth/devin/record.go`, `CreateAuthRecord` | Records provider=devin/auth_kind=oauth; api_key and session_token contain the same permanent token. Profile/quota enrichment is best effort. |
| `sdk/auth/devin.go`, `RefreshLead` | Returns nil: permanent session token, no token expiry/refresh-token rotation contract. |
| `internal/runtime/executor/devin_executor.go`, `Refresh` | FetchUserStatus updates user/organization/plan/quota observations, not authentication rotation. |

The executor's `devinAuthCredentials` reads attribute api_key, then
session_token, then token; metadata api_key/session_token follows. Base URL and
optional device_seed are configuration, not arbitrary client request fields.
These aliases do **not** establish a second public Devin API-key auth mode.
MIMIC uses runtime `SessionToken` / `StaticSession`, never dummy OAuth expiry.
Do not store this material in captures, grounding packs, model lists or logs.
It appears in both Authorization **and the binary request body**.

## Actual provider protocol

This is Codeium/Cognition reasoning Connect-RPC, **not** Devin session
creation/polling REST (`/v1/sessions`, etc.). Those APIs are out of scope.

`devin_executor.go::RequestToFormat` selects CPA's interactions intermediate
format. `prepareDevinHTTPRequest` translates into it, resolves model UID,
system/prompts/tools/generation settings/session/cascade, constructs protobuf,
wraps one Connect frame, then performs a complete POST:

`https://server.codeium.com/exa.api_server_pb.ApiServerService/GetChatMessage`

`PrepareRequest` adds:

- `Authorization: Basic <token>-<token>` (literal, **not** base64 Basic auth).
- `Content-Type: application/connect+proto`.
- `Connect-Protocol-Version: 1`, `Accept: */*`.
- Chat-only `Sentry-Trace: <32 hex>-<16 hex>-1`.
- No User-Agent; no implicit gzip advertising in the standard helper.

`helps/proxy_helpers.go::NewDevinHTTPClient` clones standard `http.Transport`,
sets DisableCompression, and permits configured/injected transports. There is
no explicit HTTP/2-only or duplex requirement in this helper. This source fact
is **not executed proof of production H1 compatibility**. Per coordinator
decision, v3 and this bridge permit binary HTTP/1 only on loopback; remote
binary execution and HTTP/2 remain unsupported.

## Wire layout and lifecycle

`helps/devin_wire.go::BuildDevinClientMetadataBytes`:

- Metadata fields 1/12=`chisel`; 2/7=`3000.10.21`; 3=token; 4=`en`; 5=OS.
- Field 31 is 732 lowercase hex characters. Empty device seed uses fresh random
  366 bytes; configured seed uses concatenated SHA256(seed-counter) blocks.

`BuildDevinGetChatMessageRequest`:

- 1=metadata, 2=sanitized system, repeated 3=history prompts.
- Prompt fields: 1=message UUID, 2=source (user1/assistant2/tool4), 3=text;
  6=tool calls, 7=tool result ID, 10=inline images, 11=thinking,
  12=signature bytes, 18=signature type.
- 7=5; 8=completion config (enabled1, max tokens default128000, 400,
  temperature default1.0, 40, float64(float32(0.95))).
- 10=tool definitions; 15=session UUID + nonzero turn ordinal + source4 +
  conditional user boundary14; 16=cascade/cache UUID; 20=1; 21=model UID.
- CPA has a bounded process-local session turn counter and deterministic UUIDv5
  mapping for non-UUID session names. MIMIC's first slice uses a fresh one-shot
  UUID and ordinal0 only; it does not claim session continuation/cache parity.

Connect envelopes are flag byte + 4-byte big-endian length + payload. CPA accepts
flags0(data),1(gzip data),2(JSON trailer),3(gzip trailer), 16MiB frame and 64MiB
decompressed bounds. MIMIC accepts only0/2 with an8MiB bound and explicitly
rejects compression. Raw protobuf never goes through shared `Capture.body`.

Response fields parsed by CPA `ParseDevinFrame`: 1=output ID, 2=timestamp,
3=text bytes,4=delta tokens,5=stop reason (2/4 stop,10 tool calls),
6=tool-call deltas,7=usage,9=thinking,10=signature,12=latency,17=message ID,
21=signature type,28=response dimension groups. UTF-8 can span frames.
Usage includes input/output/cache-write/cache-read/status/request ID/model.

Both Execute and ExecuteStream consume the same upstream frame stream;
non-streaming aggregates to interactions, streaming emits interactions events
then translates to the requested client protocol. Tool IDs/names/arguments
are accumulated and finalized; terminal state is not just an HTTP EOF.
MIMIC deliberately rejects unknown semantic fields, incomplete UTF-8, missing
terminal, malformed protobuf/trailer and data after terminal rather than
silently losing fidelity. It does not reproduce all permissive CPA parser paths.

## Models, tools, modalities and errors

- `sdk/cliproxy/service_auth.go` registers DevinAuthenticator;
  `service_executors.go` registers NewDevinExecutor; `service_models.go` uses
  registry.GetDevinModels. This is an actual runtime provider registration.
- `internal/registry/devin_models.go`, embedded `models/devin_models.json`,
  `devin_models_updater.go`: Devin catalog, devin/ namespace, effort aggregation,
  fallback/updates. `helps/devin_models.go::ResolveDevinChatModelUID` resolves
  effort suffixes, aliases, budgets and catalog-supported levels. MIMIC's sole
  explicit model `devin/swe-1-7` maps to `swe-1-7` (source's bare default);
  its pinned catalog maximum is64000 and overrides the generic128000 wire
  default. No implicit catalog discovery or guessed alias support.
- `cmd/fetch_devin_models/main.go`: POST GetCliModelConfigs on ApiServerService;
  `application/proto`, literal Basic token-token, unframed protobuf. Not chat.
- `internal/auth/devin/user_status.go::FetchUserStatus`: POST
  `/exa.seat_management_pb.SeatManagementService/GetUserStatus`,
  `application/proto`; same Basic auth, no Sentry/User-Agent. Parses
  identity/org/plan/daily+weekly quota percentages and reset times.
- `devin_executor.go::parseInteractionsPayload`, `helps/devin_wire.go`,
  `internal/translator/common/devin_tools.go`: tools include CPA-specific
  normalization/filtering, orphan tool handling, custom calls and call/results.
  This stream does not advertise tools until those transformations are covered.
- `extractDevinImage` accepts image/input_image/image_url with direct data,
  source.data, base64 data URLs or inline_data. Plain remote image URLs are not
  fetched. `extractInteractionsStepContent` falls back to p.text; unsupported
  image/audio without text can be silently ignored by CPA. **Do not claim CPA
  explicitly rejects them.** MIMIC rejects all images/audio in this slice.
- `CountTokens` is `len(req.Payload)/4` bytes, returning total_tokens/input_tokens;
  no upstream tokenizer. `auth.estimated_tokens` is labeled an estimate.
- `newDevinStatusError` propagates HTTP status; HTTP429 reads numeric or HTTP-date
  Retry-After. Current bridge handles bounded numeric delays only.
- `ParseDevinTrailerError`: invalid_argument400 (internal-error message502),
  internal502, unauthenticated401, permission_denied403 (high demand429),
  resource_exhausted429, unavailable503, canceled499, deadline_exceeded504,
  failed_precondition400 (quota/credit/acu/exhausted/limit429), fallback502.
  This stream exposes fixed safe diagnostics, never provider message text.
  Trailer errors are after Started and never cause runtime replay.

## Tests inspected, not executed

`internal/auth/devin/{devin_auth,record,user_status}_test.go`,
`sdk/auth/devin_test.go`, `internal/runtime/executor/devin_executor_test.go`,
`helps/{devin_wire,devin_models}_test.go`,
`internal/registry/devin_models_test.go` and
`internal/translator/common/devin_tools_test.go`.

They establish source intent (header absence, metadata tags, framing, tools,
thinking/signatures, models, quota, Retry-After and auth cancellation).
The executable conformance owner requires15 Devin rows: auth-pkce, auth-import,
chat-http, messages-http, responses-http, responses-sse, tools, thinking,
multimodal, models, count-estimate, stream-lifecycle, persisted-isolation,
status-quota, 429-failover. None is released by source review or runtime-adapter
tests alone; mandatory assembled_ingress remains false here. Responses
HTTP/SSE, compact and WebSocket are separate; this stream registers none.
