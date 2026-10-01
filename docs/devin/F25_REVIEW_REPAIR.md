# F25 independent-review repair — source-only, not admitted

The earlier 90-test receipt in `F25_VALIDATION.md` is retained as historical
local evidence, **not** SDK/schema, root-route or shipment admission. Review
found production/schema and deadline-publication gaps those tests did not cover.
This revision has not been formatted, compiled or executed under the current
F04/F13 validation HOLD.

## Actual pinned source inspected

Official OpenAI Python **2.26.0**, immutable commit
`15afa21e54952c06e2ac4d3e3a82f144c2cf9ed9`:

| Source under `src/openai/` | SHA256 fetched bytes | Evidence |
|---|---|---|
| `_version.py` | `1a3f3067a904a2a1b2ddee211489a1e2b97582bbcb7eb51a135a01e83186f830` | Actual version 2.26.0 |
| `types/responses/response_error_event.py` | `7e307deb87925848747224a4e6ceb84d0189c93b188ed353f1db92ab3b63856d` | Flat message/string, sequence/integer, type/error; code and param optional nullable strings |
| `types/responses/response_usage.py` | `83562a577e456d612c1640f25f243de602b508f4f6bd76848fb771df9372965a` | Non-nullable input/output detail objects and integer cached/reasoning counters |
| `types/responses/response.py` | `14fafde5aecdc3b34a0f1c7345f3cc4723c8188c866d419b071f2004a2856dfd` | Required tools/tool_choice/parallel_tool_calls; **whole usage is Optional[ResponseUsage]=None**, lines293–297 |
| `types/responses/response_create_params.py` | `497701fd77859e54c7cfea69a2fc6f3cce592afb8bc9df7b1bb4d1dc24e2ccb1` | Actual client request fields, not a Chat wrapper |
| `types/responses/function_tool.py` | `c9cf8249518ec4ab4e7db7a2ae8152944a14e1f24d316920e96083d3adffdaaf` | Strict is optional/nullable, but documented default is **true** |

Reader links:
[ErrorEvent](https://github.com/openai/openai-python/blob/15afa21e54952c06e2ac4d3e3a82f144c2cf9ed9/src/openai/types/responses/response_error_event.py#L11-L26),
[usage](https://github.com/openai/openai-python/blob/15afa21e54952c06e2ac4d3e3a82f144c2cf9ed9/src/openai/types/responses/response_usage.py#L8-L40),
[Response](https://github.com/openai/openai-python/blob/15afa21e54952c06e2ac4d3e3a82f144c2cf9ed9/src/openai/types/responses/response.py#L112-L151),
[nullable whole usage](https://github.com/openai/openai-python/blob/15afa21e54952c06e2ac4d3e3a82f144c2cf9ed9/src/openai/types/responses/response.py#L293-L297),
[FunctionTool](https://github.com/openai/openai-python/blob/15afa21e54952c06e2ac4d3e3a82f144c2cf9ed9/src/openai/types/responses/function_tool.py#L17-L34).

Official `openai/openai-openapi` **manual_spec** commit
`498c71ddf6f1c45b983f972ccabca795da211a3e`, `openapi.yaml` SHA256
`6a6c681b182002de4ad335fa80214158f2d8f383a418f865c87876c3ed67cad9`:
[CreateResponse parallel_tool_calls default true, lines22059–22065](https://github.com/openai/openai-openapi/blob/498c71ddf6f1c45b983f972ccabca795da211a3e/openapi.yaml#L22059-L22065).
Response also has default true at lines32888–32892.

This is public **client-contract default evidence only**, not evidence that
Devin has a native parallel-control knob. The manual spec is older than the
SDK contract: its error schema omits sequence_number and its optional usage
reference does not declare nullable. Do not describe it as the schema backing
SDK2.26 or use it to claim modern `usage:null` compatibility.

These are inspected generated-model/spec facts, not installed SDK execution,
NativeSDK compatibility, measured native latency, differential or live evidence.

## Usage architectural decision — awaiting explicit user approval

Native events provide qualified exact core totals, but not a source-qualified
OpenAI reasoning-token breakdown. A complete `ResponseUsage` requires both
detail objects and integer counters. Neither missing/null detail objects nor
null individual counters are supported by the inspected SDK types. Filling
those fields with zero would fabricate data.

Three choices:

1. **Recommended:** emit **whole `usage:null`**, which the pinned actual SDK
   supports, while retaining exact native totals/accounting in explicit
   `devin.native_usage` and marking the unavailable Responses breakdown.
   No known native count is lost or turned into zero.
2. Keep a partial usage object or nullable details: **schema-invalid** under
   the inspected SDK. Not an acceptable repair.
3. Reject every response without a qualified breakdown: honest unsupported,
   but would remove essentially all current native Responses successes.

The parent is requesting user approval for option1. **Usage representation has
not been changed yet.** The existing partial public usage shape is not claimed
schema-conforming or admitted in this source checkpoint.

Product caveat: clients that inspect only standard `response.usage` and ignore
the `devin` extension would see unknown usage, not the exact native counters.
SDK type compatibility with nullable whole usage does not guarantee an
application accepts that product contract. This distinction must remain explicit.

## Source repairs completed independently of that decision

- Flat typed ErrorEvent with nullable code/param and the actual next sequence;
  safe diagnostics only. New independent error-shape regressions do not use
  the permissive shared error observer as acceptance evidence.
- Input item limit256 checked **before** shared request/pairing scans. A
  written 8192-distinct-call regression fits below the root1MiB body limit and
  must fail at cardinality, not enter the quadratic pairer.
- Final JSON cached during common construction: the gateway deadline check is
  no longer followed by another expensive JSON serialization after EOF.
- Shared strict `push_json` validates serialized SSE events, including the
  extra response-envelope depth, not only a constructed-tree push.
- Typed admitted-request settings populate tools/tool_choice/parallel flag,
  instructions/limits/temperature and source-backed native top_p. Only explicit
  `strict:false` definitions are admitted; strict/required/forced controls are
  not guessed into the native RPC. Tool names must be admitted definitions.
- Standard public parallel defaultTrue is used; explicit False rejects more
  than one generated function call before any success. This is fail-closed
  projection qualification, **not** a claim of native execution enforcement.
- New bounded publication wrapper reuses existing native `client.next`/cancel/
  ownership. It adds no decoder/credential manager/socket/watchdog. The original
  deadline is passed unchanged through catalog opening and sender.

## Exact cooperative SLA

Native acquisition/I/O retains F28's original absolute deadline. Construction
checks that same deadline before native semantic events and after final
JSON/SSE serialization. Successful generated-frame callbacks are checked before
invocation and after nonterminal callbacks return: none begins after expiry.
A slow first callback after EOF prevents all remaining generated frames and
the terminal, even though the native lease has already been released.

There is **no hard-preemption or guaranteed wire-flush/return-time deadline**
for an already blocked emit callback. Bytes cannot be recalled. If a terminal
callback began within budget, it may finish later; never append an error after
that possibly delivered terminal. A safe typed error notification is best
effort after an expired success budget and is not a successful-generation
callback. No idle downstream-close watcher or second watchdog is claimed.

Root `catalog_gateway.execute/serve` signatures are unchanged. Additive
`open_responses_until` passes the original deadline; F25's provider `send` now
takes that deadline explicitly instead of manufacturing a new sender budget.

## New written regressions and pending gates

- Typed flat errors, negative sequence/old nested shape, and real original
  native deadline error with actual peer EOF and zero leases.
- Post-EOF first callback crossing deadline: no remaining/terminal callback;
  exact next error sequence and zero native leases.
- Isolated synthetic adapter aggregate8MiB exact/+1 in multiple chunks, both
  JSON/SSE, cancellation, no second-account open, zero leases. This avoids
  mistaking the independent egress8MiB limit for the F25 wrapper.
- **Finalized**256-item JSON/SSE positive and257-item rejection with only128
  tools; not merely an unfinalized builder acceptance.
- Request-grounded echo, explicit strict-false subset and parallel false
  fail-closed behavior.

No tests/builds/format/BEAM/socket/Python workflow have run for this revision
during HOLD. Earlier failed attempts and passing local90 remain retained.
Usage decision, scoped revalidation, actual authenticated root source/shipment,
full assembled suite, SDK execution, CPA and live gates remain pending.
