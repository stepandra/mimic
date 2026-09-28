# Next-parity source import: verified inputs, not an assembled release

Baseline: `3e00808ff0fefbb6728edb1769c17139ef0fd93a`. The integration
source is the current `git ls-files -co --exclude-standard` inventory of
`/Users/jerryjohnson/dev/mimic/.delta/worktrees/rmdgphtw2034/mimic`.
Its 461 eligible regular UTF-8 files were hashed before and after inspection.
The unchanged `.agents` instruction and `.github` CI files are not import
deltas; compare CI with the baseline again if the source changes.

Overlay these **source members only**, in order. Paths below are relative to
`/Users/jerryjohnson/dev/mimic/.delta/worktrees/`; the right column is the
SHA-256 of the archive, not a validation result.

| Order | Packet | Archive path | SHA-256 |
| --- | --- | --- | --- |
| 1 | Shared S4 | `5nfm4rg21cmy/mimic/build/shared-core/snapshot-4/source.tar.gz` | `f318501aaaa1cbf5a8c477097b871387b6a85f30a9692c2f9cdda1dc524bb5bc` |
| 2 | Shared S5 | `5nfm4rg21cmy/mimic/build/shared-core/snapshot-5/source.tar.gz` | `a663d946002aa8eeed255f8df4cde6c49faacf1b304b5ed370eef48cf2f04f5f` |
| 3 | Shared S6 | `5nfm4rg21cmy/mimic/build/shared-core/snapshot-6/source.tar.gz` | `f533762770c9cba6c7cd4b99c2ad1b46e9e8946ad9b7ab9d24c05dcea3afc7b3` |
| 4 | Claude policy | `wdz557n46f58/mimic/build/claude-policy-v1.tar.gz` | `f70ba1c673b52c8928cd8d4e6589ad3b96c0b4f594a109cb679f0718e22a723d` |
| 5 | Claude enrollment | `wdz557n46f58/mimic/build/claude-enrollment-v1.tar.gz` | `42846c04ca4464fb9bdd38e6c41743051c32ac7131d288d542c2bd1662a27361` |
| 6 | Claude 429 | `wdz557n46f58/mimic/build/claude-429-v1.tar.gz` | `93fcbfff8ab8196805b9bb9f86dc55df2a9fe56cc6e94175de37d6ed49a1283f` |
| 7 | Codex HTTP | `bwpsew7nwg6g/mimic/build/codex-http/snapshot-2/source.tar.gz` | `332278d8bf6384d639f13929d081c18709c66799d86601f70135f160ced1a21a` |
| 8 | xAI v2 | `agchrccss0s4/mimic/build/xai-native/snapshot-v2/source.tar.gz` | `1fa25e82b69b45c8d435c918bc387427691e14fb7eb14d2d967e3d90fded5a92` |
| 9 | xAI v3 | `agchrccss0s4/mimic/build/xai-native/snapshot-v3/source.tar.gz` | `4122aa9a6599692384b6bb211514d2af172f50cedaf23ff9a3ecd436cd94d2de` |
| 10 | Devin | `sywjsn5cw3xq/mimic/build/devin-native/snapshot-1/source.tar.gz` | `be95cefb846f6bdc07dba16df27f8af68873b6299c856ef52e06405a31b9fe57` |
| 11 | Native QA full 15-file packet | `b3sb2191nf6d/mimic/.tools/native-clients/exports/a0e38f41a4d0e99a90dc73bb6f67e7624981994e06017c99b71e5a058d058f50/native-qa-admission-source.tar` | `a0e38f41a4d0e99a90dc73bb6f67e7624981994e06017c99b71e5a058d058f50` |
| 12 | CPA safe source v3 | `mp00zs06tcp3/mimic/build/parity-reference/source-handoff-v3.tar.gz` | `4a2353399c2ae5e69fe14cb6cc46805a4cec1a891d9faae5e7b6fc9b0cb2804e` |

The CPA archive's `HANDOFF_MANIFEST.json` is handoff metadata, not a source
file. Its 23 source hashes match its manifest. Its required
`scripts/parity/test_local_driver.py` overwrite is a harmless discovery shim;
do not run CPA, candidate build/runtime, legacy `--prepare`, Docker, native
clients, or provider traffic to validate this import. Preserve the hard block.
No archive touches the current integration `src/mimic/gateway.gleam`; preserve
current Kimi and the parent-owned `docs/PARITY_NEXT_THREADS.md` and
`docs/NEXT_PARITY_RELEASE_AUDIT.md`. No deletions are prescribed.

The local ignored `build/parity-import-verification/` contains base, frozen
source, destination preimage, and expected final per-file SHA-256 inventories;
ordered archive/member provenance and owner mapping; and the exact add/modify
list. `ARTIFACT_SHA256SUMS` authenticates those local artifacts. At inspection,
the expected source-only final map contained 510 files, with 129 additions and
60 modifications against the parent baseline plus its two docs. This is a
**verification target**, not evidence the source has been imported. Native JJ
handoff merges must compare exact final hashes and investigate any divergence
without silently overwriting or deleting files. Gateway routes and wrappers
are not yet wired; formatting, Gleam check, full gates, and live parity are
not claimed here.
