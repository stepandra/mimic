# F23 local Chat SSE admission

Imported frozen `9facbe42122bb436fbd74db2f7edd2ae8bee76f3` after verifying
all eight payload hashes. Coordinator reviewed the lifecycle/facade and
applied the root registration and streaming dispatch proposal to the current
F14/F15/F22 assembly. The provider packet remains unchanged.

The route is experimental numeric-loopback only. It reuses the existing
native decoder and runtime owner, emits validated Chat SSE, and publishes
DONE only after valid Connect EOS plus clean HTTP EOF. Errors preserve the
valid prefix and terminate abnormally without replay. Exact raw trailer
metadata/status fidelity and remote transport qualification remain open.

## Executed here

- Format/build and named EUnit: **19 passed**, 3.093 seconds.
- Actual source CLI: passed, four Chat SSE positives, seven started-failure
  negatives, downstream disconnect, 12 native requests, zero fallback accepts.
- Fresh shipment export and the same workflow: passed with the same counts.
- Adapted F22 source and shipment checks: both passed. Its old Chat streaming
  denial is now an unsupported Responses streaming denial, still before I/O.
- Whitespace, shell syntax and final application/test format checks passed.

The root integration script includes both source and shipment checks.
Full Gleam/integration after this addition remains pending; the earlier
751-test result predates F23. No native client, live, CPA differential or
remote-provider success is claimed. Owner-reported independent source review
is separate from these coordinator-run tests.

Logs under `build/f23-admission/` (ignored):

```text
517fc693d213336335068f54c16076d07ae410c37c24ee8f72530de71ccf73e4  focused.log
76c8f364e8a84bc082e0ab4421bc98121f61b705c49dc5fcda93b7212dda140c  source.log
1087a975d7f7df0187160d785172717e9869ecf0a07c3608821762ce4e27ee47  shipment.log
a94b279dd973729c036a06e87f5813201d6da2f99d358c1355de2c10f30e9c95  f22-source.log
7ef584613dc28cd038b6a0cab44770585ad21402e08399d67ee51432535b6303  f22-shipment.log
```

Gateway SHA-256 after admission:
`030010bfcc90a9235515d7b64ee94b958ae0fc86be5e520ca81a9bf6ca40441d`.
