# F28 parent source admission

The actual authenticated source-root status workflow passed with Gleam 1.18.1
and `ERL_FLAGS='+S 2:2 +A 2'`. This is synthetic loopback evidence, not live
Devin, shipment, or full-suite qualification.

Executed command:

```text
python3 docs/devin/f28_local_cli.py
```

The workflow passed four positive observations and 12 failure cases. It checked
exact selected-account status without fallback, authorization before account
lookup/I/O, unchanged permanent credential bytes/revision/metadata, safe
numeric observations, rejection of malformed/oversized/truncated/compressed
responses, persisted quota denial, key revocation, and refusal to take store
ownership from a running gateway. The gateway's discovery remained unchanged.

Receipt:

```text
build/closure/f28-root-source-1790889386309727000/
  source-inputs.json
  workflow.log
  receipt.json
workflow.log SHA256:
22b0c0039c2b768e90ac76d0c34ee43caea31e0a4fbe072d53b217184f2ba495
```

Exit 0 in 17.729 seconds. Recorded source inputs were unchanged, fixture cleanup
completed, the owned-process audit was empty, and the owned shared validation
lock was released. No production or harness correction was required by this run.

The worker's earlier 105 focused passes and retained initial timing/test-fixture
failures remain separate evidence in `F28_STATUS.md`. This root workflow does
not explain or waive those initial timing failures.

Shipment execution, full assembled `gleam test`, and external/native/live
qualification remain pending.
