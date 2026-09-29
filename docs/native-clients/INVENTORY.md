# Official client inventory

Registry metadata and source were read on 2026-09-29. Pins are exact, not
`latest` resolution at execution. The machine-readable lock is
`scripts/native-clients/clients.lock.json`.

| Client | Pinned artifact/source | License | Execution status |
|---|---|---|---|
| Claude Code | `@anthropic-ai/claude-code-linux-x64@2.1.284` | `SEE LICENSE IN LICENSE.md`; do not assume OSI/open implementation | acquired; blocked |
| Codex | `@openai/codex@0.158.0-linux-x64`; native version `0.158.0` | Apache-2.0 | acquired; blocked |
| Kimi Code | `@moonshot-ai/kimi-code@2.1.1`, source `f67e6398fb3210ad8ace970e2dfd5bcc984ed61f` | MIT | inventory only |
| Grok Build | `xai-org/grok-build@f0e3be1100ef5252488e3be8bb0e91cf68d8c305`; `SOURCE_REV=036a5d8348cd744767cd0b08518ab17bf608fa7f` | Apache-2.0 | build closure not pinned |
| Devin CLI | `CognitionAI/devin-cli@bd4163ed29e934b898f185752182c91aacac20f7` | implementation license not established | distribution/docs repository, not source-backed implementation |

Kimi Code is the newer TypeScript CLI, distinct from the archived Python
`MoonshotAI/kimi-cli`. Do not accidentally qualify one from evidence about the
other. Its top-level artifact is pinned but **not installed**: runtime and
transitive dependencies (`ws`, `qrcode`, optional native dependencies) need an
integrity-locked closure before an executable adapter is safe to acquire.

Grok has source, but no official versioned binary release was established in
this inventory. Its build needs Rust and additional DotSlash/protoc tooling.
Devin has an official CLI distribution, but the inspected repository does not
contain implementation source or its license. These are specific blockers, not
claims that the provider protocols do not exist.

Gemini, Antigravity and Copilot are intentionally excluded.

## Artifact hashes measured after acquisition

SHA-512 registry integrity strings are in the lock; the following are independent
SHA-256 hashes computed from downloaded archive bytes and extracted native
executable bytes. These attest acquisition only, not execution or provenance
signature verification.

| Artifact | SHA-256 |
|---|---|
| Claude archive | `642690c3afaa22029c17341e520d8c35ca85857fce6dcc9ecd90ef5e3c7f1027` |
| Claude executable | `5cd90aabd83f8a15136c35aa37bb1d92b348993573316643dc3fe4e04afbf88f` |
| Codex archive | `3fe84106aaf2fbfc13299068510d34b3d0157eeb9af4b37be8cf5416f485a6bb` |
| Codex executable | `167c0148a849d2444f1b5a7fb5f8bb2de1de5ae13a2a504b833fc765980f5cd9` |

## Source-backed entry points

- [Claude CLI reference](https://code.claude.com/docs/en/cli-reference):
  `-p`, output format, model, tool permission and continuation flags.
- [Claude environment](https://code.claude.com/docs/en/env-vars):
  `ANTHROPIC_BASE_URL`, telemetry/nonessential-traffic controls. These do not
  establish a configurable local OAuth issuer.
- [Claude exact platform metadata](https://registry.npmjs.org/@anthropic-ai/claude-code-linux-x64/2.1.284).
- [Codex exact package metadata](https://registry.npmjs.org/@openai/codex/0.158.0-linux-x64).
- [Codex pinned npm launcher](https://github.com/openai/codex/blob/rust-v0.158.0/codex-cli/bin/codex.js):
  resolves `vendor/<target>/bin/codex`; package resource layout is retained.
- [Codex config reference](https://developers.openai.com/codex/config-reference):
  custom model provider `base_url`, `wire_api`, `env_key`, analytics, feedback,
  update checks. Custom model routing is not a custom OAuth login contract.
- [Kimi pinned commands](https://github.com/MoonshotAI/kimi-code/blob/f67e6398fb3210ad8ace970e2dfd5bcc984ed61f/apps/kimi-code/src/cli/commands.ts):
  `-p/--prompt` supports noninteractive text/stream-JSON. The pinned
  [options parser](https://github.com/MoonshotAI/kimi-code/blob/f67e6398fb3210ad8ace970e2dfd5bcc984ed61f/apps/kimi-code/src/cli/options.ts)
  rejects prompt mode with `--yolo`, `--auto`, or `--plan`.
- [Kimi pinned config schema](https://github.com/MoonshotAI/kimi-code/blob/f67e6398fb3210ad8ace970e2dfd5bcc984ed61f/packages/node-sdk/src/config/schema.ts):
  named providers with `baseUrl`, `apiKeyEnv`, provider type/model aliases;
  no local OAuth issuer contract established.
- [Grok pinned source](https://github.com/xai-org/grok-build/tree/f0e3be1100ef5252488e3be8bb0e91cf68d8c305).
- [Devin pinned distribution repository](https://github.com/CognitionAI/devin-cli/tree/bd4163ed29e934b898f185752182c91aacac20f7).
