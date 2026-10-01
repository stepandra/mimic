# F08 — Claude OAuth companion observations

## Outcome and evidence boundary

The provider workflow is implemented and compiled. Focused local checks pass:
**36 EUnit tests**, the existing login enrollment scenario, and **20 synthetic
loopback cases** that include real token/profile/roles sockets and the actual
existing root `/v1/messages` route after companion enrollment.

This is **source-backed and mock-qualified**, not complete Claude parity.
The root configuration/CLI companion branch below is **not applied or compiled**.
A positive assembled root companion-login workflow remains outstanding until
the initiating coordinator applies that branch and tests the actual CLI.
The scenario explicitly calls the provider full-enrollment wrapper, then uses
the existing gateway. It is not an adapter-only test, nor a claimed CLI smoke.

- Exact base: `ca86b531cea7e1a509ac8e6038604fe91819ac07`.
- Frozen shared F11 parent: `3190bc60381d39f03dac1ebda92cf7ca47676b26`;
  its parent is the exact base. No F11 bytes were changed.
- No common enrollment/storage/runtime, adapter, request/cache/policy,
  client-profile/identity, stream/http, root config/CLI, dependency, vendor,
  CI or panel implementation was edited.
- No new FFI, credential manager, JSON parser, background task or telemetry.
- No F03 reference report is available. No native CLI or live account was used.
  See [the blocked upstreamcheck prerequisite](F08_CLAUDE_UPSTREAM_CHECK.md).
- `https://localhost:8317` was not contacted, restarted, reconfigured or used for
  account discovery. Foundation's reported root-200/TLS-valid observations are
  not Claude qualification and do not admit an additional live check.

## Immutable public source, not a capture

CPA pin: `acdace936fa7df2905500c7f5e0a97d683138dea`.

| Inspected file bytes | SHA-256 |
| --- | --- |
| `internal/auth/claude/anthropic_auth.go` | `ed8b3de740abdc754f492c64feb3bb38583a0346836b61e7cb0090ff4b8f9357` |
| `internal/runtime/executor/helps/claude_credential_identity.go` | `40cb43f38cf1668f0b1f3d3d3484be8a16183f82baa0e3f3e28128421ed8c48a` |

Fetched from public immutable raw URLs. The retained copies under `build/f08/`
are ignored audit artifacts, not vendored source or executed CPA evidence.

Actual source findings:

1. [Control-plane GET construction](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/auth/claude/anthropic_auth.go#L201-L258)
   supplies Bearer authorization and `Cache-Control: no-cache`.
2. [Profile decoding](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/auth/claude/anthropic_auth.go#L260-L274)
   requires nonempty trimmed `account.uuid`; organization identity is optional.
3. [Roles](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/auth/claude/anthropic_auth.go#L276-L289)
   remains raw valid JSON. Only the request shape has CPA's claimed capture
   support; neither CPA's comment nor this source read qualifies entitlements.
4. [Exchange companions](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/auth/claude/anthropic_auth.go#L291-L305)
   call profile, then roles, including roles after profile failure. Both failures
   are advisory in CPA. MIMIC discards diagnostic text rather than logging it.
5. [Actual identity precedence](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/auth/claude/anthropic_auth.go#L432-L464)
   is stronger than its comment: nonempty trimmed profile values overwrite
   token account/org even when different. **MIMIC intentionally rejects these
   conflicts.** Source precedence is not evidence that overwriting is safe.
6. [Selected-credential account lookup](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/helps/claude_credential_identity.go#L215-L227)
   tries `account_uuid`, then `accountUuid`. MIMIC keeps only its existing
   canonical private key; this slice adds no alias precedence or F09 rewrite.
   [CPA's metadata rewrite](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/helps/claude_credential_identity.go#L265-L309)
   also selects/generates a device pool. None of that generation is adopted.
7. [CPA refresh](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/auth/claude/anthropic_auth.go#L587-L596)
   fetches profile after refresh, not roles. F08 adds companions only to the
   explicitly approved enrollment workflow; it does not enable autonomous
   companion I/O in the existing shared refresher.

This extends the implementation described by
[the older source inventory](CLAUDE_POLICY_SOURCE_V1.md#L74-L85), while preserving
its no-implicit-companion default and no transport-fingerprint claim.

## Behavior and private reconciliation

[The shared identity rule](../src/mimic/providers/claude/oauth.gleam#L296)
accepts missing observations and fills gaps. Every nonempty observed account or
organization must agree across operator, token and validated profile. UUID
strings are bounded/control-free; source token/profile UUIDs are trimmed.
Explicit operator values must already be nonempty, bounded and control-free.
The existing shared timestamp validity rule also bounds returned token expiry.

| Condition | Result |
| --- | --- |
| Companion configuration absent | No profile, roles, usage or telemetry I/O |
| Explicit endpoint configuration, approval false/missing | No approved capability; reject configuration |
| Missing/invalid operator device ID | Reject before reservation or provider I/O |
| Account absent in operator, present in token/profile | Use that validated observation |
| Account absent everywhere | Fail closed; never manufacture an account |
| Profile transport/status/media/encoding/JSON/identity failure | Advisory absence; roles still attempted exactly once |
| Roles failure | Advisory absence, no effect on identity |
| Validated profile conflicts with token/operator | Fatal sanitized identity mismatch |
| Organization absent | Leave absent; no invented organization |
| Roles contains account/device/tier-like fields | Remains opaque; supplies no identity or entitlement |
| Administrative mutation/cancellation wins S5 CAS | Late completion cannot replace or remove the winner |

[Operator input](../src/mimic/providers/claude/companion.gleam#L109) requires the
existing 64-character lowercase hex device format. The value comes exclusively
from the operator's private observed identity. Device fields in token/profile/
roles, a token hash, process randomness, a default pool or copied user-agent do
not become device identity.

[Reconciliation](../src/mimic/providers/claude/companion.gleam#L248) produces the
existing OAuth auth material with only private `device_id`, `account_uuid`, and
optional `organization_uuid`. Email, organization name, the whole profile,
roles JSON, device pools and transport fingerprints are not stored. Roles JSON
can exist only as private ephemeral
[observations](../src/mimic/providers/claude/companion.gleam#L32); enrollment drops
it. All errors are fixed text or existing secret-free OAuth failure variants.
Never log or serialize grants, observations, callback state or PKCE verifiers
into public output, captures, metrics or model grounding packs.

## Compiled additive seam: shell versus CLI

[Provider callback and transport types](../src/mimic/providers/claude/login.gleam#L14):

```gleam
pub type Callback {
  Callback(state: String, code: String)
}
pub type Transports {
  Transports(
    token: fn(oauth.TokenRequest) -> Result(oauth.TokenResponse, String),
    companion: fn(companion.Request) -> Result(oauth.TokenResponse, String),
  )
}
```

[Store-free workflow](../src/mimic/providers/claude/login.gleam#L28):

```gleam
pub fn exchange_grant(
  config: auth.Config,
  pending: auth.Login,
  callback: Callback,
  identity: ir.Value,
  approved: Option(companion.Approved),
  now_ms: Int,
  transports: Transports,
) -> Result(contracts.AuthMaterial, String)
```

This function creates no listener, ticket or store record. The shell must reserve
its own ticket before announcing/doing I/O, atomically consume its pending login
once, pass independently received state/code, and commit/cancel its own ticket.
It must **never call either full-enrollment wrapper**. There is no second
reservation hidden in the seam. S5 remains the commit/cancel race arbiter.
No F05 shell types, signatures or implementation are assumed; F05 is uncompiled.
Cancellation does not revoke a provider token or retroactively unsend an admitted
request; it prevents a late local commit. There is no guessed UI cancellation API.

[Existing CLI wrapper](../src/mimic/providers/claude/login.gleam#L64) preserves its
signature and calls no companions. The additive
[approved full wrapper](../src/mimic/providers/claude/login.gleam#L87) is:

```gleam
pub fn run_with_companion(
  config: auth.Config,
  store: storage.Store,
  key: String,
  identity: ir.Value,
  timeout_ms: Int,
  announce: fn(String) -> Nil,
  approved: companion.Approved,
  transports: Transports,
) -> Result(Nil, String)
```

Both full wrappers share
[one S5 scope](../src/mimic/providers/claude/login.gleam#L147): begin once, commit
once on success, cancel only their ticket on ordinary failure. They reuse the
existing loopback callback listener, PKCE/token protocol, `runtime_store` and its
exact-slot/generation semantics. Panics/process death still leave first-enrollment
markers fail closed for explicit operator recovery.

[Explicit approval](../src/mimic/providers/claude/companion.gleam#L42):

```gleam
pub fn approve(
  profile_url: String,
  roles_url: String,
  approved: Bool,
) -> Result(Approved, String)
```

There are no published default URLs in executable code. Each endpoint must be a
canonical HTTPS URL, or HTTP numeric/localhost loopback, with an explicit
non-root path. URL credentials, query, fragment, encoded paths, backslash,
whitespace, invalid ports and unsupported IPv6 authority forms are rejected.
Only trusted operator configuration should construct this capability.

[GET transport plans](../src/mimic/providers/claude/companion.gleam#L26) have
`url: String` and ordered `headers: List(Header)`. The injected callback performs
one GET, no redirects/retries or diagnostics persistence.
[The default send](../src/mimic/providers/claude/companion.gleam#L217) reuses
`replay.send`, not another socket FFI. It builds an in-memory private request
frame; it never writes a capture.

MIMIC sends JSON Accept/Content-Type, Bearer, no-cache, `Accept-Encoding: identity`
and connection-close. It does **not** send CPA's Axios user-agent or advertise
gzip/compress/deflate/br. Existing BEAM peer-verified HTTPS is a source-inspected
transport mechanism, not measured Firefox/native TLS fidelity.
[One response gate](../src/mimic/providers/claude/oauth.gleam#L234) uses the
existing raw duplicate-aware JSON guard: 64 KiB JSON, depth 32, 4096 values,
including escaped/unicode duplicate keys. Missing Content-Type remains allowed
as in existing transport; a supplied type must be a single JSON/+json UTF-8 type.
Content-Encoding is absent or a single identity value only. Duplicate media/
encoding declarations and compression fail explicitly. The existing replay
transport has a separate 2 MiB wire-frame bound before the narrower JSON gate.
The corrected media gate validates a single HTTP-token subtype, rejects controls
and non-ASCII whitespace before trimming, and supports no parameter or exactly
one `charset=utf-8` parameter. Comma-combined values, additional slashes,
in-token whitespace and duplicate parameters are rejected.

## Minimal coordinator-only root instructions

**Not applied or compiled.** Base all production changes on
`3190bc60381d39f03dac1ebda92cf7ca47676b26`, plus this frozen F08 packet. Production
paths required: `src/mimic/gateway/config.gleam`, `src/mimic/gateway.gleam`.
No change to the root dispatch in `src/mimic.gleam` is necessary: it already
forwards `providers` arguments to the gateway CLI.

Read-only base byte hashes:

```text
5cf31b72a1773e2be88c9c651f3748137211274d73b939864ee305bc5989765f  src/mimic/gateway/config.gleam
d0fe0c567c827749f6f645865af2fc1f12ad18648fd30011962d9fa393dbcd1d  src/mimic/gateway.gleam
875b740f6795822524b481c40a070fead459af9e3f22cf7dffb91bdceb7d5c97  src/mimic.gleam
```

Recommended minimal additive route (avoids changing every Account constructor):

1. In [OAuthConfig](../src/mimic/gateway/config.gleam#L49), import companion and
   add `ClaudeCompanionOAuth(auth.Config, companion.Approved)` alongside the
   unchanged `ClaudeOAuth(auth.Config)` variant.
2. In [decode_pkce_oauth](../src/mimic/gateway/config.gleam#L291), after the
   existing Claude PKCE configuration check, read optional `oauth.companion`.
   Absent yields the original variant. Present must be an object with
   `profile_url`, `roles_url`, and a **required boolean** `approved`; call
   `companion.approve` and produce the new variant. Missing/false approval or
   malformed configuration must error, not silently downgrade. In
   [decode_oauth](../src/mimic/gateway/config.gleam#L272), reject a companion
   object for non-Claude providers.
3. In [Claude OAuth requirement admission](../src/mimic/gateway/config.gleam#L127),
   accept both variants. In
   [runtime_accounts](../src/mimic/gateway/config.gleam#L349), pattern both Claude
   variants to the **same existing** token refresher. Do not add profile/roles
   calls to refresh.
4. In [the current CLI login branch](../src/mimic/gateway.gleam#L120), add a
   branch for the new variant, leaving the existing branch intact:

   ```gleam
   Some(config.ClaudeCompanionOAuth(oauth, approved)) ->
     claude_login.run_with_companion(
       oauth, store, key, identity, 120_000, io.println, approved,
       claude_login.Transports(refresh.claude, claude_companion.send),
     )
   ```

   Import `mimic/providers/claude/companion as claude_companion`. This is the
   **full CLI wrapper**, so root must not begin another enrollment ticket.
   An enrollment-owning F05 shell instead calls the store-free seam above.

Proposed secret-free explicit configuration fragment (not yet decoded by root):

```json
{
  "companion": {
    "profile_url": "http://127.0.0.1:19444/profile",
    "roles_url": "http://127.0.0.1:19444/roles",
    "approved": true
  }
}
```

Place it inside the configured Claude account's `oauth` object. This fragment
is synthetic, not approval of an account or live endpoint.

Coordinator acceptance must exercise the actual current command
`providers credential login <config> <account-id> <private-identity-file>`
with a private synthetic fixture and a mock loopback authorization/callback,
then actual root Messages routing from that stored credential. Verify exact
POST token → GET profile → GET roles ordering, absence/false/malformed approval,
advisory failure, missing identity, conflict, stale admin/cancellation commit,
default-zero companion sends and no secret output. The root `credential stored`
message alone is insufficient. Update coordinator-owned configuration/CLI
tests and smoke script in the serialized lane, not this child's owned packet.

## Focused checks and retained attempts

Environment: Gleam **1.18.1** through `mise exec gleam@1.18.1`, OTP **29**,
`ERL_FLAGS='+S 2:2 +A 2'`. No full `gleam test` or full integration was run;
those require the coordinator's `READY_FOR_GATE` grant.

Commands executed, with all seven owned Gleam paths for scoped formatting:

```sh
ERL_FLAGS='+S 2:2 +A 2' mise exec gleam@1.18.1 -- gleam format --check \
  src/mimic/providers/claude/oauth.gleam \
  src/mimic/providers/claude/login.gleam \
  src/mimic/providers/claude/companion.gleam \
  test/claude_provider_oauth_test.gleam \
  test/claude_login_enrollment_test.gleam \
  test/claude_companion_test.gleam test/claude_companion_scenario.gleam
ERL_FLAGS='+S 2:2 +A 2' mise exec gleam@1.18.1 -- gleam build
ERL_FLAGS='+S 2:2 +A 2' erl -noshell -pa build/dev/erlang/*/ebin -eval '
  application:ensure_all_started(mimic),
  Mods=[claude_provider_oauth_test,claude_login_enrollment_test,
        claude_companion_test,claude_runtime_v4_test],
  Tests=[{atom_to_list(M)++":"++atom_to_list(F),{timeout,60,fun M:F/0}}
         || M <- Mods, {F,0} <- M:module_info(exports),
            lists:suffix("_test",atom_to_list(F))],
  case eunit:test(Tests,[verbose]) of ok -> halt(0); _ -> halt(1) end.'
ERL_FLAGS='+S 2:2 +A 2' mise exec gleam@1.18.1 -- gleam run -m claude_companion_scenario
ERL_FLAGS='+S 2:2 +A 2' mise exec gleam@1.18.1 -- gleam run -m claude_login_enrollment_test
```

| Local gate/artifact | Result | SHA-256 |
| --- | --- | --- |
| `build/f08/format-final.log` | Scoped format check exit 0; empty log | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `build/f08/build-final.log` | Build exit 0 | `c629f87b98e90bfed95a6bd48bf09940aec79972310f0a3f7753c88eef12894e` |
| `build/f08/focused-eunit-final.log` | 36 passed, exit 0; bounded 60s per test | `b189815b44ad744f9fbcc471db9b114553e18bb82fe6ce60002768e96c20df54` |
| `build/f08/companion-scenario-final.log` | 20 synthetic loopback cases + actual local root route, exit 0 | `0f26c0018923bb54828727067082fd1c49933f921493d2013c6195a960e6a485` |
| `build/f08/login-scenario-final.log` | Existing and additive S5 enrollment matrices, exit 0 | `c87cf666c2598b034f7258b466a3339bbf7a679bcabaeb3385ddda6a1f5a4588` |

Failed attempts are not waived:

- `build-attempt2.log`, SHA-256
  `9edff815bef1ec3e9ffcc8994c6a6de00e850aa60b3a6cd7147f437287431e73`:
  compile failed because the fixture mixed UTF-8 `Nil` and JSON `String` errors.
  The fixture now normalizes that error to fixed text.
- `focused-eunit-attempt1.log`, SHA-256
  `cf310cff7e7415e2743b7e7e3582d8251fdf2f376902386cbb9b0aef9e72288d`:
  27 passed then a five-second timeout in the raw root-request close/idle wait.
  Accidental duplicate tool invocations interleaved this log; its timings are
  not reliable evidence. A standalone scenario completed successfully
  (`companion-scenario-attempt1.log`, SHA-256
  `53411e393f1633bec4e5c67facc9e308fd2ce5de80f472c6be8513408685c9c6`).
  The owned fixture now finishes its actual root HTTP request on framing using
  the existing HTTP client, without changing root behavior or any FFI.
- `focused-eunit-attempt4.log`, SHA-256
  `61499e6aba5e2c0c8b4fbfa4e2c854b9fcac29e7fdc02e5ca34edcd7c30ed67d`:
  plain EUnit's default five-second timeout cancelled the aggregate
  companion/admin matrix. Final explicit per-test bounds execute all assertions;
  that matrix passed in 5.153 seconds. This is local test-runner timing, not a
  performance or provider benchmark. The dependency's normal Gleeunit runner
  scales its EUnit timeouts; no suite-wide timeout/source changes were made.

Tests cover successful reconciliation, both advisory failures, missing account/
device, operator/token/profile conflicts, opaque roles, no generated device/
fingerprint fields, response/transport-error sanitization, duplicate/escaped
keys, bytes/depth/value bounds, wrong media/encoding, one shell-owned ticket,
explicit cancellation, first/re-enrollment, and admin replace/same-value/delete/
insert-delete at callback, exchange, profile and roles boundaries. The loopback
cases use production token and GET transports and inspect only path/boolean
conformance; profile/roles observations do not become log fields.

## Parent review correction: single response media type

The original frozen F08 packet at
`dae5652093fd4f4d31d07e9383955d0ce54af963` was held after an independent static
review found that prefix/suffix matching accepted a combined declaration such
as `application/json, application/problem+json`. The profile, roles and token
consumers share that gate.

The parent reproduced the finding before the fix: three new consumer tests
failed, while the valid-media control passed (exit 1). The corrected rule
validates one `application/json` or nonempty HTTP-token subtype ending `+json`,
then the explicitly supported parameter list. Four added tests cover fourteen
malformed values across all three consumers and five valid single-type values.
The parent reran the same four focused modules with 60-second per-test bounds:
**all 40 tests passed**, including enrollment races, mock sockets and current
root Messages after explicit provider enrollment. Scoped format/build and
diff checks passed. This is not the still-unwired configured CLI branch, a full
suite, or native/live qualification.

Only `oauth.gleam`, `claude_companion_test.gleam` and F08/status documentation
changed for this correction; active F09 ownership was not touched. Original
packet and failed-run evidence remain available. No second child or heavy
gate was started, and no JJ commit/bookmark was changed during parallel work.

Corrected code hashes:

```text
919ad100836ff65200a1b84c42fb0edabcb1fa84b00470e1e29fffd16c6928b7  src/mimic/providers/claude/oauth.gleam
71bcf43093e3d6115cca9089315a317af219f7a37f31717bd748ce27273575f6  test/claude_companion_test.gleam
```

Parent-local ignored logs under `build/f08-review/`:

| Artifact | Outcome | SHA-256 |
| --- | --- | --- |
| `red-source.sha256` | Original OAuth bytes plus regression tests before fix | `4d4b489da46f7504404016b897d19b8909aa09efe878e4ee786a4ba809edcac3` |
| `media-red.log` | 3 failed, 1 passed; exit 1 | `175a5143478e5046e35f5ac540cccba313ae04d95e303f40f155e01b7efb0dd0` |
| `format-green.log` | Scoped check exit 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `build-green.log` | Gleam 1.18.1 build exit 0 | `8f0da6c1c68d264a0821e798eeab94b00ad1a5554a77d9767ce520da98c3a4ed` |
| `focused-green.log` | 40 tests passed, exit 0 | `62eea47f114473cd6e1294af975fa7d7e74acb820693b2d5020d0ea46c0d7d69` |

The focused command is the four-module EUnit command above, run from the
parent worktree after rebuilding. Source is frozen separately in the successor
admission packet; no self-hash is embedded in this document.

## Outstanding admission gates

1. Coordinator applies and tests the root config/CLI branch above.
2. Coordinator grants/runs assembled full format/test/integration and shipment
   checks, preserving frozen F11 and any admitted sibling bytes.
3. F03 supplies a qualified immutable reference report.
4. Explicit account/endpoint/budget/containment authorization and a real upstream
   check are supplied; native/live remain **false/blocked** until then.
5. Parent freezes the local JJ bookmark and submits `READY_FOR_ADMISSION`;
   this child does not commit, bookmark, publish or claim release admission.
