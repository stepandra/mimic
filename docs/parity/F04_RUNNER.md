# F04 bounded executable scenario runner

**Implementation checkpoint, not F04 live acceptance / DONE.** The Gleam
execution/budget core and standalone synthetic transport are implemented.
Live/native launch admission is **blocked**: F02 has no operator-approved real
kernel launcher or measured containment/lifetime selftests; F03 has not verified
the running CPA reference. No caller boolean, approval file, supplied executable
digest or historical receipt can substitute for those dependencies.

**The focused review gate passed and is quiescent.** See `F04_REVIEW.md` for the
ordered usage, peer-close evidence and RFC header-name corrections, exact
17-input receipt, retained setup failure and actual validation results:
eight offline tests, twenty execution tests and the existing synthetic CLI
harness. All directly invoked commands exited, private fixtures are gone and
only this invocation's own shared lock was removed. No deferred run remains.

The **earlier CRLF-corrected source** passed a parent-granted exact dependency
closure check, seven offline tests, ten execution tests and the actual
production synthetic CLI workflow. Those results and the 15-input receipt below
are historical: they do not qualify the review corrections. In particular,
the old timeout-as-close oracle did not prove client socket closure or a
production leak. The historical setup/CRLF failures and logs are preserved,
not relabeled. No full-suite/root composition gate was run here. No browser,
native workflow, real account, credential store, provider request, paid call,
localhost:8317, Docker, VM or image action has been used.

## Ownership and parent integration

Owned source:

- `src/mimic/live.gleam`: `cli(args: List(String)) -> Result(String, String)`.
- `src/mimic/live/admission.gleam`: opaque typed launch admission.
- `src/mimic/live/identity.gleam`: exact F01-byte and selected-case bindings.
- `src/mimic/live/policy.gleam`: explicit approval, body/route/token/price policy.
- `src/mimic/live/budget.gleam`: one monotonic bounded per-run ledger.
- `src/mimic/live/runner.gleam`: serialized admission/reservation owner,
  asynchronous guarded execution, cancellation/deadlines.
- `src/mimic/live/http.gleam`: direct standalone synthetic HTTP/1.1 adapter.
- `src/mimic/live/synthetic.gleam`: explicitly synthetic fixture constructors and
  injectable transport, no launcher.
- `src/mimic_live_ffi.erl`: small monotonic-clock, SHA256 and explicit bounded
  regular/private-file primitives. Existing `mimic_egress_ffi` socket primitives
  are reused without edits.
- `test/live_test.gleam`, `test/live_execution_test.gleam`,
  `test/mimic_live_test_ffi.erl`: dedicated tests and actual synthetic execution
  harness; the latter FFI provides loopback socket and explicit private scratch
  fixture create/remove OS primitives. Removal checks the exact created
  inode/device token and is never recursive.

**Exact root hook, parent-owned, not edited here:**

```gleam
import mimic/live

// In the existing root dispatch:
["live", ..args] -> live.cli(args)
```

No F01 data/preparation runner, native acquisition, F02 kernel/launcher,
root CLI/config/gateway, providers/runtime/store or other workers' files changed.
The old Python native-client `live.py` preflight remains untouched; it does not
become an alternate launch path.

## Public execution seam

```text
identity.bind(contract_bytes, expected_sha256, case_id, candidate_claim,
              reference_claim) -> Result(Binding, String)
admission.synthetic(exact_loopback_origin) -> Result(Admission, String)
admission.live(LiveInputs) -> Result(Admission, String)   # blocked dependency
admission.native(LiveInputs) -> Result(Admission, String) # blocked dependency
policy.authorize(admission, approval, binding, request) -> Result(Plan, String)
runner.start(admission, approval, binding, Transport(connection))
    -> Result(Runner, String)
runner.submit(runner, attempt_id, request) -> Attempt
runner.await(attempt) -> Result(Outcome, String)
runner.execute(runner, attempt_id, request) -> Result(Outcome, String)
runner.cancel(runner, attempt_id) -> Result(Nil, String)
runner.snapshot(runner) -> Result(Snapshot, String)
runner.close(runner) -> Result(Snapshot, String)
```

The budget/execution state machine is transport-independent, not a preflight.
`Transport(connection)` supplies one `connect`, one `send`, bounded pull `next`
and `cancel`. A reviewed future live/native adapter can reuse this state machine,
but must obtain a distinct opaque admission capability from an independently
verified real boundary here, plus verified route/pricing/token-ceiling rules.
The current concrete HTTP adapter **cannot** become remote by adding a new
admission constructor: it independently restricts numeric loopback.
Injectable adapters are trusted synthetic test code, not an adversarial sandbox.

There is no persisted `qualified` flag, auto-resume, retry loop, account discovery
or credential acquisition. Approval is per explicitly invoked run; repeating a
CLI invocation is a new operator action, not an automatic continuation. This
checkpoint is not a durable account-wide quota ledger or authority for
cross-process/multi-host live spend. A future live admission must also establish
the account's exclusive run/ledger ownership before supporting restart/resume.

## Budget rule

All currency is integer **nano-USD** (1 USD = 1,000,000,000 nano-USD).
Prices are explicitly scoped to exact account, endpoint, model, method and path.
For each attempt the actor atomically reserves:

```text
requests += 1
input_tokens += approved_input_ceiling
output_tokens += approved_output_ceiling
cost_nano_usd += input_ceiling * input_price_per_token
               + output_ceiling * output_price_per_token + fixed_price
```

Reservation finishes **before the only worker launch site**. It must fit every
remaining request/input/output/cost budget and the absolute run deadline.
Unknown price/route/token ceiling or identity/allowlist mismatch rejects without
transport I/O. Integer arithmetic avoids rounding/NaN issues.

Reservations **never refund**: not after proven pre-send failure, smaller
observed usage, timeout, cancellation, lost reply, worker failure, disconnect or
server error. Usage/cost observations are separate optional fields and cannot
increase allowance. Unknown usage/cost is unknown, not zero. A known usage
ceiling violation closes the run and kills remaining workers. Duplicate admitted
attempt IDs are rejected even after failure/cancellation; an explicit retry with
a new ID needs a fresh full reservation. There are **zero automatic retries**.

The current `synthetic-bytes/v1` token rule belongs only to synthetic fixtures:
one raw request byte is one fixture input token, and the explicit JSON output
maximum is no greater than the reserved output ceiling. It is **not** a
tokenizer estimate or a real-provider upper-bound claim. Real pricing/token
ceilings remain unavailable inputs; using this synthetic rule for live is not
authorized.

Hard implementation caps: 1024 attempts, 1,000,000 input/output tokens per run,
1 USD, 60,000ms run duration, request duration no greater than run duration,
16KiB request, 64KiB response, 1024 data chunks, 1024 usage observations (including
a terminal snapshot), 8KiB response headers and 32 headers. Operator limits can
only reduce the existing byte/time/chunk caps. `stream_chunks` bounds pull/data
chunks, not provider semantic SSE event count. Overall byte/time/chunk ceilings
also bound streams lacking a terminal event. Ordered complete synthetic usage
snapshots are checked before the next pull; missing/null usage and `End(None)`
retain known counts. Invalid/decreasing assertions fail closed and cannot
replace validated counts. This is not a universal provider usage contract.

## Lifetime and delivery classification

- Connect failure confirmed before `send`: `not_sent`; reservation still held.
- `send` failure/partial write: `uncertain`; never refunded or replayed.
- Confirmed write followed by response/disconnect/error: `sent`; still held.
- Cancellation, hard watchdog timeout or worker/owner failure: conservatively
  `uncertain` unless the execution result had already won completion.
- A reply loss cannot imply `not_sent`; the API requests cancellation and
  reports unknown delivery with the reservation retained.

One absolute monotonic millisecond deadline covers connect, write, headers,
every framing read and body pull. A separate Gleam guard watches deadline and
budget-owner death even while transport blocks; killing the guard kills its
linked execution process, whose OS-owned socket closes. Completion/cancellation
is serialized by the same owner; late results cannot reopen or refund the run.
At run expiry all workers are killed, snapshots remain queryable for at most one
second, then the abandoned owner retires. `close` stops it immediately.
These BEAM guards are **not native process/filesystem/network containment**.

## Route/body/transport authority

Only exact `http://127.0.0.1:<explicit-port>` synthetic origins are admitted.
Ports below 1025 and 8317 are rejected. No hostname/DNS, URL userinfo, trailing
path, query, fragment, normalization, redirect, proxy or environment lookup.
Selected endpoint must equal an entry in the operator's exact allowlist.

The selected F01 method/path and HTTP-versus-SSE mode must match the request
exactly. Both use HTTP/1.1; SSE requires explicit `stream: true` and a buffered
HTTP case cannot be silently converted into a stream.
This bounded text-generation checkpoint permits POST `/v1/messages`,
`/v1/chat/completions`, `/v1/responses` only. Other routes/protocols explicitly
fail; it does not claim media/video/counting/native workflow support.
The exact body SHA must be separately approved. A duplicate-key/depth/value/
byte guard precedes decoding. Allowed controls are only selected model,
explicit output ceiling, simple text input and optional boolean stream.
Tools/media/URL-fetch/body-origin/output-limit override controls are rejected,
including if an operator supplies a matching body hash.

The adapter constructs Host/content-length/content-type/accept/encoding/close
headers itself. Request bytes cannot override headers, authority or protocol.
Response framing accepts bounded canonical Content-Length or chunked only;
duplicates/conflicts, trailers, chunk extensions, redirects, compression,
upgrade, binary and unsupported content type fail explicitly. JSON/SSE body
bytes stay bounded; only optional synthetic usage is interpreted. No response
body or credentials enter reports, logs, captures or grounding packs.

CLI input files are explicit operator-owned fixtures, not credential discovery.
Final symlinks, non-regular/oversized files and nonprivate approval/body files
are rejected; opened descriptor metadata is rechecked and reads are capped.
This input hygiene is not an adversarial filesystem sandbox: untrusted path
ancestor/race containment requires the unavailable real F02 boundary.

## F01 and identity: claims are not proof

F04 hashes **exact supplied contract bytes**, checks the explicit expected SHA,
F01 scope/version/pins and selected case route. It does not reimplement the
complete F01 validator or authenticate source files/executables. Upstream F01
validation remains independently required.

`f04_case_binding_sha256` is SHA256 of the UTF-8 fixed-order JSON array:

```json
["mimic.f04-case-binding/v1","<exact-contract-byte-sha256>","<selected-case-id>"]
```

This unambiguous, versioned binding includes every contract byte via its digest
and the selected case ID. It is an **F04 binding**, not an invented F01 canonical
case hash, fixture hash or runtime proof. Changing any contract byte changes it.

Candidate/reference artifact, source, dependency and configuration SHA fields
are retained **exactly as supplied claims**. Running identity is `unverified`.
Synthetic construction labels the claims as hashes of synthetic nonexecutables,
never as CPA identity. Reports set differential/native/live to `not_run` and
F01 case assertions to `not_evaluated`. A transport-completed outcome is not a
F01 source/mock/reference/differential/native/live qualification or parity pass.

## CLI approval schema

After the root hook is admitted, actual synthetic execution is:

```text
mimic live synthetic <0600-approval.json> <F01-contract.json> <0600-body.json>
```

The following is a **synthetic schema example**, not a valid approval, measured
tariff, real account or runnable endpoint. Replace placeholders with the exact
approved fixture bytes/digests and an operator-owned synthetic endpoint. No
credential fields are supported.

```json
{
  "schema": "mimic.f04-approval/v1",
  "allowed_data": "synthetic-only",
  "approved_by": "synthetic-fixture-operator",
  "account": "synthetic-account",
  "scenario": "synthetic-budget-case",
  "endpoint": "http://127.0.0.1:<approved-fixture-port>",
  "endpoint_allowlist": ["http://127.0.0.1:<approved-fixture-port>"],
  "case_id": "claude-messages.final-v1",
  "contract_sha256": "<exact-F01-contract-byte-sha256>",
  "body_sha256": "<exact-request-body-sha256>",
  "model": "synthetic-model",
  "price": {
    "scope": {
      "account": "synthetic-account",
      "endpoint": "http://127.0.0.1:<approved-fixture-port>",
      "model": "synthetic-model",
      "method": "POST",
      "path": "/v1/messages"
    },
    "input_nano_usd": 2,
    "output_nano_usd": 3,
    "fixed_nano_usd": 0
  },
  "ceilings": {"rule": "synthetic-bytes/v1", "input": 512, "output": 32},
  "limits": {
    "requests": 1,
    "input_tokens": 512,
    "output_tokens": 32,
    "cost_nano_usd": 1120,
    "duration_ms": 2000,
    "request_ms": 1000,
    "response_bytes": 4096,
    "stream_chunks": 32
  },
  "candidate_claim": {
    "artifact_sha256": "<synthetic-claim-sha256>",
    "source_sha256": "<synthetic-claim-sha256>",
    "dependencies_sha256": "<synthetic-claim-sha256>",
    "configuration_sha256": "<synthetic-claim-sha256>"
  },
  "reference_claim": {
    "artifact_sha256": "<synthetic-claim-sha256>",
    "source_sha256": "<synthetic-claim-sha256>",
    "dependencies_sha256": "<synthetic-claim-sha256>",
    "configuration_sha256": "<synthetic-claim-sha256>"
  },
  "attempt_ids": ["explicit-attempt-1"]
}
```

`price: null` / `ceilings: null` are decoded as unknown and rejected before any
transport action. Unknown top-level fields are rejected. Each listed attempt
is explicit; no retry is inserted. `Ok(report)` means a bounded execution report,
not all outcomes succeeded; inspect each outcome/denial. Static invalid inputs
return `Error(String)` without launching.

## Validation plan and remaining admission

### Historical initial-core / CRLF validation, not review validation

The earlier source-only closure was prepared under `build/f04-closure` with exact copies
of 15 source/test/contract files and 168 package-source files. It uses only
generated build metadata and the unchanged root-pinned package versions:
`argv@1.1.0`, `filepath@1.1.2`, `gleam_erlang@1.3.0`, `gleam_json@3.1.0`,
`gleam_otp@1.3.0`, `gleam_stdlib@1.0.5`, `gleeunit@1.11.0`,
`simplifile@2.7.0`. `SOURCE_RECEIPT.json` records each exact input's bytes/SHA;
there are no source stubs, overlays or rewritten domain logic.

First-slot actual history, retained under `build/f04-validation-logs`:

| Log | Result |
| --- | --- |
| `01-format.log` | Owned Gleam paths formatted |
| `02-check.log` | Compile setup failures: actor callback argument order and `Down.monitor` API |
| `03-format.log`, `04-check.log` | Setup corrected; test compile failures: list generation / `argv.Argv.arguments` API |
| `05-format.log`, `06-check.log` | Exact closure check passed; two unused test-return warnings |
| `07-offline.log` | Six dedicated offline tests passed |
| `08-execution.log` | First six injectable execution/lifetime tests passed; buffered loopback failed `ReadFailed != Completed`; stop, no retries |

The parent-approved source-only correction replaces grapheme-count trimming
with exact terminal CRLF parsing at both header and chunk-size call sites.
`string.drop_end(..., 2)` operates on **graphemes**, not bytes, and CRLF is one
grapheme. A dedicated pure regression now checks final header characters,
decimal lengths, zero/single/multiple hex digits and malformed delimiters.
The next parent-granted slot confirmed the diagnosis with the original
buffered/SSE/CLI assertions unchanged.

Corrected-byte validation, same pinned Gleam toolchain and
`ERL_FLAGS='+S 2:2 +A 2'`:

| Log | Actual result |
| --- | --- |
| `09-crlf-format.log` | Owned paths formatted |
| `10-crlf-check.log` | Exact closure `gleam check`: passed, no warnings |
| `11-crlf-offline.log` | `gleam run -m live_test`: all seven offline cases passed |
| `12-crlf-execution.log` | `gleam run -m live_execution_test -- <explicit-private-fixture-dir>`: all ten execution/socket/lifetime tests and the actual production synthetic CLI workflow passed |

Actual CLI report in `12-crlf-execution.log`:

- One request reserved, sent and `transport_completed_not_a_parity_pass`.
- 89 input / 32 output tokens reserved; **274 synthetic nano-USD** retained.
- A two-byte `{}` fixture response; usage and observed cost remain `null`.
- The explicit new-ID retry is denied `live_budget_exhausted`; reusing the
  original ID is denied `live_expired_or_duplicate_attempt`.
- Final lifecycle is `operator_closed`; running identity is `unverified`,
  differential/native/live are `not_run`, F01 assertions are `not_evaluated`.
- Exact created private-file inode tokens removed both CLI fixture files.
  The fixture state directory is empty and all validation commands/BEAMs exited.

All 15 historical copied source/test/contract input hashes matched the tested receipt;
all 168 pinned dependency-source files were verified unchanged. The final
`SOURCE_RECEIPT.json` SHA256 is:

```text
1af237ca0d6341168a14cf4a113f1a3f3e8d7e86233981a3465b4a38cd5fbdda
```

This is a historical source-input receipt, not validation of the review bytes,
native/live containment or running candidate/reference identity. **No full
`gleam test` gate was authorized or run.** Root composition/full-suite validation
remains parent-owned. The review closure must additionally include the unchanged
shared `mimic/protocol/sse` and `mimic_responses_bytes_ffi` sources, without stubs
or logic overlays.

Dedicated checks cover exact F01-byte binding; typed live/native failclosed;
unknown/mismatched routes/prices/ceilings; body authority; every independent
budget dimension; reservation-before-send; eight concurrent callers competing
for one cost reservation; pre/post-send failure; duplicate/retry denial;
cancellation/timeout without refunds; unknown usage/cost; known ceiling breach;
response/chunk limits; owner death and bounded retirement. The actual loopback
harness covers buffered JSON, chunked SSE, captured synthetic request authority,
post-send disconnect, timeout, the unqualified old socket-close oracle, no replay, redirects, compression,
binary media, oversized and ambiguous framing. All fixture orchestration is
Gleam, OS socket primitives only in Erlang.

Still required for F04 live acceptance:

- Actual F02 operator-approved launcher, kernel/network/filesystem/resource and
  lifetime/cleanup qualification; a reviewed admission capability bound to that
  execution, not a supplied digest/boolean.
- F03 independently verified running reference and exact candidate identity.
- Explicit operator-selected real account/endpoint/scenarios/data permission,
  verified route/token ceiling/pricing, exclusive budget/ledger ownership and
  reviewed credential-injection/transport cancellation boundary.
- Synthetic runtime validation first, then separately approved bounded live
  acceptance; none of these are inferred from synthetic completion.
