# Generic Kimi semantic media guard

This is a narrow successor to the frozen Kimi v1 source and wire-v2 exports.
Those archives and the v1/v2 wire fixtures remain unchanged.
No public API, native Kimi policy, gateway, shared codec or auth-store changed.

## Reproduced defect

`openai-compatible-kimi` registered no audio capability, but actual ingress
supplied `Request.required: []`. The generic planner rejected only top-level
`audio`/`modalities`. The shared native Chat decoder intentionally preserved
unknown content, so `messages[*].content` could contain an `input_audio` block
and still produce an upstream plan. A caller-supplied capability list is not
evidence that the body conforms to the provider's capabilities.

Six additional planner tests exercise the actual `required: []` boundary.
Before the fix, four test categories failed: nested media, unsupported content
across roles, message-level audio references, and malformed/disguised media.
Positive preservation tests passed before and after.

## One boundary rule

`kimi_compat/request.prepare_at` now checks each message's semantic content:

- The same policy applies to system, developer, user, assistant and `role: tool`
  result content.
- Plain strings/null/absent content retain the shared decoder's structural
  policy. Content arrays support `text` and `image_url` blocks only.
- Text requires a string. Images require a nonempty supported source:
  credential-free HTTPS URL, or an inline
  `data:image/{png,jpeg,webp,gif};base64,...` string.
- Audio/video/file/unknown content-block forms and the standard message-level
  `audio` field fail with `Failure(Unsupported, NotSent, None)`.
- No recursive name search is performed. JSON schemas, function argument
  strings, tool-result text strings, and vendor extension objects may contain
  keys named `audio`, `video`, `file`, `content`, or `type`. They remain
  byte-preserved in the generic upstream request.
- No URL is fetched, no media bytes are decoded, and no native Kimi
  model/thinking/device transformation is introduced.

## Verification

Using Gleam 1.18.1 in the ignored owner overlay:

- Focused `kimi_compat_test`: **9 passed** (including six new tests).
- Full `gleam test`: **582 passed, no failures**.
- `gleam format --check src test`: passed.
- Actual CLI loopback: `input_audio`, `video_url`, and `file` content in both
  user and tool-result messages returned **422 with zero upstream requests**
  in all six cases.
- Positive CLI loopback: text plus inline image with `audio`-named schema and
  vendor data returned **200 with exactly one upstream request**; those fields
  were observed unchanged.

The CLI probe reused the synthetic wire-v2 fixture server with its response
model set to the generic configured model (no native alias normalization).
It used only temporary private state and loopback endpoints. Results contain
counts/statuses, not credentials. The parent owns the durable root CLI
regression assertion and full integration rerun.

Assembly: base `3e00808ff0fefbb6728edb1769c17139ef0fd93a`, approved shared S4
archive `f318501aaaa1cbf5a8c477097b871387b6a85f30a9692c2f9cdda1dc524bb5bc`,
and the previously hash-approved integration source staged only in the ignored
overlay:

- `gateway.gleam`:
  `d9676d4b0228c1b0ba91bc340f5a279dac5b184e5fddd2cc5b0fb45347b33024`
- `gateway/config.gleam`:
  `cac362318cc2dfe7ae7b500f0dd36569c31c13bc0e7a9ec9012c0219e00661f7`

No live provider or CPA differential run occurred. No sibling edits/builds,
commits, pushes, or skip/status changes were made.
