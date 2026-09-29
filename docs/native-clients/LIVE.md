# Live gate and operator checklist

**No live calls are authorized or implemented by the offline runner.**
`live.py` is a separate authorization preflight, not a working provider runner.
Without `--execute`, it emits `not_run` and reads no approval or credential file.
With `--execute`, it requires private scoped approval metadata and still emits
`blocked`: live endpoint allowlisting and token/cost budget enforcement must be
implemented and reviewed first. There is intentionally no bypass flag.

This is a remaining implementation gate, not a claim that environment
credentials or a metadata file grant authorization.

Before any future live execution:

1. Obtain explicit human authorization **in the thread** for the exact client
   version, approved operator-owned account, endpoint, model and workflow.
   “Test compatibility” is not permission to log in, discover accounts, inspect
   profiles or upload a checkout.
2. Approve synthetic test data only. Do not mount private code, native HOME,
   existing OAuth files, browser profiles, SSH agents or credential stores.
3. Agree positive hard budgets for requests, input tokens, output tokens, cost
   and wall time. Unknown token usage/cost must stop the run, not become zero.
4. Provision credentials privately into a fresh mode-0600 file or secret FD,
   outside committed/shared evidence. Supply them only after an enforcement
   adapter has been reviewed. Never put values in an approval file, command
   line, prompt, report, environment dump or repository. No credentials are
   requested or read by the current preflight.
5. Establish egress containment for the approved endpoint only, including DNS,
   redirects, WebSocket and OAuth endpoints; reject all background discovery,
   telemetry and update traffic. Network-none must not merely be removed.
6. Enforce budgets at the gateway/egress boundary, not solely in a client prompt.
   Verify child cleanup and secret-free summaries before enabling execution.
7. Record separate `real-provider/live` evidence with actual exits and observed
   protocol assertions. A local synthetic pass is never live or CPA evidence.

Example **metadata only**, written privately by the operator outside source:

```json
{
  "approved_by": "operator-name",
  "account_label": "approved-account-label-not-an-email-or-token",
  "endpoint": "https://operator-owned.example/v1",
  "model": "approved-exact-model",
  "allowed_data": "synthetic-only",
  "max_requests": 2,
  "max_input_tokens": 1000,
  "max_output_tokens": 100,
  "max_cost_usd": 0.05,
  "max_seconds": 30
}
```

Preflight commands (neither sends requests):

```sh
python3 scripts/native-clients/live.py
python3 scripts/native-clients/live.py --execute --approval /private/approval.json
```

The second command must remain blocked until the missing enforcement is built.
Do not interpret `--execute` as authorization from this task. No actual login,
account discovery, browser interaction, real-provider tokens or benchmark
measurements have been performed.
