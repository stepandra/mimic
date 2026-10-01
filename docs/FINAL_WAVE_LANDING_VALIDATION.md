# Final-wave integration: admitted subset

## Scope

This is an integration of **F08, F14, F15, F22 and F23**, plus the
**preparation-only F30–F34 packet**. It is not completion of every final-wave
thread, CPA parity, native-client qualification, or real-account validation.

The published starting point was
`ca86b531cea7e1a509ac8e6038604fe91819ac07`. Before integration, the coordinator's
entire working change was preserved at
`1b52daaf9109078e60d389b491928eb9a5a8dee1`, with local bookmark
`landing-preserve-rz87rbwdwjd8`. A separate checkout consumed that exact
snapshot so validation did not overwrite the coordinator's unfinished work.

| Input | Admission in this integration |
| --- | --- |
| F08 corrected companion enrollment, callback completion and raw media parsing | Admitted for explicitly approved configuration and synthetic local workflows; no live upstream-check claim |
| F14 `643941e03e943c501271aca889f387202045cb45` | Native Kimi Messages SSE through root CLI and shipment |
| F15 `8fd0c6fc` | Separate generic Kimi Chat SSE through root CLI and shipment |
| F22 `5dfbbd6b` | Devin local transport safety; remote transport remains closed |
| F23 `428b7671452a4c637ca227411f02bc1760d66349` | Experimental local Devin Chat SSE, not ordinary remote Devin support |
| F30–F34 `fd7cb6ce27e05ec9e0c5556056e1a6e3c0e064ea` | 22 added preparation files; all 20 provider-file checksums verified; no runtime/differential admission |

F30–F34 were merged from their standalone, single-parent checkpoint on the
published base. No withdrawn F11 or unrelated provider ancestors were imported.
The preparation tests now run under the existing process/network guard in
`scripts/parity/preparation_unit_tests.py`, called by the regular integration
gate. Their output remains `candidate_runtime`, `cpa_execution`,
`native_client` and `live_verified`: `not_run`.

## F08 review correction

Independent review found that the JSON response gate rejected legal HTAB
whitespace at the end of Content-Type or before its charset parameter.
A new actual-loopback test reproduced the failure: **1 failed, 5 passed**.
The media validator now permits SP/HTAB outside tokens, while the existing
token/parameter grammar still rejects whitespace inside them. Other controls,
non-ASCII whitespace, duplicate declarations and combined media remain denied.

The corrected focused run passed **46 tests**, including actual-wire negative
controls and auth/config/provider tests. This is not a live-provider test.
The callback lifetime, HTTP/2 rejection, single enrollment-ticket/CAS,
explicit companion approval and token-only refresh wiring also received
independent static review; no additional blocker was identified in that scope.

## Final destination checks

Executed with Gleam **1.18.1** on macOS and Erlang/OTP **29**. CI is configured
separately for Linux/OTP 28; local results do not substitute for a CI result.

```sh
gleam deps download
PYTHONUNBUFFERED=1 GLEAM="$(mise where gleam@1.18.1)/gleam" \
  sh scripts/verify-integration.sh
```

The final complete script finished with **exit 0**:

| Gate | Result |
| --- | --- |
| Gleam format check and full test suite | **801 passed**, no failures |
| Existing guarded CPA harness units | **47 passed**, no CPA/candidate launch |
| Guarded F30–F34 preparation units | **119 passed**, no paired execution |
| Checkpoint-admission units | **13 passed** |
| F08 smoke-harness units | **13 passed** |
| Guarded native report contracts | **31 passed**, zero native executions |
| Kimi ordered-wire unittest | **1 passed**, synthetic credentials |
| Doctor and parity-v2 manifest/schema check | Passed |
| Runtime/provider/Responses/strict WebSocket local scenarios | Passed |
| F22/F23 root CLI and shipment workflows | Passed, local only |
| F08 configured root CLI and shipment | **27 scenarios each passed** |
| Kimi native/generic streaming, enrollment, HTTP/WS and Codex continuation | Root CLI and shipment passed |
| Fresh-VM Claude credential restoration without reseeding | Passed |
| Erlang shipment export | Passed |
| Source/test/script/vendor/configuration input inventory | **442 files unchanged** across the final gate |

The Python total is **224**, not 224 native workflows or provider tests.
Source and shipment runs use real local sockets and synthetic credentials.
Only release documentation was changed after the final gate.

The local full log is `build/landing/gate-final.log`, SHA-256
`658003f34e829b2e614c30060c5bad2ee18ab669a10a9b6e9fabe0e1bce49fa0`.
The input inventory is `build/landing/final-inputs-before.json`, SHA-256
`75bd3caba937d74dcc63295c17c7f92e82c8583f6f1dae45c7f4a7bad10913f3`.
These are ignored local artifacts, not portable proof of live qualification.

## Interrupted and failed attempts

- The initial 240-second invocation hit the terminal's outer limit during
  local integration scenarios. It was incomplete, not a full pass.
- After the media correction, the 1,200-second invocation passed the source
  workflows and reached shipment checks before the outer timeout. Its
  remaining shipment checks subsequently passed separately; that alone was
  not relabeled a complete-script pass.
- The final invocation used a sufficient 3,600-second outer bound and completed
  the entire gate with exit 0, including the newly integrated preparation suite.
- The F08 media regression's red run is retained separately from its green run.
- Snapshot patch artifacts contain literal unified-diff context lines consisting
  of a space. They are retained byte-for-byte rather than stripped to satisfy a
  whitespace checker. Source/test/script whitespace checks pass.

## Still unadmitted

This publication does not import the unfinished OAuth UI F05–F07, unfinished
foundation F01–F04, withdrawn F11, the remaining Claude/Codex packets, or the
later Kimi/Grok and Devin packets that lack destination admission.
In particular F24 Devin Messages has SDK-compatibility blockers and must not
be admitted merely because its internal observer tests passed.

Frozen packets, source-only findings and preparatory cases are not silently
turned into executable support. Historical strict CPA conformance remains
**0/37**. The eight actual native-client workflows remain unperformed.
**No real-account OAuth login, live inference, or paid provider request was
performed for this integration.**
