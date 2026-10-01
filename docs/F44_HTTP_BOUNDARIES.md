# F44 — HTTP/1 request boundary ownership

**Baseline owner result: implemented and focused-tested; coordinator
admission/fullgate still required. Independent-review follow-up: scoped
format/build, 19 socket tests and eight Python controls pass; historical-source
red and composed/full gates remain unverified (see below).**
This is synthetic localhost evidence, not CPA differential,
native-client, TLS-fingerprint, benchmark, live-provider or release qualification.

Starting revision: `dd15c610ec39e4f296c30fe02347d0d2b368a629`. Dependencies:
vendored Mist 6.0.3, glisten 9.0.1, Gleam 1.18.1 and local OTP 29. Root gateway,
CLI, configuration, auth, FFI, dependencies, CI and other features are unchanged.
No children, Git/JJ mutations, commits or publication were performed.

## Delivered rule

Each HTTP/1 request owns exactly its framed body. The connection loop owns
everything after that boundary and dispatches it only after sending the previous
response. This is independent of method or route:

- No `Content-Length` and no transfer coding means an empty body, not all bytes
  after the headers. A validated fixed length splits buffered body from tail;
  subsequent socket reads request only the missing body bytes.
- Nonempty fixed/chunked bodies use `Body.Framed(data, completion, permit)`.
  These are fresh request-local subjects in the existing connection process,
  not a new actor, registry, credential manager or global mutable state.
  The permit makes completion one-shot. Repeated terminal stream tokens do
  not read another request or duplicate completion messages.
- `Http1Request` carries the already-buffered tail as a third internal field.
  `http_handler.call` returns `#(State, BitArray)`; the outer loop consumes that
  tail serially and cancels intermediate idle timers.
- A route that rejects a body or returns before consuming it through completion
  gets `Connection: close`. This includes fully coalesced unread bodies.
  There is no pre-dispatch whole-body buffering or post-rejection unbounded
  drain. Explicit request closure and ordinary HTTP/1.0 closure are respected.
- `mist.read_body` and `mist.stream` share the incremental reader. Chunked
  decoding consumes the terminal CRLF and benign trailers, preserves the
  exact following request, and rejects malformed size/data terminators.
  Caller limits are enforced cumulatively before each chunk's data is read.
  Streaming chunked input has a 64 MiB ceiling; size/trailer lines have an
  8192-byte ceiling and cumulative size-line/trailer metadata is capped at
  65536 bytes. HTTP/1 body readers have a 15-second absolute socket-read
  deadline, not a timeout reset by each received fragment.

Raw singleton validation now also covers `Origin`, `X-CSRF-Token`, `Cookie`,
`Content-Length` and `Transfer-Encoding`, before the header Dict collapses
duplicates. CL/TE coexistence is rejected in either order. Content length must
be nonempty ASCII decimal digits (surrounding HTTP OWS and leading zeroes are
accepted). Negative, signed, comma-list and malformed lengths are rejected.
Only a single `chunked` transfer coding is supported, case-insensitively;
other codings and coding lists fail before any route dispatch.

## Compatibility seam

The original five-element Erlang `Connection` tuple is unchanged. This is
required by the existing custom gateway WS socket FFI's positional match.
Public `mist.read_body`, `mist.stream`, builder and handler signatures are
unchanged. Internal `http.read_body` now also takes the limit, and
`DecodeError.BodyTooLarge` maps to the existing `mist.ExcessBody`.

Zero-body HTTP/1 remains `Initial(<<>>)` even with a buffered next request.
WebSocket upgrade remains `Initial(rest)` so the custom gateway's handoff retains
coalesced frame bytes. Built-in Mist WS now also forwards those bytes to its
new owner after socket takeover, including complete and split first frames.
HTTP/2 remains `Stream`; its callback denial is not confused with `Framed`.
Built-in WS rejects an HTTP request body rather than treating it as WS frames.

The root auth callback has a fallback for `Framed`, so no executable root hook
is necessary. Nonempty callback bodies are rejected with 400, not the H2-only
505. The coordinator should narrow its old comment in `src/mimic/auth.gleam`
claiming `Initial` for all HTTP/1 to **zero-body HTTP/1**.

## Actual focused evidence

Final ABI-preserving candidate:

| Gate | Observed result |
| --- | --- |
| `gleam format --check src test` plus all changed vendor Gleam files | exit 0 |
| `gleam run -m f44_http_boundary_test` | exit 0, 14 tests, about 20 seconds including the real 15-second deadline probe |
| Five existing H1/H2 OAuth callback regressions + six existing Mist boundary tests | exit 0, all 11 |
| Six Python controls for raw smoke serialization/response parsing | exit 0 |
| Root CLI F44 raw socket smoke | exit 0, 646 cases |
| Freshly exported shipment F44 raw socket smoke | exit 0, 646 cases |
| Existing custom gateway WS root smoke | exit 0 |
| Existing custom gateway WS shipment smoke | final direct run exit 0; see failed history below |
| Smoke SIGHUP interruption probe | exit 129, synthetic child stopped, runtime ownership released, temporary state removed |
| `git diff --check` | exit 0 |

The F44 socket tests compare exact handler bodies, dispatch observations and
response order. They exercise sequential/coalesced GET/GET and POST/GET,
every two-part byte split for GET, fixed read/stream and chunked read/stream,
three requests in one write, trailers, one-shot terminal tokens, raw security
rejection with **zero dispatch**, size/unread-body closure, HTTP/1.0, coalesced
OAuth callback cleanup, and built-in WS complete/partial first-frame handoff.

Each root/shipment smoke includes 238 GET/GET and 387 POST/GET split positions,
plus controls, fully coalesced requests, chunked body/trailer tail, ambiguous
raw security/framing headers with zero HTTP response/no upstream request,
HTTP/1.0 and immediate size-guard rejection. Upstream normalized POST bytes
must equal the sequential control exactly. Synthetic keys are checked absent
from responses/CLI logs, and normal runtime-owner cleanup is asserted.

### Failed-run history (not waived)

1. Before vendor changes, the new socket suite had 1 pass / 10 failures.
   Sequential controls passed; coalescing timed out or threw `FunctionClause`,
   chunk tails/WS frames disappeared, and ambiguous/security requests dispatched.
2. An intermediate added `Connection.boundary` field compiled and passed the
   HTTP tests but broke the real custom gateway WS tuple FFI. It was removed;
   the final `Framed`/`Http1Request` design preserves that ABI. No root FFI edit
   was made.
3. Adding a repeated terminal-token test exposed re-reading of chunked socket
   data. The one-shot completion peek now returns `Done` without another read.
4. The initial root smoke fixture incorrectly omitted Claude's actual
   `?beta=true` target query. The fixture was corrected against source; no
   production route workaround was introduced.
5. One run failed before tests at Mist clock `init_timeout`. Subsequent serial
   runs use `ERL_FLAGS='+S 2:2'`; this startup failure is not test-pass evidence.
6. One combined 120-second command was interrupted midway through shipment
   HTTP smoke. Only the identified synthetic child was shut down, its state
   was removed, and the shipment gate was rerun independently to completion.
   The new smoke now handles SIGINT/SIGTERM/SIGHUP via normal cleanup.
7. One ABI-preserving shipment custom-WS run received 101 but timed out on its
   first event. A test-side instrumented replay passed (one upstream handshake,
   one create), then the unmodified shipment WS script passed. The first
   timeout's cause remains **unclassified**, not declared a preexisting flake.
   The coordinator's assembled WS gate must retain this history.

## Rerun / coordinator gates

Run these serially. Allow 180 seconds per full F44 HTTP smoke rather than
combining both modes and compilation into a single short terminal deadline.

```sh
export GLEAM="$(mise where gleam@1.18.1)/gleam"
export ERL_FLAGS='+S 2:2'

"$GLEAM" run -m f44_http_boundary_test
python3 -m unittest discover -s scripts -p 'test_smoke_f44_http_boundary.py' -v
python3 scripts/smoke-f44-http-boundary.py
"$GLEAM" export erlang-shipment
python3 scripts/smoke-f44-http-boundary.py --shipment build/erlang-shipment
python3 scripts/smoke-provider-websocket.py
python3 scripts/smoke-provider-websocket.py --shipment build/erlang-shipment
```

`--boundary-splits-only` is an optional quick smoke, not a substitute for the
default all-split qualification. The parent owns final `gleam test`, the full
integration gate, root/CI registration of the two new HTTP smoke invocations,
destination hash verification and the F44 status in the wave document.

Existing focused callback/Mist regression command after a dev compile:

```sh
erl +S 2:2 -pa build/dev/erlang/*/ebin -noshell -eval '
{ok,_} = application:ensure_all_started(mimic),
Tests = [
 fun auth_test:first_valid_callback_response_finishes_before_listener_shutdown_test/0,
 fun auth_test:http2_callback_is_rejected_without_consuming_login_test/0,
 fun auth_test:callback_only_timeout_rejects_duplicates_and_closes_listener_test/0,
 fun auth_test:http1_callback_still_works_after_http2_denial_test/0,
 fun auth_test:loopback_callback_state_path_and_token_exchange_test/0,
 {module, mist_boundary_test}],
case eunit:test(Tests, [verbose, {scale_timeouts, 10}]) of
 ok -> halt(0); _ -> halt(1) end.'
```

## Boundaries / unverified work

Only ordinary HTTP/1 Bytes/File-response pipelining is resumed by this loop.
SSE/chunked response handoffs keep their existing separate lifecycle; this
slice does not promise subsequent HTTP requests while such a response is active.
WS upgrade deliberately transfers the remaining bytes to its new protocol owner.
Trailer authority/framing fields are rejected; benign trailers and chunk
extensions are consumed as metadata, not exposed as a new application API.
Body stream tokens are forward-only and are consumed synchronously by the
request handler; terminal tokens are safe to repeat.

General HTTP/2 parsing, TLS transport, native clients, CPA comparisons, live
providers, full application suites and final assembled release qualification
were not run by this worker. Existing HTTP/1.0 Host-header policy is unchanged.
No live accounts, endpoints or real secrets were used.

## Baseline owned source SHA-256

These hashes describe the previously focused-tested F44 baseline, not the
independent-review follow-up below. Import the whole owned patch together; no
guessed dependent API or root patch is needed. HEAD remains the starting revision
by explicit no-commit instructions.

```text
a0824127a27df0c7f56b17a8ced55874e46c080615a2f494cc86f44a4bda4790  vendor/mist/src/mist.gleam
caac078035f1525cf7666ee93cab8ebbb0fb2b3be5b061fe11f62026e7dcb785  vendor/mist/src/mist/internal/handler.gleam
c3870881dbf0ab40b9bd6b7a4838bcebc48be2149b6c5a55ea5a512772796af2  vendor/mist/src/mist/internal/http.gleam
152e07268760627c8ebcdb2a1940f1f0075d264faa2f20959bf9e9ba6c05970e  vendor/mist/src/mist/internal/http/body.gleam
9f670aae47d7b494ba7da267383c18eeb30bce74baf58be82c06918c3c95400a  vendor/mist/src/mist/internal/http/handler.gleam
65902c489196e0ef058517e664ee7a6da7a8ca5a6a99fa81f0836466830818db  vendor/mist/src/mist/internal/websocket.gleam
1a718152155ee767dcc72137b10153b092c3f6b90671a135ad0fdf1810163b50  vendor/mist/src/mist_ffi.erl
9823609ec072a68b7212e72c4ea8216788bf709fb817d7d8f988903ec5abc820  test/f44_http_boundary_test.gleam
57c1d2a31f33f4783f2143177b9a6efdd74953f20142eacc10dfdef60b0d50c6  test/mimic_f44_http_boundary_test_ffi.erl
52ad2af49d9013a05a55b4ecb3ac079328ce15da4ac72482556bf67790abc9f2  scripts/smoke-f44-http-boundary.py
b8436462a1c83463e0bdb9d019db9bd0f5158e481d1cb57338f38752c6f23b4a  scripts/test_smoke_f44_http_boundary.py
```

## Independent-review follow-up

**Status: scoped format/build, 19 socket tests and eight Python controls pass.
Historical-source red setup stopped at its baseline hash guard; no red tests
ran. Parent/worker overlap is possible, so this is passing assertion evidence,
not globally exclusive timing qualification. No more worker gates are pending.**
The earlier evidence table remains historical baseline evidence. It does not
qualify this follow-up. All compiler, BEAM, socket, browser and workflow runs
require the coordinator's validation slot; the final heavy gate remains the
parent's responsibility. No root source/build/CLI/CI changes are part of this
follow-up.

### Four corrected rules

1. **WS byte ownership and rejection share HTTP OWS recognition.**
   `internal/http.gleam` now uses the same predicate for `frame_body` and
   `body_tail`: trim only ASCII SP/HTAB, then compare `websocket`
   case-insensitively. Thus `Upgrade: websocket\t` still produces
   `Initial(retained_bytes)`, and an ordinary response rejecting that upgrade
   closes rather than interpreting the bytes as another HTTP request. The
   raw Upgrade value exposed to handlers is not rewritten.
2. **Every built-in WS selector retains the internal subject.**
   `internal/websocket.gleam` stores the immutable socket/internal-subject
   selector in WS actor state. Initial selection and both user-message and
   frame-handler replacement paths merge user selectors with that base.
   `None` continues to mean keep the current selector. This does not extend the
   HTTP `Connection` tuple or change public `mist.websocket` APIs.
3. **Connection close is a token-list decision, never last-field-wins.**
   Request parsing joins repeated `Connection` fields with `, ` in arrival
   order. One shared SP/HTAB-trimming, case-insensitive token predicate checks
   all request/response Connection fields, so `close` wins in either field
   order, including response `Close` or `keep-alive, close`. Singleton
   security/framing rejection and unrelated header handling are unchanged.
4. **One bounded head, independent of TCP fragmentation.**
   Each `parse_request` creates a private head budget shared by request-line
   and header parsing:
   - **65,536 raw bytes**, including the request line, raw field bytes and CRLF
     separators/end-of-headers. Accounting uses decoder input minus remainder,
     not normalized string lengths; coalesced body and next-request bytes are
     excluded.
   - **100 raw fields**, including Host and repeated non-singleton fields.
     Count is advanced before insertion into the Dict.
   - **15,000 ms absolute monotonic deadline**, starting when parsing the first
     request bytes, not a fresh deadline per read or per phase. Remaining time
     is clamped to zero and checked before receive; negative monotonic clock
     origins are valid. Every subsequent request gets a fresh budget.

   `packet_size` bounds the decoder's unfinished raw packet; MoreData cannot
   grow past the remaining head budget. Head size/count/deadline failures close
   before route dispatch using existing DecodeError variants. Public
   `parse_request`/`parse_headers` signatures, public body readers and the
   five-element Erlang `Connection` ABI are unchanged. The legacy `read_data`
   API remains available but is no longer used for request-head parsing.

The explicit 64 KiB/100-field bounds allow sizable ordinary headers while
bounding total parsing/memory and field-processing work; unlike a per-line
limit they also reject many individually small fields. Reusing the existing
15-second body-read duration avoids another timeout concept, but head and
body each have their own phase-local absolute deadline. These are supported
boundaries, not measured claims about any provider's maximum headers.

### New regression coverage

Dedicated `f44_http_boundary_test` additions assert actual loopback behavior:

- Complete and split first WS frames with trailing HTAB and mixed-case SP/HTAB
  Upgrade values; rejected OWS upgrades with a valid coalesced HTTP tail must
  produce only the first response/dispatch.
- A custom message is queued during `on_init`. Its handler waits on a subject
  barrier until `mist.websocket` returns, proving socket takeover and retained
  bytes were queued. Releasing the handler installs a replacement selector
  before those bytes are handled. Exact echo, replacement custom-message
  delivery and a second frame-handler selector replacement are asserted.
  A PID-scoped temporary Erlang logger handler observes only a boolean
  unknown-message event; it does not store or forward payload/credential data.
- Duplicate request Connection fields in both orders, response `Close` and
  mixed-case close token lists, duplicate response fields in both orders, and
  a legal repeated-field keep-alive control, all with pipeline tails.
- Exactly 65,536 bytes and exactly 100 fields pass coalesced/fragmented input;
  the next byte/field fails with zero dispatch. Incomplete long request/header
  lines also close. Body/tail exclusion and separate near-limit heads on one
  connection are checked. Every ordinary handler checks the five-element ABI.
- A real 15-second head deadline probe makes successful progress at 6, 10 and
  14 seconds, crossing request-line/header phases, yet must close before
  17.5 seconds with zero dispatch. A subsequent connection is a normal control.

The dedicated root/shipment HTTP smoke adds close precedence, rejected OWS
upgrade closure and exact/over head limits, including fragmented input and
zero synthetic-upstream requests on rejected heads. Two additional Python
controls check raw field/OWS preservation and exact wire-byte fixture sizing.
Smoke/probe assertions were not weakened. Focused assertions passed as recorded
below; execution of the updated root/shipment smoke remains parent-owned.

### Executed follow-up evidence and failed-attempt history

- Scoped `gleam format` and `gleam format --check` with Gleam 1.18.1 and
  `ERL_FLAGS='+S 2:2 +A 2'` both exited 0. Exact (empty successful) logs are
  `build/integration/f44-review/format.log` and `format-check.log`.
- The initial slot command subsequently exited 1 during setup inspection:
  `ls: build/packages: No such file or directory`. The parent's read-only
  package cache exists. The slot was released at that nonzero command; no
  build, BEAM/socket test, Python control or red regression ran. The exact
  combined output is retained in the validation terminal transcript.
- A renewed slot copied that cache read-only and ran `gleam build`, which
  compiled Mist but exited 1 during test compilation: `Unknown type for record
  access` on `retained_frame(req.body)` in the new WS barrier handler. Exact
  log: `build/integration/f44-review/build.log`. The slot was released. An
  explicit `Request(Connection)` parameter annotation was added source-only;
  no assertion was changed. The next attempt compiled and tested that correction.
- Before import, read-only hashes of the parent's pre-review `http.gleam`,
  `http/handler.gleam` and `websocket.gleam` matched the historical hashes above.
  Those bytes were **not saved to disk** before the parent source changed.
- Scoped `git diff --check` exited 0 before formatting.

The latest worker root is
`/Users/jerryjohnson/dev/mimic/.delta/worktrees/3bj7m5c581y4/mimic`.
Exact unique attempt logs are under
`build/integration/f44-review/attempt-3.l2JlnC/`:

| Gate | Actual result | Log |
| --- | --- | --- |
| Scoped `gleam format --check` | exit 0 | `format-check.log` |
| `gleam build` | exit 0 | `build.log` |
| Dedicated F44 socket suite | exit 0, all 19 tests pass | `socket-tests.log` |
| Python smoke controls | exit 0, all eight tests pass | `python-controls.log` |
| Historical-source copy guard | exit 1, changed parent source hash; stopped before copy/red compile/tests | `red-baseline-copy.log`, `status.txt` |

The socket log records 34.176 seconds for the suite, 15.005 seconds for the head
deadline assertion and 15.002 seconds for the existing body deadline assertion.
These are actual logged durations, **not globally exclusive timing or benchmark
qualification**: the parent reports that completion/slot reassignment may have
overlapped parent composed validation and worker execution. The passing
assertions remain evidence; resource/timing exclusivity is not claimed.

Attempt 3 used an atomic per-worker `validation.lock` directory around the
entire sequence plus a permanent `attempt-3.claim` to reject accidental
re-execution, and unique logs. It stopped at the first nonzero setup gate and
released the lock. No later worker gate or deferred test task will run.

The red guard expected the historical HTTP source SHA-256
`c3870881dbf0ab40b9bd6b7a4838bcebc48be2149b6c5a55ea5a512772796af2` but observed
`756ef628d9b6e88f07996620bf4ea587e5d35a0c6ca6f8342f64ee5b13a43dfc` after parent
auto-import. The isolated `red-project` contains corrected-source copies, not
the historical baseline: **no original-code red regression was executed**.
Do not label that directory or setup failure reproduction evidence, use older
Git HEAD as a substitute, or reconstruct the baseline loosely.

### Slot-gated validation plan and limitations

Once the coordinator grants a slot, run serially with the pinned toolchain:

```sh
export ERL_FLAGS='+S 2:2 +A 2'
mise exec gleam@1.18.1 -- gleam format --check \
  vendor/mist/src/mist/internal/http.gleam \
  vendor/mist/src/mist/internal/http/handler.gleam \
  vendor/mist/src/mist/internal/websocket.gleam \
  test/f44_http_boundary_test.gleam
mise exec gleam@1.18.1 -- gleam run -m f44_http_boundary_test
python3 -m unittest discover -s scripts -p 'test_smoke_f44_http_boundary.py' -v
```

Demonstrate the new assertions red against the original pre-review F44 sources
in an isolated project if practical; do not revert the shared workspace or use
the older Git HEAD as a substitute for the uncommitted F44 baseline. Only a
run against that baseline is executed reproduction evidence. Parent-owned
`gleam test`, assembled integration, root/shipment smoke and existing custom
gateway WS gates still apply. Do not attribute the historical unclassified
custom WS shipment event timeout to these four findings.
