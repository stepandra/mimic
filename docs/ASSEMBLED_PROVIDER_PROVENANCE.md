# Frozen provider source assembly

This tree combines **synthetic/local contract sources**, not measured upstream
parity. Base revision: `c3ca7e805b8e4c3f8271468fbbe46271a5b0e8f4`.
Source paths below are read-only sibling exports; SHA-256 manifests were checked
against every listed file before import. The original manifests are retained
under `docs/source-manifests/` (Claude's under `docs/`).

| Package | Read-only export relative to `/Users/jerryjohnson/dev/mimic/.delta/worktrees/` | Manifest SHA-256 | Listed files |
|---|---|---|---:|
| Runtime v4 | `qhtjz5hs63hm/mimic/build/provider-runtime-contract-v4/` | `b6730e91c13503ce469c7b4e8721791b08135eb2ac28e298ffe874eeba3d3784` | 12 |
| Responses v2 | `bp3dg4b63e1r/mimic/build/responses-contract-v2/` (`source/` relative paths) | `6550e0a4e63c2838a0688f7db1bb1aac064c99e2a638d9de66d80e0072a859da` | 18 |
| Codex v4 | `y8j5nqdkw46y/mimic/build/codex-provider-v4/` (`source/` relative paths) | `84df1afa9f172f996ff453e2b62f6308583a2afb6aa2ad76f34bc4c9cb5a7372` | 24 |
| Devin v1 | `fmgzrj7d0m1k/mimic/build/devin-provider-v1/` | `d0d2658359c16f33a5a7140f72850d266d10cf03d1d1e1447db0df7eff33e8fd` | 16 |
| Claude corrected provider v2 | `bhpswn35wmkw/mimic/` | `5c050a4f2e4e5aa1921dbaa752262ab4838b66a1f01a74cfc1b2521d6d6b6e8a` (`docs/CLAUDE_PROVIDER_V2_SHA256SUMS`) | 14 |
| Claude runtime-v4 consumer | same | `2b54251f7f9dc5bba943c2a9b44ac30c41c98511a0d9dfbf276284971c05c71f` (`docs/CLAUDE_RUNTIME_V4_V2_SHA256SUMS`) | 3 |
| Conformance v2 | `dbcgy4kegxa3/mimic/build/parity-handoff-v2/` (`source/` relative paths) | `71f154d6ea043c7f877ad6b533b86fb282f935faa8d12191ac6b5f9b001b59b2` (`manifest.json`) | 51 |

The exact conformance `manifest.json` and `SHA256SUMS` are retained at
`docs/parity/v2/FROZEN_HANDOFF_MANIFEST.json` and `FROZEN_SHA256SUMS`. All 51
files are imported unchanged, including two historical synthetic Gemini v1
fixtures so the immutable v1 matrix remains reproducible. Gemini,
Antigravity and Copilot are **not active v2 scope**, and none of their provider
implementations or older provider source snapshots was assembled. The older
Responses handoff documents bundled in its v2 manifest are historical,
superseded by `docs/RESPONSES_HANDOFF_V2.md`; they do not establish newer
validation.

The runtime-v4 source manifest did not contain its published regression files.
These additional, unmodified files came from
`qhtjz5hs63hm/mimic/` (same runtime owner), with SHA-256:

| Path | SHA-256 |
|---|---|
| `test/mimic_auth_runtime_v4_test_ffi.erl` | `332ad9445c35e1329ae02f6a78cb758e045a299be263e99bb946b8f89f8e9754` |
| `test/provider_runtime_v4_test.gleam` | `941ba4a59ccff0a86ba8bf356a05604af88b69fdd3bd850d7b43ead2d599f5ac` |
| `test/provider_runtime_v3_test.gleam` | `626210623e71bbcebe24529dbd1be78b138fb26e1db22329d0e2e0f8661d9cc0` |
| `test/provider_runtime_scenarios.gleam` | `41eb930e8140eb3c333b7706fabb364fd5cdf4f39c61430b08292b42b5d0d8f2` |
| `test/provider_runtime_test.gleam` | `744e582c0a2008c0e43a68fc0b2e801dc24df54fb41dc404b5ef21edc7c898af` |
| `test/provider_runtime_tls_test.gleam` | `e0465dd090a9cb1cb8f4afac1a2196fa65eb5196b040684b94a30c95db04b83f` |
| `test/mimic_provider_runtime_test_ffi.erl` | `ce8c7b55be6d8c6903f66cfb50ec8a752931fa02afbe47dd7f85f48476b52964` |
| `docs/PROVIDER_RUNTIME_V4.md` | `ae1d3ac5edb0ca105afc5484a5b63b95631c1d1cbaa312905d197523f1c9db54` |
| `docs/PROVIDER_RUNTIME_CONTRACT.md` | `2bfd1756f4c8031c25c181a20070bc6862f6f90776883fe8334181b73fa2fdbf` |
| `docs/PROVIDER_RUNTIME_INTEGRATION.md` | `50a3120e1aa7996e50513ce73d544d35199cdaf9d0fdf991f5b59a288d2c0772` |

The corrected Claude consumer template remains intact at
`test/fixtures/claude/runtime_v4/claude_runtime_v4_test.gleam.in`.
`test/claude_runtime_v4_test.gleam` materializes the same module in the regular
suite with only its obsolete "ignored overlay" comment changed (assembled SHA-256
`d09d971b0087db12cbac1cdb126f50c31634568c700969ee3046c9ee46e5243e`).
The owner `run.py` remains for separate fresh-VM seed/restore checks.

## Local checks at assembly

- `mise exec gleam@1.18.1 -- gleam format --check`: clean.
- `mise exec gleam@1.18.1 -- gleam test`: **422 passed**.
- `mise exec gleam@1.18.1 -- gleam run -m provider_runtime_scenarios`:
  **52 synthetic runtime-library scenarios**, `assembled_ingress=false`.
- `mise exec gleam@1.18.1 -- gleam run -m parity/runner -- check --manifest test/parity/v2/manifest.json`:
  schema valid; no capability execution.
- `mise exec gleam@1.18.1 -- gleam run -m parity/runner -- baseline scripts/parity/baseline-drivers.json --manifest test/parity/v2/manifest.json`:
  expected exit 1, **3/37 required rows** in mock baseline,
  `live evidence: not_run`; release remains blocked.
- `python3 -m unittest scripts/parity/test_local_driver.py`: 7 passed.

No assembled ingress, live-provider, CPA differential, fresh-VM Claude
seed/restore, or deployment claim follows from these checks.
