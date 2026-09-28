# Track A1: local TLS recorder transport

This is an opt-in QA proxy for an **operator-owned** HTTPS endpoint. It binds
only `127.0.0.1`, accepts only an exact `CONNECT host:port` matching one
configured `https://host:port`, terminates that tunnel with a leaf certificate
signed by a private CA, and creates a separate **verified** TLS connection to
the allowed upstream. There is no general-purpose forwarding or live upstream
test by default.

## Private CA and client setup

`mimic/recorder/tls.generate_ca(new_directory)` creates `ca.pem` and
`ca-key.pem`. The directory must not exist; it is created with mode `0700` and
the key is `0600`. The CA lasts seven days, the per-proxy leaf one day. The
leaf key is created in a random `0700` temporary directory and removed on
normal shutdown. OpenSSL is launched by executable plus argument vector,
never through a shell. Keep the state directory outside source control.

With the recorder CLI's `ca` and `tls` commands (or the corresponding Gleam
functions):

```sh
gleam run -- record ca /private/qa-state/recorder-ca
gleam run -- record tls /private/qa-state/corpus 8443 \
  /private/qa-state/recorder-ca/ca.pem \
  /private/qa-state/recorder-ca/ca-key.pem \
  https://qa.example.test:443
```

In a **separate, deliberately configured QA client process**, not a global
shell or system trust store:

```sh
HTTPS_PROXY=http://127.0.0.1:8443 \
NODE_EXTRA_CA_CERTS=/private/qa-state/recorder-ca/ca.pem \
your-qa-client
```

`NODE_EXTRA_CA_CERTS` is specific to Node.js; other clients need their own
per-process CA option. Do **not** install the CA system-wide, disable TLS
verification, or send real credential-bearing traffic to a test recorder.
The proxy passes the original request to the configured upstream unchanged,
including credentials; only the persisted copy is redacted.

## Boundaries and capture

- Only HTTP/1.1 over TLS is supported. ALPN is read from the **client-side**
  handshake: `http/1.1` or `none` if not negotiated. JA4 is `None`, not a
  fabricated fingerprint. A client negotiating h2 is rejected; an HTTP/2
  preface, binary UTF-8, encoded bodies, chunked requests, ambiguous framing,
  or an off-allowlist CONNECT fails closed.
- Request headers (including original spelling, duplicates, and order) and
  request body are passed intact to `wire.parse_request`. The resulting
  capture is persisted **only** through `corpus.add`, which redacts headers,
  paths, and JSON body values before writing. A failed parse/redaction/store
  returns a proxy error and does not forward the request.
- The request head is limited to 64 KiB and body to 8 MiB; response head to
  64 KiB and body to 32 MiB, with 30-second read timeouts. The proxy relays
  JSON/text/SSE responses, including chunked SSE incrementally.
  `Content-Encoding` and unsupported media types are rejected rather than
  decoded or recorded incorrectly. Response body bytes are relayed without
  UTF-8 validation; responses are **not stored** in A1's request corpus.
- The upstream uses `verify_peer`, hostname verification, and OS CA roots.
  `serve_with_capture` permits an explicit CA file for a local QA fixture;
  public `serve` does not replace OS roots. No upstream TLS fingerprint is
  claimed from the proxied client handshake.

The implementation accepts concurrent tunnels but closes each after one
request/response; it does not support pipelining, HTTP/2, WebSockets, arbitrary
CONNECT targets, request streaming, gzip/br/zstd transport decoding, or a
long-lived SSE stream beyond the 32 MiB/30-second-idle bounds. If the shared
corpus validator cannot represent a non-negotiated ALPN, capture fails closed
with 502 rather than inventing an ALPN value.
Client/version/request-kind metadata are `"unknown"` until explicitly supplied
by a caller with a trusted provenance source. No real CLI/upstream capture,
JA4 measurement, or external acceptance gate has been verified.

The local TLS tests generate a **synthetic** CA and leaf, perform an actual
CONNECT plus verified client/upstream TLS handshake, check ordered/cased
headers, chunked SSE delivery, allowlist denial, and rejection of an
untrusted upstream certificate. They make no external connections.
