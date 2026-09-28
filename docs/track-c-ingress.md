# Track C / D4: local oracle, acceptance check, ingress

These paths are compatibility test infrastructure. All fixtures are synthetic;
no live upstream behavior, TLS/JA4 profile, throughput, or latency target has
been measured here.

## Local lab

`mimic/lab.start(port)` binds `127.0.0.1` HTTP/1.1 (`0` allocates a port).
`start_with(port, Config(required_headers, failure_status, status,
response_body, sse_events))` configures literal required header values,
failure status, deterministic body and scripted SSE `data:` events.
`last(port)` returns the latest parsed method/target/version, ordered/cased
duplicate headers and UTF-8 body. `requests(port)` holds at most 32 **sanitized
reconstructed frames** in memory: auth/cookie/API-key header values are
redacted; header whitespace is normalized, so these are not raw captures.
Nothing is persisted. `count(port)` counts successfully sent scripted events.
`stop(port)` closes the listener. Transfer-Encoding, malformed framing,
binary UTF-8, oversized body and non-HTTP/1.1 are rejected explicitly.
ALPN/TLS forcing is not implemented by this plain-h1 oracle.

## Acceptance check

`check.run(endpoint, captures, max_ttft_ms)` invokes `replay.send` against the
explicit endpoint for each capture; empty selections fail. `run_with` accepts
an injected sender for deterministic tests. The JSON verdict contains status
classes (`2xx`, `3xx`, `4xx`, `5xx`, invalid), a coarse 4xx reason dictionary,
and per-response TTFT envelope classification. It does not treat a 4xx or a
slow 2xx as accepted. `check.cli` accepts
`<corpus-root> <explicit-endpoint> [max-ttft-ms]` or
`<corpus-root> <explicit-endpoint> --id <id> <max-ttft-ms>`.
It does **not** run against a live endpoint by default.

## Ingress

`ingress.start(port, origin, client_key, upstream_key)` is a single-key,
explicit-origin local mode. CLI `serve <port> <origin>` reads
`MIMIC_INGRESS_KEY` and `MIMIC_UPSTREAM_KEY` from the environment, never CLI
arguments. `start_as(Config(...), dialect.Openai)` chooses an OpenAI upstream;
Anthropic is the default. Mist binds `127.0.0.1`, requires one client
`x-api-key` or `Authorization: Bearer ...` header, allows only POST
`/v1/messages` and `/v1/chat/completions`, and has no management route.
Plain HTTP upstream is allowed only to loopback; HTTPS uses verified
certificate/hostname validation. The target path, upstream auth and
unsupported cross-dialect fields are explicit. Non-stream responses are
bounded to 1 MiB. SSE is read one upstream segment at a time after downstream
send, translated by `mimic/dialect.feed`, and requires a terminal event
through `finish`; it is not fully buffered. Malformed stream and unsupported
compression fail rather than silently lose fidelity. Gemini, WebSocket,
HTTP/2 outbound, binary request bodies and compressed upstream responses
are unsupported. No performance gate has been verified.

`start_managed(port, origin, state_dir, provider, credential_id, dialect)`
requires a precreated private state directory, a gated
`workshop.pointer(state_dir, provider)` and `read_artifact`, and an auth-store
credential. Per request it verifies the client key through
`mimic/ingress/keys` (or an explicitly configured legacy env key), reloads
the active TOML persona, lints and materializes the outgoing `Capture`.
The outgoing socket uses the materialized header order/case and validates
Host/Content-Length. Client credentials are stripped; the upstream bearer value
is supplied at runtime to an authorization passthrough rule, preserving its
position, or appended exactly once if the profile has no authorization rule.
The secret value is never part of the stored persona.
It acquires/releases a local-loopback `fleet` lease and records
response headers/status through the durable `quota/worker` before delivering
the response. Expired/missing credentials, missing active pointer, bad
persona and failed quota recording deny forwarding. `serve managed <port>
<origin> <state-dir> <provider> <credential-id> <anthropic|openai>` starts
that mode. Bound-address/proxy egress remains explicitly unsupported by D2.
Inbound Mist normalizes request header names; managed outgoing fidelity is
the **materialized persona**, not the incoming SDK frame.

`keys.create/revoke/verify/list_metadata` uses salted HMAC-SHA256 verifiers
under the explicit absolute 0700 state directory, with 0600 verifier files.
Only identifiers appear in metadata; secret values are never returned,
logged, or written. Revocation is checked on every managed request.

## Verified / not verified

Synthetic localhost socket tests cover lab ordered/cased/duplicate headers,
required-header failure, SSE counters, ingress rejection, Anthropic SSE
relay, OpenAI-to-Anthropic IR request and response conversion, and check
verdict sensitivity to bad headers/TTFT. A scratch integration overlay of
A/B/D/E/F modules ran `gleam test`; there was no live upstream call. The
integrated control test additionally exercises API draft non-activation,
gated synthetic-lab promotion, a real managed ingress socket round-trip,
correct upstream Host, and immediate denial after key revocation.
Production-signed UI promotion, SDK compatibility, actual SSE first-byte
latency, verified external HTTPS, ALPN/TLS fingerprints and p50 overhead
targets remain unverified gates.
