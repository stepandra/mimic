# F22 bounded LOCAL transport safety checkpoint — NOT F22 DONE

## Result and evidence boundary

Recovered from a stopped worker, then compiled and tested only in the attached
replacement worktree. **24 focused synthetic transport tests passed** in the
serialized recovery4 run (16.855 seconds). The actual root CLI's synthetic H1
workflow passed in recovery8 (32.986 seconds). No full Gleam/integration gate,
shipment run, CPA differential, native client, remote request, enrollment or
LIVE inference was performed. Root/shared/config/egress/dependency/vendor/CI
files were not edited. `F22_ROOT.patch` is an unapplied admission proposal.

This is a recoverable **local safety checkpoint, not F22 DONE**, not a frozen
JJ handoff and not remote qualification. The parent freezes JJ after auto-merge.
No commit, bookmark, publication or raw Git mutation was performed.

| Evidence class | This checkpoint |
| --- | --- |
| Source | Historical CPA pin `acdace936fa7df2905500c7f5e0a97d683138dea`, pending F01; read source notes and actual local transport, not current upstream behavior |
| Synthetic provider sockets/TLS | Verified local CA positive, actual wrong CA and SAN failures, H1/no-ALPN observations, H2-only rejection, framing/cleanup negatives |
| Actual root CLI | Current assembled entrypoint, buffered Chat over synthetic loopback HTTP; permanent-grant restoration, six framing negatives, SSE denial and four config denials |
| Root TLS | **Blocked**: current Devin gateway config rejects HTTPS and passes no private CA; provider-only TLS success is not a root TLS workflow |
| Shipment/root patch admission | **Unexecuted/unapplied**; read-only patch applicability check passed |
| CPA differential / authentic native client | **Unperformed** |
| Remote TLS / ALPN / H2 / actual remote wire | **Unqualified and disabled** |
| LIVE / enrollment authorization | **Not authorized**; no CPA connections, credential reads, restart or reconfiguration |

The pin's `NewDevinHTTPClient` source declares no explicit H2-only/duplex
requirement; that is not executed production H1 evidence. No native TLS
fingerprint, upstream support or source-scope qualification is inferred. See
[SOURCE_CONTRACT.md](SOURCE_CONTRACT.md),
[EXPANSION.md](EXPANSION.md), [VALIDATION.md](VALIDATION.md) and
[the historical destination gate](../NEXT_PARITY_MERGE_VALIDATION.md).
Their earlier totals are not added to this checkpoint.

## Recovery provenance and preimages

Attached base: `ca86b531cea7e1a509ac8e6038604fe91819ac07`, with the parent's
`docs/devin/FINAL_UMBRELLA5.md` addition already present. That file is untouched.
The input checkout below was read-only throughout: no build, reference/index
mutation, source edit, cache/state/credential import or sibling/primary edit.

```text
/Users/jerryjohnson/dev/mimic/.delta/worktrees/drwwbajabsjx/mimic
prior thread: ksQQweRIpNx2Sm-sVPBOJ-0quJLOAFSuW5IBxBDu1fs15rdKs6m5jRdeJnRz
```

The three inputs and all 13 retained `build/f22/*.log` files were read and hashed
before recovery. The first attached `apply_patch` recreation matched all three
retained hashes exactly. The retained inputs were rehashed unchanged at the end.
These were mutable stopped-worker recovery inputs, **not an audited frozen
handoff**. In particular, the recovered 605-line test already split grouped
suffix cases and used `spawn_unlinked`, without a corresponding successful run.

| File | Attached base preimage | Retained recovery SHA-256 |
| --- | --- | --- |
| `src/mimic/providers/devin/bridge.gleam` | `1bb518e91ab1b47a27ecc29c720585285fdeadc9291233392685e753d89ad52e` | `0b2241c699c585f8082083aa673fe0d675a0555a72e97a63a18e5bfa17dcb7ad` |
| `test/devin_transport_qualification_test.gleam` | Absent | `43d4d7e16870229a1e8487fd36d432e2012ceadbc753548598cb09644a0e02ae` |
| `test/mimic_devin_transport_qualification_test_ffi.erl` | Absent | `7f70ed1a295b9cc3f589bb901fb35174edca17f002c0246e00fb37801387076e` |

## Implementation and unchanged compiled contract

The **only production change** is [authority port validation](../../src/mimic/providers/devin/bridge.gleam#L162):
an explicit port must be in `1..65535` before the token-bearing plan is encoded.
Omitted ports retain their existing behavior. Prepare-only boundary tests cover
1/65535 and reject -1/0/65536/999999 with `NotSent`. They never connect to those
boundary/invalid ports. Numeric loopback and binary-H1 restrictions remain.

All public production signatures remain unchanged; compilation and actual BEAM
exports confirmed these bridge APIs:

```gleam
models() -> List(registry.Model)
configured_models(List(catalog.Model)) -> List(registry.Model)
adapter(Option(String)) -> c.Adapter(egress.Stream)
configured_adapter(Option(String), List(catalog.Model)) -> c.Adapter(egress.Stream)
prepare(c.Context, c.Request) -> Result(c.HttpRequest, c.Failure)
prepare_configured(c.Context, c.Request, List(catalog.Model))
  -> Result(c.HttpRequest, c.Failure)
rejection(Int, List(Header)) -> Option(c.Failure)
execute(runtime.Runtime, Option(String), c.Request) -> Result(String, c.Failure)
execute_configured(runtime.Runtime, Option(String), c.Request, List(catalog.Model))
  -> Result(String, c.Failure)
open_native_stream(runtime.Runtime, Option(String), c.Request, List(catalog.Model))
  -> Result(#(String, stream.Stream), c.Failure)
cli(List(String)) -> Result(String, String)
```

`SessionToken` / `StaticSession` remain permanent credentials. No expiry,
refresh token, renewal manager or grant rotation was added. Test-only Stream
registry opt-in is not root/client SSE registration.

### Local assertions, not inferred transport behavior

- The [TLS fixture](../../test/mimic_devin_transport_qualification_test_ffi.erl#L87)
  binds `127.0.0.1` on an ephemeral port, signs synthetic leaves with the
  existing recorder primitive and uses the **actual shared egress TLS client**.
  It retains only known synthetic requests in memory, not capture files.
- [Verified TLS/wire](../../test/devin_transport_qualification_test.gleam#L279)
  observes actual server ALPN `http/1.1`, POST H1, literal Basic token-token,
  native Connect content type/version, correct Host/length, embedded synthetic
  protobuf token, and absence of User-Agent/compression/chunked-request headers.
- [No ALPN](../../test/devin_transport_qualification_test.gleam#L294) is separately
  observed as `none`, not inferred H2 support. SNI is configured by shared source,
  not newly measured on a remote peer.
- [Wrong CA](../../test/devin_transport_qualification_test.gleam#L332) includes a
  same-client trusted-CA control and actual `unknown_ca` handshake failures.
  [SAN mismatch](../../test/devin_transport_qualification_test.gleam#L353) uses the
  SAME signer as a successful matching leaf; endpoint/Host policy passes and the
  actual certificate check reports `hostname_check_failed`. Negative peers
  receive no complete request/application bytes after the rejected handshake.
- [H2-only peer](../../test/devin_transport_qualification_test.gleam#L377) reports
  actual `no_application_protocol` before HTTP bytes. This is **H2 rejection,
  NOT H2 qualification or a negotiated-H2 transport test**.
- [Independent framing cases](../../test/devin_transport_qualification_test.gleam#L460)
  cover compressed/reserved flags, malformed/nonobject/non-UTF8 trailers,
  malformed protobuf, truncated Connect header/payload, absent EOS, incomplete
  UTF8 despite EOS, oversized data/trailer declarations without large payload
  allocation, post-EOS bytes and truncated chunked HTTP despite valid Connect EOS.
  Each preserves exactly one valid text prefix, rejects with
  `InvalidResponse/Started`, emits no success Stop, releases leases, and leaves
  the backup at zero accepts. Repeated terminal pull emits no prefix/error again.
- [Duplicate cancel](../../test/devin_transport_qualification_test.gleam#L595)
  and [adopted owner death](../../test/devin_transport_qualification_test.gleam#L626)
  require actual peer EOF and zero runtime leases, one primary request and zero
  backup accepts. EOF is not a timeout or fixture-teardown counter. The borrower
  is killed after adoption and delivery of the prefix from an incomplete stream;
  the exact entry time into its next blocked pull is not instrumented.

## Timeout diagnosis: bounded correction, remaining uncertainty

Ranked hypotheses were repeated independent setup exhausting the grouped
per-test budget, workers surviving asynchronous teardown, or an individual
runtime credential mutation stalling. Retained attempt6 timed out in
`mutate_runtime/4` during another account save. Its isolated 2.178-second pass
did **not** establish the cause or clear the suite.

Recovery2 also reproduced a default-5-second timeout, but in the SAME-CA TLS
negative open, after 5 passing tests. Its runtime-setup phases included 339ms
then 1430ms, not a demonstrated hung mutation. Immediate VM halt left two
synthetic state directories and one CA directory from that failed run; they
remain ignored failed-run artifacts, not imported inputs. No claim of successful
forced-EUnit-timeout cleanup is made.

The correction is not an arbitrary timeout increase:

1. Each independent suffix is now its own test, including separate oversized
   data/trailer cases. Assertions were not weakened.
2. Fixture stop kills/awaits the acceptor **before** enumerating workers, then
   waits for worker death and checks leaf removal. A monitored scope owns
   synthetic state/CA directories; normal completion awaits scope death and
   verifies directory removal. Its owner-exit path is implemented but a forced
   EUnit-timeout cleanup regression remains unverified here.
3. Opt-in phase logs contain only fixed labels/timings, never token/body/path
   values. The compiled `grouped_truncation_diagnostic` retains the old grouping
   for manual comparison; it was **not executed** or counted as a passing test.
4. Focused execution uses the **existing project's** gleeunit options, not a new
   production/test timeout rule. `manifest.toml` pins gleeunit 1.11.0;
   `build/packages/gleeunit/src/gleeunit.gleam` `do_main` already sets
   `ScaleTimeouts(10)` (default EUnit5s becomes50s). Inspected source SHA-256:
   `41cf5c65ce6f737e84cd04a5c6deac3468cd9b62e629d66cc970bc1fc661776b`.

Serialized recovery4 used one terminal invocation with an outer **90-second**
wall bound. All individual tests completed in 0.159–1.810 seconds except the
prepare-only positive boundary case at0.038s; total16.855s. Phase evidence:

| Phase | Count | Maximum ms |
| --- | ---: | ---: |
| CA generation | 23 | 281 |
| Leaf/listener ready (real bound listener returned) | 40 | 960 |
| Synthetic credential save | 40 | 223 |
| Runtime start | 23 | 107 |
| Complete runtime setup | 23 | 341 |
| Fixture worker-zero/leaf-removed acknowledgment | 40 | 13 |
| Scoped resources-zero acknowledgment | 22 | 10 |

No new state/CA directory remained from recovery4. The earlier failed remnants
were not mistaken for recovery4 leaks or silently deleted. These observations
support bounded independent tests and measured cleanup. **The exact historic
timeout cause remains unresolved**; no host-contention or shared-runtime defect
is asserted, and 24 passing tests alone do not diagnose it.

## Actual root CLI workflow and proposed admission

The [F22-only script](f22_local_cli.py#L121) invokes the real `mimic` root through
`gleam run --`, imports only private synthetic `session_token` material/client
key into its own temporary state, and serves real loopback sockets. It reuses
the existing root smoke startup/shutdown contract; no provider-specific fake CLI
or source-copy overlay is substituted.

Recovery8 verified:

- Two actual buffered Chat successes, including a fresh VM restoring the same
  permanent grant without re-import; correct synthetic native request wire.
- Six independent framing failures, each in a fresh root runtime: malformed
  trailer, truncated header/payload, missing EOS, oversized declaration and
  post-EOS bytes. Every failure is sanitized503, one primary send, zero backup
  accepts, and no successful prefix leakage.
- Root SSE denial422 before I/O.
- Actual root config/CLI denial before I/O for port0, port65536, a `.invalid`
  remote origin, and loopback HTTPS (the **current root TLS gap**, not a TLS
  success). No DNS/live attempt is made to the `.invalid` name.
- Eight total primary sends, zero fallback accepts, root owner-lock removal,
  fixture thread/socket shutdown and removal of its temporary synthetic state.

The first root fixture incorrectly assumed sticky selection across different
requests. Actual fleet selection advances a cursor (`fleet.gleam:152–156`);
a later request legitimately used the healthy backup. Fresh runtimes isolate
the per-request no-replay assertion without changing production selection.
The next fixture failure required one particular config-error phrase;
the final assertion instead requires actual root exit1/`mimic:` diagnostic,
unchanged denied traffic and secret-free output, not a compiler/launcher error.

Minimal root patch base:
`ca86b531cea7e1a509ac8e6038604fe91819ac07`.
Only proposed path: `scripts/verify-integration.sh`.
Preimage SHA-256:
`2b6bf568c0a37e06a49d10539578ff2b76959655a3a2db8f1519128077cbd28a`.
[F22_ROOT.patch](F22_ROOT.patch#L1) adds exactly two verification commands:
source CLI smoke after Devin scenarios, shipment smoke after shipment export.
`git apply --check docs/devin/F22_ROOT.patch` passed read-only. **It was not
applied**; no root/config/egress feature broadening is proposed in this checkpoint.
Shipment execution and any full gate require the coordinator's serialized
`READY_FOR_GATE(slice, revision, command, timebound)` grant.

## Commands and failed-attempt ledger

Compiler: Gleam1.18.1 via `mise exec gleam@1.18.1`; runtime Erlang/OTP29.
Focused build and scoped format passed. No `gleam test` or full integration
command was run. Exact admitted commands:

```sh
mise exec gleam@1.18.1 -- gleam build
mise exec gleam@1.18.1 -- gleam format --check \
  src/mimic/providers/devin/bridge.gleam test/devin_transport_qualification_test.gleam
F22_PHASE_LOG="$PWD/build/f22/recovery4-phases.log" \
  erl -noshell -pa build/dev/erlang/*/ebin -eval \
  'Result = eunit:test(devin_transport_qualification_test, [verbose, {scale_timeouts, 10}]), timer:sleep(2000), case Result of ok -> halt(0); _ -> halt(1) end.'
PYTHONDONTWRITEBYTECODE=1 mise exec gleam@1.18.1 -- \
  python3 -B docs/devin/f22_local_cli.py
git apply --check docs/devin/F22_ROOT.patch
```

Focused EUnit outer bound90s; root script internal alarm120s plus outer150s
cleanup allowance. The final root command also used an atomic ignored
`build/f22/serialized-cli.lock` directory/trap to refuse a concurrent duplicate.
It was removed on exit. No other implementation children were spawned.

| Attempt | Actual outcome; not waived |
| --- | --- |
| Retained1 | Build passed17.59s; direct prepare port0 RED: 1failed/0passed, token-bearing plan returned instead of `NotSent` |
| Retained2 | Build passed2.58s; focused port negative 1passed after authority fix |
| Retained3 | Build passed0.93s with unused-test declarations; focused 3passed |
| Retained4 | Build log includes build-lock wait; focused 7passed, actual TLS negative notices retained |
| Retained5 | Build passed0.77s; 14passed then owner-death test process killed; suite cancelled, not green |
| Retained6 | Build passed1.95s; 9passed then grouped truncation test EUnit5s timeout during account save; cancelled |
| Retained6 isolation | One truncation test passed2.178s; not full-suite or cause evidence |
| Recovery1 | Exact recreation hashes matched; initial format check failed on bridge/test layout; build passed17.92s. Formatting was subsequently applied only through `apply_patch` |
| Recovery2 | Build passed1.52s; focused default5s run 5passed then SAME-CA negative open timed out; phases/failure retained, no suite-green claim |
| Recovery3 | Wrapper duplicated commands using shared log targets; output reported24passed, but run/log/timing is **inadmissible as serialized evidence** |
| Recovery4 | ONE serialized run with project gleeunit options: build1.36s, **24passed16.855s**, phase/cleanup proof above |
| Recovery5 root | Failed fixture's sticky-account assumption; no production correction inferred |
| Recovery6 root diagnostic | Wrapper duplicated a shared log target; **inadmissible serialized evidence**. Surviving log reports malformed-trailer200, primary1/backup1 |
| Recovery7 root | Fresh-runtime framing/positive assertions reached config negatives, then failed the fixture's exact error-text expectation |
| Recovery8 root | ONE lock-serialized final script: **passed32.986s**, positive2/framing-negative6/SSE-denial1/config-denial4, primary8/backup0, cleanup true |
| Recovery9 | Final scoped format check passed (empty log) |

## Hash ledger

Owned executable/artifact hashes (this document's hash is supplied by the parent
handoff report, avoiding a self-referential digest):

| Path | SHA-256 |
| --- | --- |
| `src/mimic/providers/devin/bridge.gleam` | `df57541ea2831248cebfb145b041a774f47e64095d4e44d826f95951108cd226` |
| `test/devin_transport_qualification_test.gleam` | `630cd41d95423b4680fd53a6f766ff9498fce682089641040d8cfe58a15ded80` |
| `test/mimic_devin_transport_qualification_test_ffi.erl` | `2ac45ddabe04fc38979c0dd8ff8f458312388213fca1e24cf34aede96b8f603a` |
| `docs/devin/f22_local_cli.py` | `9538f62a9a6e0db004aa1fb59434d7da1b6fb5c31e09a620a8366e3829f3f90e` |
| `docs/devin/F22_ROOT.patch` | `96e6dbf334c87d4003c339ef1d12fbc4194276915c343aaaf6c3ec2fdf870aac` |

The originals remain read-only at the recovery path. Exact log bytes are also
preserved below so another machine does not need that stopped checkout.
`retained/` means its `build/f22/`; `recovery/` means this attached `build/f22/`.
All29 logs, including failures and inadmissible duplicated-target remnants, have
per-record hashes in the archive. No `.git`, `.jj`, package cache, state directory
or credential file is included. This encoding is **not redaction**; the archived
logs were read and contain only the synthetic/local test evidence described above.

| Retained log | SHA-256 |
| --- | --- |
| `attempt1-build.log` | `1a3dca4b600fbc90ee71d8af75cc76cdba665e62b52cbb385aaada9fb0d0170c` |
| `attempt1-eunit.log` | `3041ede5c0d59f70bc5f4b9c7a48ab8f2492027b49e508a45eaa22efd6aeb89d` |
| `attempt2-build.log` | `62e8aae247ef4cf674389a2621234439b6552bc29dd8857e2fba6093d252a46d` |
| `attempt2-eunit.log` | `56245402027cb5335078afcbbd92204d32d1c9dae094ece719944451ebae01d2` |
| `attempt3-build.log` | `1d207e96435fb08b894e6e513ead90e68e1256fad26ca0ead82fef05479ba015` |
| `attempt3-eunit.log` | `1ef44118d4e7f56556b93622bba0e0e414b248cf750fb2775662a291705a1926` |
| `attempt4-build.log` | `6c02a79abd20b1c4c183b0a51ff1b5aeacf1f1f182b71c81309c5d60856cfdf2` |
| `attempt4-eunit.log` | `af2348b1634afab1ddca3b99fe0993d7d42effefa95ee7771bc6236b3866320e` |
| `attempt5-build.log` | `761a05d4f14d20a6bb4cf6fa60e153b8b51e861d76724cf6248681e1195bfd68` |
| `attempt5-eunit.log` | `2727b62861472a1b9761c87d22f7dfd1b9c87e04c7e9c82edfeec44b7a82def6` |
| `attempt6-build.log` | `53af09aedab12ab00f9089409ed6530a9b2936ef8fb19d17a035229b8acdd0ec` |
| `attempt6-eunit.log` | `cf9557c34eb899adafd9a7235ba1a94922d40e4013e8f8f8f5cfd18a97ac589f` |
| `attempt6-truncation-isolation.log` | `4f384166027cf26aab86d5fdbff962015247dbdf3afb1190e7fb6cbd36597697` |

| Admitted recovery log | SHA-256 |
| --- | --- |
| `recovery4-build.log` | `57d9c62cce698fe8ad674e4b37f05a11a5f6460624d3b011fbab71e478297c22` |
| `recovery4-eunit.log` | `8194fedde59f5d9feaa89117d205217ad601ebe2058bc3b7846197eaea11af19` |
| `recovery4-phases.log` | `22283e0bb25e6d80d54976f22eedd1d2850af2b0abb953685d3184eaac61cd79` |
| `recovery8-root-cli.log` | `52a2536b828e98fbf04e5b3b255103f7e4f9e906f2a485e89bd05767b113e7ab` |
| `recovery9-format.log` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |

### Portable exact-byte log archive

Format: base64(zlib(UTF8 JSON)); each record has `path`, `sha256` and
`content_utf8`. Compressed bytes9298; SHA-256
`7c4d3fb1c4436ddc6c0b0557d194eb29216f23de85a94810baf10861a500c0ed`.
Verify/read without writing any source or state:

```python
import base64, hashlib, json, re, zlib
from pathlib import Path
text = Path("docs/devin/F22_TRANSPORT.md").read_text()
block = re.search(r"```f22-log-archive-zlib-base64\n(.*?)\n```", text, re.S)[1]
packed = base64.b64decode(block)
assert hashlib.sha256(packed).hexdigest() == "7c4d3fb1c4436ddc6c0b0557d194eb29216f23de85a94810baf10861a500c0ed"
logs = json.loads(zlib.decompress(packed))["logs"]
assert len(logs) == 29
for log in logs:
    raw = log["content_utf8"].encode("utf8")
    assert hashlib.sha256(raw).hexdigest() == log["sha256"]
    print(log["path"], len(raw), log["sha256"])
# Inspect an individual log with print(logs[index]["content_utf8"]).
```

```f22-log-archive-zlib-base64
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
```
