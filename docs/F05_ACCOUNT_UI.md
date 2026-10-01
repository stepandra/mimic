# F05 — operational Kimi account UI

## Implemented scope

The loopback operator page performs real Kimi device start/poll/cancel/expiry
orchestration through the existing Kimi OAuth library, and installs its grant
with the existing S5 runtime store. It does not create a credential manager,
start a gateway runtime, copy CPA grants, or configure CPA. F06/F07 are not
implemented here.

Recovered from the prior F05 UI checkout associated with Delta thread
`ksQQb9FLfzOvROCTHSjh0BOwgJLOAFQ2MZIBxBDu1fs15rdKs6m5jRdeJnRz`,
then compiled and revalidated on baseline `dd15c610ec39e4f296c30fe02347d0d2b368a629`.
Historical instructions and results were not executed or treated as new proof.

Owned implementation:

- `src/mimic/account_ui.gleam`: CLI and testable loopback server lifecycle.
- `src/mimic/account_ui/coordinator.gleam`: one operator session and one active
  cancellable enrollment; the only UI grant-commit owner.
- `src/mimic/account_ui/http.gleam`: bounded, same-origin operator HTTP API.
- `src/mimic/account_ui/page.gleam`: local HTML/CSS/JS presentation; no CDN,
  embedded capabilities, provider secrets, or frontend dependency changes.
- `src/mimic/account_ui/primitives.gleam`: bindings to existing crypto,
  private-file, atomic mutation, and signal primitives.
- Dedicated `account_ui*_test.gleam`, `mimic_account_ui_test_ffi.erl`, and
  `scripts/smoke-account-ui*.py` tests.

## Compiled API and use

```gleam
cli(args: List(String)) -> Result(String, String)
start(settings: Config, private_identity_path: String, port: Int)
  -> Result(Server, String)
stop(server: Server) -> Result(Nil, String)
port(server: Server) -> Int
bootstrap_path(server: Server) -> String
start_with_transport(settings, private_identity_path, port, send: oauth.Send)
  -> Result(Server, String)
```

The transport-injection seam is for synthetic tests. The production CLI always
uses `gateway/refresh.kimi`, including its configured endpoint, bounded HTTP
response, timeout, TLS, and no-redirect policy.

Command after parent root admission:

```text
mimic accounts ui serve CONFIG PRIVATE_DEVICE_IDENTITY PORT
```

`CONFIG` is loaded by the existing gateway loader. It supplies an explicit
private `state_dir`, Kimi OAuth accounts, models, origins, and OAuth endpoints.
The UI accepts at most 64 Kimi OAuth accounts with unique, nonempty IDs of at
most 256 bytes. No provider, endpoint, identity, or credential can be supplied
through the page. Non-Kimi accounts are not exposed or enrolled by F05.

`PRIVATE_DEVICE_IDENTITY` must be an absolute, nonsymlink, regular 0600 file
containing only `{"device_id":"<existing device identity>"}`. The UI neither
invents an identity nor accepts it in argv. `PORT` is an explicitly selected
decimal number from 1 to 65535; the listener always binds `127.0.0.1`.

The CLI prints the loopback URL and **path only** of a newly created 0600
bootstrap file in the configured 0700 state directory. Read that file locally
and enter its one-time code into the password field. The code expires after
five minutes and is consumed and deleted before session issuance. The
operator session lasts at most 30 minutes; ending it or reloading/leaving the
page requires restarting the UI to unlock again. SIGTERM performs joined
listener, workflow, and bootstrap cleanup. Feature modules never exit the VM.

Production startup, real state paths/ports, real provider/account access, and
live-provider qualification still require operator approval. None was exercised
by this implementation's tests.

## Security and enrollment rules

- Every API action requires exact `Host: 127.0.0.1:<port>`, the same exact
  `Origin`, JSON content type, and `X-Mimic-UI: 1`.
- Every post-bootstrap action binds a random HttpOnly, SameSite=Strict session
  cookie to a separate in-memory `X-CSRF-Token`. Neither is accepted as a
  provider credential. There is no CORS relaxation or remote bind option.
- Bodies require canonical bounded Content-Length (1–1024 bytes), valid UTF-8,
  bounded strict JSON, and the exact action schema. Chunked input, unknown
  fields, duplicate JSON keys, queries, and unsupported actions fail explicitly.
- Unauthenticated traffic shares a 20-request/second admission budget. The
  bootstrap exchange has a one-second cooldown and at most eight failed tries.
  One bounded roster, one session, and one active attempt are retained; there is
  no accumulating login history or second grant cache.
- `runtime_store.begin_enrollment` succeeds **before** provider I/O. Only the
  coordinator can call `commit_enrollment`. Workers return private material
  and never call `save`. Cancel, expiry, logout, and graceful stop compete with
  the exact S5 ticket before killing linked blocking network work.
- Same-token admin save, replacement, deletion, refresh, or winning cancellation
  defeats an older ticket. A mutation error is reported as
  `installation_unconfirmed` or `cancellation_unconfirmed`, never as a promise
  of rollback or permission to overwrite unconditionally. Existing credentials
  are retained on successful cancellation with a new generation, not revoked.
- Abrupt whole-VM loss preserves S5's fail-closed pending reservation semantics;
  there is no new TTL takeover or automatic unconditional recovery.
- Provider device codes/identity and access/refresh/session credentials never
  enter assets, DOM, UI response JSON, URL state, client storage, or logs. The only provider prompt
  shown to the authenticated operator is the validated bounded verification
  URI and transient user code. Links have noopener/noreferrer/no-referrer.
- Prompts are cleared on cancellation/expiry/logout/backgrounding/navigation.
  Generation-bound JS continuations cannot resurrect an old prompt/session or
  run a stale button under a newer capability. Unchanged status polls preserve
  button identity rather than steal keyboard focus.
- Static and API responses are no-store, no-referrer, nosniff, frame-denied,
  with same-origin-only script/style/connect CSP.

### Required raw parser admission

Baseline `dd15c610` Mist collapses duplicate fields into a Dict before handing
them to Gleam HTTP. Handler-side singleton checks cannot reconstruct that lost
multiplicity. The parent-owned F44 vendor patch must reject raw duplicate
Origin, X-CSRF-Token, Cookie, Content-Length, Transfer-Encoding (as well as its
existing Host/auth/WS singleton rules), and both orderings of CL/TE coexistence
**before dispatch**. Do not waive this dependency or call baseline security
green. Content-Type duplicate behavior remains report-only in the raw fixture;
strict JSON/body validation is not evidence of raw multiplicity rejection.

The dedicated `raw_header_ambiguity_must_close_before_operator_actions_test`
retains the known-red baseline. It is separate from ordinary UI/security tests
so the vendor failure does not hide body/schema/session negatives. Actual
zero-handler-call instrumentation and the coalesced pipelining correction
remain in the parent's exclusive vendor lane, not in account UI source.

## Parent-owned root hook

Root admission needs only dispatch/help changes; the feature API needs no
gateway/config/dependency/CI change. Required vendor changes are independently
owned by F44 as described above:

```gleam
import mimic/account_ui
```

In `mimic.dispatch`:

```gleam
["accounts", "ui", ..args] -> account_ui.cli(args)
```

Suggested help row:

```text
  accounts ui  Loopback Kimi account enrollment (explicit config/identity/port)
```

The existing root supplies error exit policy. The independent module `main`
supports the same `accounts ui` prefix for source proof without pretending
root admission has occurred.

## Executed qualification

All runtime fixtures were synthetic, private, and inside this attached
worktree's ignored `build` directory. Providers/gateway/UI bound loopback only.
No real provider, account, CPA service, stored credential, or browser profile
was accessed. No root/vendor/config/dependency/CI source or Git/JJ ref was
mutated.

| Command | Observed result on dd15c610 |
| --- | --- |
| `TMPDIR="$PWD/build/account-ui/tmp" mise exec gleam@1.18.1 -- gleam build` | PASS; compiled feature/server/CLI and dedicated tests |
| `mise exec gleam@1.18.1 -- gleam format --check src/mimic/account_ui.gleam src/mimic/account_ui test/account_ui_test.gleam test/account_ui_coordinator_test.gleam` | PASS |
| `TMPDIR="$PWD/build/account-ui/tmp" mise exec gleam@1.18.1 -- gleam run -m account_ui_test` | **12 PASS / 1 FAIL**; raw duplicate Origin returned 200, expected peer close/0; vendor dependency retained, not skipped |
| `python3 scripts/smoke-account-ui.py` | PASS; actual source UI CLI and root gateway, start 7 / poll 4 / refresh 1 / chat 2 |
| `python3 scripts/smoke-account-ui-presentation.py` | PASS, six served-JS deterministic out-of-order/focus cases; not browser evidence |
| `python3 scripts/smoke-account-ui-browser.py` | PASS, actual local Chrome via agent-browser; start 3 / poll 1 / refresh 1 / chat 1 |

The source CLI smoke starts the existing gateway **before** UI enrollment.
That gateway consumes the installed expiring grant, refreshes it through its
existing runtime, saves rotation, and a fresh gateway process reuses the saved
grant without reseeding or a second refresh. It also proves real socket
blocked-start/poll cancellation, admin replacement/deletion, device expiry,
graceful shutdown, restart session invalidation, and absence of secret values
in public output and process logs.

Browser proof exercises unlock, actual login prompt/link, cancel, grant
completion, actual gateway request/refresh, expiry preserving prior material,
and logout. A fresh restricted Chrome context uses sanitized environment,
private HOME/TMP/socket directories in the worktree, and a 127.0.0.1-only
browser allowlist. Screenshots were inspected at desktop and 390×844; no
horizontal overflow was observed. Axe 4.12.1 reported 29 passes, zero
violations, zero incomplete checks. Page console/errors were empty; bootstrap
input cleared, document.cookie empty, client storage empty, and provider
private sentinel values absent from DOM.

Retained local evidence:

- `build/account-ui/focused-baseline.log`, `focused-final.log`
- `build/account-ui/source-cli-gateway.log`, `presentation.log`,
  `browser-proof.log`
- `build/account-ui/browser-proof/`: locked/unlocked/waiting/cancelled/stored/
  expired/mobile/ended full-page screenshots, accessibility trees, axe report,
  and browser transcript. Transient codes in screenshots are **synthetic**.

### Gates not claimed here

- Passing raw singleton/CLTE security depends on parent's F44 admission.
- Actual **root UI** dispatch remains a distinct post-hook gate:
  `python3 scripts/smoke-account-ui.py --root-ui`,
  `python3 scripts/smoke-account-ui-browser.py --root-ui`.
- `python3 scripts/smoke-account-ui.py --root-ui --raw-header-report` checks the
  application over the admitted parser; it does not replace instrumented vendor
  zero-dispatch tests.
- Full `gleam test`, shipment, and full integration gates were deliberately
  not run concurrently with the parent's serialized heavy gate. The focused
  runner executes only these two dedicated EUnit modules; standard gleeunit
  discovery has no module-selection option.
- No live Kimi/source-reference differential/provider-parity result is implied
  by the operational synthetic tests.
