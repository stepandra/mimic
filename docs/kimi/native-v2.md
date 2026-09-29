# Bounded Kimi native extension contract

Base: `3e00808ff0fefbb6728edb1769c17139ef0fd93a`.
CPA source: `acdace936fa7df2905500c7f5e0a97d683138dea`.
All test bodies, tokens, media data and hosts are synthetic. No real accounts,
provider calls, measured fingerprints or live acceptance are claimed.

## Actual dependencies and ownership

This provider delta is **not standalone on the published base**. Chat streaming
uses shared-core **snapshot 2**, archive SHA-256
`ac3b58e2f5b04818b5108398d1e8400e4979d6c11cace6a955ae4e37ea6ced54`.
The owner's source-only archive and every `SHA256SUMS` entry were verified,
then installed only into the ignored `build/kimi-overlay` test assembly.
No shared protocol, gateway, transport, auth-store or root files are modified
by this delta. Shared-core owns dependency integration.

The snapshot provides `protocol/chat/http.open_sse` and
`run(state, handle, next, cancel, restore, emit)`, native
`Event(document) / ErrorEvent(document) / Done`, and common SSE byte framing.
There is no Kimi-local SSE parser or Responses implementation.

Integration owns route/configuration and baseline smoke changes. The old smoke
expects `tools: []` to fail; the new native tools implementation intentionally
accepts it. Do not call that unchanged smoke green or change a parity driver
status to hide the difference.

## Typed integration hooks

All paths below are under `src/mimic/providers/`.

| Hook | Contract |
|---|---|
| `kimi/models.registration(id)` | Native provider `"kimi"`; explicit known model IDs; API key/OAuth; protocols `"responses"`, `"chat"`, `"anthropic"`; operations `"responses"`, `"chat/completions"`, `"messages"`; tools and model-appropriate images. No audio/continuation/WS. |
| `kimi/request.http_at(resolve_base_path, ca_file)` | Existing callback ABI. Resolve path from the runtime-selected **account**, never the first account. Runtime owns approved origin, credentials, transport and refresh. |
| `kimi/request.prepare_at(base_path, context, request)` | `/coding` default; empty prefix permitted; a final `/v1` is recognized rather than duplicated. Native targets `/v1/responses`, `/v1/chat/completions`, or `/v1/messages?beta=true`. |
| `kimi/adapter.collect_for(response, request)` | Buffered Responses/Chat/Messages, shared dialect validation, duplicate guard, requested-model restoration; removes stale Content-Length/Transfer-Encoding after re-encoding. Do not use legacy `collect` for new dispatch. |
| `kimi/adapter.run_for(response, request, emit)` | Responses `stream.Event` and `stream.Outcome`; restores only recognized Responses envelope model slots. Shared prefix/UTF-8/terminal/cancel semantics remain authoritative. |
| `kimi/adapter.run_chat_for(response, request, emit)` | Shared Chat `Event/ErrorEvent/Done`, `Completed/Incomplete/RemoteError/Cancelled`; model restoration before emission, explicit upstream-model mismatch error, synchronous pull/cancel. |
| `kimi_compat/request.registration(model)` | **Distinct** provider `"openai-compatible-kimi"`; arbitrary explicitly configured exact model; API key only; buffered native Chat, tools/images. No Kimi aliases, thinking/temperature conversion, device headers or OAuth. |
| `kimi_compat/request.http_at(resolve_base_path, ca_file)` | Generic base path is the **API prefix**, normally `/v1`, producing `/v1/chat/completions`. It is not a native `/coding` base. Credentials/session identities are separated by provider ID. |

Messages streaming is still denied by the planner until the owned Claude
restoration hook is available. Generic streaming is not registered in this
bounded generic slice. The base gateway still denies native Chat SSE and
Messages routing; integration must select the new provider hooks explicitly.

## Native fidelity and deliberate differences

- **Tools:** Chat modern function schemas with object roots are preserved;
  missing root `type` becomes `"object"` like CPA. `$ref`, `$defs` and
  `definitions` fail rather than claiming CPA's local-ref inlining. Legacy
  `functions`/`function_call` and non-function/custom tools fail. Native
  Responses function schemas are preserved, not run through Chat normalization.
- **History:** explicit function IDs and raw argument strings survive. Chat and
  Messages tool results require matching explicit call IDs; no inferred IDs.
  Responses uses shared `pair_input`. Chat history with calls must retain
  nonempty `reasoning_content` unless thinking is disabled; unlike CPA, no
  `"[reasoning unavailable]"` text or copied reasoning is fabricated.
- **Thinking:** native reasoning content, Responses summary/encrypted content,
  Messages thinking signatures and redacted thinking survive. Chat
  `reasoning_effort` maps to native `thinking`; simultaneous controls fail.
  `"none"` is forbidden for K2.7 Code; `max` is limited to K2.8/K3;
  K2 has no configurable thinking. Numeric-budget/level clamps are not guessed.
  Native Messages enabled budgets must be positive and below max_tokens;
  adaptive/budget-to-effort translation is not claimed.
- **Temperature:** Chat permits absent temperature, `1` with default/enabled
  thinking, or `0.6` with disabled thinking. CPA drops other values; MIMIC
  returns an explicit loss error. Responses uses its native parameter contract,
  not the Chat transform.
- **Images:** source-backed native image forms are passed without fetching:
  Chat `image_url`, Responses `input_image.image_url`, Messages
  `image.source` URL or base64. Inline `data:image/{png,jpeg,webp,gif};base64,...`
  and credential-free HTTPS remote URLs are distinct. K2/K2-thinking reject
  images. Audio/video/files/file IDs and unsupported content are rejected,
  including images/audio nested in tool outputs under the same media policy.
  This is source/mock coverage, not measured upstream media acceptance.
- **Extensions:** native JSON fields survive where they do not invoke an
  explicitly unsupported feature. Duplicate keys fail before dictionary
  conversion. No cross-dialect projection is implied: unsupported translation
  must remain an error in shared codecs, not drop a block.
- **Restoration:** only protocol-owned model fields change. Tool names, call IDs,
  argument JSON strings, reasoning, signatures, nested user `"model"` fields,
  and extension objects are not recursively rewritten.
- **Streaming:** Chat requests usage, retains argument fragments/reasoning and
  usage events, requires a terminal `[DONE]` after finish, and distinguishes
  length/content-filter incompleteness, remote errors and cancellation. Native
  Responses keeps its original shared stream lifecycle.
- **State:** compact is explicitly unsupported by pinned CPA. No
  `previous_response_id`, conversation handle or implicit thinking replay cache
  is enabled. Rejecting them preserves account/client/model/session isolation;
  no prior IDs are dropped and no state crosses credentials.
- **Auth:** OAuth duplicate-key checks, CAS refresh fences, persistence, selected
  account binding, TLS verification and no replay after uncertain/started
  delivery are unchanged. HTTP 429 is not declared safe for automatic replay.
  Kimi Messages uses Kimi Bearer credentials, not Claude OAuth identity/tool
  normalization. No CPA device/build fingerprint is spoofed.

## Source evidence (not live measurement)

Pinned repository: <https://github.com/router-for-me/CLIProxyAPI/tree/acdace936fa7df2905500c7f5e0a97d683138dea>

- `internal/runtime/executor/kimi_executor.go:98–160,232–297`:
  native protocol selection, Chat model/thinking/schema/temperature policies,
  streaming `include_usage`.
- `kimi_executor.go:394–425,505–536`: distinct Responses path/contract;
  compact denied rather than silently treated as inference.
- `kimi_executor.go:673–939,1157–1289`: ID/reasoning repair, aliases, schema
  normalization and temperature dropping. Differences above are deliberate.
- `internal/thinking/provider/kimi/apply.go:59–171` and pinned
  `internal/registry/models/models.json`: native controls and per-model levels.
- `internal/runtime/executor/helps/kimi_responses.go`: `.com`/`.ai` bases,
  existing `/v1` handling and Messages delegation base.
- `sdk/cliproxy/service_executors.go:31–60,281–299` and
  `service_executor_registration_test.go:135–193`: native `"kimi"` and generic
  `"openai-compatible-kimi"` coexist in either registration order.
- `kimi_executor_test.go:206–242,367–472`: compact denial, Messages model
  normalization, Responses explicit reasoning/function history preservation.
- `internal/translator/claude/openai/chat-completions/claude_openai_request.go:464–525`
  and its image tests: inline/remote image forms, not proof of Kimi acceptance.
- `internal/auth/kimi/{kimi,token}.go`, `sdk/auth/kimi.go`: OAuth/domain
  semantics already documented in [native.md](native.md).

## Evidence layers

1. **Source:** pinned files and registration/executor tests inspected.
2. **Pure/synthetic:** native request/restore tests, shared Chat all-byte-split
   tests, ID/schema/media/control errors and generic/native separation.
3. **Actual loopback:** [wire-v1.md](wire-v1.md) observes ordered raw header
   pairs, bodies and Responses events through assembled CLI processes; key and
   both OAuth domain labels, selected second account, synthetic refresh.
   `test/kimi_stream_loopback_test.gleam` additionally exercises the actual
   runtime/HTTP native Chat adapter with gated incremental socket writes:
   split UTF-8 reasoning, tool argument fragments, model restoration, usage,
   finish/DONE, early disconnect and cancellation/socket/lease cleanup.
4. **CPA differential:** not run; fixtures/hooks supplied to the CPA lab.
5. **Live:** not run; no default real endpoint or account use.

The final owner-only export manifest records exact file hashes and validation
results. Do not infer new-route CLI coverage from the existing wire-v1 fixture.

### Verified snapshot-2 assembly

- `mise exec gleam@1.18.1 -- gleam test` in `build/kimi-overlay`:
  **562 passed, no failures** (includes shared-core snapshot-2 tests).
- `mise exec gleam@1.18.1 -- gleam format --check src test`: passed.
- `PYTHONDONTWRITEBYTECODE=1 GLEAM="$(mise where gleam@1.18.1)/gleam"
  python3 -m unittest discover -s test -p 'kimi_wire_test.py' -v`: passed,
  three actual loopback sessions.
- Baseline Python parity harness unit suite: **10 passed**.
- Full published-base integration attempt: **not green**; it reached the stale
  native tools rejection in `scripts/smoke-http-providers.py:515–520`.
  Integration owner was notified; that file is outside provider ownership.
