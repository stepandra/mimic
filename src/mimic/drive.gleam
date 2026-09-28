import gleam/dict
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import simplifile
import tom

pub type Drive {
  Drive(
    image: String,
    executable: String,
    seed: Int,
    args: List(String),
    expected_request_kinds: List(String),
    recorder_proxy: String,
    recorder_container: String,
  )
}

fn required_string(table, key) -> Result(String, String) {
  tom.get_string(table, [key])
  |> result.map_error(fn(_) { "missing or invalid " <> key })
}

fn strings(table, key) -> Result(List(String), String) {
  case dict.get(table, key) {
    Ok(tom.Array(items)) ->
      case
        list.all(items, fn(item) {
          case item {
            tom.String(_) -> True
            _ -> False
          }
        })
      {
        True ->
          Ok(
            list.map(items, fn(item) {
              case item {
                tom.String(value) -> value
                _ -> ""
              }
            }),
          )
        False -> Error("invalid string array " <> key)
      }
    _ -> Error("missing string array " <> key)
  }
}

pub fn parse(input: String) -> Result(Drive, String) {
  use table <- result.try(
    tom.parse(input) |> result.map_error(fn(_) { "invalid drive.toml" }),
  )
  use image <- result.try(required_string(table, "image"))
  use executable <- result.try(required_string(table, "executable"))
  use args <- result.try(strings(table, "args"))
  use expected <- result.try(strings(table, "expected_request_kinds"))
  use seed <- result.try(
    tom.get_int(table, ["seed"])
    |> result.map_error(fn(_) { "missing integer seed" }),
  )
  let proxy = tom.get_string(table, ["recorder_proxy"]) |> result.unwrap("")
  let recorder =
    tom.get_string(table, ["recorder_container"]) |> result.unwrap("")
  let drive = Drive(image, executable, seed, args, expected, proxy, recorder)
  case valid(drive) {
    True -> Ok(drive)
    False ->
      Error(
        "drive needs a pinned image, absolute executable, expected kinds, and paired recorder settings",
      )
  }
}

pub fn valid(drive: Drive) -> Bool {
  pinned(drive.image)
  && string.starts_with(drive.executable, "/")
  && !list.is_empty(drive.expected_request_kinds)
  && {
    { drive.recorder_proxy == "" && drive.recorder_container == "" }
    || { drive.recorder_proxy != "" && drive.recorder_container != "" }
  }
}

fn pinned(image: String) -> Bool {
  case string.split(image, "@sha256:") {
    [name, digest] ->
      list.all(string.split(name, "/"), fn(component) {
        component != ""
        && !string.starts_with(component, "-")
        && !string.starts_with(component, ".")
        && !string.starts_with(component, "_")
        && list.all(string.to_graphemes(component), fn(c) {
          string.contains("abcdefghijklmnopqrstuvwxyz0123456789._:-", c)
        })
      })
      && string.length(digest) == 64
      && list.all(string.to_graphemes(digest), fn(c) {
        string.contains("0123456789abcdef", c)
      })
    _ -> False
  }
}

/// Network is disabled unless the operator explicitly names a recorder
/// container. The pinned image must contain the executable; no runtime install.
pub fn docker_args(drive: Drive) -> List(String) {
  let network = case drive.recorder_container {
    "" -> ["--network=none"]
    container -> [
      "--network=container:" <> container,
      "--env",
      "HTTPS_PROXY=" <> drive.recorder_proxy,
    ]
  }
  list.append(
    [
      "run",
      "--rm",
      "--read-only",
      "--cap-drop=ALL",
      "--security-opt=no-new-privileges",
      "--pids-limit=64",
      "--memory=512m",
      "--user=65534:65534",
      "--tmpfs=/tmp:rw,noexec,nosuid,size=64m",
      "--env",
      "HOME=/tmp",
      "--env",
      "MIMIC_DRIVE_SEED=" <> int.to_string(drive.seed),
      "--entrypoint",
      drive.executable,
    ],
    list.append(network, ["--", drive.image, ..drive.args]),
  )
}

@external(erlang, "mimic_drive_ffi", "docker")
fn docker(args: List(String)) -> Result(Int, String)

/// Caller must validate captured request kinds against `expected_request_kinds`
/// before treating the drive as coverage evidence.
pub fn run_with(
  drive: Drive,
  invoke: fn(List(String)) -> Result(Int, String),
) -> Result(Int, String) {
  case valid(drive) {
    False -> Error("invalid drive")
    True -> invoke(docker_args(drive))
  }
}

pub fn run(drive: Drive) -> Result(Int, String) {
  run_with(drive, docker)
}

pub fn cli(args: List(String)) -> Result(String, String) {
  case args {
    ["run", path] -> {
      use text <- result.try(
        simplifile.read(path)
        |> result.map_error(fn(_) { "cannot read drive.toml" }),
      )
      use drive <- result.try(parse(text))
      use code <- result.try(run(drive))
      case code {
        0 -> Ok("drive exited; capture coverage not verified")
        _ -> Error("drive exited nonzero: " <> int.to_string(code))
      }
    }
    _ -> Error("drive: run <drive.toml>")
  }
}
