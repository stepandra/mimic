# Claude enrollment race — frozen red checkpoint v1

This is pre-fix evidence, not a completed enrollment implementation.
Claude policy v1 and its exported manifest remain unchanged.

## Reproduction

```
ERL_FLAGS='+S 2:2 +A 2' mise exec gleam@1.18.1 -- gleam run -m claude_login_enrollment_test
```

The test compiles, then exits 1. All twelve cases return
`#(False, False)` for `(login_rejected, admin_state_preserved)`; expected
`#(True, True)`. Thus the old login reports success and overwrites the
administrator's state, not merely the wrong error classification.

The matrix has two deterministic mutation points:

1. Inside `announce`, before the actual loopback callback is sent.
2. Inside the injected token exchange, before the synthetic response returns.

At each point it covers:

- Existing credential: replacement, same-material save, deletion.
- Initially absent slot: replacement, deletion, insert-then-delete ABA.

The callback uses the actual local PKCE listener and generated state. The
announce callback synchronously completes the HTTP response before returning,
so listener shutdown cannot masquerade as the enrollment bug. No upstream
authorization/token endpoint is contacted. All token material is synthetic;
failure output contains only booleans.

## Exact evidence hashes

```
db09801982d21e436446e078fb6d944a673aa2f45e978ed39caf504551d6c3e7  src/mimic/providers/claude/login.gleam
e92c577c13ebbeb18b980a16cd0dc4ba1694ca141a6815989a96b1809490d6bc  test/claude_login_enrollment_test.gleam
4890c409395aa924a660f44fe36a31682768496c7a667515c9f7bb0ac94e294a  build/claude-login-enrollment-red-v1.log
885edb1af762a655504cede37f01af358b83f12398c0cf1f4feaf38658f99513  build/claude-login-enrollment-red-v2.log
```

The first successful reproduction logged a single combined boolean per case;
the second separates rejection from preservation. Build logs retain the raw
command output locally; this document records the durable result and hashes.

## Approved next step / dependency

Integration approved shared-core's proposed opaque enrollment ticket:

- `begin_enrollment(Store, key)` before OAuth begin/announce/callback/network.
- Existing slot: exact-generation snapshot.
- Absent slot: atomically reserve the same slot with a nonce-only pending marker.
- `commit_enrollment(Enrollment, AuthMaterial)` uses exact CAS.
- `cancel_enrollment(Enrollment)` must lose to concurrent administrator or
  successful commit. Existing-ticket cancellation preserves material/gate while
  bumping generation; this intentionally invalidates generation-bound sessions.
- No crash-marker TTL cleanup: explicit administrative recovery is required.

Claude production source is not changed at this checkpoint. Binding and green
regressions wait for the shared owner's frozen S5 API/source artifact.
No parallel credential manager, token seed, or local substitute CAS is added.
