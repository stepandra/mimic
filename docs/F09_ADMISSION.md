# F09 destination admission — source workflows passed

Parent-owned configuration now admits trusted per-account `claude_policy`
and `claude_client_headers`. Absent options retain native/preserve defaults.
Non-Claude accounts reject either option; automatic one-hour caching requires
OAuth. Request preparation selects these options from the runtime's actual
selected account, matching provider, auth mode, origin and configured model.
Caller-supplied client headers never select policy or operator approval.

Independent static review found no production blocker in the root wiring.
Its test-coverage finding was corrected: non-Claude negative tests now first
prove that each unmodified provider/auth/model configuration is valid. An
OAuth one-hour positive test was also added.

## Executed destination evidence

| Check | Result |
| --- | --- |
| Composed Gleam build | Passed |
| Explicit EUnit list: gateway policy, CLI, F09, existing policy/wire/request | **50 passed** |
| Actual configured gateway matrix | Passed after the harness correction below |
| Source CLI, default path | **12 successful / 6 unauthenticated pre-I/O rejections** |
| Source CLI, configured policy and selected-account isolation | **24 successful / 9 unauthenticated pre-I/O rejections** |
| Shipment / combined full gate | Pending; not inferred from source workflows |

All executions used synthetic private state and loopback providers, Gleam
1.18.1 / OTP 29, with process-local `ERL_FLAGS='+S 2:2 +A 2'`. There was no
CPA, installed native-client, real-account or live-provider execution.

## Failed first configured matrix and corrected expectation rule

The first configured matrix failed on the OAuth variant of the fixed
`header-before-body-dedup-api-key` vector. The harness reused an API-key
expectation for OAuth by deleting/reinserting the OAuth beta immediately after
the leading Claude beta. That is not the source rule: an existing OAuth beta
in the approved header retains its original position.

Production request code was unchanged. Each fixed golden now runs with its
declared auth mode and original expectation. Separate explicit API-key/OAuth
vectors exercise preserved OAuth-beta positioning through both buffered and
SSE routes. The independent endpoint/auth/turn/cache matrix, incoming-hint
rejection and selected-account checks remain in place.

The original 35-vector JSON and four provider modules remain byte-identical
to the recovered source checkpoint. The scenario's original SHA-256 was
`634bc2557e9c61a71045528cb2ab32bccfaf076ec360309df557e90935f5563d`;
its corrected SHA-256 is
`93507620a68f8323047cebc4891da74252bb7d0a1ceb93e7d4e5808a63bc82b6`.
The checked-in `test/fixtures/claude/f09/SHA256SUMS` reflects this intentional
destination harness correction.

| Local artifact | SHA-256 |
| --- | --- |
| `build/closure/f09-composed-focused.log` | `ff4514d3ad7c52d13ff83b26ae97e7b8335103c77ee95acfbdac871bde75ebc8` |
| `build/closure/f09-coordinator.log` (failed first attempt) | `a4c1f127b504470d02029460e497b25f7d5ec16a21c38b798c5a075bb3c78c36` |
| `build/closure/f09-coordinator-attempt2.log` | `657c5fdedf893891c2e94dedf62d0ce49e0ea6039b26445fbaf709fcd5ce238d` |
| `build/closure/f09-source-default.log` | `574c2cb438b129b724d463b6b6b0fc171b0c02020532b7e45bd4a7b6f7afd231` |
| `build/closure/f09-source-configured.log` | `69447242d5f8002d67f0516d3fba36deae3f78c05f45ee9856e979ab46471337` |
