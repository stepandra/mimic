# F27 current compiled root hooks — parent-owned integration

Compiled against the attached current base with corrected F24. Do not apply
the retained old `F27_ROOT*.patch` variants: they target old Chat-only roots.
This document is a schema/hook contract, not an applied root patch or gateway
execution receipt.

## 1. Decode once with validated account bindings

Import `mimic/providers/devin/configuration as devin_configuration`.
Add one `Config` field:

```gleam
devin: devin_configuration.Configured
```

After existing strict JSON and account decoding:

```gleam
use devin_catalog <- result.try(devin_configuration.from_root(value) |> safe)
```

Replace the single hard-coded Devin model auth branch with:

```gleam
"devin", "session_token", _ ->
  devin_configuration.enabled(devin_catalog, a.models)
  |> safe
  |> result.map(fn(_) { Nil })
```

Do not allow any other Devin auth mode. After existing account invariants,
construct and append to `Config(...)`:

```gleam
use devin <- result.try(
  devin_configuration.new(
    devin_catalog,
    accounts
    |> list.filter(fn(a) { a.provider == "devin" })
    |> list.map(fn(a) {
      devin_configuration.Account(a.id, a.origin, a.models)
    }),
  )
  |> safe,
)
```

Empty Devin-account lists are allowed; empty account model lists are not.
Root's existing numeric-loopback-only Devin endpoint check remains unchanged.

## 2. Register/discover the exact admitted rows

Import `mimic/providers/devin/catalog_gateway as devin_catalog_gateway`.
Devin `registrations(config)` branch:

```gleam
#("devin", model) ->
  devin_catalog_gateway.registration(config.devin, model) |> sanitized
```

For GET `/v1/models`, derive rows from the **actual** `registrations(config)`,
which already deduplicates only configured account model IDs. For each Devin
row:

```gleam
devin_catalog_gateway.listing(config.devin, registered)
|> result.map(ir.to_json)
|> sanitized
```

Keep all unrelated provider rows as existing `{"id":..., "object":"model"}`.
Never enumerate the whole catalog, native UIDs or canonical siblings as
additional enabled model IDs. Preserve root's client-key check.

## 3. Dispatch both current protocols using selected runtime context

Keep the existing request protocol mapping and native `generate` operation:
Chat -> `openai-chat`, Messages -> `anthropic-messages`.
Use the same catalog gateway for both Chat and Messages; it invokes the
current F23/F24 native client and the existing binary transport:

```gleam
// Streaming, for either current client operation:
devin_catalog_gateway.serve(req, engine, None, request, config.devin)

// Buffered, for either current client operation:
devin_catalog_gateway.execute(engine, None, request, config.devin)
```

Buffered `Unsupported/NotSent` -> existing sanitized 422 rejection;
other failures -> existing sanitized 503. Streaming returns the equivalent
response. Do not enable Responses/count/continuation routes as a side effect.

The provider adapter's binding follows actual `Context.account` and origin
from runtime, not the initial dispatcher account; no root per-request
credential/mapping lookup or first-account pinning is needed.

## Exact public signatures

```gleam
// configuration
pub type Account { Account(id: String, origin: String, models: List(String)) }
pub opaque type Configured
from_root(ir.Value) -> Result(catalog.Catalog, String)
enabled(catalog.Catalog, List(String)) -> Result(List(models.Model), String)
new(catalog.Catalog, List(Account)) -> Result(Configured, String)

// catalog_gateway
registration(Configured, String) -> Result(registry.Model, String)
listing(Configured, registry.Model) -> Result(ir.Value, String)
execute(runtime.Runtime, Option(String), c.Request, Configured)
  -> Result(String, c.Failure)
serve(Request(mist.Connection), runtime.Runtime, Option(String),
      c.Request, Configured) -> Response(mist.ResponseData)
```
