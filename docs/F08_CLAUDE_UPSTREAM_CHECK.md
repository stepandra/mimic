# F08 — EXTRA Claude upstreamcheck prerequisite

## Current verdict: BLOCKED, not a mock-derived pass

This is an explicit prerequisite report, **not an executed native/live report**
and not an accepted report for the native-client harness. Source inspection and
synthetic local sockets do not qualify an account, entitlement, endpoint,
fingerprint, native CLI or executable CPA reference.

```json
{
  "slice": "F08",
  "cpa_source_pin": "acdace936fa7df2905500c7f5e0a97d683138dea",
  "mimic_base": "ca86b531cea7e1a509ac8e6038604fe91819ac07",
  "frozen_shared_parent": "3190bc60381d39f03dac1ebda92cf7ca47676b26",
  "status": "blocked",
  "f03_reference_report": "unavailable",
  "f03_reference_prerequisite_satisfied": false,
  "explicit_upstream_check_approval": "not_supplied",
  "explicit_upstream_check_report": "not_performed",
  "upstreamcheck_passed": false,
  "native_qualified": false,
  "live_qualified": false,
  "extra_claude_live_qualification_admitted": false,
  "root_cli_companion_workflow": "coordinator_patch_and_test_outstanding"
}
```

Foundation owns read-only qualification of the already-running
`https://localhost:8317`. The reported root-200/TLS-valid observations, supplied
by the coordinator rather than measured here, **are not Claude qualification**.
This child did not call it, restart/reconfigure it, copy credentials, discover
accounts, perform login, send inference, or launch a replacement CPA instance.
Missing F03 evidence is not permission to discover a reference or real account.

## Exact evidence labels

| Label | What exists | What it cannot establish |
| --- | --- | --- |
| **SOURCE** | Public pinned OAuth/identity implementation, byte hashes and exact precedence inspection | Actual native captures, entitlements, live acceptance |
| **MOCK** | Initial child: 36 focused tests and 20 synthetic loopback cases. Parent review correction: 40 focused tests passed, including the existing loopback/root-after-enrollment cases and malformed-media regressions | Real account login, root CLI companion configuration, native/live parity |
| **DIFF** | Only the nine named F08-owned source/test/docs paths; no frozen F11 or root edits | Coordinator admission or complete assembled integration |
| **NATIVE** | Not run; prerequisite unsatisfied | No passed native workflow |
| **LIVE** | Not run; extra upstream check not authorized/performed | No passed upstreamcheck or inferred live budget |

Source pins, hashes, exact local commands, logs, retained failed attempts,
compiled APIs and coordinator-only root instructions are recorded in
[the F08 packet](F08_CLAUDE_COMPANION.md). Its mock success must never flip any
native/live field above to true. Neither CPA source comments about captures
nor historical destination-suite success is new runtime evidence.

## Requirements before an EXTRA live/native check

All prerequisites below must be supplied and explicitly reviewed. Unknown,
missing, stale, misbound or failed prerequisites leave the check blocked.
This checklist is **not authorization** and contains no invented account,
endpoint approval, budget, model availability or containment result.

### 1. Qualified F03 reference

- Foundation's immutable report must identify the reference implementation/
  revision, executable provenance if applicable, endpoint identity, qualification
  scope, exact executed checks, outcomes, logs/hashes and descendant containment.
- Bind the reference report to the proposed Claude OAuth enrollment/profile/
  roles operation, not only root status or TLS availability.
- Explicitly distinguish source-only HTTP behavior, a native observation and
  an executed live check. Do not use another model/provider's pass.
- No restart, reconfiguration, account discovery or credential inspection of the
  running foundation reference is authorized by this F08 packet.

### 2. Operator-owned account and observed identity

- Name one operator-owned sacrificial Claude OAuth account by a non-secret
  local alias, with operator consent for exactly the proposed operation.
- Supply credentials through the existing private store/channel, never argv,
  source files, reports, captures, logs, metrics or model grounding.
- Supply the operator's actual observed device identity. Do not hash tokens,
  synthesize an account/device, import CPA's generated pool, or copy an invented
  fingerprint. Account/organization observations must reconcile without conflict.
- Use a dedicated private 0700 state directory and 0600 private files, separate
  from production. Preserve S5 reservations/CAS and v4 uncertainty fences.
- State whether login, refresh or already-authorized token use is approved.
  Approval of one does not authorize discovery or a different action.

### 3. Endpoint and operation approval

- Explicit approved authorize/token/loopback-callback/profile/roles endpoint
  configuration and exact trusted account binding are required.
- Approval must cover both GET destinations. Source's published URLs are
  documentation, not an operator allowlist or runtime default.
- Allow only the approved HTTPS destinations and loopback listener; validate
  authority, TLS trust, egress policy, no URL credentials/query/fragment and
  no redirects. Unsupported encoding/protocol must fail, not be impersonated.
- This slice requests no telemetry/usage/entitlement endpoint, account enumeration
  or unsolicited inference. Native-client telemetry stays denied unless separately
  authorized; an unknown mandatory workflow leaves qualification blocked.

### 4. Budget and stop conditions

- Supply concrete maximum requests, elapsed time, attempts, account quota/cost
  allowance, approved egress and the person authorized to stop the check.
- A proposed minimal code-exchange check is one exchange followed by one profile
  GET and one roles GET. These are proposed bounds, **not approved budget values**.
- No automatic retries, repeated logins, failover account, intentional 429 probe
  or inference spending is authorized here. Inference requires a separate approved
  model/operation/token budget and known account support.
- Stop on conflict, missing required identity, denial, uncertain write/rotation,
  unexpected destination/telemetry, unsupported protocol or exhausted bounds.
  An advisory companion failure is a login-policy decision, not evidence of
  successful upstream qualification.

### 5. Containment and privacy

- Before running a native CLI or reference executable, provide pinned version,
  file hashes and an isolated disposable runner. Never execute an untrusted
  CLI directly on the operator host.
- Prove parent and descendant containment, network allowlisting, private-store
  separation and cleanup. Do not weaken existing harness blockers to get a pass.
- No host credential-directory copies, shell-concatenated input, shared live
  account pools or access to the running foundation's secret state.
- Record only redacted operation order/status, boolean identity agreement and
  minimal approved diagnostics. Raw token bodies, PKCE verifiers/state, private
  identities and roles payloads must not become shared artifacts.
- Source-inspected BEAM TLS verification does not equal native Firefox/Axios
  transport, header or compression fidelity. Any redaction/degraded capture axis
  must remain explicitly unqualified.

### 6. Root and report acceptance

- Apply the coordinator-owned root configuration/CLI patch, compile it and
  demonstrate a positive actual configured companion-login route on mocks first.
  The compiled store-free shell seam is not the CLI full-enrollment wrapper.
- In a separately approved contained run, record the actual exchange → profile →
  roles sequence, validated identity agreement, private S5 commit and relevant
  terminal outcome, bound to the exact candidate and qualified reference hashes.
- Produce the explicit upstreamcheck report with real evidence and approved
  account/endpoint/budget/containment binding. No empty report, root-only 200,
  TLS-only check, fixture identity or mocked status can count as a pass.
- A real native qualification additionally needs the actual pinned native-client
  workflow and its existing report-admission contract. This Markdown report is
  not a substitute.

## Gate expression and handoff

EXTRA Claude live qualification may be considered only after:

```text
qualified_F03_reference
AND compiled_and_tested_coordinator_root_workflow
AND explicit_operator_account_endpoint_operation_approval
AND concrete_budget_and_containment_approval
AND executed_explicit_upstreamcheck_with_bound_evidence
```

None of these prerequisites is inferred from mocks. At handoff, F03 and
upstreamcheck remain unavailable/unperformed, and root companion configuration
remains unapplied. **Native/live/upstreamcheck are false/blocked.**
Only the coordinator can schedule the assembled full gate after
`READY_FOR_GATE`; the parent freezes the packet and submits
`READY_FOR_ADMISSION`. Neither action itself authorizes a live account check.
