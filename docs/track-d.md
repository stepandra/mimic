# Track D — auth, fleet and quota

## Implemented interfaces

- `mimic/auth`: configurable Claude OAuth authorization-code flow with PKCE
  S256, CSRF state, 120-second loopback callback CLI, token exchange, refresh,
  metadata-only listing and delete. `mimic/auth/worker` serializes refresh per
  credential, shares the refreshed result across queued callers, backs off
  5 seconds to 5 minutes, and requires reauthorization after token-endpoint
  4xx. The embedding supervisor owns worker lifecycle.
- `mimic/auth/storage`: operator-supplied **existing absolute** `0700`
  directory. Credential JSON is plaintext at `0600`, written using a private
  temporary file, `sync`, and atomic rename. Existing symlink/nonregular files
  and nonprivate modes fail closed. No age encryption is claimed.
- `mimic/fleet`: policy selection, round-robin new sessions, sticky identity,
  quota cooldown and bounded in-flight leases. `start_pool` owns the routing
  state in one BEAM actor; `release_slot` is required after each request,
  including failed connections. Double release cannot free another lease.
- `mimic/quota`: parses ordered `WireResponse.headers` case-insensitively for
  Unified 5h/7d/7d_oi utilization, reset, status, global status and
  `Retry-After` seconds/HTTP-date. `quota/worker` serializes updates and
  atomically persists the ledger under `quota-ledger.json`.

Times are integer milliseconds except upstream numeric reset values in Unix
seconds (converted to milliseconds); RFC3339 reset values are also accepted.
Invalid headers do not invent a window.
429/529/rejected responses cool the credential for at least 60 seconds, or
until the later valid reset/Retry-After.

## CLI login

`mimic auth login claude` requires all of:

- `MIMIC_CLAUDE_CLIENT_ID`
- `MIMIC_CLAUDE_AUTHORIZE_URL`
- `MIMIC_CLAUDE_TOKEN_URL`
- `MIMIC_CLAUDE_REDIRECT_URI` (`http://127.0.0.1:<port>/<path>` or `localhost`)
- `MIMIC_STATE_DIR` (pre-created absolute `0700` directory)

The command prints the authorize URL only after its loopback listener is
ready, retains state/verifier in-process, waits for a GET callback at the exact
path with matching state, exchanges the code, stores the token and returns
only id and expiry metadata. It does not launch a browser or select a live
endpoint by default. Never supply authorization codes, refresh tokens or API
keys through CLI arguments or record the URL in diagnostics.

See the **synthetic** configuration outline in `examples/d_auth.md`. The
parent CLI must dispatch `auth.cli(args)` for this command to be reachable.

## Integration contract

1. Construct `fleet.Profile(id, upstream_url, LocalLoopback, max_in_flight)`
   for an explicitly configured loopback HTTP endpoint. `Proxy` and
   `BoundAddress` are rejected until an actual binding transport exists.
2. Load credential via `auth.load(store, id)` and use only in the trusted
   egress path; never put `Credential` in capture or log values.
3. `fleet.acquire(pool, ledger_snapshot, session_id, now_ms)` yields a
   `Selection(profile, session_id, lease_id)`. Release it on all completion
   paths. A sticky session will **not** switch profiles during cooldown.
4. `quota/worker.record(writer, id, response, now_ms)` persists a new ledger;
   pass a fresh snapshot to selection. `quota.lookup` exposes only
   utilization/status/reset/cooldown metadata.

The fleet actor is a **routing/lease pool, not a socket pool**. It does not
claim connection reuse, per-credential IP binding, TLS fingerprint, or
streaming transport. The separate egress transport track must own persistent
clients per selected profile; no proxy or bound-address support can be
advertised before verification. `auth.list_metadata` excludes token values.
No client API-key registry is included; ingress/management must coordinate
that separately.

## Evidence and remaining gates

- `gleam test`: synthetic local token endpoint, PKCE RFC vector, wrong state
  and callback path rejection, concurrent singleflight refresh, 4xx
  reauthorization block, symlink rejection, 0700/0600 modes, fleet
  rotation/sticky/cooldown/lease handling, Unified and Retry-After parsing,
  ledger persistence. No real credential or upstream file was read.
- `gleam format` run on this track's Gleam files.
- **Not verified:** real Claude authorization/refresh semantics, real account
  login, complete HTTP-date/reset variants observed in live responses,
  crash durability of renamed directory entries on all platforms, real
  connection reuse, per-credential proxy/IP egress, and SSE transport. The
  OAuth exchange currently posts form-encoded values; validate against
  provider behavior before a real account run. No live API/OAuth endpoint was
  contacted in testing.
