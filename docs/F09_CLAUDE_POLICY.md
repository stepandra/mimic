# F09 Claude request-normalization contract

The existing corrected F09 implementation is recovered for module merge, not
redesigned. The four application modules and 35 ordered JSON vectors are
byte-identical to the preserved worker checkout. Application bytes match the
parent-confirmed historical `2ca01f015fad2f11d41766300b52948937c3fe24`.
The latest dedicated test module has 12 tests; its scenario and three corrected
policy/request/wire expectations were also recovered byte-for-byte.

The parent has prepared typed root policy/profile wiring. This worker did not
change root gateway/config/CLI, shared responses, vendor, F08 authentication or
transport. Composed admission remains the parent's gate. The source notes in
[F09_CLAUDE_SOURCE.md](F09_CLAUDE_SOURCE.md) are recovered unchanged historical
source evidence; no upstream research or CPA execution was repeated.

Final owned file hashes are in
[SHA256SUMS](../test/fixtures/claude/f09/SHA256SUMS). Unlike the old recovered
manifest, this lists only owned files and the latest test/scenario/CLI bytes.

## API and authority

Unchanged: `adapter.prepare(Context, Request)`, `adapter.prepare_with_policy`,
`adapter.account_identity(metadata)` (F08), `request.prepare`,
`request.prepare_with_policy`, `Policy(input, turn, cache)` and opaque scoped
`client_profile.Approved`.

Additive: `policy.validate`, `policy.normalized_nested` and
`client_profile.validate_headers`. No second parser, credential manager or config
abstraction. These validate data, not authority. `from_operator` binds to actual
selected provider/account/auth mode/origin/session; `for_context` fails on
mismatch. Unsupported header names, C0/DEL values and duplicate non-beta
identity headers fail. Header/body beta lists are normalized separately,
including MIMIC's declared body-comma splitting.
Header/profile assembly and advisor insertion precede protocol flags and body
extras; final model/turn filters never reposition advisor. First occurrences
win at each ordered append stage.

Clients cannot supply upstream authentication, Host/framing, profile/policy
authority, or selected credential identity. Root's inherited downstream
`x-client-request-id` correlation is tenant/account scoped by `runtime.attempt`,
not software-profile approval or authorization.

## Policy table

Key: selected model/auth + trusted input/turn/cache + operation + scoped approved
software headers. Never infer from UA/token/body identity. “Translated” means
already translated Claude JSON with explicit normalization selection, not a
new unsupported protocol codec.

| Branch | Messages buffered and SSE | Actual count endpoint |
| --- | --- | --- |
| Native/preserve | Byte-preserve body/unknown extensions if unchanged; never auto-place cache | Preserve thinking/tool_choice/sampling/extensions; declared five-field prune |
| Native/automatic cache | Explicit error, not ignored selection | Same invalid policy |
| Translated/preserve | No cache placement; remove temperature/top_p; top_k only with active thinking | No placement or Messages normalization |
| Translated/5m | Without markers: system/tool prefix plus rolling host `{type:"ephemeral"}` | Never auto-place; validate explicit layout |
| Translated/approved 1h | Requires selected OAuth/non-helper; only absent markers get `{type:"ephemeral",ttl:"1h"}` | Validate same trusted selection; never auto-place |
| Existing markers | Preserve valid full layout/extensions; suppress placement/upgrade | Preserve/validate; never repair |
| API key | Selected x-api-key only; remove OAuth beta; no OAuth metadata | Same auth; token-counting; no inferred native CLI baseline |
| OAuth | Selected Bearer; selected account/device/scoped-session metadata; OAuth beta inserted | Bearer/OAuth beta; no metadata injection |
| Conversation | Caller TTL flag preserved; explicit 1h appends extended TTL | Native requested TTL flag preserved; translated baseline omits managed TTL |
| Subagent | Without explicit 1h remove TTL beta; explicit 1h preserves/appends it | Without 1h remove TTL beta; no automatic TTL beta addition |
| Helper | Gate effort/display/TTL; 1h layout errors, never stripped; explicit title-helper fallback preserved | Same turn gates; no synthetic helper detector |
| Haiku lexical predicate | Gate effort and fallback-without-fallbacks (except trusted helper) | Same beta gates, not capabilities |
| Other descriptive model classes | No inferred progress, binding, clear-at, per-turn, mid-system, fallback, effort, max_tokens, entitlement | Same no-inference rule |
| Forced any/tool | Remove thinking and effort only; preserve output format/extensions; remove empty output object; stricter forced effort/display beta gate | Preserve body controls, no Messages-only mutation |
| Active enabled/adaptive/auto | Native temperature !=1, top_p<0.95 and top_k removed; translated removes temperature/top_p/top_k | Preserve these fields |
| Inactive/absent/unknown thinking | Native temperature wins over top_p, top_k stays; translated removes temperature/top_p, unknown thinking preserved | Preserve controls |
| Disabled thinking | Gate effort/display betas; no registry-based body pruning claimed | Same explicit beta gates |
| Nonblank string display | Remove conflicting redact-thinking beta, do not synthesize display | Same conflict gate |
| Advisor | Original requested flag or normalized advisor_ tool type; insert into header/profile before exact nine source trailer boundaries, then append extras and filter | Small translated baseline gets advisor before unmanaged extras; native uses the same staged caller-owned rule |
| speed=fast | Trim/case source predicate; append protocol beta, no speed inference | Native caller-owned count appends; translated small count profile does not infer fast beta |

Thinking type predicates trim/case-fold without changing caller values. Forced
tool choice is the exact source `any`/`tool` predicate, not fuzzy detection.
Numeric sampling/output object shapes must be supported on Messages; count does
not accidentally run that generation validation. Cache evaluation order is
tools -> system -> message content; <=4 ephemeral markers; supported TTL absent,
5m, 1h; never 1h after 5m. Schemas/tool inputs/nested tool-result data are opaque,
not recursively scanned for markers. Protocol container errors fail explicitly.

Count always uses the operator-owned real endpoint and returns its actual
response, not an estimate. Its declared compatible-endpoint prune removes
stream, max_tokens, metadata, context_management and diagnostics; true stream
fails. Native count adds token-counting and credential OAuth only. Explicit
translated count selects Code, optional OAuth, interleaved, context-management,
token-counting, then advisor when needed, then unmanaged extras. Managed flags
are not a global allowlist: native flags/extensions remain caller-owned with
documented conflict gates. This pruning and custom-origin real count are
deliberate source differences, not exact CPA fidelity.

Registry thinking conversion, budget/defaults/entitlements, billing/CCH,
device/fingerprint/TLS generation, native detection, MCP aliases, cloak,
system-role repair and telemetry are not implemented. Unsupported transport
encodings still fail; this recovery leaves the conservative Claude 429 wrapper
unchanged.

## Parent integration contract

The obsolete root patch proposal and old checkpoint log inventories are replaced
here by the existing contract, not a second root implementation.

```json
{
  "claude_policy": {"input": "translated", "turn": "conversation", "cache": "5m"},
  "claude_client_headers": [["X-App", "synthetic-operator-approved"]]
}
```

Absent fields default to native/preserve/no profile. Policy requires exactly
`input`, `turn`, `cache`; accepted values are native/translated,
conversation/subagent/helper, preserve/5m/1h. Run `policy.validate`; 1h additionally
requires selected OAuth. Headers are ordered two-string arrays validated by
`client_profile.validate_headers`. These fields on non-Claude accounts, unknown
fields/values, wrong shapes, forbidden headers and ambiguous identity headers
must fail config decoding.

`config.prepare_claude` must resolve the actual selected runtime context,
including account/provider/auth/origin/model, not the dispatcher's first
eligible account. Missing or mismatched selection fails Unsupported/NotSent,
never falls back to another profile. Incoming request hints are not operator
approval. The parent owns this helper, decoder and root tests.

## Exact parent commands

Run from the composed repository root after sibling modules have merged. These
are commands to execute, not recovery-worker acceptance claims. Every BEAM
command uses bounded scheduler settings. `gleeunit.main` does not filter
module-name arguments: do not use `gleam test <modules>` as a focused gate.

```sh
# Compile the composed project, including test modules/FFI.
ERL_FLAGS='+S 2:2 +A 2' mise exec gleam@1.18.1 -- gleam build

# Explicit focused EUnit exports, 60-second per-test timeout.
ERL_FLAGS='+S 2:2 +A 2' erl -noshell -pa build/dev/erlang/*/ebin -eval '
  {ok, _} = application:ensure_all_started(mimic),
  Modules = [claude_f09_test,claude_policy_test,claude_policy_wire_test,
             claude_provider_request_test],
  Tests = [{atom_to_list(M),
            [{timeout,60,fun() -> apply(M,F,[]) end}
             || {F,0} <- M:module_info(exports),
                lists:suffix("_test",atom_to_list(F))]}
           || M <- Modules],
  case eunit:test(Tests,[verbose]) of ok -> halt(0); _ -> halt(1) end.'

# Actual configured root routes, not an adapter closure or substitute gateway.
ERL_FLAGS='+S 2:2 +A 2' erl -noshell -pa build/dev/erlang/*/ebin -eval '
  {ok, _} = application:ensure_all_started(mimic),
  claude_f09_scenario:coordinator(),
  halt(0).'

# Native/default actual gateway, separately from configured acceptance.
ERL_FLAGS='+S 2:2 +A 2' mise exec gleam@1.18.1 -- \
  gleam run -m claude_f09_scenario

# Real source CLI: default baseline; then configured policy/account isolation.
mise exec gleam@1.18.1 -- \
  python3 -B test/fixtures/claude/f09/cli_workflow.py --default
mise exec gleam@1.18.1 -- \
  python3 -B test/fixtures/claude/f09/cli_workflow.py

# Parent builds shipment; harness only exercises that existing export.
ERL_FLAGS='+S 2:2 +A 2' mise exec gleam@1.18.1 -- \
  gleam export erlang-shipment
python3 -B test/fixtures/claude/f09/cli_workflow.py \
  --shipment build/erlang-shipment --default
python3 -B test/fixtures/claude/f09/cli_workflow.py \
  --shipment build/erlang-shipment
```

The configured scenario exercises all golden policies; Messages/SSE/count;
API key/OAuth; approved/unapproved hints; conversation/subagent/helper;
preserve/5m/1h; forbidden profile headers; two same-model accounts with distinct
origins/policies/profiles and sticky client isolation; helper explicit-1h body
rejection. Root helper context mismatch and strict decoder negatives remain
parent-owned tests.

The CLI harness invokes actual root commands using argument vectors, creates
only private synthetic temporary state, binds ephemeral loopback upstreams,
keeps observations in memory and sanitizes retained process logs. Default
success output should report 12 successful requests and 6 unauthenticated
pre-I/O rejections; configured output should report 24 and 9. These expected
counts are not a claim that the configured or shipment workflows passed.
It checks stage order, lexical Haiku alias, count pruning, selected-account
policy/profile/auth/session, fresh request IDs, selected SSE model, actual
upstream count response and runtime-owner cleanup. A blank `GLEAM` environment
value now falls back to `gleam`, just like an absent value.
Logs live under ignored `build/f09/cli-default` or `cli-configured`; no grants
or wire credentials are written there.

## Evidence: preserved execution versus recovery checks

Preserved logs read from worker `b3174f80a90447be`, under its
`build/f09/logs/`; they were not rerun in this recovery:

| Log | Observed outcome | SHA-256 |
| --- | --- | --- |
| `focused.log` | All 36 focused tests passed, including 12 F09 tests and 35 ordered vectors | `be760eee3027858be2bc1d66995bb0b9719928f143e9f0dbf496f63eb482df64` |
| `native-default.log` | Actual native/default gateway: 96 successful requests plus 30 invalid-cache pre-I/O rejections | `1101d0b816467e1511a61089d97317f33edf966aac0383d0dacc70e16b46819d` |
| `source-cli-default.log` | Failed before CLI launch: blank GLEAM executable, PermissionError | `7a2d61a14bbaa4cd45d7d2996718d886db07971066d7d632f8c44f7c6609106e` |
| `source-cli-default-2.log` | Actual source CLI default: 12 successful, 6 unauthenticated pre-I/O rejections | `574c2cb438b129b724d463b6b6b0fc171b0c02020532b7e45bd4a7b6f7afd231` |

Recovery checks:

- Every recovered application/test/golden byte verified against preserved files.
  Source notes recovered exactly; this policy/handoff document refreshed.
- Gleam 1.18.1 owned-file format check passed.
- Python syntax/import/`--help`, UTF-8, actual command expression with unset,
  blank and explicit GLEAM, shipment argv including spaces, and fixed wire
  positive/negative checks passed without launching a runtime or provider.
- An attempted `gleam test` compilation stopped at the inherited missing
  `mimic/providers/devin/messages_gateway` import in `gateway.gleam:45`, before
  any tests ran. This is an awaiting-F24 composition blocker, not an F09 defect.
  No import was changed and no build was repeated; parent has since reported
  completed F24 modules for its own merge.

Configured gateway/CLI, exported shipment, composed full suite, native clients,
CPA executable differential and live upstream gates were not run by this
recovery worker. No full suite, live/CPA/account calls, child agents, Git/JJ
mutations or edits to the preserved checkout were performed.
