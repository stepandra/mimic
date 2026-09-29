# K5 Kimi wire-v1: synthetic loopback observation

This is an **assembled CLI HTTP/1.1 observation**, not a live Kimi capture,
upstream fingerprint, CPA differential, or proof of upstream compatibility.
The dedicated [test](../../test/kimi_wire_test.py) imports the startup,
shutdown, private-file and synthetic SSE helpers from
`scripts/smoke-http-providers.py`/`scripts/smoke-gateway.py`; it does not use
provider internals or a new feature hook. Both gateway and configured upstream
bind `127.0.0.1`. It starts the gateway with `gleam run -- providers serve
providers <config>` and imports a client key plus a selected Kimi account
credential through the existing `providers key import` / `providers credential
import` CLI. The first configured account is deliberately absent, with an
unreachable origin and wrong base path; the selected second account provides
the credential, origin and `/operator/kimi` base path.

Run from the repository root:

```sh
PYTHONDONTWRITEBYTECODE=1 GLEAM=gleam python3 -m unittest discover -s test -p 'kimi_wire_test.py' -v
```

If Gleam is installed with mise but not on `PATH`, replace `GLEAM=gleam` with
`GLEAM="$(mise where gleam)/gleam"`. The test uses temporary private state and
credential files under `build/integration`, removes them on completion, and
does not contact either Kimi domain. Only the OAuth **domain label** differs
between the `kimi.com` and `kimi.ai` cases; their explicitly configured token
URLs point to the same loopback fixture server. API-key mode has no token
exchange. OAuth starts with an expired synthetic grant, observes one loopback
refresh, then sends the refreshed bearer token and device header.

## Observed and checked

- [Immutable, redacted API-key snapshot](../../test/fixtures/kimi/v1/wire-snapshot.json)
  and [SHA-256 manifest](../../test/fixtures/kimi/v1/manifest.json) capture the
  upstream request target, ordered raw header pairs (case and duplicates are
  retained), decoded JSON bodies, gateway response header pairs, buffered
  Chat/Responses bodies and parsed Responses SSE `response.created` followed
  by `response.completed`. The manifest digest is checked before comparison.
- The handler reads `self.headers.raw_items()`, not `dict(self.headers)`.
  Inference requests observed `Host`, `Authorization`, `Content-Type`,
  `Accept`, `Accept-Encoding`, `Content-Length` in that order and case.
  OAuth adds `X-Msh-Device-Id` last. The OAuth token POST has its own observed
  raw header order and form body; both `.com` and `.ai` cases are checked
  against the API-key snapshot plus exactly that extra device header, with the
  same downstream bodies/events.
- Bearer values, refresh material, client key and device ID are checked
  transiently against **synthetic** inputs and recorded only as redacted
  values plus match booleans. The dynamic loopback port and HTTP Date are
  normalized. Gateway output is discarded (never logged); CLI output, response
  payloads and fixture are checked before any assertion can print an observation.
  This protects known fixture values, not arbitrary secrets: do not run with
  real credentials.

On this checkout, the equivalent command using the explicit installed Gleam
binary passed: `PYTHONDONTWRITEBYTECODE=1
GLEAM=/Users/jerryjohnson/.local/share/mise/installs/gleam/1.18.1/gleam
python3 -m unittest discover -s test -p 'kimi_wire_test.py' -v` reported
`Ran 1 test in 8.689s / OK` (the test runs API key, OAuth `kimi.com` and OAuth
`kimi.ai` as three real gateway/upstream sessions). The snapshot SHA-256 is
`af43aaa92579e09d1a480a8b8ceb069e8c2042a3168d12184457b29453508381`.
The separate full `gleam test` attempt did **not** complete within 120 seconds
and showed concurrent Kimi request/model unit-test failures while those source
files were being edited by another worker; it is not a passing gate for this
snapshot. `gleam format --check src test` also reported the other worker's
`src/mimic/providers/kimi/transform.gleam` as unformatted; this K5 test did not
edit that file.

## Not verified here

No live provider, non-loopback origin, TLS fingerprint, packet capture,
cross-provider behavior, OAuth device authorization UX, login polling, Chat
SSE, malformed/disconnected SSE, cancellation, benchmark, or CPA strict
conformance was tested. Assertions are specific to the assembled integration
base's buffered Chat/Responses and Responses SSE support; they do not depend
on forthcoming Kimi feature hooks.
