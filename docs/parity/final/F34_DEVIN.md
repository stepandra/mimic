# F34 Devin — blocked preparatory fixtures and adapter

**SYNTHETIC, UNAPPROVED, nonexecuting. Historical strict conformance stays 0/37.**

This slice adds only `scripts/parity/f34_devin.py`, its focused test,
`test/parity/final/f34_devin.json`, and this report. No root patch, CI,
provider code, common harness, contract or matrix changes. No launch,
admission, translation or comparison implementation is supplied.

## API and evidence boundary

- `load_fixture(root=ROOT)` loads one fixed bounded local JSON file. Unknown
  provenance, payloads, sample types, bindings, duplicate JSON keys or mappings
  are rejected. This is a Devin-specific closed synthetic vocabulary check,
  not a copied generic F01 validator.
- `case_plan(value, scenario_id)` resolves the fixture's named client input,
  native request/response script and client projection into independent,
  identical `cpa` and `mimic` copies. It sends and compares nothing.
- `blocked_report(root=ROOT, scenario_id=None)` reports `blocked` and `not_run`
  at the report and case levels. Only the four owned local byte hashes are
  populated. Future source/driver/fixture/dependency/executable/shipment/contract
  hashes are all `null`; peer revisions are not hash bindings.
- `main(argv=None)` accepts only optional `--case <scenario-id>`. Valid
  preparation returns **2**, rejected input **1** with a fixed safe error and
  no rejected payload echo. No capture, file-import, launcher or endpoint flags.

MIMIC base `ca86b531cea7e1a509ac8e6038604fe91819ac07` and historical CPA pin
`acdace936fa7df2905500c7f5e0a97d683138dea` are provenance labels, not executed
source qualification. The historical inventory is
[`test/parity/v2/manifest.json`](../../../test/parity/v2/manifest.json#L38-L52).
F01 is not frozen/imported here. The provider-specific plan schema is
`mimic.f34-devin-preparation/v1`, **not** `mimic.final-parity-plan/v1`.

## Prepared data, not new routes

The 25 scenarios map to the unchanged 15 Devin historical rows. Every scenario
has explicit `row_id` and `<row>.final-v1` primary mapping; 10 additive controls
add neither required rows nor a new denominator. All mappings remain
`provisional_pending`.

| Historical row(s) | Prepared input/control |
| --- | --- |
| `devin-auth-pkce`, `devin-auth-import` | Synthetic code/verifier/state and wrong-state data; explicit permanent token import; no login/code exchange |
| `devin-chat-http` | Raw buffered Chat, additive Chat SSE, native-only Connect sketches |
| `devin-messages-http`, `devin-responses-http`, `devin-responses-sse` | Distinct proposed JSON/SSE projections; no inference of assembled routes |
| `devin-tools` | Tool declaration, call/result IDs and arguments; synthetic native response fields; request encoder/projection pending |
| `devin-thinking` | Thinking, signature bytes, signature type and replay input; replay encoder pending |
| `devin-multimodal` | Unsupported inline/remote image and audio controls; deliberately not a valid PNG; never fetch |
| `devin-models`, `devin-status-quota` | Unframed `application/proto` requests distinct from framed chat; no invented model/status response |
| `devin-count-estimate` | UTF-8 payload-byte-length `/4` estimate sketch, not an upstream tokenizer |
| `devin-stream-lifecycle` | Cancel/disconnect proposal, truncation, unsupported compression/semantic field, H2 and remote controls |
| `devin-persisted-isolation` | Separate known synthetic accounts/tokens and session/restart proposal; no real persistence |
| `devin-429-failover` | HTTP429/Retry-After and trailer quota controls; no replay/failover authorization |

Client request targets, whitespace, UTF-8 bodies and ordered, cased duplicate
headers are copied exactly. Native request bodies and each response chunk keep
their exact base64 encoding, byte length and framing label. The prepared
Connect envelopes contain a flag, four-byte big-endian length, and payload.
Separate frames split UTF-8 `é`; client SSE separately splits `data:` and
retains CRLF/heartbeat/terminal bytes. Proposed read segmentation `[1,3,11]`
is synthetic, not observed TCP segmentation.

The native bytes are **small partial field-layout sketches**, not complete CPA
request encodings, native captures, or goldens. Tool/thinking request encoding,
catalog/status response encoding and assembled projection qualification remain
pending. Synthetic client projection strings are proposals, not translator
outputs. EOF, Connect trailer and client terminal are separate concepts.

## Binary and credential safety

Binary samples are reconstructed solely from fixed literals in the adapter:
at most **512 bytes per sample**, **4096 bytes per vocabulary**, and **131072
bytes per owned local file read**. A SYNTHETIC label alone is insufficient:
every supplied binary/text/header payload must equal that closed vocabulary.
No unknown base64 is decoded, no arbitrary capture path or raw binary API exists.
Changing the vocabulary requires a reviewed change to these provider files.

**Base64 is an encoding, not redaction.** Known tokens
`devin-session-token$synthetic-a` and `devin-session-token$synthetic-b` occur in nested protobuf
metadata as well as literal `Basic <token>-<token>` headers. The only client
credential is `synthetic-client`. Dormant origins are `http://127.0.0.1:0`
and `https://devin.synthetic.invalid`; remote image input uses `.synthetic.invalid`.
Neither is contacted. No ambient environment/home/auth/config discovery occurs.
Unknown credential strings in bodies, headers or local import input are rejected.

## Qualification checkpoint and hard stops

The earlier base peer report described buffered Chat on numeric `127.0.0.1`
HTTP only. `response.feed_prefix`, `stream.next` and `project` alone did **not**
qualify client SSE or assembled ingress. That historical base scope is not a
global denial of later F23 work.

The latest coordinator message reports checkpoint
`428b7671452a4c637ca227411f02bc1760d66349`, provider
`9facbe42122bb436fbd74db2f7edd2ae8bee76f3`, **ACCEPTED experimental LOCAL ChatSSE**.
This is reported-only: its contract, provider and checkpoint are **not imported,
locally admitted or qualified here**. Reported generic client new/adopt/cancel/
next/run and Chat new/encode seams are not imported APIs in this adapter.
Reported source/shipment checks are not F34 verification. They do not establish
raw-trailer/exact-status, idle-close watcher, remote, differential, native or
live qualification, nor Messages/Responses routes.

F03 and F23–F29 remain unadmitted **locally**. F24–F29 contracts are unknown here;
the peer reports F24/25/26/28/29 queued, F25 shared F11 held/partial, and F27
recovery unfrozen/unadmitted. Reported F22 local acceptance
`5dfbbd6bad1160d97f304583e4ccc886ba1119d3` does not open its NOT DONE remote gate.
H2/native source qualification is pending; remote binary qualification is
distinct and closed. Unsupported modes fail closed, never H1/generic fallback.

Proposed trailer `unauthenticated` is credential scope/401/reauthorize;
`invalid_argument` is request scope/400/no reauthorize; quota is request
scope/429/no credential invalidation. These are **planned controls**, not
observed classification. Cancellation/truncation has uncertain delivery.
All retry/fallback flags remain false; no replay after Started is authorized.
Hardening differences require a decision, never normalization into a match.

Existing CPA8317 identity is unknown and untouched. The sourceV3 unconditional
Antigravity updater and candidate descendant-containment blockers remain hard
stops; no waiver, reference patch, service reconfiguration or duplicate deploy.

## Focused verification only

Run from the project root:

```sh
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=scripts/parity python3 - <<'PY'
import unittest
from safe_unit_tests import execution_guards
with execution_guards():
    suite = unittest.defaultTestLoader.loadTestsFromName("test_f34_devin")
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(0 if result.wasSuccessful() else 1)
PY
```

Focused result: **31 tests passed** under `execution_guards`. Tests also enter the guards individually;
CLI checks call `main` in-process, never spawn it. No shared test allowlist change.
Gleam/full-source/shipment, actual CPA/MIMIC/provider/native/login/network/live
gates are **not run**. This preparation admits no executable parity results.
