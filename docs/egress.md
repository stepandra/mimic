# Reusable egress client (D2)

`mimic/egress` is a **direct, buffered HTTP/1.1 transport**, not a fleet
scheduler or a streaming proxy. The caller explicitly supplies an `http://` or
`https://` origin (host and optional port, no credentials, path, or query).
`start(endpoint)` allocates a serial actor; its first `send(client, capture)`
connects lazily. Keep one `Client` per profile/origin, call `send` for each
request, and call `close` when the profile is retired. A `Capture` must name
the same origin. Fleet slot acquisition/release remains the fleet owner's
responsibility.

The actor owns **one socket** and serializes calls. It sends bytes from
`wire.render_request(capture)` without converting the ordered header list to
a map, so case, order, and duplicates survive. It reuses a socket only after a
complete framed response. `Connection: close` closes it after that response;
an already-observed idle EOF is reconnected before the next request. A close
racing the next send may instead fail that request. Any uncertain write,
timeout, parse error, or disconnect discards the socket and returns an error;
**no request is automatically replayed**, including non-idempotent POSTs.
The next explicit call may establish a new socket. A timed-out actor call is
killed rather than allowing a queued request to transmit later.

Responses support Content-Length, final chunked transfer encoding (including
chunk extensions), HEAD/204/304 no-body semantics, and up to four unframed
informational responses before the final response. Ordered response headers
are preserved. Limits: 5 s connect and per-request write/read deadline,
12 s actor call timeout including queueing, 8 KiB line, 64 KiB aggregate
header block, and 8 MiB decoded body. Bodies must be valid UTF-8.
`ttft_ms` measures elapsed time through the first final status line, not
streaming token timing. The buffer is decoded before return, so this client
does not provide demand-driven SSE streaming.

TLS uses system CA roots, `verify_peer`, HTTPS hostname matching, SNI, and
advertises only `http/1.1`; a negotiated other ALPN is rejected. HTTP/2,
protocol upgrades, redirects, proxies, bound-address egress, compressed or
binary response bodies, ambiguous Content-Length/Transfer-Encoding, trailers,
and close-delimited response bodies are unsupported and fail explicitly.
Declared non-JSON/SSE response media are rejected; absent `Content-Type` is
accepted only if the framed bytes decode as UTF-8, so callers requiring a
declared media type must validate that header themselves.
Do not enable fleet `Proxy` or `BoundAddress` profiles via this client.
Ingress SSE relay still uses its separate streaming socket path, not this
buffered reusable socket.

Tests use only synthetic loopback TCP fixtures. `egress_test` verifies two
requests over **one accepted socket**, `Connection: close` and observed EOF
reconnection, exact outgoing ordered headers, chunked and Content-Length
framing, informational/no-body cases, header/body limits, UTF-8 rejection,
and timeout. A manual synthetic loopback TLS check rejected a self-signed
peer. No live upstream, trusted-chain/hostname fixture, latency profile, or
TLS fingerprint has been measured. Verified HTTPS depends on the Erlang/OTP
SSL trust store on the deployment host; a missing trust store must fail closed.
