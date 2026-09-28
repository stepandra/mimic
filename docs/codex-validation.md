# Codex validation and dependency handoff

## Results

Base verified before implementation:
`c3ca7e805b8e4c3f8271468fbbe46271a5b0e8f4`.
The initially empty attached worktree was moved to a new isolated `jj` change
above this base only after coordinator approval. No mutating Git commands,
parallel commits, primary-checkout edits, or live provider calls were used.

| Gate | Evidence |
| --- | --- |
| Initial assembled-source baseline | 179 tests passed |
| Pure Codex policy modules | 200 tests passed before runtime bridge imports |
| Pure executable scenario added | 201 tests passed; scenario exit 0 |
| Runtime v1 bridge overlay | 204 tests passed |
| Actual loopback runtime lifecycle | Initial test failed on missing HTTP framing in provider Capture; adding Host and byte-accurate Content-Length fixed the real boundary |
| Reviewed policy + loopback overlay | **210 tests passed**, no failures |
| Fresh final-runtime-v2 overlay | **210 tests passed**, format check passed; both executable scenarios exit 0; all 12 dependency hashes verified before and after |
| `gleam run -m mimic/providers/codex/scenario` | Exit 0, synthetic policy flow |
| `gleam run -m mimic/providers/codex/local -- <private-state-dir>` | Exit 0, actual runtime/store/HTTP socket flow |
| Initial shared Responses v1 composition | **236 passed / 0 failed** |
| Subsequent v1 combined run | **234 passed / 2 failed**: TLS recorder `proxy_not_ready` / timeout; cause unestablished, not dismissed as preexisting |
| Hardened Responses v1.1 + runtime v2 composition | **263 passed / 0 failed**, full format check and all dependency hashes verified; both Codex executables and shared Responses HTTP scenario exit 0 |
| Runtime v4 + Responses v2 migration, before review fix | **289 passed / 0 failed**; both Codex executables and shared actual-loopback HTTP/WS scenarios exit 0 |
| Runtime v4 + Responses v2, review corrections | **291 passed / 0 failed**, both Codex and both shared loopback scenarios exit 0; format and all 30 dependency file hashes pass |
| Installed native Codex client, full discovery catalog | **Not established** |
| Conformance lab / CPA differential | **Blocked**, including mandatory assembled ingress |

Use runtime **v4** plus Responses **v2** for the current Codex source. Earlier
results and exports remain unchanged historical checkpoints, not evidence for
new dependency semantics.

Overlay tests are not a fully merged source result. Historical runtime-only
overlays contain 179 baseline + 31 Codex tests. The latest combined overlay
first contained **179 baseline + 42 Codex + 42 shared Responses = 263** tests.
The final runtime-v4/Responses-v2 run contains **179 + 52 Codex + 60 Responses = 291**,
not the runtime owner's separate test suite.
Runtime owner independently reported 188 tests for v1 and 203 tests plus
19 scenarios for v2; those owner results are not counted as Codex test executions.
Gleam 1.18.1 and Erlang/OTP 29 were used. Cold builds emitted existing dependency
deprecation warnings; negative TLS tests emitted expected Unknown CA notices.

## Independent review addressed

- WS `generate:false` is preserved, never silently converted into generation.
- Pending calls retain function/custom kind; cross-kind outputs fail, including
  when seeded by a previous turn.
- `user` is removed; `context_management` is explicitly unsupported.
- HTTP-date Retry-After uses existing quota parsing, with millisecond conversion.
- Pinned `gpt-reserve` and `codex-auto-review` visibility remains `hide`.
- WS receipts bind the runtime's connection generation as well as account/session;
  HTTP-origin and replaced-socket receipts fail WS continuation.
- Error classification preserves original upstream status provenance; in-band
  errors over HTTP 200 never become safely retryable rejections.

## Approved source-only runtime overlay

### Codex-owned export

The coordinator import checkpoint is `build/codex-provider-v1/source/` in the
Codex thread's `y8j5nqdkw46y/mimic` worktree. It contains exactly the 18 owned
files: 11 Codex Gleam modules, five Codex test modules, and these two Codex
documents. `build/codex-provider-v1/SHA256SUMS` records SHA-256 for every file
relative to `source/`; verify with `cd source && shasum -a 256 -c ../SHA256SUMS`.
No runtime dependencies, state, credential data, `.git`, `.jj`, or compiled
artifacts are part of this export. Treat this checkpoint as immutable.

The separate final-runtime-v2 checkpoint is `build/codex-provider-v2/source/`,
with its own `build/codex-provider-v2/SHA256SUMS`. It contains the same 18 owned
paths. No Codex source/test changes were necessary for v2; only the handoff
documentation records the additional evidence.

The separate composition checkpoint is `build/codex-provider-v3/source/`,
with `build/codex-provider-v3/SHA256SUMS`: **21 owned files** (12 modules,
seven test modules, two docs). V1 and v2 exports remain immutable. This
composition checkpoint uses runtime v2 + shared Responses v1.1, not the
announced but unpublished runtime v4. It is not a release candidate.

The current migration checkpoint is `build/codex-provider-v4/source/`,
with its own `SHA256SUMS` and dependency manifests beside `source/`. It contains
24 owned files (13 modules, nine test modules, two documents), no foreign
source or state. See the v4/v2 dependency section below. This is still not
assembled-ingress, native-client, or release evidence.

### Runtime v1 dependency

Compiled in ignored `build/codex-integration/`, containing this worktree's
source/test/project files and only the following foreign dependency files.
Each foreign file was copied from the owner's immutable
`build/provider-runtime-contract-v1/` after verifying its documented SHA-256.
No foreign `.git`, `.jj`, runtime state, credentials, tests, or build artifacts
were copied. No foreign-owned file is added to the tracked Codex delta.

The source-only snapshot owner was the Provider runtime thread's
`qhtjz5hs63hm/mimic` worktree. Its `docs/PROVIDER_RUNTIME_CONTRACT.md` is the
authoritative manifest and interface guide. Exact verified manifest:

| File | SHA-256 |
| --- | --- |
| `src/mimic/providers/contracts.gleam` | `2e0200739a103bef7915d532594035a497d6eb8efd851c7d96212553a7940b9d` |
| `src/mimic/providers/registry.gleam` | `7df2b417147c3a5ed9d7e5d38e00bfd3f6e93607c2af0361afc13b0d9edb6e9c` |
| `src/mimic/providers/runtime.gleam` | `3e479e4c4f3ae6edc8df932e8ee13dd9c77e548dbaa59cc36a3c62bf7214dd72` |
| `src/mimic/providers/transport.gleam` | `d2f38f38ea4c7157312423164038ff3cc8518a5c3f562f23f482028d5d48a6dc` |
| `src/mimic/auth/runtime.gleam` | `6ce21e06bf4de1b68b511996f2fd8cc66f02632297e24c0f1a6baaaa2767a6b6` |
| `src/mimic/auth/runtime_store.gleam` | `dd69b2ad72efbec635f681552475fe342e9fce639b6d58377ff9d600b21e1e5b` |
| `src/mimic/auth/storage.gleam` | `cb3c4281128a47efd32216226ec75027afa44184a1bdaeabcea63b4c96103729` |
| `src/mimic/egress.gleam` | `85a891cfef2ca4c1b890f484f8a375f1213ad5a7507f1fd1f6f9fba6f7d5c8bc` |
| `src/mimic/fleet.gleam` | `412a4212357c56520d7bc04c16de896396de180be0fa96a97a4c08e04bb1d19a` |
| `src/mimic/quota.gleam` | `ca1006e8eafc65558edc1b0d94395b5b968a61f46e7e90dec7de5262de297fb1` |
| `src/mimic_egress_ffi.erl` | `d62ad00cdf89f3e4a138eb6b0ed455534fa2dd011b3cab71d1dbb97280fdb7fc` |
| `src/mimic_provider_runtime_ffi.erl` | `46aa23b5e0fb21f0342ab05ffe03db75b939a28ac997aadb10c8127ee2c72003` |

The overlay is disposable and not replicated as product source. Recreate it from
the exact base/Codex source plus the verified owner snapshot, or merge the owner
change before building. Do not copy a whole foreign checkout or “fix” foreign
sources in the overlay. Future runtime hardening needs its own revalidation.

### Final runtime v2 dependency and retest

Created a fresh ignored `build/codex-integration-v2/` overlay; did not overwrite
the v1 overlay or export. The runtime owner's immutable
`build/provider-runtime-contract-v2/` and `docs/PROVIDER_RUNTIME_V2.md` supplied
these exact files. All hashes matched before copying and after the test runs:

| File | SHA-256 |
| --- | --- |
| `src/mimic/providers/contracts.gleam` | `2e0200739a103bef7915d532594035a497d6eb8efd851c7d96212553a7940b9d` |
| `src/mimic/providers/registry.gleam` | `7df2b417147c3a5ed9d7e5d38e00bfd3f6e93607c2af0361afc13b0d9edb6e9c` |
| `src/mimic/providers/runtime.gleam` | `4411227bd2158ae32352ca7ffbfd4aad0315d68aa47e1eaf224723664291e699` |
| `src/mimic/providers/transport.gleam` | `d2f38f38ea4c7157312423164038ff3cc8518a5c3f562f23f482028d5d48a6dc` |
| `src/mimic/auth/runtime.gleam` | `14ac32df5532e987bb0f8b2c34b38382e54411b1f58da2830c03f0969dad360d` |
| `src/mimic/auth/runtime_store.gleam` | `13fd353801873bac2c2cb2109b4cbfa614c0e012015e8b8ad8bb92b80a160e19` |
| `src/mimic/auth/storage.gleam` | `94dc663a9ad2f201695488b338a6f1679dc65bbee19666033fd3afc854fd8cc0` |
| `src/mimic/egress.gleam` | `f49812c02cb5422c4250b8f0c5da6b2871bcdc7dde4e3347140595fd61abd62b` |
| `src/mimic/fleet.gleam` | `412a4212357c56520d7bc04c16de896396de180be0fa96a97a4c08e04bb1d19a` |
| `src/mimic/quota.gleam` | `ca1006e8eafc65558edc1b0d94395b5b968a61f46e7e90dec7de5262de297fb1` |
| `src/mimic_egress_ffi.erl` | `d62ad00cdf89f3e4a138eb6b0ed455534fa2dd011b3cab71d1dbb97280fdb7fc` |
| `src/mimic_provider_runtime_ffi.erl` | `3411b07ad4116b7767225317a3c0c36c5966e9f979247089c71fac8193f6df1d` |

The existing Codex bridge passed v2's strict Host/authority check, including the
ephemeral nondefault loopback port. Real HTTP responses, compact, cancellation,
uncertain-send no-replay and lease cleanup passed unchanged.

V2's additive `runtime.adopt(stream)` is **not exercised by this Codex retest**.
The coordinator must call it synchronously in Mist's chunk-process initializer
before the request owner exits, then validate that handoff at assembled ingress.
Do not infer that gate from the unchanged local scenario or the owner's tests.
Shared Responses codecs, actual WS transport and `assembled_ingress` remain
blocked exactly as before.

### Hardened shared Responses v1.1 composition

The newer `build/codex-responses-v1_1/` overlay supersedes the previous paragraph's
shared-codec blocker, but not physical WS or assembled-ingress gates. All 13
foreign files were copied byte-for-byte from the Responses owner's
`bp3dg4b63e1r/mimic/build/responses-contract-v1.1/source/`. Manifest SHA-256:
`6c6daa2a7ceb90b76b670a4d83bc2f373c2510447c713ec10d1ebe94ea685a58`.
The runtime dependency is still the exact v2 manifest above.

| File | SHA-256 |
| --- | --- |
| `src/mimic/dialect/responses.gleam` | `e3b2f0a9f1cbf4bae7e1a0f491e9d23dd3a178205a982d8230a3ef2f8e39e6d1` |
| `src/mimic/protocol/responses/stream.gleam` | `7bf21ed2fdf4cdac09fb876f2a48ed922d4a445f430fecde236995e600c2f92b` |
| `src/mimic/protocol/responses/http.gleam` | `b03db62b16a39859ac63c0ee623c68b31798c91019404dd157e095986a6a8f72` |
| `src/mimic/protocol/responses/websocket.gleam` | `69b82b12bb89a45cd509e43c470198e06320fd9314c4892667762c73e92a1b4f` |
| `src/mimic_responses_bytes_ffi.erl` | `875107705d5f1d2c778588d9be208c95a348a5d46f47a2be1d3044786bd84d09` |
| `test/responses_protocol_test.gleam` | `ca21609e2e87a8cb070a78cae33174735c54bc3cef5b1e77a434bc47c2d090bc` |
| `test/responses_http_test.gleam` | `7aebdbffaac65d64cbacef6304542834f0787baa3575edbdbc851d6af1518fd4` |
| `test/responses_websocket_test.gleam` | `541b0460510e766767e0e567d2f89fad769ac89ace60092351d1003c55f6e922` |
| `test/responses_scenario.gleam` | `61ee45ea839d9d55cdf24d4a0d48e35b85f6341f4ed7f210e026acb606b45faf` |
| `test/mimic_responses_http_test_ffi.erl` | `a30b6ef2cd0d7e1d6d6c446ee0754f82ebcd0e05962b624e9c6acfb9047c9cb5` |
| `docs/RESPONSES_PROTOCOL.md` | `675f13aeab75f8486c59d26e284709495f321006a1a40df39885c93bccd9970e` |
| `docs/RESPONSES_HANDOFF_V1.md` | `6d67cbab7e22af5d2fe9f1ff6c6e962ecf4fd81baa6dc6b11f2ef42d2d3e5f5a` |
| `docs/RESPONSES_HANDOFF_V1_1.md` | `28975a3f2b57c675103b5b2e2b695dbe7383095da4a04558dd867462b207cb1b` |

Responses v1 (manifest
`011036e8964139ba0851b7c0830258b821d37d274a562de399a86c7d8cbdd09f`)
was used only in the historical `build/codex-integration-v3/` overlay.
It is superseded for security/correctness findings; do not integrate it.
The 236/0 and later **failed** 234/2 runs remain distinct evidence. No control
baseline was used to establish the timeout cause. A later pass does not erase
that failure. Full builds after the replacement progressed through 260, 261 and
finally **263 passed / 0 failed** as regressions were added.

The current runs used `ERL_FLAGS='+S 2:2 +A 2'`. One earlier cold run exceeded
the terminal's 200-second bound; it is not a passing suite result.

Independent composition review found three Codex bugs; all were corrected:

- Full retained history is shared-pairing-validated before receipt creation,
  rejecting reuse of previously completed tool call IDs.
- Actual A=401/B=200 failover selects B's prepared plan; `consume` independently
  rejects mismatched plan/account provenance. The B-pinned full-history request
  is observed on the real loopback wire.
- Valid unsuccessful terminal documents, usage and details survive as typed
  results without continuation receipts. Non-200/protocol/transport faults and
  cancellation cannot create a success receipt.

One-byte SSE segmentation, encrypted reasoning, raw arguments, reported usage,
compact separation, missing arguments-done, sparse/truncated terminals,
post-terminal input, scope/connection mismatch and shared WS create/cancel
composition have regression coverage. The common validator exposed a missing
arguments-done event in the original synthetic fixture; the fixture was fixed,
not the validator weakened.

At that historical checkpoint runtime v4 was unpublished and untested.
The following section records the separate migration; the older export was not
rewritten.

### Runtime v4 + Responses v2 migration

Fresh ignored overlay: `build/codex-final-v4/`. All foreign sources were copied
byte-for-byte only after verifying both manifest digests and every listed file.
The frozen Codex v4 export includes `RUNTIME-SNAPSHOT.sha256` (12 file hashes)
and `RESPONSES-SNAPSHOT.sha256` (18 file hashes) beside its owned-file manifest.
These text manifests contain dependency hashes, not foreign source or state.

| Dependency | Immutable source | SHA-256 of exact source manifest |
| --- | --- | --- |
| Provider runtime v4 | `qhtjz5hs63hm/mimic/build/provider-runtime-contract-v4/` | `b6730e91c13503ce469c7b4e8721791b08135eb2ac28e298ffe874eeba3d3784` |
| Shared Responses v2 | `bp3dg4b63e1r/mimic/build/responses-contract-v2/source/` | `6550e0a4e63c2838a0688f7db1bb1aac064c99e2a638d9de66d80e0072a859da` |

The named worktrees are under
`/Users/jerryjohnson/dev/mimic/.delta/worktrees/` on the validation host.
Runtime manifest is `SHA256SUMS` in its source root; Responses manifest is
`../SHA256SUMS` relative to `source/`.

Codex-specific migration regressions cover:

- Rotated tokens plus minimal identity persist with `Ready` before use.
- Malformed success may conceal rotation and maps to `RefreshUnavailable`,
  not safe retry. The runtime recovery fence survives worker restart and
  metadata/material/status reads; only explicit save reopens the gate.
- Known structured HTTP 429 defers for a supplied one-hour minimum without
  a five-minute upper clamp. Bare/contradictory 429, arbitrary 5xx,
  rate-looking 200 and malformed/negative/duplicate delay fields never grant
  retry permission.
- `RefreshRetryable` is passed through only from the trusted transport's
  affirmative delivery classification, never manufactured from a generic error.
- Streaming forwarding uses shared `http.run`/`feed_partial`, emits a valid
  prefix before malformed trailing data for coalesced and split chunks,
  classifies faults `Started`, performs no extra pull/open/replay and leaves
  zero leases. Local cancel and downstream error are covered.
- Native compact absent output stays absent on encode; null remains invalid.
- The real Codex loopback scenario now exercises both buffered SSE consumption
  and streaming forwarding in order. Shared standalone HTTP and RFC6455
  mock scenarios also passed, each explicitly `assembled_ingress:false`.

Migration review found a real ambiguity bug before freezing: the default JSON
parser collapses duplicate keys, allowing conflicting 429 errors to authorize
deferral or conflicting 200 refresh tokens to commit the wrong token.
`codex/json_guard` now rejects duplicate object keys at every OAuth decode
boundary (including escaped-equivalent keys, nested objects and account claims).
It delegates JSON syntax/value decoding to existing IR, bounds input to 1 MiB
and uses per-object dictionaries rather than quadratic list membership.
Regressions prove ambiguous responses map to `RefreshUnavailable`, and a
duplicate-refresh-token success body leaves the actual runtime recovery fence
intact across worker restart and reads instead of committing `Ready`.

The review also requested zero-emission failure coverage. Added account/status/
media/encoding preflight failures, first-pull failure, malformed first frame,
empty EOF and truncated EOF. All assert `Started`, no emitted event, no second
account/replay, exactly one transport cancellation and zero remaining leases.
The final 291-test gate includes both corrections; no new FFI or shared-owner
source edits were used.

The consumer refresh tests use mocked token responses and restart credential
workers within the test VM. They do not establish a separate two-OS-process or
power-loss gate. The provider runtime owns those mechanisms and its independent
evidence; its 236 tests/52 scenarios are not included in the Codex count.
No real token endpoint, native account or upstream quota measurement was used.

## Commands after dependency assembly

```sh
gleam format --check src test
gleam test
gleam run -m mimic/providers/codex/scenario
state_dir=$(mktemp -d "$PWD/build/codex-local.XXXXXX")
gleam run -m mimic/providers/codex/local -- "$state_dir"
```

The state directory contains only synthetic credentials in the shared runtime's
private store. It is not evidence of fresh-process persistence parity: the local
scenario deliberately seeds it. The Conformance lab's restart phase must instead
load prior state without reseeding, after assembled ingress exists.

## Remaining exact integration work

1. Merge the reviewed runtime dependency separately; register the Codex adapter
   and minimal `chatgpt_account_id` OAuth metadata using its actual contract.
2. Use the tested shared Responses v2 composition. Verify Codex/runtime WS transport
   and the Mist/runtime owner handoff separately; do not infer them from message
   protocol or standalone transport tests. Use runtime v4 refresh semantics.
3. Coordinator wires authenticated route aliases, native intent, model listing,
   OAuth callback one-time consumption and CLI. Neither generic Chat Completions
   routing nor a runtime-only test counts as this integration.
4. Use actual assembled ingress in the Conformance driver; consume its exact
   fixture plan and SHA, preserve observations and require all checks including
   `assembled_ingress`. Until then every affected row stays blocked.
5. Perform live/native-account tests only with separate explicit approval.
