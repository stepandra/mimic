# Track A: HTTP/1.1 capture, corpus, and drift

This implementation covers a **deliberately restricted** HTTP/1.1 compatibility
surface. Captures in tests and `examples/a_synthetic.http` are synthetic. No
upstream CLI version pair, TLS ClientHello, ALPN negotiation, JA4, performance
profile, or external provider acceptance has been measured here.
The example file uses LF for readable source control; `parse_request` requires
actual CRLF separators on its input.

## Public contracts

- `wire.parse_request(raw, client, version, endpoint, request_kind) -> Result(Capture, String)`
  parses a complete request string, preserving header order, duplicate names,
  name case, and body. `wire.render_request(Capture) -> Result(String, String)`
  checks framing and renders the request.
- `recorder.record_request(root, raw, client, version, endpoint, kind) ->
  Result(String, String)` parses and persists a locally obtained request. The
  offline CLI is `mimic record capture <root> <request-file> <client>
  <version> <endpoint> <kind>`; it reads the request from a file, not argv.
- `corpus.encode(Capture) -> String` and `corpus.decode(String) ->
  Result(Capture, String)` use versioned JSON schema 1. **`encode` is lossless
  and is not a safe persistence boundary.** Only `corpus.add(root, Capture) ->
  Result(String, String)` redacts before storing. `load(root, id)` verifies
  BLAKE3 on the uncompressed JSON; `list(root)` reads the corpus. `select`
  filters client/version/endpoint/request-kind, using `""` as a wildcard.
  `export`/`cli(["diff-export", ...])` emits newline-delimited redacted capture
  JSON. `rotate(root, older_than_days)` removes entries older than that many
  whole days, based on filesystem modification time.
- `differ.diff(before, after) -> Result(Report, String)` compares ordered/cased
  header names and values, ordered comma-separated Anthropic beta labels, JSON
  field presence/types/array shape, HTTP version, ALPN, and supplied JA4.
  `report_json(Report)` emits schema-1 change JSON; `human(Report)` renders
  lines. `cli(["json"|"human", root, before_id, after_id])` loads stored records.

Each stored record is `<BLAKE3(redacted-schema-1-JSON)>.json.zst`, with actual
zstd compression. The immutable file is created through a private temporary
file plus hard link; concurrent identical adds deduplicate only after verifying
the existing regular object has identical compressed bytes. Corrupt objects and
symlinks fail closed rather than reporting a successful add. Reads reject
symlinks and bound file size before allocation. The store uses an
**on-demand index** by scanning validated IDs and decoding records, rather than
a separate transactional index file. This is adequate for small QA corpora but
has O(n) selection cost. `b3sum` and `zstd` must be installed on `PATH`; missing
tools fail explicitly. There is no SHA-256 fallback. Corpus files are mode
0600; choose an operator-owned state directory outside the source tree.
Processes also create short-lived, mode-0600 temporary files for the redacted
JSON and zstd data. Records and command output have a 16 MiB safety bound.

## Privacy contract

`add` replaces every non-allowlisted header value with `[REDACTED]` without
changing header names, order, or case. `User-Agent`, Authorization, cookie,
API-key, tracing, and unknown header values are removed. `Host` is retained
only when it exactly matches the already retained operator-supplied endpoint
authority; otherwise it is scrubbed. Only recognized
`Content-Type` media types (case-insensitive JSON and application/*+json, with
supported UTF-8 charset), `Accept` media types, date-form Anthropic version,
and dated beta identifiers retain values. URL query order and recognized
parameter names remain, with all values `REDACTED`; unknown query keys and
unknown path segments become `redacted`/`REDACTED`. Userinfo (`@`) and
fragments (`#`) fail closed. The hostname remains operator-supplied and
must be reviewed before capture; arbitrary account-like hosts are not inferred.

JSON is recursively parsed: object/array structure and allowlisted protocol
field names remain. Unknown or sensitive object names, including credential-
keyed maps and arbitrary tool argument keys, reject the capture explicitly
rather than exposing keys or replacing them with colliding placeholders.
Arbitrary strings (including messages, tool arguments, IDs, tool names,
unknown fields) become `[REDACTED]`; arbitrary numbers become `0`. Safe
structural values are retained only for validated vendor-prefix `model` identifiers
(restricted character set), enumerated `role`, `type`, `stop_reason`, selected
bounded generation numbers (`max_tokens`, `temperature`, `top_p`, `top_k`), and
booleans. This preserves e.g. Anthropic request shape for replay, without
retaining prompt text. Unknown semantics are redacted, not guessed. The body
is reserialized and `Content-Length` corrected in place. The redaction policy
is intentionally lossy: a stored record is *safe structure*, not a byte-for-byte
copy of a request that carried private data.

Non-UTF-8, unsupported content or transfer encodings (including chunked),
ambiguous Content-Length, HTTP/2, binary bodies, and SSE body persistence fail
explicitly. `wire.parse_request` accepts SSE as UTF-8, but the corpus refuses
to store arbitrary SSE content until a safe event-wise redaction policy exists.
No transport fingerprint is inferred: parser-created captures set
`Transport(alpn: "http/1.1", ja4: None)`. TLS-recorded HTTP/1.1 requests with
no negotiated ALPN can be rendered with `alpn: "none"`; this is not a claim
about a TLS fingerprint. The differ prints `unknown` for missing JA4.

## Gates and scope

Synthetic tests cover ordered/cased duplicate headers, stale lengths,
unsupported framing/H2, round-trip encoding, real BLAKE3+zstd storage,
deduplication, nested-secret redaction, filtered selection, offline capture,
header casing-only drift, beta order, and JSON shape drift. The A1 native
CLI/MITM integration and a real installed-client smoke session are separate
gates; do not interpret these synthetic fixtures as an observed upstream
profile. No npm pair (2.1.258 vs 2.1.270) was fetched or tested.
