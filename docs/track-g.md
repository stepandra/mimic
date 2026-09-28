# Track G — Autopilot

Autopilot is a **proposal and reporting adapter**, not a Workshop executor.
`mimic/autopilot.gleam` exposes `invoke(endpoint, model, role, curated_artifacts)`
and `invoke_with(send, ...)` for deterministic mock inference. It supplies a
closed `response_format.json_schema` to a localhost OpenAI-compatible
`/v1/chat/completions` server, then independently parses every role output with
required, type-checked fields and no unknown keys. A citation names a curated
artifact ID and half-open **Unicode grapheme** span `[start,end)` within its
**redacted** text (not a UTF-8 byte offset); empty or out-of-range citations
fail. Integral-valued JSON numbers such as `1.0` are accepted as schema
`integer` citation offsets, but fractional offsets are rejected. Classifier
confidence must be within `0..1`, and low confidence (`<0.7`) routes at least
MAJOR, full oracle, and human review. The mechanical severity floor cannot be
lowered by the model.

The default endpoint is `http://127.0.0.1:8080/v1/chat/completions`.
Other destinations are denied unless the caller constructs an explicitly
trusted HTTPS `Endpoint`; redirects and URL credentials/query/fragment are
denied. No inference call is made by default or in the tests. Packs are curated
by the caller, limited to 16 artifacts / 2,000 UTF-8 bytes each / 24,000
UTF-8 bytes total **before** and after redaction. If an artifact contains any
common credential marker, its **entire text** is replaced with `[REDACTED]`:
unstructured, folded, or structured values on another line cannot be safely
redacted independently. This redaction is a second defense, **not a credential
detector**: never pass raw captures, credentials, or arbitrary corpus data as
grounding.
Model names are limited to 128 bytes, serialized requests to 65,536 bytes,
response envelopes to 65,536 bytes before JSON parsing, and extracted model
content to 16,384 bytes. Model output validation also rejects raw JSON over
16,384 bytes before decoding. The CLI rejects oversized pack/facts JSON before
parsing, though its file read is not streaming. These are byte caps, **not a
token-budget measurement**; callers must separately ensure the configured
model's context window accommodates the pack and schema.
The API provides no `shell_exec`, model-directed filesystem read, stage,
approval, or promotion operation.

Classifier returns a validated `Classification` and `route` returns a
conservative suggestion. Hypothesizer returns a bounded, single-file
`persona.toml` unified diff; the validator preserves trailing whitespace in
context lines and requires hunk counts to match exactly. Patch-capable calls
must include exactly one artifact with ID `persona.toml`: its text is the
**complete, current base file** (up to the ordinary 2,000-byte artifact cap),
including its terminal newline. Slices are not supported. Each hunk's
one-based old-file range and every deleted/context line must match the
corresponding base lines; insertions are constrained to a position within that
base. Missing, stale, oversized, or redacted bases reject the patch. This
conservative limit means a larger or credential-containing persona cannot be
modified by this model adapter without a separately designed safe contract.
`lint_proposal` requires a caller-supplied lint callback as a **second** gate;
neither validation nor lint writes or applies the patch. The Workshop adapter
must apply it to an isolated candidate, run persona lint, oracle, canary, budget
guards, and human gates **itself** before recording stage evidence. A model
assertion cannot become `mimic/workshop.Evidence`.

Diagnostician's `hypothesis` is one of `NETWORK`, `CODE`, `DATA`, or
`ENVIRONMENT`, not freeform prose. Its `next_action` accepts only
`RETRY_NETWORK`, `RECHECK_DATA`, `REPAIR_PERSONA`, or `ASK_HUMAN`;
`REPAIR_PERSONA` requires a patch checked against the same full base, while
other actions require an empty patch. Call
`diagnostic_action` to turn `ASK_HUMAN` into a typed `Ask`. `invoke` tries once
plus at most three retries, then returns `Ask(question, options, reasons)`.
Persist `Budget(replans)` with the Workshop checkpoint and call `replan` on
each replan; the third request returns `Ask`. The Workshop adapter pauses the
run and presents this question to an operator; this module does **not**
implement a messenger button or persistent checkpoint.

Reporter can only select `NO_COMMENTARY` or `REVIEW_REQUESTED`. The
deterministic `render_report` inserts every number and gate status from
caller-provided `ReportFacts`. These must come from engine-verified artifacts
in production, not from model text or a manually supplied JSON file. The
renderer does not promote anything; eligibility requires all supplied
lint/oracle/canary/human flags and is still not a promotion action.

Schemas and prompts are mirrored under `priv/autopilot/`; a parity test
compares them to the runtime schema/prompt. This keeps decoding independent
of schema-constrained generation. An operator can invoke
`autopilot.cli(["invoke", "classifier", "examples/g_classifier_pack.json", "local"])`
with a running local server, or
`autopilot.cli(["report", "examples/g_report_facts.json"])` offline. Both
examples are **synthetic**; the latter must not be treated as verified evidence.
The parent CLI may dispatch these arguments to `autopilot.cli`.

## Validation status

- Isolated G `gleam test` harness: mock inference exercises retries,
  malformed/unknown fields,
  citation bounds and integral offsets, multiline credential suppression,
  byte bounds, hunk whitespace/counts, routing, endpoint denial, patch lint
  callback, persona-base binding, diagnostic enums/escalation, schema/prompt
  parity, and deterministic reporting.
- `gleam format` run for owned Gleam files. At this snapshot the full project
  `gleam test` cannot compile because unrelated `mimic/lab` and
  `mimic/recorder/tls` modules are still missing.
- **Unverified:** G1 historical classifier schema validity ≥95%; G2 ten
  historical diff classifications and lint-valid patches; G3 end-to-end
  PB injected oracle failure / messenger confirmation. No upstream, live
  model, canary, or measured acceptance gate was run.
