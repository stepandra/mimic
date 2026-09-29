# Claude policy checkpoint 1 — frozen provenance

Base: `3e00808ff0fefbb6728edb1769c17139ef0fd93a` fetched from
`https://github.com/stepandra/mimic.git`, clean `jj new` on that exact base.
CPA source pin: `acdace936fa7df2905500c7f5e0a97d683138dea`.
This checkpoint is source/synthetic/loopback evidence, not live/native evidence.

Passed:

```
mise exec gleam@1.18.1 -- gleam format src/mimic/providers/claude test/claude_policy_test.gleam test/claude_policy_scenarios.gleam
ERL_FLAGS='+S 2:2 +A 2' mise exec gleam@1.18.1 -- gleam run -m claude_policy_scenarios
```

The scenario runner compiled and passed eight new policy tests plus the existing
Claude provider scenarios (PKCE/JSON exchange/refresh, native request handling,
SSE observer, local Messages/count_tokens HTTP). Initial full-suite invocation
without bounded schedulers timed out at 200 seconds; no passing result claimed.

Callback: `adapter.prepare_with_policy(context, request, policy, approved_profile)`.
The old `prepare` delegates to native/caller-owned defaults with no profile.
No changes to shared runtime, auth persistence, gateway, or transport.

Exact checkpoint hashes (later changes require a new manifest, not rewriting this):

```
404bd75453ca062043369319e9e68a026cb8d6079f787dcb3e3069a9f24df8b8  src/mimic/providers/claude/adapter.gleam
6fbc07338ffc8fd49a31ba5fb3483d6e9d8936f630cde2660646f9c04dc0f9be  src/mimic/providers/claude/cache.gleam
e4d508cee181aec5615db762c7b6079c25de1aa1db01d874eb94da4a2dddd508  src/mimic/providers/claude/client_profile.gleam
7aeb5aeb59b8b2db48e0a3499aa3eacc3adba80a0a10b4ddc4ca395981a47535  src/mimic/providers/claude/policy.gleam
161f5e080b0d78c8b94eb39c1e4e1fbdebeb0a239a582bfa552d04bb36f00165  src/mimic/providers/claude/request.gleam
13af16f1bc3494df181c7451797c9b10322f54312a852407bc9fdd9a17e3f520  test/claude_policy_test.gleam
f6a494ec48e689e4edac99a9fef5da3504b13fb068798fd0592c0ca37952c695  test/claude_policy_scenarios.gleam
```
