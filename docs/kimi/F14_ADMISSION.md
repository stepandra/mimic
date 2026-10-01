# F14 destination checkpoint

Imported frozen `47d9c7cb607ad49cfbe65ddf962c432def3f6a02` onto the
F15/F22-local assembly after verifying all 11 manifest entries and handoff hash.
Applied the two gateway hunks; provider/Claude source remains unchanged.
Native Kimi Messages SSE is now routed through the existing ownership helper.

Destination format/build passed; 20 Kimi and 6 Claude focused tests passed.
Final source and shipment smokes passed with 21 synthetic upstream requests
each. Independent source review found no production blocker. Coordinator
corrected its harness findings: honor GLEAM, require exact header-error status,
and test literal/escaped duplicate keys solely inside message.model.
Legacy blanket streaming-422 checks now test unsupported streaming media with
zero upstream I/O; dedicated F14/F15 smokes cover positive streaming.

## Combined validation — NOT a single successful full-script run

- Attempt 1: 751 Gleam passed, then failed obsolete Messages-stream denial.
- Attempt 2: 751 Gleam passed, then failed obsolete generic-Chat-stream denial.
- Corrected standalone HTTP-provider smoke passed.
- Attempt 3: 751 Gleam and 92 Python units passed; all source gates completed.
  Shipment export, Devin and base gateway shipment checks completed.
  The 900-second tool limit interrupted shipment HTTP-provider checking.
  This run is **TIMED OUT / INCOMPLETE**, not exit 0.
- One orphan BEAM was identified by its own `build/integration/claude-quota-*`
  cwd and parent PID 1, stopped with SIGTERM, and confirmed exited.
- A separate sequential remainder passed all six shipment scripts:
  HTTP providers, enrollment, generic Kimi, Kimi Messages, provider WS,
  and Codex HTTP. This is separate evidence, not a retroactive full-script pass.

Logs are retained in `build/f14-admission/`. SHA-256:

```text
e247ab8ca1b0fe108760d1bb31964e2b9eec1a554d0abcf49c3f57f596e59bb4  combined-integration.log
7340749217f2e4f0ae04b2098e1f492ee5d72857ed64db1855c6debc873c9dc3  combined-integration-attempt2.log
6006b2e48d4a97f5baa0d8f419d9edf5793abdf325b5d0cde9beda1ee71a3e43  combined-integration-attempt3.log
284e2d4efb3448a6eea7e35aeaf4ddc8f517bbd0576cf60afc17b8108f5215b6  shipment-remainder.log
```

Publication/CI and a clean whole-script release run remain pending.
F22 is local safety, not remote qualification. F11 and F05 are not imported.
F44 remains an explicit known defect. No CPA/native/live success is claimed.
