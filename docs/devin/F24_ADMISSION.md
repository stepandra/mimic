# F24 destination admission — in progress

The corrected provider packet and parent-owned gateway hook are present.
The actual root source CLI workflow passed after the correction below.
Shipment and combined gates remain pending while the parallel imports finish;
this is not full destination/release admission.

## Actual authenticated root workflow

`mise exec gleam@1.18.1 -- python3 -B docs/devin/f24_local_cli.py` passed:
two JSON and two SSE positive cases with complete reconstruction equality,
eight started failure modes in each representation, three preflight denials,
20 native synthetic requests, zero fallback accepts, and successful cleanup.
The runner explicitly reported `incremental_streaming`, `remote`, `live`,
`native_client`, `sdk_execution` and `cpa_differential`: false.

Log: `build/closure/f24-source.log`, SHA-256
`9d4527efc04b82358c4721d04a6cc5437449024ee35e94d12b903c61c863476e`.

## Independent review and envelope-depth correction

The review found one remaining mismatch in the supposedly common JSON/SSE
subset. A tool argument of depth 126–128 passed its standalone depth-128
parser. The surrounding Message/content/tool envelope adds three containers:
buffered encoding accepted it, but SSE's complete-message parser rejected it.

The parent reproduced this using the worker's compiled modules after checking
that their two source files exactly matched the imported pre-fix bytes:

```text
depth=124 buffered=ok sse=ok
depth=125 buffered=ok sse=ok
depth=126 buffered=ok sse=error
depth=127 buffered=ok sse=error
depth=128 buffered=ok sse=error
```

This diagnostic returned normally; it is evidence of mismatched outcomes,
not a claimed failing test-process exit.

`messages.encode_response` now validates the complete document with the same
IR parser at the shared boundary before returning either representation.
Standalone argument limits are unchanged; no arbitrary depth subtraction or
SSE-only exception is introduced. Two regressions cover accepted depths
124–125 with full reconstruction equality and rejection in both modes at
126–128.

The corrected **29 focused tests passed** in a generated dependency-closure
build containing 47 Gleam modules copied from the destination, with copied
dependencies/vendor and an input hash inventory. This avoided substituting
stubs for the not-yet-imported UI/F09 root dependencies. It is focused library
and actual local socket evidence, **not a root gateway/shipment pass**.
Gleam 1.18.1, OTP 29 and process-local `ERL_FLAGS='+S 2:2'` were used.

| Artifact | SHA-256 |
| --- | --- |
| `build/closure/f24-depth-red.log` | `f74d43f6385fd902e83bf3957c11d2c9e178d6df325220590621e0b7e5a2d3d3` |
| `build/closure/f24-depth-green.log` | `d0db187a80bef9c8905f1d434eb0925025c92f56876563360f108b5e6033bff4` |
| `build/closure/f24-focused/inputs.json` | `6459e21f64ba02447612ffad8be883b42ccaf2bb319b3d9c35d527bc1f63572d` |
| Corrected `messages.gleam` | `6859d96cccc69fbfc04bc96191c458a962e27c7ecc1ae302a3397fe75a7e4533` |
| Corrected projection test | `551bb4adae66b36eecb456831da82f5f225770d124d3c2ed6dd55e03ce39a673` |

The original [provider handoff](F24_MESSAGES.md) records the supported subset
and earlier attempt history. The behavior remains delayed bounded
buffered-to-SSE, not native token-latency streaming. No installed SDK,
remote Devin account, live provider or CPA differential was executed here.
