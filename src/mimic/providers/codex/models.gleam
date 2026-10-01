/// Source-derived metadata, NOT account discovery or live measurements.
/// No model is available until the runtime explicitly allows its exact ID.
import gleam/list
import gleam/result
import mimic/ir
import mimic/providers/codex/json_guard
import mimic/providers/codex/normalize

pub const baseline = "acdace936fa7df2905500c7f5e0a97d683138dea"

pub type Source {
  PinnedCpa
  OperatorSupplied
  Synthetic
}

pub type Model {
  Model(
    slug: String,
    reasoning_efforts: List(String),
    context_window: Int,
    prefers_websocket: Bool,
    responses_lite: Bool,
    parallel_tools: Bool,
    input_modalities: List(String),
    raw: ir.Value,
  )
}

pub type Catalog {
  Catalog(source: Source, models: List(Model))
}

/// Parse an explicitly supplied Codex /models payload, preserving unknown
/// metadata rather than manufacturing capabilities from a model-name prefix.
pub fn decode(body: String, source: Source) -> Result(Catalog, String) {
  use root <- result.try(json_guard.parse(body))
  use values <- result.try(ir.required(root, "models"))
  use values <- result.try(ir.as_array(values))
  use models <- result.try(list.try_map(values, model))
  let ids = list.map(models, fn(model) { model.slug })
  case list.unique(ids) == ids {
    True -> Ok(Catalog(source, models))
    False -> Error("duplicate Codex model slug")
  }
}

fn model(value: ir.Value) -> Result(Model, String) {
  use slug <- result.try(ir.string_field(value, "slug"))
  use context <- result.try(ir.required(value, "context_window"))
  use context <- result.try(ir.as_int(context))
  use levels <- result.try(ir.required(value, "supported_reasoning_levels"))
  use levels <- result.try(ir.as_array(levels))
  use efforts <- result.try(
    list.try_map(levels, fn(level) { ir.string_field(level, "effort") }),
  )
  use default <- result.try(ir.string_field(value, "default_reasoning_level"))
  use modalities <- result.try(ir.required(value, "input_modalities"))
  use modalities <- result.try(ir.as_array(modalities))
  use modalities <- result.try(list.try_map(modalities, ir.as_string))
  use ws <- result.try(ir.optional_bool(value, "prefer_websockets", False))
  use lite <- result.try(ir.optional_bool(value, "use_responses_lite", False))
  use parallel <- result.try(ir.optional_bool(
    value,
    "supports_parallel_tool_calls",
    False,
  ))
  case slug != "" && context > 0 && list.contains(efforts, default) {
    False -> Error("invalid Codex model metadata")
    True ->
      Ok(Model(slug, efforts, context, ws, lite, parallel, modalities, value))
  }
}

pub fn lookup(catalog: Catalog, slug: String) -> Result(Model, String) {
  list.find(catalog.models, fn(model) { model.slug == slug })
  |> result.map_error(fn(_) { "Codex model has no explicit catalog metadata" })
}

/// Exact intersection with runtime availability. WS preference is masked when
/// transport is unavailable; lite-only models are omitted without lite support.
pub fn available(
  catalog: Catalog,
  ids: List(String),
  websocket_enabled: Bool,
  lite_enabled: Bool,
) -> ir.Value {
  ir.Object([
    #(
      "models",
      ir.Array(
        catalog.models
        |> list.filter(fn(model) {
          list.contains(ids, model.slug)
          && { !model.responses_lite || lite_enabled }
        })
        |> list.map(fn(model) {
          normalize.put(
            model.raw,
            "prefer_websockets",
            ir.Boolean(model.prefers_websocket && websocket_enabled),
          )
        }),
      ),
    ),
  ])
}

/// F12 gateway discovery: HTTP-lite is implemented, WS-lite is not. Ordinary
/// models retain the existing explicit WS opt-in. F13 can replace this binding
/// only after its actual native WS consumer and authority fences are admitted.
pub fn available_http(
  catalog: Catalog,
  ids: List(String),
  websocket_enabled: Bool,
) -> ir.Value {
  let catalog =
    Catalog(
      ..catalog,
      models: list.map(catalog.models, fn(model) {
        Model(
          ..model,
          prefers_websocket: model.prefers_websocket && !model.responses_lite,
        )
      }),
    )
  available(catalog, ids, websocket_enabled, True)
}

/// Deliberately small native-client metadata subset transcribed from
/// internal/registry/models/codex_client_models.json at `baseline`.
/// Not a capture, not a claim that these models are enabled for any account.
pub fn pinned() -> Catalog {
  let usual = ["low", "medium", "high", "xhigh"]
  let max = list.append(usual, ["max"])
  let ultra = list.append(max, ["ultra"])
  Catalog(PinnedCpa, [
    entry("gpt-6-astra", "GPT-6-Astra", ultra, "medium", True),
    entry("gpt-6-sol", "GPT-6-Sol", ultra, "medium", True),
    entry("gpt-6-luna", "GPT-6-Luna", max, "medium", True),
    entry("gpt-reserve", "GPT-Reserve", max, "medium", True),
    entry("gpt-5.6-sol", "GPT-5.6-Sol", ultra, "low", True),
    entry("gpt-5.6-terra", "GPT-5.6-Terra", ultra, "medium", True),
    entry("gpt-5.6-luna", "GPT-5.6-Luna", max, "medium", True),
    entry("gpt-5.5", "GPT-5.5", usual, "medium", False),
    entry("codex-auto-review", "Codex Auto Review", max, "medium", True),
  ])
}

fn entry(
  slug: String,
  name: String,
  efforts: List(String),
  default: String,
  lite: Bool,
) -> Model {
  let value =
    ir.Object([
      #("slug", ir.String(slug)),
      #("display_name", ir.String(name)),
      #("context_window", ir.Integer(272_000)),
      #("default_reasoning_level", ir.String(default)),
      #(
        "supported_reasoning_levels",
        ir.Array(
          list.map(efforts, fn(effort) {
            ir.Object([
              #("effort", ir.String(effort)),
              #("description", ir.String(description(effort))),
            ])
          }),
        ),
      ),
      #("input_modalities", ir.Array([ir.String("text"), ir.String("image")])),
      #("prefer_websockets", ir.Boolean(True)),
      #("use_responses_lite", ir.Boolean(lite)),
      #("supports_parallel_tool_calls", ir.Boolean(True)),
      #(
        "visibility",
        ir.String(case slug {
          "codex-auto-review" | "gpt-reserve" -> "hide"
          _ -> "list"
        }),
      ),
    ])
  Model(slug, efforts, 272_000, True, lite, True, ["text", "image"], value)
}

fn description(effort: String) -> String {
  case effort {
    "low" -> "Fast responses with lighter reasoning"
    "medium" -> "Balances speed and reasoning depth for everyday tasks"
    "high" -> "Greater reasoning depth for complex problems"
    "xhigh" -> "Extra high reasoning depth for complex problems"
    "max" -> "Maximum reasoning depth for the hardest problems"
    "ultra" -> "Maximum reasoning with automatic task delegation"
    _ -> effort
  }
}
