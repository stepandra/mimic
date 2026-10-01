# F22 local-safety destination checkpoint

Imported frozen JJ revision `96e68387c309027baf58bd010c817b968d81ec2e`
(`umbrella5-f22-local`) onto the coordinator's F15-admitted workspace.
All seven advertised file hashes matched the frozen Git objects before merge.
The only production change rejects explicit ports outside `1..65535` in
the existing numeric-loopback Devin authority check. Public APIs, remote
admission, TLS policy, shared egress and runtime behavior are unchanged.

**This does not complete F22 remote transport qualification.** No real Devin,
CPA differential, native-client, remote H2, live or fingerprint evidence was
produced. The owner history in `F22_TRANSPORT.md`, including the unresolved
earlier focused timeout and unverified forced-timeout cleanup, remains intact.

## Destination verification

Executed with Gleam 1.18.1:

- `gleam format --check src test` and `gleam build`: passed.
- Named EUnit `devin_transport_qualification_test` using the project's timeout
  scale of 10: **24 passed**, 16.953 seconds.
- `GLEAM=$PWD/.tools/gleam python3 docs/devin/f22_local_cli.py`: passed.
- `gleam export erlang-shipment`: passed, dependency deprecation warnings only.
- `python3 docs/devin/f22_local_cli.py --shipment build/erlang-shipment`: passed.
- Integration-script shell syntax and changed-source whitespace checks: passed.
  The imported unified-diff artifact retains its required blank context marker.

Each actual CLI workflow checks two successful buffered requests, six framing
failures, one pre-I/O streaming denial and four configuration denials. Each
observed eight primary sends, zero fallback accepts and fixture cleanup.
Source elapsed 28,811 ms; shipment elapsed 13,069 ms. These are run durations,
not benchmarks. Synthetic TLS/ALPN/hostname controls in the focused tests do
not enable or qualify the gateway's remote/TLS Devin path.

The coordinator adapted the two proposed root smoke additions to the current
integration script, preserving the admitted F15 gates. A later F23 streaming
admission must explicitly update the old pre-I/O denial expectation rather
than silently deleting the negative test.

The destination full Gleam/integration gate after this merge remains pending.
The prior 711-test result predates F22 and is not presented as this checkpoint's
full-suite evidence.

## Retained evidence

Logs under ignored `build/f22-admission/`:

```text
a92ede06e4e77668a99b28ef3224102143b3f3080282494dec670e428f16838a  focused.log
28d9a1d6a3128b8a006184d595133953e364f7ee0d182b746b2c0294b4844425  source.log
ea5939400f1c77712f886c91a7c660eb36ecd508681453b83b9f62d3591b9c27  export.log
2b7586da7cb4d0667b0678b4d6cabdca01a1df8f310c3cdc3d23aa0dd023d5b7  shipment.log
```

The unchanged imported bridge SHA-256 is
`df57541ea2831248cebfb145b041a774f47e64095d4e44d826f95951108cd226`.
The root script after adding the two F22 checks is
`a6b4364046b1468b1193e6a16c042f084d3d613d7657ef3228a428b276ca4ade`.
