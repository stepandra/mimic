# F01 handoff — executable contract and pinned source inventory

**READY_FOR_ADMISSION of offline contract tooling/source evidence only.**
The requested five APIs compile and work on exact input baseline
`dd15c610ec39e4f296c30fe02347d0d2b368a629`. All historical rows/fixtures are
retained. Runtime parity remains **0/37**, all runtime/native/live evidence is
`not_run`, existing CPA identity is `unknown`, and full F01 acceptance remains
blocked by the explicit stronger proof/scope obligations.

No root gateway/config/CLI/build/CI/vendor/common-runner or provider file was
edited. No commits, ref mutations, broad merges, pushes, subagents, service
access, credential inspection or native/provider executions occurred.

## Recovered provenance

The prior foundation thread
`ksQQlX4HR-jcQdm57gYjroBRwZLOAFQzY5IBxBDu1fs15rdKs6m5jRdeJnRz`
had corrected but unfrozen files in its attached checkout. Those were read
without changing that checkout or executing its historical commands.

With explicit coordinator permission, only the generated
`docs/parity/final-v1/contract.json` artifact was byte-copied into this attached
owned path. Original/import size **153030 bytes**, SHA256
`c740c8372221a06e6dc136c598cce9c6f9463403712b1eeb6caf2928842feea1`.
The path allowlist and both hashes were checked. All subsequent edits used
`apply_patch`.

Handwritten `contract.py` was recovered through `apply_patch` and initially
matched the corrected original byte-for-byte, SHA256
`9cef1313ba887db8ec69cff695848a2a8b18a41fbcd1300b1ecd48b9dbc1fd4e`.
It was then extended/hardened. All **98 original source catalog records remain
unchanged**; 20 actual pinned excerpts were added. Stale foundation prose
claiming 15/7 or 34 current tests was replaced, not accepted as evidence.

## Finished deliverable

- Immutable raw-byte contract binding and read-only `.document` access.
- `load_contract`, `validate_contract`, `select_rows`, `case_plan`, `summary`;
  additive `native_pins` / `select_operations`.
- Same F30–F34 early plan fields, primary case IDs and historical fixtures.
- 37 primary plans carrying every historical/universal required check.
- 118 actual source excerpts / 54 exact source file hashes.
- 25 source-bound operation findings, with source presence, requested vs
  conditional applicability, auth/backend, observation boundary and runtime
  proof kept separate. They have **no denominator effect**.
- Strict bounded JSON/filesystem validation and guarded focused regressions.
- Actual pinned archive drift inventory and source scope/error decisions.

Current contract SHA256:
`88123126fb067dad1e46f95a2e4476a2f75a53ea1988778f67a95f0813b3bd44`.
The final thread handoff supplies hashes for all seven owned paths, including
this file; a file cannot contain its own final SHA256.

## Commands actually verified here

```sh
python3 -B -m unittest discover -s scripts/parity -p test_contract.py -v
PYTHONPYCACHEPREFIX=build/f01-pycache python3 -m py_compile \
  scripts/parity/contract.py scripts/parity/test_contract.py
python3 -B scripts/parity/contract.py validate \
  --source-dir build/f01-source/acdace936fa7df2905500c7f5e0a97d683138dea
mise exec gleam@1.18.1 -- gleam format --check src test
python3 -B scripts/parity/preparation_unit_tests.py
```

| Check | Actual result |
| --- | --- |
| Owned focused unittest suite | **40 passed**; import + execution process/network guarded |
| Python compilation | Exit 0, bytecode only in ignored build directory |
| Historical source file/span verification | Exit 0, all **118/54** bindings matched actual pin |
| Gleam formatting check | Exit 0, no source rewrite |
| Already integrated F30–F34 guarded preparation suite | **119 passed**, no paired/native/live execution |
| All 37 plans / provider selection / immutable binding / CLI controls | Exercised by focused tests |

The 40 + 119 totals are **159 QA preparation tests**, not 159 provider
workflows or differential passes. No `gleam test`, shipment or full integration
gate was run here: no Gleam source changed, and the coordinator owns the heavy
gate. The baseline [landing report](../../FINAL_WAVE_LANDING_VALIDATION.md#L47)
is historical attributed evidence, not a gate result from this slice.

A deliberate red run of two new tests exposed seven mutation subcases that
could promote conditional source presence to approval or lend Codex wire/
authority between projections. The validator was corrected using frozen v1
dispositions and projections from the already validated Codex boundary; the
final full 40-test run passed. No provider behavior was changed to satisfy QA.

The compact correction also retains a real boundary distinction: the HTTP
handler rejects `stream: true` with 400 JSON before dispatch, whereas Kimi's
executor stream guard has a different 400 message. Neither is a successful
compact SSE route.

## Exact remaining blockers

Of 22 historical pending requirements, **14 are bounded-mapped and 8 remain
unresolved**. Nine partial rows overall include historically reviewed WS:

1. Claude expiry/shared-waiter refresh, OAuth replay scope and native malformed
   media pre-I/O rejection.
2. Codex SSE/WS full effective auth/router/plugin/executor/interceptor chain,
   transparent HTTP-SSE product difference and full client/account isolation.
3. Devin strict media loss/rejection difference, exact catalog fixture/
   startup provenance and full persisted account/session/cascade isolation.

Supplemental F18 effective physical-WS/config/session proof and F19 approved
model/tool-form/restore vectors also remain explicit operation blockers. They
are not hidden in the historical 22-marker counter or counted as admitted rows.

The [source map](SOURCE_MAP.md#L1) names each narrower fact and missing proof.
Source presence does not erase these obligations. Known unsupported native
Kimi compact, ordinary Grok HTTP continuation and core job-cancel surface
cannot be forced into successful support. Conditional media and buffered-lite
product choices need explicit versioned scope decisions.

F03 must qualify actual CPA source/build/config/fixture identity; no version
was inferred for the existing `8317` service. `--local-model` disables model
catalog updaters, **not** the unconditional Antigravity updater. Containment,
native workflows, paired assertions and destination admission are separate
unperformed gates.

## Minimal parent integration

1. Admit these **seven owned paths** only:
   `scripts/parity/contract.py`, `scripts/parity/test_contract.py`,
   `docs/parity/FINAL_CONTRACT_V1.md`, and
   `docs/parity/final-v1/{contract.json,SOURCE_MAP.md,DRIFT.md,HANDOFF.md}`.
2. Rerun focused validation and verify hashes at the destination. The child
   made no ref/bookmark mutation; parent coordinates the resulting checkpoint.
3. In the coordinator's exclusive common-runner slot, add `test_contract` to
   the existing guarded preparation suite. No production registration or
   root build/CLI/config patch is required.
4. F02 consumes unchanged row/plan bindings for containment. F03 qualifies
   CPA identity/source/fixtures. F04 owns only budgeted, separately authorized
   live execution. F30–F34/provider peers/shared harness own differential
   assertions; coordinator owns actual destination admission.

## Recreating optional public source inputs

Ignored build artifacts are not assumed to replicate. Source validation needs
an operator-approved **public source download only**, never CPA/service or
provider access. The archives and SHA256 pins are in
[DRIFT.md](DRIFT.md#L14). A safe reproduction uses Python stdlib:

- Disable ambient proxies with `urllib.request.ProxyHandler({})`.
- Fetch only the two fixed codeload URLs; bound socket time to 60 seconds and
  archive reads to 32 MiB + 1 byte.
- Verify the full archive SHA256 before writing/extracting.
- Require prefix `CLIProxyAPI-<revision>`, relative paths, no `..`, and regular
  files/directories only; reject symlink/hardlink/device entries.
- Bound each file to 16 MiB and total expanded bytes to 128 MiB.
- Extract only under `build/f01-source/<revision>`, then run the `--source-dir`
  command above. The later tree must fail historical verification.

No automatic downloader or network authority was added to `contract.py`.
Both actual archives were downloaded and checked here; the changed-path counts
and bounded semantic review are recorded in [DRIFT.md](DRIFT.md#L21).
