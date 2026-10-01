# F25 root integration contract — compiled seam, actual route pending

Current revision is under source-only independent-review repair, not admitted.
The old compiled receipt does not validate the repairs; see `F25_REVIEW_REPAIR.md`.

The root/config/CLI remains parent-owned. F25 adds no configuration fields,
credential managers, store, auth mode or entitlement. The F27 `Configured`
object and its actual selected-Context adapter remain authoritative.

## Actual gateway route (parent applies)

In `src/mimic/gateway.gleam`:

1. In the `provider == "responses"` account selector, add `a.provider == "devin"`
   only when the original client operation is `"responses"`. Do not select Devin
   for compact or count merely because native operations later become generate.
2. Preserve `client_operation` **before** the existing Devin `generate` remap.
3. Before the existing `"devin" -> "openai-chat"` protocol fallback, add:

   ```gleam
   "devin" if client_operation == "responses" -> "openai-responses"
   ```

4. In the streaming Devin Chat/Messages dispatch, add the alternative:

   ```gleam
   | "devin", "responses", True
   ```

   Continue using the existing
   `devin_catalog_gateway.serve(req, engine, None, request, config.devin)`.

5. In the buffered Devin Chat/Messages dispatch, add:

   ```gleam
   | "devin", "responses", False
   ```

   Continue using `devin_catalog_gateway.execute(engine, None, request,
   config.devin)` and the existing sanitized 422 `Unsupported/NotSent` vs 503
   failure handling.

No new root Response relabelling, dispatcher's first-account model mapping,
binary transport, native parser, S6 receipt or WS cache is introduced.
`POST /v1/responses` must be the actual authenticated root route. The root
already uses `catalog_gateway.registration` and `listing`; those now admit the
third actual protocol with **unchanged** Stream/Buffer/Tools/Images capabilities.

## Exact provider APIs

Existing F27 signatures are unchanged:

```gleam
registration(configuration.Configured, String) -> Result(registry.Model, String)
listing(configuration.Configured, registry.Model) -> Result(ir.Value, String)
validate(configuration.Configured, contracts.Request) -> Result(Nil, contracts.Failure)
execute(runtime.Runtime, Option(String), contracts.Request, configuration.Configured)
  -> Result(String, contracts.Failure)
serve(Request(mist.Connection), runtime.Runtime, Option(String),
      contracts.Request, configuration.Configured) -> Response(mist.ResponseData)
```

Additive F27/native client seam:

```gleam
open_responses(runtime.Runtime, Option(String), contracts.Request,
               configuration.Configured)
  -> Result(#(String, client.Client(responses_stream.State)), contracts.Failure)
```

New `responses_gateway`:

```gleam
configured_registration(String, List(models.Model))
  -> Result(registry.Model, String)
validate(contracts.Request, List(models.Model)) -> Result(Nil, String)
execute_with_adapter(runtime.Runtime, contracts.Request, List(models.Model), contracts.Adapter(h))
  -> Result(String, contracts.Failure)
open_with_adapter(runtime.Runtime, contracts.Request, List(models.Model), contracts.Adapter(h))
  -> Result(#(String, client.Client(responses_stream.State)), contracts.Failure)
send(Request(mist.Connection), client.Client(responses_stream.State), deadline: Int)
  -> Response(mist.ResponseData)
```

The trusted `execute_with_adapter_until`/`open_with_adapter_until` variants add
an **absolute monotonic** integer deadline as the final parameter for focused
tests. Normal gateway calls use now + 10,000 ms. Negative monotonic origins
are valid. F25 uses F28's additive `runtime.open_until` and existing native
`Stream`/`client` `runtime.next`; the original runtime deadline persists through
ordinary pulls and idle ownership. No second timer/watchdog is added.

## Explicit non-capabilities

- No `Continuation`, `WebSocket`, compact, count, stored Responses or previous
  response lookup. Previous IDs (including another tenant's valid-looking
  projected ID) reject before credentials/I/O.
- Full submitted function-call/result history is locally paired by the strict
  shared API. That is not a server continuation authorization.
- Numeric `127.0.0.1` gate is unchanged. Neither local H1 fixtures nor these
  projection APIs authorize a remote Devin endpoint.
- This is delayed buffered-to-SSE, not measured incremental native latency.

## Parent-owned actual-route validation

After explicit serialized validation grant and F28 import/qualification:

```sh
ERL_FLAGS='+S 2:2 +A 2' mise exec gleam@1.18.1 -- \
  python3 -B docs/devin/f25_local_cli.py
ERL_FLAGS='+S 2:2 +A 2' mise exec gleam@1.18.1 -- \
  python3 -B docs/devin/f25_local_cli.py --shipment /absolute/shipment/path
```

The script uses the **actual** source CLI or shipped `entrypoint.sh`, CLI imports
of synthetic account/client credentials, fresh private state and operator-owned
numeric-loopback fixtures. It never overlays root source or starts a facade.
Source success is not shipment success. Both executions are parent-owned.

The APIs above now compile against the exact assembled parent snapshot with
qualified F28. All 90 focused provider/F27/F23/F24/S6 tests passed, including
18 F25 tests. See `F25_VALIDATION.md` for hashes, retained failures and receipts.
This does not claim actual-root source/shipment execution or full `gleam test`.
Those remain parent-owned, pending gates. No remote/live authority is changed.
