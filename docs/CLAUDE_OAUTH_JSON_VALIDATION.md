# Claude handoff revision 2: reject ambiguous OAuth JSON

**This revision supersedes the earlier Claude adapter and runtime-v4 consumer
handoffs. Do not use their successful gates as approval for the pre-fix parser.**
The shared runtime-v4 snapshot is unchanged.

## Explicit supersession

Source root:
`/Users/jerryjohnson/dev/mimic/.delta/worktrees/bhpswn35wmkw/mimic`.

Base remains `c3ca7e805b8e4c3f8271468fbbe46271a5b0e8f4`;
CPA reference remains `acdace936fa7df2905500c7f5e0a97d683138dea`.

Retired manifest files are retained byte-for-byte as historical records. Because
their listed source has been corrected, they deliberately no longer verify the
current worktree:

| Retired manifest | Historical SHA-256 |
| --- | --- |
| `CLAUDE_PROVIDER_SHA256SUMS` | `06a36b25957ea9b461cddf688b4e0ff25676691206c7b91efc4e15f3152b9ca0` |
| `CLAUDE_RUNTIME_V4_SHA256SUMS` | `e912a1706348840cbd3bb8613c60844cd8ca1b93731266c1a44216b95a4c5d17` |

Authoritative revision-2 manifests:

* `docs/CLAUDE_PROVIDER_V2_SHA256SUMS`: 14 current provider source/test/fixture
  files, SHA-256
  `5c050a4f2e4e5aa1921dbaa752262ab4838b66a1f01a74cfc1b2521d6d6b6e8a`.
* `docs/CLAUDE_RUNTIME_V4_V2_SHA256SUMS`: the updated overlay runner, updated
  integration template and this document. Its digest is reported in the handoff.

The original capability and integration documents remain useful **historical**
context. Their 201/207 test counts and old manifest/reproduction hashes are
superseded here. These new manifests intentionally separate executable fixtures
from this supplemental evidence, avoiding circular manifest hashes.

## Reproduction and root cause

Two new tests failed before the fix:

1. HTTP 200 with duplicate `refresh_token` fields returned
   `Ok(Tokens(... synthetic-stale ...))`, rather than InvalidResponse.
2. HTTP 429 with duplicate contradictory `error` fields returned
   `RateLimited(17000)`, rather than InvalidResponse.

The shared `ir.parse` decodes JSON objects into a dictionary, losing repeated
keys before token validation. Separately, the Claude 429 branch previously did
not parse the body. A provider could therefore supply an ambiguous success or
error envelope without the adapter noticing. The runtime cannot repair that:
it depends on its provider callback to distinguish safe rejection from an
unknown grant-execution outcome.

No real token or provider response was used to reproduce this. The raw bodies
are synthetic unit/integration fixtures.

## Fix

`mimic/providers/claude/json_guard.gleam` performs a bounded raw-byte structural
scan **before** the ordinary JSON decoder can discard duplicate keys:

* At most 65,536 UTF-8 bytes, 32 nested containers and 4,096 JSON values.
* Decoded key equality, including escaped ASCII, escaped slash/quote/backslash,
  literal Unicode, escaped Unicode and surrogate-pair spellings.
* A fresh key set for each object, including objects nested inside arrays.
  Identical keys in separate objects are allowed.
* Duplicate keys are rejected even when values are equal or in unknown metadata.
  This avoids silently selecting one interpretation of an unmodeled field.
* JSON-looking strings are data, not recursively interpreted as objects.
* The existing JSON decoder remains authoritative for ordinary JSON syntax,
  number and escape validation. The guard reports only a constant error string.

`oauth.parse_tokens` invokes this gate for **every token/error response status**,
requires a JSON object, rejects `error` field presence on an HTTP-200 token
success, and rejects token/expiry fields on non-success responses. Field
presence is checked even for `null`.

Malformed, oversized, over-depth, over-value-budget, duplicated or conflicting
envelopes return `InvalidResponse`; the existing bridge maps that to
`RefreshUnavailable`, which preserves runtime-v4's recovery fence. Non-JSON or
empty error responses now conservatively require recovery as well; this is a
deliberate safety change, not a claim about measured provider error formats.

Unambiguous HTTP 429 still maps to `RefreshRateLimited`. No generic transport
error or malformed response was upgraded to `RefreshRetryable`. The runtime,
credential manager, shared IR, common ingress and other providers were not
modified. This guard applies to OAuth token exchange/refresh JSON, not all
Messages JSON, raw callback query parsing or unrelated provider protocols.

## Validation

Commands executed with installed Gleam 1.18.1:

```sh
mise exec gleam@1.18.1 -- gleam format --check src test \
  test/fixtures/claude/runtime_v4/claude_runtime_v4_test.gleam.in
mise exec gleam@1.18.1 -- gleam test
mise exec gleam@1.18.1 -- gleam run -m claude_provider_scenarios
python3 test/fixtures/claude/runtime_v4/run.py \
  /Users/jerryjohnson/dev/mimic/.delta/worktrees/qhtjz5hs63hm/mimic/build/provider-runtime-contract-v4
```

| Gate | Observed result |
| --- | --- |
| Two regression tests before fix | Both failed with the unsafe outcomes above |
| Main worktree formatting | Passed |
| Main worktree `gleam test` | **206 passed, no failures** |
| Provider scenario runner | All four groups passed |
| Runtime-v4 source hash verification | Passed; unchanged manifest digest `b6730e91c13503ce469c7b4e8721791b08135eb2ac28e298ffe874eeba3d3784` |
| Ignored overlay formatting and `gleam test` | **212 passed, no failures** |
| Runtime consumer scenario runner | All six groups passed, including expanded ambiguity cases |
| Separate seed/restore BEAM processes | Passed for the ordinary deferral/fence and three new ambiguity fences |

Successful revision-2 overlay: `build/claude-runtime-v4-q1ufy80q`.
The 212 count is the 206 provider/base tests plus six consumer tests, not the
runtime owner's separate test suite. Baseline TLS-negative notices and existing
dependency deprecation warnings are unchanged.

New unit coverage checks decoded duplicate keys, nested/array scopes, escaped
and surrogate-pair collisions, allowed distinct scopes/cases, malformed JSON,
byte/depth/value limits, root conflicts and the code-exchange entry point.
Independent read-only review identified an empty-container depth edge case;
the fix and 32-versus-33-container regression are included in the passing gates.
The reviewer reported no remaining blocker after targeted differential probes.

Expanded real-loopback runtime cases check duplicate token responses in either
order, escaped keys, nested Unicode collisions, contradictory duplicate errors
and token-bearing HTTP 429. All produce NeedsReauthorization, retain the old
credential, and perform no second exchange after worker restart. Separate fresh
VMs restore duplicate-success, duplicate-error and duplicate-nested fences
without reseeding or invoking a token callback.

## Release boundary

This closes the reproduced ambiguity bug and retests its actual runtime-v4
mapping. Production wrapper/ingress assembly, real native-client/provider
validation, unsupported policies and power-loss durability remain outside this
gate. All network fixtures remain local/synthetic; no accounts or live provider
calls were added. There were no shared-source edits, finalized commits, merges
or publication. Copy only the new manifested artifacts, not ignored overlays
or private synthetic stores.
