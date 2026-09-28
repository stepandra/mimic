# Independent CPA conformance lab

This is a test namespace, **not a replacement MIMIC application or provider
adapter**. Domain/gate logic and orchestration are Gleam; Erlang provides the
bounded argv/process boundary; the Python standard-library driver supplies OS
process and HTTP socket operations.

Read [CONTRACT.md](CONTRACT.md) before implementing a driver. Source baseline:
`c3ca7e805b8e4c3f8271468fbbe46271a5b0e8f4`. CPA is pinned to
`acdace936fa7df2905500c7f5e0a97d683138dea`.

## Commands

From repository root, with Gleam 1.18+, Erlang/OTP and the project's documented
tools on `PATH` (plus Python 3 with the standard library):

```sh
# Offline normal suite. No provider accounts or CPA executable required.
gleam format --check src test
gleam test
gleam run -m parity/runner -- check
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/parity -p 'test_*.py' -v

# Actual assembled ingress + synthetic localhost upstreams.
# EXPECTED NONZERO: required capabilities are absent on the assembled base.
gleam run -m parity/runner -- baseline scripts/parity/baseline-drivers.json

# Strict differential RELEASE gate: requires real reviewed drivers for BOTH.
gleam run -m parity/runner -- release /absolute/path/to/drivers.json
```

`check` validates the matrix and fixtures; it never executes capabilities.
`baseline` establishes only MIMIC mock evidence. `release` runs both targets,
even if MIMIC fails, compares observations, requires reviewed source evidence,
and rejects any unmet required row. There is no `--allow-missing` or
`--skip-required`, and reports cannot be fed back in as successful execution.
An empty CPA argv produces blocking evidence, not an implicit skip.

## Evidence artifacts

Each run prints a `report.json` path in ignored `build/parity-results/`.
Artifacts include exact plans, original driver stdout JSON, fixture SHA-256,
manifest SHA-256, independent source/mock/CPA/differential/live states and
per-capability private state. They are synthetic test artifacts only. State
directories are `0700`; MIMIC credential records are `0600`. The suite does not
read real credential stores.

The denominator is **25 required capability rows in manifest schema v1**.
This is a deliberately explicit initial gate, not the universe of CPA
features, provider/model combinations or native-client fidelity. Expanding
that scope requires reviewed matrix/fixture changes. No percentage is claimed.
The ledger includes fixture contracts for every requested family; **a fixture
contract with an unsupported driver is not an implemented test or coverage**.

The fixture file bytes and reference SHA are pinned in every invocation.
Change fixture IDs/versions when changing semantics; report digests make old
results stale. Header lists preserve order, casing and duplicate occurrences.
Bodies, SSE event order and WS frame order are not normalized. Volatile dates,
generated IDs and ephemeral ports may cause conservative differential failures;
v1 does not hide them. PID metadata is diagnostic, not protocol observation.

## Supplying real executable drivers

The executables in this configuration implement the **test-driver contract**,
not raw production CLI flags:

```json
{
  "mimic": {
    "argv": ["/absolute/path/to/mimic-parity-driver", "--executable", "/absolute/path/to/mimic"],
    "revision": "<full MIMIC revision>"
  },
  "cpa": {
    "argv": ["/absolute/path/to/cpa-parity-driver", "--executable", "/absolute/path/to/CLIProxyAPI"],
    "revision": "acdace936fa7df2905500c7f5e0a97d683138dea"
  }
}
```

The runner appends an absolute plan filename, executes without a shell, bounds
stdout at 1 MiB and execution at 60 seconds, and removes inherited environment
variables except `PATH`, `TMPDIR`, `SystemRoot`. `HOME`/XDG paths point into the
fresh private lab directory. Drivers must reap their children on all exits and
have their own shorter deadlines.

The shipped baseline driver boots the compiled `parity/target` entrypoint in a
new BEAM, which calls **actual `mimic/ingress` and `mimic/auth/storage`**. It
supports buffered baseline routes and persisted-state probes only. It does not
pretend to boot CPA, support OAuth provider login, or implement provider-specific
SSE/WS/lifecycle scenarios. The scenario fixtures intentionally return
`unsupported` until adapter streams supply real localhost drivers.

No raw CPA launcher is shipped: the pinned CPA configuration has startup
services, remote model catalogs and provider flows that require a reviewed
offline launcher. A raw binary must not be passed directly as a driver.
The runner's environment hygiene is **not an OS network sandbox**. Run external
drivers inside an operator-provided no-egress environment (loopback allowed),
and explicitly redirect *all* upstream, token, model-discovery and ancillary
endpoints before enabling them. Never substitute a synthetic echo target and
label it `cpa`; the synthetic component is the upstream only.

## Adapter integration checklist

1. Keep each provider/auth/input/upstream combination explicit. A generic Kimi
   request cannot satisfy native Kimi; xAI API cannot satisfy Grok Build;
   Gemini API-key cannot satisfy Code Assist OAuth or Antigravity OAuth.
2. Implement a driver that consumes `fixture_json`, provisions only synthetic
   accounts in `state_dir`, launches the actual executable/library, and tests
   real loopback HTTP/SSE/WS transport.
3. Implement every fixture `required_checks` assertion; unknown checks must
   remain false/absent, never `True` by default. Emit `capability_id` exactly.
   The gate additionally requires `assembled_ingress: true` as a named check;
   direct adapter scenarios alone cannot close an assembled route requirement.
4. For `restart`, do not reseed state. Observe token exchange counts and account
   affinity, stream termination, lease release, retry boundaries and cancellation
   through services—not callback return values.
5. Keep raw ordered upstream/downstream observations. Add adversarial regressions
   for each check before changing source applicability from `pending`.
6. Pin/hash the actual executable in your build provenance. The runner binds
   driver-reported target revision to configuration but cannot independently
   attest an arbitrary executable's source revision; wrappers are trusted test
   code, not adversarial attestation.
7. Run the strict gate. Passing offline tests alone does not authorize parity
   release, and passing the differential gate does not establish live verification.

## Exact coordinator CI hooks (proposal only)

Normal offline CI job, after toolchain setup:

```sh
gleam format --check src test
gleam test
gleam run -m parity/runner -- check
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/parity -p 'test_*.py' -v
```

Separate required `cpa-parity-release` job in the no-egress release environment:

```sh
gleam run -m parity/runner -- release "$PARITY_DRIVER_CONFIG"
```

Archive `build/parity-results/` **even on failure**. Do not mark that job
`continue-on-error`, turn exit 1 into success, or run the ordinary offline
suite under a name implying provider parity. Root build/CI files are unchanged.
