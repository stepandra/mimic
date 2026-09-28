# CPA parity lab contract v1

Status: required matrix published; no provider parity established.

Assembled MIMIC base: `c3ca7e805b8e4c3f8271468fbbe46271a5b0e8f4`.
CPA reference: https://github.com/router-for-me/CLIProxyAPI/tree/acdace936fa7df2905500c7f5e0a97d683138dea
All CPA evidence and synthetic reference fixtures must name that revision.
Nothing here is a native capture.

## Required matrix

The versioned ledger is `test/parity/manifest.json`. Its unit of coverage is
one explicit `(provider, auth_mode, input_protocol, upstream_mode, capability)`
row, not a provider name or a Cartesian product of assumed support.

| Provider | Auth modes kept distinct | Upstream modes kept distinct |
|---|---|---|
| Claude | API key; OAuth | native Messages |
| Codex | OAuth | native Responses; direct Codex alias |
| Kimi | API key; OAuth | generic OpenAI-compatible; native Kimi |
| xAI | API key; OAuth | xAI API; Grok Build |
| Gemini | API key | Gemini API |
| Antigravity | OAuth | Antigravity gateway |

Gemini CLI Code Assist OAuth is **not** a CPA-required capability at this pin.
The pinned Gemini executor uses `x-goog-api-key`, not a separate CLI OAuth
backend. Code Assist research belongs in a separately pinned optional ledger,
not in Gemini API coverage. Grok Build applicability remains pending review.

Required families: model discovery; Messages and count_tokens; Responses HTTP,
SSE, compact and WebSocket; tool call/result turns; thinking/reasoning;
supported and explicitly rejected multimodal forms; terminal stream markers,
disconnect and cancel; expiry, refresh and singleflight; credential/session
isolation; 429/reset/failover; fresh-process persisted state.

A required capability is not satisfied by 404, skipped, unsupported, missing
driver, an unrun fixture, source inspection, or a passing mock of the harness
itself. Supported and rejected forms have separate assertions. Exact
provider-specific applicability must be supported by pinned source evidence;
an unknown is a blocking investigation, never an implicit pass.

## Evidence and release contract

Keep independent evidence axes:

1. **Source evidence:** pinned path/symbol and review status. Demonstrates what
   CPA implements, not that MIMIC implements it.
2. **Mock-tested:** real localhost request to the actual target, synthetic
   upstream observation, assertions, target identity, fixture digest and result.
3. **Differential:** same fixture against pinned CPA and MIMIC; preserve
   response and upstream semantic differences.
4. **Live-verified:** separate opt-in operator evidence, absent by default.

The default suite is offline and synthetic. Release validation requires every
required row to have passing MIMIC mock and CPA differential evidence bound to
the exact manifest and fixture hashes. It must reject empty/stale/duplicate or
unknown results. No live status is inferred from local evidence. A stricter
live gate must require separately reviewed live evidence; this lab does not
make provider calls.

## Test-driver contract (v1)

Drivers are test-only executables, not production API additions. Supply an
argument-vector command, never a shell command string. The harness starts a
fresh driver process per fixture and target, passes a JSON plan filename as
the final argument, and expects one JSON result on stdout. Logs go to stderr.
A driver receives:

- `schema_version`, target identity and CPA reference revision;
- the same versioned synthetic fixture for either implementation;
- an isolated absolute `state_dir` (new per fixture);
- `phase` (`exercise` or `restart`) and fixture digest;
- only synthetic credentials, with no inherited provider credentials.

Drivers must bind real services to `127.0.0.1`, redirect every provider and
token endpoint to the fixture's loopback upstream, and disable provider
discovery/telemetry. They must not read operator credential directories.
Production executables with incompatible CLIs need different thin wrappers;
both wrappers consume the same fixture. Never substitute an echo server for
the target implementation.

**Universal required check:** every passing result must include
`{"name":"assembled_ingress","passed":true}` in addition to the fixture's
`required_checks`. This can be asserted only after a real client-facing request
to the actual assembled ingress. A direct runtime-adapter call cannot satisfy
it. The gate enforces its presence even when all fixture-specific checks pass.

Result shape:

```json
{
  "schema_version": 1,
  "capability_id": "example-capability",
  "fixture_id": "example-v1",
  "fixture_sha256": "...",
  "target": "mimic",
  "target_revision": "...",
  "phase": "exercise",
  "status": "passed",
  "observations": "{\"response\":{\"status\":200,\"headers\":[],\"body\":\"...\"},\"upstream\":[]}",
  "checks": [{"name":"authenticated_http","passed":true}]
}
```

The plan carries the original fixture bytes as `fixture_json` (a JSON string);
its SHA-256 covers those UTF-8 bytes, not a reserialized object. Results carry
`observations` as a JSON **string** for lossless comparison in Gleam.
HTTP observations contain `status`, ordered `headers` as `[name, value]`
pairs, body text, and ordered upstream observations. SSE frames and WS
messages remain ordered; terminal/cancel/disconnect outcomes are explicit.
No header dictionary, sorting, ID stripping, timestamp wildcard, or blanket
error equivalence. Volatile normalization is only per fixture, per exact
field/path with a documented reason. **v1 normalizes nothing**, including dates
and ephemeral port values. This is conservative: volatile differences can block
release until narrowly scoped normalization is implemented and reviewed; they
cannot hide semantic drift. Raw results are retained unchanged.

For persistence fixtures the harness invokes the driver twice as separate OS
processes with the same private state directory. `restart` must load and
exercise the first process's state without reseeding it. A callback stub or
in-process reload is insufficient. Refresh/singleflight checks must observe
token HTTP exchange counts under concurrent real ingress requests.

Until an adapter driver exists, its rows remain blocked. Provider threads
should supply fixture-specific wrappers and assertions in their own test
namespace, or coordinate additions to `test/parity/**`; do not change this
contract by interpreting unavailable behavior as success.

### Minimal executable driver boundary

This executable skeleton validates the invocation and correctly reports missing
scenario implementation. It is deliberately **not a passing provider driver**.
Replace only the scenario execution section with real localhost services,
actual target execution, observations, and independently evaluated assertions.
Keep unknown fixture/check names failing closed.

```python
#!/usr/bin/env python3
import hashlib
import json
import sys

with open(sys.argv[-1], encoding="utf-8") as source:
    plan = json.load(source)
fixture = json.loads(plan["fixture_json"])
assert plan["schema_version"] == fixture["schema_version"] == 1
assert fixture["cpa_revision"] == plan["cpa_revision"] == (
    "acdace936fa7df2905500c7f5e0a97d683138dea"
)
assert hashlib.sha256(plan["fixture_json"].encode()).hexdigest() == (
    plan["fixture_sha256"]
)

# Scenario execution section: currently absent, therefore no coverage.
checks = [{"name": "assembled_ingress", "passed": False}]
checks += [{"name": name, "passed": False}
          for name in fixture["required_checks"]]
observations = {}
status = "unsupported"

print(json.dumps({
    "schema_version": 1,
    "capability_id": plan["capability_id"],
    "fixture_id": fixture["id"],
    "fixture_sha256": plan["fixture_sha256"],
    "target": plan["target"],
    "target_revision": plan["target_revision"],
    "phase": plan["phase"],
    "status": status,
    "observations": json.dumps(observations, separators=(",", ":")),
    "checks": checks,
}))
```

Run shape: `python3 /absolute/driver.py /absolute/plan.json`. The real runner
constructs the plan and appends its path; do not add it to driver config argv.
One zero-exit JSON result with `status: unsupported` is a **failed gate**, not a
successful test. Nonzero exit, malformed output, timeout, stale digest or
unknown phase also fail. To see an actual target/service implementation, use
`scripts/parity/local_driver.py` and `test/parity/target.gleam`.

## Integration ownership

This thread owns `test/parity/**`, `scripts/parity/**`, `docs/parity/**`.
Coordinator owns root CI/build and production integration. Proposed CI hooks:
run the existing Gleam gate, run the offline parity lab tests, then run the
strict parity release command against artifacts of *both* executables.
Do not attach the strict release gate to ordinary offline unit-test success.
