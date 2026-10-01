# F44 review corrections: destination evidence

The parent imported the four review corrections documented in
`F44_HTTP_BOUNDARIES.md`: Upgrade OWS, retained WS selector ownership,
Connection token-list closure, and bounded absolute-deadline request heads.

## Executed parent evidence

On the assembled working copy, scoped root formatting, Gleam 1.18.1 build,
all **19 F44 socket tests**, and both new F10 root configuration tests passed.
The retained parent log is:

```text
build/closure/f44-composed-1790879470794074000.log
SHA256 2cfea1e21faddf861fbf3b55c8d52cf39e96040110e6dd48b4b095e8c81d25fb
```

This includes the deterministic on-init selector replacement regression,
retained-frame precondition, Upgrade OWS variants, duplicate request/response
close fields, fragmented head budgets and the 15-second absolute head deadline.

The worker subsequently reported its own passing 19-test socket run and eight
Python controls. Its initial cache/setup and test annotation build failures
remain recorded. The worker's completion notification arrived before its
renewed run receipt; therefore **global timing exclusivity is not established**
for these runs. Passing assertions remain evidence, not a claim that concurrent
test load was absent.

## Still pending

- An executed pre-review red run: original source hashes were checked, but no
  original source snapshot was saved before automatic import. Corrected copies
  must not be represented as the historical red baseline.
- Current root and shipment smoke repeats and assembled full-suite gate.
- Any explanation for the older custom-WS shipment timeout. The two corrected
  builtin/framing defects do not establish that historical timeout's cause.

All executed traffic was synthetic loopback. No live-provider, native-client,
CPA differential or real-account qualification follows from these tests.
