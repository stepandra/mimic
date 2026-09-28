# Track B — persona and ordered HTTP/1.1 replay

The checked-in [`b_synthetic.toml`](../examples/b_synthetic.toml) is a synthetic
fixture, **not** a measured Claude Code or other upstream baseline. Profiles
express observed contract rules; they do not assert a reproducible ClientHello,
JA4, HTTP/2 behavior, timing distribution, or upstream acceptance.

## Schema

Root `forbidden_betas = [["a", "b"]]` and `notes = ["..."]` are optional.
`[meta]` requires `client`, `version`, and `source` (`synthetic`, `hand`, or
`measured`). `[transport]` accepts `alpn = "http/1.1"` or `"none"` for an
observed HTTP/1.1 connection without negotiated ALPN; `ja4` cannot be
reproduced and is rejected by lint. `[identity] session = "passthrough"` and
`[timing] jitter_ms = 0` are the supported initial values. Both tables may be
omitted. Header rules are ordered `[[headers]]` tables:

- `name`: exact emitted case; duplicates and relative positions are preserved.
- `source`: `fixed` (`value` required), `passthrough` (take the corresponding
  occurrence case-insensitively from the sample), `uuid` (fresh UUID v4),
  `timestamp` (current Unix milliseconds), or `betas` (only for
  `anthropic-beta`, from the applicable ordered `[[betas]]` rules).
- `request_kind`: optional exact capture kind or `*` (default). A Host rule is
  mandatory, exactly one must apply to each emitted kind. `value` must be empty
  or absent for non-fixed sources. Fixed authentication credential headers are
  forbidden; no credential value belongs in a persona.

Each `[[betas]]` table has `value` and optional `request_kind`. A forbidden
combination applies if **all** values in a group would be emitted for one kind.
These constraints must come from your own corpus/analysis; the project does
not ship purported upstream beta combinations.

`persona.parse`, `lint`, `render`, and `draft` expose the typed API. `draft`
requires nonempty captures from one client/version/ALPN with HTTP/1.1 request
versions. It emits only header names present in every sample of each
request-kind; values fixed across samples become `fixed` except Host,
Content-Length, sensitive names, and redaction markers, which remain
`passthrough`. Host therefore follows the explicitly supplied runtime request,
not the ephemeral port of a captured lab. Stable beta header values remain
separate fixed occurrences, preserving duplicates and comma whitespace.
Variable values are passthrough; ordering, missing headers, and conditions
must be reviewed. The notes explicitly record what was not inferred. The
draft `source` is `synthetic` pending independent provenance review.

CLI entrypoints (parent command router supplies the subcommand arguments):

```text
persona lint|validate <persona.toml>
persona draft <corpus-root> [client version]
replay [run] <persona.toml> <corpus-root> <capture-id> <explicit-endpoint>
replay <persona.toml> --sample <corpus-root> <capture-id> --endpoint <explicit-endpoint>
```

The draft command emits TOML; filter client/version when the corpus is mixed.
Replay reports only status and TTFT, not body or credentials. The endpoint
must be an operator-owned fixture unless a live test has been explicitly
approved and configured.

`replay.materialize` replaces the entire ordered header list; it does not
merge unprofiled fields. It rejects missing passthrough occurrences, forbidden
beta combinations against the actual emitted headers (including fixed and
passthrough values), unresolved `[REDACTED]` headers, malformed fields, request
transfer encoding, h2/JA4, and incorrect UTF-8 Content-Length. An HTTP/1.1
capture may have `http/1.1` or `none` recorded as its ALPN.
`replay.render_request` emits an HTTP/1.1 request frame without header
normalization. `replay.send` requires an explicit
operator-supplied `http://host[:port]` or `https://host[:port]` authority and
does not follow redirects. The captured Host is intentionally not rewritten,
so a loopback echo fixture can inspect the original frame. For HTTPS, the
socket uses peer/hostname verification and advertises only HTTP/1.1; it
**does not** reproduce TLS fingerprints. Connect/individual receive timeouts
are 5 s, with a 15 s total response deadline; requests and responses are
limited to 2 MiB, each response header block and trailer block to 64 KiB.
Response framing consumes bounded informational 1xx blocks before the final
response (101 upgrades fail explicitly); HEAD, 204 and 304 final responses
have no body even when Content-Length or Content-Encoding describes a
representation. UTF-8 response bodies with decimal Content-Length, chunked
(quoted extensions and trailers validated), or close-delimited framing work.
Malformed field names and Transfer-Encoding/Content-Length ambiguity fail
before body parsing. Binary
bodies, other transfer/content encodings and IPv6 literal endpoint authorities
currently fail explicitly. `send` does not retry or follow redirects; it
collects a bounded response rather than streaming SSE events incrementally,
so long-running/infinite streams time out.

## Validation status

Replay loopback tests cover raw-byte round-trip, chunked SSE with a multibyte
character split across chunks, HEAD/204/304 no-body framing, split interim and
final responses, quoted-semicolon chunk extensions with BWS, malformed and
ambiguous headers, complete oversized headers, prohibited representation
trailers, unsupported upgrades, bounded interim chains, oversized responses,
and a fragmented response sent as 800 one-byte writes. The one-shot Erlang
oracle is synthetic. Full-project `gleam test` remains subject to other
tracks' modules building;
these tests do not prove the ≥90% baseline agreement or real upstream
acceptance gates in SLICES.md, nor a TLS ClientHello/HTTP/2 fingerprint or
HTTPS integration. No live provider request was made.
