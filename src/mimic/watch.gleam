import gleam/dynamic/decode
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/option.{Some}
import gleam/result
import gleam/string
import mimic/workshop

pub type Watch {
  Watch(
    package: String,
    provider: String,
    registry_url: String,
    debounce_ms: Int,
  )
}

pub type Pending {
  Pending(package: String, provider: String, version: String, ready_at_ms: Int)
}

@external(erlang, "mimic_watch_ffi", "observe")
pub fn observe(
  dir: String,
  config: Watch,
  version: String,
  now_ms: Int,
) -> Result(Pending, String)

@external(erlang, "mimic_watch_ffi", "ready")
pub fn ready(dir: String, config: Watch, now_ms: Int) -> Result(Pending, String)

@external(erlang, "mimic_watch_ffi", "ack")
fn ack(dir: String, config: Watch, version: String) -> Result(Nil, String)

pub fn latest(body: String) -> Result(String, String) {
  json.parse(body, decode.at(["dist-tags", "latest"], decode.string))
  |> result.map_error(fn(_) { "registry response has no dist-tags.latest" })
}

fn fetch(url: String) -> Result(String, String) {
  use req <- result.try(
    request.to(url) |> result.map_error(fn(_) { "invalid registry URL" }),
  )
  use response <- result.try(
    httpc.send(req) |> result.map_error(fn(_) { "registry request failed" }),
  )
  case response.status {
    200 -> Ok(response.body)
    _ -> Error("registry returned non-200 status")
  }
}

pub fn poll_with(
  dir: String,
  config: Watch,
  now_ms: Int,
  get: fn(String) -> Result(String, String),
) -> Result(Pending, String) {
  case
    string.starts_with(config.registry_url, "https://")
    && config.debounce_ms > 0
    && config.package != ""
    && config.provider != ""
  {
    False ->
      Error("watch requires explicit HTTPS registry and positive debounce")
    True -> {
      use body <- result.try(get(config.registry_url))
      use version <- result.try(latest(body))
      observe(dir, config, version, now_ms)
    }
  }
}

pub fn poll(
  dir: String,
  config: Watch,
  now_ms: Int,
) -> Result(Pending, String) {
  poll_with(dir, config, now_ms, fetch)
}

/// Enqueue only after debounce. The pending event remains durable if starting
/// the provider run fails, so another invocation can retry it.
pub fn enqueue(
  dir: String,
  config: Watch,
  now_ms: Int,
) -> Result(workshop.Run, String) {
  use pending <- result.try(ready(dir, config, now_ms))
  // Length-prefix the variable components so distinct packages/providers
  // cannot claim the same durable run id for an identical version string.
  let id =
    "watch:"
    <> int.to_string(string.length(config.provider))
    <> ":"
    <> config.provider
    <> ":"
    <> int.to_string(string.length(config.package))
    <> ":"
    <> config.package
    <> ":"
    <> pending.version
  let goal = "watch:" <> config.package <> ":" <> pending.version
  let run = case
    workshop.start_with_goal(dir, id, config.provider, workshop.PB, goal)
  {
    Ok(run) -> Ok(run)
    Error(start_error) ->
      // A restart after the run checkpoint but before watch ack must be
      // idempotent, but never acknowledge a colliding, unrelated run id.
      case workshop.load(dir, id) {
        Ok(existing) ->
          case
            existing.id == id
            && existing.provider == config.provider
            && existing.kind == workshop.PB
            && existing.goal == Some(goal)
          {
            True -> Ok(existing)
            False -> Error("watch run id belongs to another release")
          }
        Error(_) -> Error(start_error)
      }
  }
  use run <- result.try(run)
  use _ <- result.try(ack(dir, config, pending.version))
  Ok(run)
}

pub fn cli(args: List(String)) -> Result(String, String) {
  case args {
    ["poll", dir, provider, package, registry_url, debounce, now] -> {
      use debounce_ms <- result.try(
        int.parse(debounce) |> result.map_error(fn(_) { "invalid debounce" }),
      )
      use now_ms <- result.try(
        int.parse(now) |> result.map_error(fn(_) { "invalid timestamp" }),
      )
      let config = Watch(package, provider, registry_url, debounce_ms)
      use pending <- result.try(poll(dir, config, now_ms))
      Ok("pending " <> pending.version)
    }
    ["enqueue", dir, provider, package, registry_url, debounce, now] -> {
      use debounce_ms <- result.try(
        int.parse(debounce) |> result.map_error(fn(_) { "invalid debounce" }),
      )
      use now_ms <- result.try(
        int.parse(now) |> result.map_error(fn(_) { "invalid timestamp" }),
      )
      let config = Watch(package, provider, registry_url, debounce_ms)
      use run <- result.try(enqueue(dir, config, now_ms))
      Ok("queued PB " <> run.id)
    }
    _ ->
      Error(
        "watch: poll|enqueue <state-dir> <provider> <package> <https-registry-url> <debounce-ms> <now-ms>",
      )
  }
}
