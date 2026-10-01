# F12 destination integration and retained regression

The root applies catalog-qualified HTTP-lite classification, Codex-only native
aliases and discovery, and the F11 clean-EOF wire consumer. WS-lite remains
separately disabled pending F13 qualification.

## Strict streaming regression: reproduced and corrected

Independent review found that routing ordinary strict stateless SSE through
`forward_http` accidentally constructed a continuation receipt. A valid
900,000-character request plus a 200,000-character output exceeded the 1 MiB
replay-history budget even with continuation disabled.

The actual exported shipment reproduced it: the small control completed;
the large control returned HTTP 200 but omitted `response.completed` and
closed the chunked response incompletely.

```text
build/closure/strict-history-red-1790881301400587000.log
build/closure/strict-history-red-detail-1790881331995794000.log
```

The root now preserves the existing strict stateless consumer and encoder.
Cached strict streaming likewise retains its original emit-before-receipt
validation behavior. Native-lite alone uses the sparse wire consumer.
No receipt limit was raised and no ambiguous history became authoritative.

Actual source CLI and freshly exported shipment both passed
`scripts/smoke-codex-strict-history-boundary.py`: small/large stateless and cached
streams, exact output, and oversized-history continuation rejection without
upstream I/O. Cached large output still delivers the terminal event before
failing receipt publication, as before F12.

```text
build/closure/strict-history-green-1790881433114000000.log
```

A duplicate command invocation was refused by the shared atomic validation
lock before executing workloads; it is not a second passing test receipt.

## HTTP-lite source workflow: not admitted yet

The actual root source workflow then failed at the idle downstream-cancellation
assertion: after the metadata event and client closure, upstream EOF was not
observed within five seconds.

```text
build/closure/f12-root-source-1790881487656107000.log
```

The leading source-backed hypothesis is synchronous upstream pulling inside
the Mist chunk actor, without downstream-close processing while the pull blocks.
The five-second upstream timeout may explain eventual cleanup, but is not a
substitute for disconnect-triggered cancellation. No assertion was relaxed,
and no measured cancellation fix is claimed. A cancel-only probe and shared
lifecycle correction remain pending.

Full HTTP-lite source/shipment, assembled full suite, native-client, CPA
differential and live-account gates remain unperformed or incomplete.
