# Devin native expansion — checkpoint and integration contract

## Evidence states

Published MIMIC base: `3e00808ff0fefbb6728edb1769c17139ef0fd93a`, fetched from
`https://github.com/stepandra/mimic.git` with `jj git fetch --remote origin`.
The attached worktree was clean and stale; `jj new <exact-base> -m ...` was used.
No primary/sibling checkout edits, Git mutations, commits, pushes, publication
or automatic integration are authorized by this handoff.

CPA pin: `acdace936fa7df2905500c7f5e0a97d683138dea` from
`https://github.com/router-for-me/CLIProxyAPI`.
`CPA_SHA256SUMS` identifies the actual pinned source inputs, including tests.
Source reading is not CPA differential execution or live provider evidence.

| State | Gate |
|---|---|
| Implemented / locally tested | Native history/request/response codec; runtime-backed event pulls; private enrollment/status hooks; pure scoped continuation state |
| Client buffered | Chat / Anthropic via shared codecs, with explicit semantic projection rejection |
| Client streaming | **Blocked**: native event API works; shared client encoder/route qualification required |
| Responses | **Blocked**: shared Responses IR conversion is unsupported on this base |
| Native continuation in gateway | **Blocked**: shared session owner must serialize/persist advances and wire the pure hooks |
| Differential verified | **No**; CPA lab driver execution not run here |
| Remote enabled | **No**; numeric-loopback binary gate remains |
| Live qualified / authentic native client | **No**; no authorized upstream/account/client workflow |

No Gemini, Antigravity or Copilot provider work is included. No browser/home/env
credentials were searched. All executable observations use known synthetic
fixture tokens. The complete HTTP binary plan is secret, not just its headers:
the token also appears in protobuf metadata. Base64 is not redaction.

## Typed integration hooks

Feature code is under `src/mimic/providers/devin/`.

- `models.Model(id, uid, max_tokens, images)` / `validate` / `resolve`:
  explicit IDs and exact native UIDs. Default pinned mapping:
  `devin/swe-1-7` -> `swe-1-7`, max 64000. No inferred aliases, discovery,
  claimed account access, or implicit reasoning-effort mapping.
- `bridge.configured_models(configured)` and `configured_adapter(ca, configured)`:
  supply the same mapping to registry and adapter. Registry: `devin`,
  `session_token`, `generate`, protocols `openai-chat` / `anthropic-messages`,
  capabilities `Buffer`, `Tools`, plus configured `Images`. No default `Stream`,
  `Continuation`, `Audio`, WebSocket or Responses capability.
- `bridge.execute_configured(runtime, ca, request, configured)` uses shared
  runtime, neutral binary transport and shared buffered codecs. Mode and body
  `stream` must agree. Unknown capabilities, continuation pins and remote
  origins fail before socket I/O.
- `bridge.open_native_stream(runtime, ca, request, configured)` returns
  `Result(#(account_id, stream.Stream), contracts.Failure)`. Requires explicit
  native-test/qualified-integration registry Stream opt-in; not a raw-SSE route.
  `stream.next` returns `Batch(stream, events, done, error)`. Deliver prefix once
  before error. Success Stop waits for HTTP EOF after valid Connect EOS.
  `stream.adopt` / `cancel` delegate to shared ownership/lease handling.
  `stream.project(batch, state, shared_encoder)` injects the shared client codec;
  projection errors preserve preceding frames and cancel transport.
- `response.feed_prefix`: `#(Decoder, List(Event), Option(String))`; errors
  poison decoder. Events preserve text/thinking, binary signatures/tool
  arguments, signature type, usage, native reason and terminal Stop.
- `continuation.new(context, request, credential_record)` / `advance(...)`:
  bind provider/account/origin/runtime client-session key/model/exact credential
  generation/token hash; advance requires account pin.
  `request.encode_continuation` emits stable UUIDs, ordinal and user boundary.
  Pure values only, not another store/scheduler. The shared owner must guard
  advances and persist them atomically if continuation is enabled.
- `tokens.estimate(payload)`: `Estimate(input_tokens, payload_bytes)`, CPA's
  byte-count / 4 heuristic. `exact_native_count` explicitly fails.
- Enrollment: `begin_manual`, `begin_callback`, `exchange_code`,
  `complete_code`, `complete_query`, `await_and_complete`, `import_session_token`.
  Callback reuses `auth.await_callback` with configured
  `http://127.0.0.1:<port>/callback`, not a second listener.
  Existing-record completion uses exact-generation CAS so concurrent admin
  replacement/deletion wins, including same-token replacement.
  First enrollment uses secret `exchange_code` output and explicit operator
  import under setup-owner guard: shared atomic create-if-absent is unavailable.
  No asynchronous unconditional write. Manual import is explicit replacement.
- `status.request(origin, token, fingerprint, os)`: secret `HttpRequest`
  (`Proto`, not Connect envelope). `status.decode(body, observed_at_ms)`:
  private Observation, absent quota stays absent, reset fields explicitly
  seconds. Neither mutates or refreshes credentials.

`SessionToken` / `StaticSession` is intentional: no invented expiry, refresh
token or refresh schedule. Profile/quota observation is not token rotation.

## Source behavior and deliberate differences

CPA source: `internal/runtime/executor/devin_executor.go`,
`internal/runtime/executor/helps/{devin_wire,devin_models,proxy_helpers}.go`,
`internal/auth/devin/{devin_auth,user_status,pkce,record}.go`,
`sdk/auth/devin.go`, `internal/registry/models/devin_models.json`.

- Native protocol is Codeium/Cognition Connect `GetChatMessage`, not public
  session-creation/polling REST. Literal Basic token-token is not base64.
- Full submitted history, text, tools/calls/results, thinking, explicit
  signatures, temperature and inline base64 images are encoded.
  CPA tool-description rewriting, proprietary namespaces/custom tools, orphan
  result role downgrading and system-prompt sanitization are not reproduced.
  Unknown inputs reject; generic descriptions/system text stay unchanged.
  Unrepresentable text/tool/text or text/attachment/text ordering rejects.
- Image forms: Chat `image_url.url` base64 data URL; Anthropic `image.source`
  base64 with MIME. PNG/JPEG/GIF/WebP, bounded valid nonempty base64; not proof
  of valid image bytes. Remote URLs, audio, detail hints, other inline wrappers
  and mixed result/media forms reject. CPA may silently omit unsupported media:
  our rejection is deliberately different, not equivalent behavior.
- Signature bytes never become UTF-8. Buffered IR uses base64 plus explicit
  `devin_signature_encoding`/`devin_signature_type` markers understood by native
  request codec. Unmarked ambiguous strings reject instead of CPA guessing.
- Connect flags 0/2 only, 8 MiB bound versus CPA 16 MiB/64 MiB inflated.
  Compression, malformed protobuf/UTF-8/trailers, unknown semantic fields,
  post-EOS data and truncation never manufacture success.
- Exact/cache/partial accounting and dimension-estimate provenance stay native.
  Partial estimates retain presence flags; absent metrics never overwrite prior
  observations. Reasons 1/3 map to max_tokens; reason 11 is retained natively
  but filtered-termination client projection remains gated.
  Shared client codecs lack faithful projection: buffered bridge rejects usage
  extensions, binary-signature markers and custom blocks rather than emitting
  invented cache keys or exact-zero absent counts. Chat reasoning also rejects.
- HTTP 429 before output may use runtime failover. Trailer/projection failures,
  disconnect/cancel are Started and never replay. Diagnostics never echo bodies.

## Transport qualification proposal — not enabled

CPA `NewDevinHTTPClient` clones standard Go HTTP transport and disables automatic
compression. It declares no H2-only/duplex requirement. This is source evidence,
not executed proof that the current upstream supports H1.

Recommended neutral shared-core opt-in: explicit experimental binary transport
bound to exact operator-approved HTTPS origin/account; verified CA, certificate
hostname, SNI and ALPN. Default stays local-only. No redirects, origin changes,
remote cleartext or mismatching Host. No plan capture/logging. H2-only
requirements or negotiated H2 without real support must fail before application
bytes, never silently downgrade. No invented native TLS fingerprint.

Local tests cover verified synthetic TLS, unknown CA, pre-send Host/origin/H2
rejection, cancel and HTTP truncation. Host-policy rejection is not certificate
hostname-mismatch proof. ALPN and remote H1 remain separate unverified gates.
Shared baseline TLS tests are separate evidence, not Devin live qualification.

Live runs need explicit endpoints/account/test-data/budget/time authorization
and native-client QA coordination. No such authorization/run exists here.

## Executed evidence

`python3 docs/devin/verify.py` verifies the actual checkout, never an overlay.
First baseline compiled but test run timed out at 200 seconds.
Targeted wire/enrollment/status/continuation suite: **44 passed**.
Native HTTP/TLS stream targeted EUnit: **6 passed**.
Python driver unit tests: **10 passed**, not CPA differential execution.

First expanded full suite: **556 passed, 1 failure**. Historical rejection test
still expected supported Tools/temperature to fail; negative cases were changed
to unsupported Audio/top_p. No implementation behavior was weakened.
Final assembled rerun:

```sh
mise exec gleam@1.18.1 -- sh scripts/verify-integration.sh
```

**Passed: 561 Gleam tests, 10 Python unit tests, all assembled local integration
and Erlang-shipment checks.** Devin native runtime driver reports 12 scenarios,
synthetic=true, assembled_ingress=false, client_stream_codec=false,
remote_enabled=false, cpa_differential=false, live_verified=false.

Independent read-only review found partial estimated-count erasure, interleaved
request-block reordering, missing normal incomplete stop reasons and
segmentation-dependent Connect buffer behavior. All four were fixed and
regression-tested in the passing assembled run. No reviewer live execution.

Shared-core S3 archive was read-only inspected and its archive SHA256 verified:
`f6c39981bd331612b67e5bd21dd582f138facd2767b4479ba09d84a7cf9d85e8`.
It provides `open_scoped` / opaque Revision and integration-owned generic
continuation cache. It has not been copied into this checkpoint: base interfaces
remain compiled here, and integration can replace private continuation-binding
plumbing with the shared S3 scope while retaining native IDs/ordinal semantics.
Shared owner confirms no new client projection encoder or remote/H2 approval.

After the full integration run, an additional standalone synthetic restart
scenario was compiled and run in two fresh BEAM invocations:
`gleam run -m devin_persistence_scenario -- seed <private-state-dir>`, then
`restore <same-dir>`. Both passed: two permanent account tokens and private
metadata survived without reseed, remained isolated and had no expiry/refresh
schedule. This is store-restart evidence, not an authentic Devin-client workflow.
The same commands are included in `docs/devin/verify.py`.

Final source input verification (`verify.py --check-only --cpa-source <pin-tree>`),
`gleam format --check src test` and `git diff --check` passed. All executed Gleam
commands used `mise exec gleam@1.18.1 --`.
