# Claude policy handoff v1

## Scope and provenance

- Base verified by fetching `origin` from `https://github.com/stepandra/mimic.git`:
  `3e00808ff0fefbb6728edb1769c17139ef0fd93a`. Clean `jj new`; no Git mutations,
  commits, pushes, primary/sibling edits, credential discovery, or provider calls.
- CPA source: `acdace936fa7df2905500c7f5e0a97d683138dea`.
  `CLAUDE_POLICY_SOURCE_V1.md` contains the inventory, version/model/auth/kind
  matrix, immutable source URLs and fetched source-byte hashes.
- `CLAUDE_POLICY_CHECKPOINT_1.md` is frozen intermediate provenance, not a
  manifest for these final files. Existing provider/runtime v2 manifests were
  not rewritten.
- Final owned files: `CLAUDE_POLICY_V1_SHA256SUMS`. Source-only archive is
  `build/claude-policy-v1.tar.gz`; its external hash is delivered in the owner
  message. It contains only manifested Claude source/tests/fixtures/docs plus
  the manifest, not build products, dependencies, credentials, or sibling edits.

## Callback contract

Existing `adapter.prepare(Context, Request)` remains available and selects
native/caller-owned handling, conversation turn, preserve-cache, no client
profile. Runtime still owns credentials, origin, auth mode, account, scoped
session, transport lifetime, refresh CAS and durable fences.

Additive callback:

```gleam
adapter.prepare_with_policy(
  context: contracts.Context,
  req: contracts.Request,
  selected: policy.Policy,
  profile: client_profile.Approved,
) -> Result(Capture, contracts.Failure)
```

`Policy(input, turn, cache)`:

- `NativeMessages` or `TranslatedMessages` (already translated Claude JSON, not
  an OpenAI translator). Native does not automatically place cache markers.
- `Conversation`, `Subagent`, or `Helper`. These are trusted routing decisions,
  **not** classifications based on arbitrary user-agent or Authorization.
- `PreserveCache`, `DefaultFiveMinutes`, or `ApprovedOneHour`. One-hour default
  injection requires selected OAuth, non-helper, explicit operator approval.
  It does not assert native account/query-source eligibility.

Integration example, inside the existing runtime transport callback:

```gleam
let prepare = fn(context, req) {
  // Resolve policy/software headers from authenticated routing and operator
  // configuration for this selected context. Never copy caller Authorization.
  use approved <- result.try(
    client_profile.from_operator(context, operator_headers)
    |> result.map_error(fn(_) {
      contracts.Failure(contracts.Unsupported, contracts.NotSent, None)
    }),
  )
  adapter.prepare_with_policy(
    context,
    req,
    policy.Policy(
      policy.TranslatedMessages,
      policy.Conversation,
      policy.DefaultFiveMinutes,
    ),
    approved,
  )
}
let provider = transport.http(prepare, adapter.rejection, ca_file)
```

`from_operator(context, headers)` validates approved noncredential software
headers and binds them to account, auth mode, selected origin and scoped
session, without retaining credential values. `for_context` rejects reuse
outside that scope. This is **not authentication**: the integration must first
authenticate/authorize the caller and select a context. Instantiate profiles
only from operator-approved configuration scoped to that runtime/tenant.
`client_profile.none()` is the safe default.

The adapter rejects provider/auth-mode/model-body mismatch before transmission,
using the existing native JSON guard. OAuth identity comes only from selected
private metadata (`device_id`, `account_uuid`); organization remains private.
Caller identity extensions are retained, but duplicate/escaped duplicate
`metadata.user_id` JSON keys fail. Request IDs are fresh runtime IDs, not a
claim of native UUID/header fingerprint parity.

Errors at the callback boundary are sanitized `Unsupported/NotSent`. Do not log
the Capture, token/body/profile inputs, or private metadata. The runtime receives
the plan only for the selected origin/credential. Existing OAuth/refresher/login
and HTTP/SSE pump remain in use; no new credential manager or transport.

## Integration, lab and native-client gates

1. Verify the archive hash, inspect its path list, then import **only** the
   manifest paths into the integration owner's worktree. Check
   `shasum -a 256 -c docs/CLAUDE_POLICY_V1_SHA256SUMS`.
2. Leave the default callback for native Messages. Bind the additive callback
   only after a trusted routing decision; default turns must not be guessed from
   caller auth/UA. Test authenticated tenant/account/origin isolation at gateway.
3. Run `claude_policy_scenarios`, the full suite, and integration gateway tests.
   Cover API key and OAuth, Messages buffered/streaming, actual count endpoint,
   tools/results/signatures, scoped approved headers, 5m/1h, and selected-model
   mismatch. Never manufacture count responses in production.
4. CPA lab: `test/fixtures/claude/policy_v1/differential.json` contains executable
   synthetic input/expected normalization pairs, volatility rules and explicit
   differences. Pin CPA exactly; disable cloak/use caller-owned profile for
   comparable cases. Compare beta order and arrays exactly; do not mask content,
   signatures, cache/usage or model. A profile mismatch is not a passing diff.
5. Native QA: record actual binary version and run tool→tool_result continuation,
   thinking signatures/usage, forced tools, count_tokens, subagents/helpers,
   streaming errors/disconnect/cancel and OAuth-vs-API-key identity. Source Code
   2.1.220/258/280 shape references are not proof of an executed client. No
   provider/account call or home/env credential search without approval/budget.

Requested Kimi `http.run_with_restore` is **not in v1**. It is a separately
versioned follow-up contract with the Kimi/shared-core owners, preserving default
native frame bytes and cleanup behavior. No Kimi policy or shared-core edits
are bundled here.

## Evidence and remaining limits

- Final `gleam test`: **536 passed, no failures**, using Gleam 1.18.1 and
  `ERL_FLAGS='+S 2:2 +A 2'`.
- Focused `gleam run -m claude_policy_scenarios`: passed. Includes policy matrix,
  scoped profile rejection, machine-readable differential expectations, real
  local HTTP auth/model/kind matrix, and real TLS one-byte HTTP chunks through
  the existing runtime/pump. TLS terminal/error/cancel checks observe exactly one
  cleanup callback, one upstream connection, and zero remaining leases.
- All two-way byte splits of the synthetic tool/thinking/usage SSE fixture and
  malformed-prefix fixture pass. This is deterministic framing evidence, not
  exhaustive arbitrary protocol fuzzing.
- Full integration script was attempted but hit its 300-second execution bound:
  its full Gleam run, 10 Python tests, provider/runtime scenarios, strict
  handshake checks, and assembled gateway CLI smoke completed before timeout.
  A subsequent assembled HTTP-provider CLI smoke reported success including
  Claude OAuth SSE, refresh singleflight/restart/CAS and configured PKCE login.
  That bounded command group later timed out during the WebSocket smoke.
  **No final full-script, shipment, or CI-green claim for this slice.**
- Initial unrestricted-scheduler baseline attempt timed out at 200 seconds.
  The later bounded-scheduler full suites passed; this is not evidence of a
  diagnosed performance fix.
- CPA differential execution, native-client execution, live upstream/account
  validation, full CLI cloak/fingerprint, registry-based thinking conversion,
  and OAuth companion network workflows remain **unverified/not implemented**.
  Unsupported explicit cache layouts and ambiguous identities remain visible
  errors, not silent repair or test-count-based parity percentages.

No automatic publication is authorized or performed.
