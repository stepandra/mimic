# F27 destination integration

Root configuration now decodes the strict catalog, binds it to configured
accounts, and uses the catalog gateway for discovery and Chat/Messages.
F25 subsequently extends this same gateway with Responses; no new account,
native UID alias, remote authority or continuation capability is introduced.

## Retained current root failures

The first actual source workflow stopped because its discovery assertion still
expected only the two pre-F25 protocols:

```text
build/closure/f27-root-source-1790881698362469000.log
```

The assertion was updated narrowly to the three exact registered protocols,
retaining model filtering, operations and capability checks. The next actual
source run passed discovery and reached Messages, then failed an outdated usage
expectation:

```text
build/closure/f27-root-source-1790881774221465000.log
```

That harness expects Anthropic cache counters, while corrected F24 intentionally
preserves native accounting under named `devin_usage` metadata rather than
guessing Anthropic cache semantics. The fixture supplies native fields 4 and 5
with values 4 and 3; the harness now requires those exact named native counters
and the unchanged core totals. Subsequent execution and corrections are recorded
below; the earlier failures remain evidence, not passing receipts.

`F27_SHA256SUMS` records the frozen F27 worker packet, not the entire later F25
composition. F25's manifest covers its intentional bridge/catalog/test changes.
The parent discovery assertion change is separately recorded here. Do not use
the original worker's 74 focused passes as destination source/shipment evidence.

## Current parent source workflow: passed

The actual source-root workflow passed with Gleam 1.18.1 and
`ERL_FLAGS='+S 2:2 +A 2'` after two further harness corrections. No production
selection, projection or accounting semantics were changed:

- Both eligible synthetic peers now supply the active scenario and independently
  check their selected credential/model mapping. The fleet round-robins new
  sessions; the old harness assumed every initial request selected the first
  account. A safe diagnostic observed two requests at each peer, while only the
  first peer supplied Messages accounting. The second peer correctly returned
  its configured text-only accounting. That was not measured projection loss.
- The baseline-catalog scenario now precedes intentional quota rejection.
  Restarting the gateway does not clear the persisted cooldown; the old order
  made later per-account counts depend on elapsed cooldown time. Exact
  per-account counts remain asserted, including rejection/failover.

The passing workflow checks configured Chat and Messages JSON/SSE, exact native
accounting and content reconstruction, selected-account credentials and model
mapping, baseline Chat, safe rejection/failover, unchanged other-provider
discovery, eight unknown/not-enabled denials, five route/capability/auth denials,
and 16 invalid configurations without upstream I/O. It made nine synthetic
native requests. Temporary diagnostic probes were removed before this pass.

```text
build/closure/f27-isolated-phases-source-1790889331267769000/
  source-inputs.json
  workflow.log
  receipt.json
workflow.log SHA256:
299fd5da828cd33d6af777c6c3866d631286dc4140e4f501cc7b0436aa82bd2f
```

Exit 0 in 12.518 seconds; recorded inputs were unchanged, the owned-process audit
was empty and the owned shared validation lock was released.

The preceding source failure, safe usage/selection probes, and later
post-rejection count failure are retained separately under `build/closure/`:
`f27-root-source-1790888943856360000`,
`f27-usage-diagnostic-1790889042076622000`,
`f27-usage-counters-1790889182515179000`,
`f27-selected-fixture-1790889231523390000`, and
`f27-round-robin-source-1790889291120462000`. The original count failure did not
record its actual count pair; do not invent one from the cooldown explanation.

This is source-root synthetic evidence only. Shipment, the full assembled suite,
CPA differential, SDK/native-client execution, live discovery and live-provider
qualification remain unperformed here.
