# Track H: observability and local control plane

## Implemented

`mimic/observability` supplies an in-memory redactor. `register`/`register_all`
accept exact secret values; `headers` preserves ordered/cased/duplicate header
names while replacing sensitive values; `json_body` recursively redacts
sensitive property names and registered values appearing in strings. Invalid
JSON fails closed. `log` emits only explicitly supplied structured fields,
never captures bodies by default. Counters (`Requests`, `Accepted`, `Rejected`)
and gauges (`QuotaUtilization`, `DriftIndex`) are retained by a dedicated ETS
owner; metric label values are SHA-256 digests, not raw credential/persona
names or tokens. `mimic metrics`, `mimic obs metrics`, and
`mimic obs redact <json>` route to `observability.cli`. Do not place real
credentials in command-line JSON; use the in-process redactor for private data.

`mimic/management` provides a loopback-only mist HTTP service with an
environment-only `MIMIC_MANAGEMENT_KEY` (minimum 32 characters), constant-time
Bearer comparison, 64 KiB body limit, exact `application/json` content type for
writes, strict field and identifier validation, Host/Origin checks, no CORS
headers, no cookies, no-store responses, `nosniff`, and restrictive CSP. Assets
in `priv/management/` are vendored; no runtime downloads or external JS/CSS.
The panel holds the management key in tab memory only, sends it in an
Authorization header, and uses DOM `textContent` for response rendering.
Responses only serialize typed metadata; credential/key token values are
neither listed nor echoed from successful writes. Backend error details are
never reflected to clients.

The HTTP API is a typed callback boundary (`management.Backend`) so there is
**no second persona, credential, or ingress-key store**. The `mimic/control`
adapter validates persona content with B `persona.parse`/`lint`, stores immutable
drafts with F `workshop.artifact`, reads the active digest with
`workshop.pointer(state_dir, provider)`, and calls F
`workshop.promote(state_dir, run_id, signature)` for activation. D
`auth.list_metadata`/`save`/`delete` owns credentials. C
`ingress/keys.create`/`list_metadata`/`revoke` owns the salted-hash client-key
store which ingress verifies on each request. The ingress and management
processes use the **same precreated private state-directory argument** in the
built-in managed configuration. Quota summaries read the durable ledger;
drift summaries read a typed report index populated by `control.record_drift`.
Arbitrary pointer writes or
direct activation are intentionally unavailable: draft → gated Workshop run
→ signed promote → ingress sees active pointer. Immutable promoted artifacts
are not deleted via this API.

### Routes

All `/api/*` routes require `Authorization: Bearer <MIMIC_MANAGEMENT_KEY>`.
Browser requests with `Origin` must come from the loopback panel origin.

| Method/path | Purpose |
|---|---|
| `GET /api/health` | Authenticated status |
| `GET /api/metrics` | Plaintext counters/gauges with opaque labels |
| `GET /api/personas/:provider/active` | Active Workshop digest |
| `PUT /api/personas/:provider/drafts` | `{ "content": "<persona TOML>" }`, validate and store immutable candidate; **not active** |
| `POST /api/promotions` | `{ "run_id": "...", "signature": "..." }`, gated Workshop promote |
| `GET /api/credentials` | Metadata IDs and `expires_at_ms` only |
| `POST /api/credentials` | `id`, `access_token`, `refresh_token`, `expires_at_ms`; no token returned |
| `DELETE /api/credentials/:id` | Delete credential |
| `GET /api/keys` | Ingress-key metadata IDs only |
| `POST /api/keys` | `id`, `token` (minimum 32 bytes); no token returned |
| `DELETE /api/keys/:id` | Revoke ingress key |
| `GET /api/quotas`, `GET /api/drift` | Typed integer summary arrays |

### Startup and validation

The root CLI routes `mimic management serve <private-state-dir> [port]` through
`mimic/control` to `management.serve_with`. It blocks and binds
**127.0.0.1 only**, using port 9090 by default. Start with
`MIMIC_MANAGEMENT_KEY` supplied in the process environment (never a CLI
argument), then visit `http://127.0.0.1:9090/`. For example, an operator can
check `GET /api/health` with an Authorization Bearer header and JSON writes
must also set `Content-Type: application/json`.

Development asset serving can fall back to the checked-out `priv/management`
directory. `gleam export erlang-shipment` includes the application's
`priv/management` directory. The integrated shipment was exercised from
`/tmp`, without relying on the source working directory.

## Verified and unverified gates

- Verified in isolated H worktree with `gleam test`: synthetic redaction,
  recursive JSON, opaque metric label, unauthorized write callbacks never
  invoked, content-type/Origin/path validation, metadata-only responses,
  distinct draft and promotion routes.
- Integrated synthetic checks cover API-created drafts remaining inactive,
  rejected unapproved promotion, a separately gated lab pipeline activating a
  candidate, managed ingress seeing the active persona and forwarding the
  correct upstream Host, and key revocation denying the next request.
- Browser QA against the exported shipment covered JS/CSS loading, API
  authentication, credential/key creation and deletion, draft creation and
  non-activation, rejected invalid writes, and absence of JS console errors.
- Still unverified: production-signed promotion end to end through the UI,
  full deployment secret scanning against a real auth directory, and real
  quota/drift workloads. There is no generic immutable-artifact CRUD endpoint;
  draft inventory/deletion needs a separate typed index.
- No real upstream, credential, or private-token fixture was used.
