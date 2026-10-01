# F27 configured Devin catalog — verified owned packet, root admission pending

## Scope and provenance

The prior packet was read **from the exact existing Git object**
`63a0096eadf23e5632a8a86bcd18d1bd294f61ab`, independently resolved from recorded
prefix `63a0096e` and confirmed as `refs/heads/umbrella5-f27` in the retained
checkout. The retained checkout was read-only. No branch was imported: that
history contains a rejected F24. Its old root patches and admission claims are
not carried forward.

This packet reuses that catalog, explicit aliases, native `models.Model`
contract, bounded validation, metadata provenance, synthetic wire inspections
and workflow. It adapts them to the **current admitted F23 Chat and corrected
F24 Messages** gateway APIs. It adds account/origin binding at the actual
runtime-selected adapter context, rather than using dispatch's first account.

No changes to the current Messages SDK-derived builder, stream projector or
parent-owned complete-document depth correction. No F22 transport replacement,
root gateway/config/CLI edit, dependency edit, reference mutation, commit,
publication, child agent, real account or upstream/CPA connection.

## Operator-approved configuration, not discovery

Optional root field (all values below are **synthetic**):

```json
{
  "devin_catalog": {
    "models": [{
      "id": "devin/synthetic-canonical",
      "uid": "exact-synthetic-native-UID",
      "max_tokens": 2048,
      "images": false,
      "aliases": ["devin/synthetic-alias"]
    }]
  }
}
```

- Omission preserves original `devin/swe-1-7` -> `swe-1-7`, 64000 tokens,
  images true. An explicit catalog **replaces**, rather than extends, baseline.
- Each account's `models` remains a nonempty, unique **public-ID allowlist**.
  Canonical and alias IDs do not enable each other. Only enabled IDs are
  registered/listed/executed. Catalog entries alone grant no account access.
- Public IDs are exact, case-sensitive
  `devin/[A-Za-z0-9][A-Za-z0-9._-]*`, at most 256 UTF-8 bytes. No trimming,
  case folding, suffix/effort inference, arbitrary URL or fallback.
- Native UIDs are opaque visible-ASCII tokens, 1–256 bytes. No interpretation
  of punctuation, signatures or upstream endpoints.
- `max_tokens` is a required integer in 1–128000; `images` a required boolean;
  `aliases` defaults to `[]`. Aliases use the exact canonical UID/limits/images.
- 1–64 canonical rows, at most 256 total public IDs, globally unique public
  IDs and canonical native UIDs. Conflicting metadata for a shared UID rejects
  even through the lower typed `models.validate` API.
- Unknown fields, duplicate decoded keys (including escaped spellings), nulls,
  wrong scalar/container types, control characters and collisions reject.
  Raw and already-parsed catalog decoding have a 65536-byte, depth-8,
  4096-node budget. Typed constructors enforce row/ID/token/metadata bounds.
- Unknown/unenabled IDs, protocol/auth/capability mismatches, invalid limits,
  mismatched body model/stream, unsupported input media/tools/options reject
  before runtime/credential acquisition. Both buffered and SSE output echo
  the requested **public ID**, never the native UID.

## Admission and isolation

The registration/listing source of truth is the actual combined current
Chat/Messages registry row: `openai-chat`, `anthropic-messages`, `generate`,
session-token auth, Buffer/Stream/Tools and explicitly configured Images.
There is no Responses, count, Audio, WebSocket or Continuation admission.
Messages SSE remains the current **bounded delayed buffered-to-SSE**
construction; a Stream capability is not a token-latency claim.

The opaque `configuration.Configured` is constructed from the validated
catalog and Devin account ID/origin/allowlists. The adapter resolves the native
mapping using **actual selected `Context.account` plus exact origin** after
runtime model/auth/account filtering, including safe-rejection failover.
A stale/foreign account, changed origin or model enabled only on another
account fails closed. Credentials still come exclusively from the existing
runtime store/manager. No token enters model metadata, logs or captures.

The existing numeric `127.0.0.1`-only bridge authority gate remains. Remote
Devin, hostname `localhost`, IPv6, paths/queries and arbitrary URLfetch remain
unadmitted; catalog configuration never unlocks them.

## Root hooks and executable evidence

[F27_ROOT_HOOKS.md](F27_ROOT_HOOKS.md) specifies the **compiled current-base**
schema/hooks for parent-owned integration. The owned source compiled with
Gleam 1.18.1 and `ERL_FLAGS='+S 2:2 +A 2'` before that handoff.
Focused current-runtime/regression evidence is recorded below. The actual root
workflow remains parent-owned and unexecuted here; no old test count is borrowed.

Executed focused `gleam test` run on a hash-recorded, byte-for-byte current
dependency closure (only F27 + F23/F24/wire tests discovered, no root overlay):

```sh
ERL_FLAGS='+S 2:2 +A 2' mise exec gleam@1.18.1 -- python3 -B docs/devin/f27_focused.py
```

Parent's actual root/source workflow after wiring, without overlays:

```sh
ERL_FLAGS='+S 2:2 +A 2' mise exec gleam@1.18.1 -- python3 -B docs/devin/f27_local_cli.py
```

The smoke covers authenticated discovery/filtering, exact public ID -> native
UID/limit mapping through existing runtime, Chat JSON/SSE, corrected Messages
JSON/SSE complete reconstruction (including interleaved tools and qualified
synthetic signed thinking), different synthetic account credentials, actual
second-account selection, safe-rejection failover, omission baseline, invalid
catalog/auth configuration, pre-I/O denials and resource cleanup.
The unchanged F24 focused tests retain depth-124/125 equality and
depth-126/127/128 rejection in **both** representations.

### Verification ledger

- Scoped `gleam format`: passed. Actual current-base `gleam build`: passed
  (6.89 seconds in the final assigned run).
- `f27_focused.py`: passed. **74 tests, no failures**, one run: 18 F27, unchanged
  19 F23 Chat, corrected 29 F24 Messages and unchanged 8 native wire tests.
  The dependency closure contained **70 current Gleam modules**, each copied
  byte-for-byte and hash-recorded. No source overlay, alternate codec or stub.
  Native mapping, real loopback sockets, actual runtime selection/failover,
  account-specific synthetic credentials and zero-I/O rejection assertions
  passed; both corrected full-document depth regressions passed.
- The granted serialized format/build/focused run took **40.741 seconds**,
  then the slot was released. The generated project and its synthetic state
  were removed. Only logs/input hashes remain under `build/f27`.
- Both Python scripts were syntax-checked via `ast.parse`. Root smoke `main`
  was **not executed** here; syntax checking is not a gateway workflow pass.
- Actual root/source/shipment workflow: parent will apply the exact hooks
  after the owned packet's auto-import and execute the workflow there.
- Root/source/shipment and full acceptance are parent-owned. `--shipment`
  smoke mode is available, not shipment evidence.
- No live discovery, upstream support/entitlement measurement, remote
  qualification, native client, installed SDK or CPA differential.

| Retained evidence | SHA256 |
| --- | --- |
| `build/f27/validation.log` | `3716157eab27aadd11d188a4a585916c6e39c16a62729193becadc64ea663bee` |
| `build/f27/focused-inputs.json` | `2637f5ae135530bb3ebbdad9426ab4e1bdd185700267b4635b30ce63ed73ef41` |

Protected input hashes, unchanged at finish and identical to focused inputs:

| Protected file | SHA256 |
| --- | --- |
| `messages.gleam` | `6859d96cccc69fbfc04bc96191c458a962e27c7ecc1ae302a3397fe75a7e4533` |
| `messages_stream.gleam` | `2c5a49c40d0ecc119f1809b3c4cdc74660ce1f5f873c14b2c69d63c9ee33c52e` |
| `test/devin_messages_projection_test.gleam` | `551bb4adae66b36eecb456831da82f5f225770d124d3c2ed6dd55e03ce39a673` |
| `providers/transport.gleam` | `138b07ba2d05264024bca270070c668eb993cc49a5e5096948874c61c4f2a0f4` |

## F01 remains honest

The new F01 source inventory does not close the outstanding `devin-models`
`catalog-background-policy` obligation:
[SOURCE_MAP.md](../parity/final-v1/SOURCE_MAP.md#L149) still requires exact
approved fixture injection/provenance and startup/executable identity;
Antigravity's unconditional updater remains unresolved. This local operator
catalog/schema is not a substitute for that qualification, not an upstream
support measurement, and does not improve historical strict conformance.
