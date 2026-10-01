import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// Explicit local control plane. Never discover Docker contexts or credentials.
pub type Backend {
  Backend(executable: String, socket: String)
}

/// All fixture listeners live inside the new, network-none namespace.
/// These are TCP bind/connect permissions, NOT permission for all loopback.
pub type Network {
  Network(bind_ports: List(Int), connect_ports: List(Int))
}

pub type Limits {
  Limits(
    wall_ms: Int,
    lease_ms: Int,
    memory_mb: Int,
    pids: Int,
    work_mb: Int,
    output_bytes: Int,
  )
}

/// Only public/synthetic configuration goes in argv. Credential injection and
/// externally routed/live networking are deliberately not supported by F02.
/// The image must already contain the target, fixtures, shipment and owner.
pub type Request {
  Request(
    image: String,
    executable: String,
    args: List(String),
    network: Network,
    limits: Limits,
  )
}

pub opaque type Plan {
  Plan(request: Request)
}

pub fn default_limits() -> Limits {
  Limits(60_000, 2000, 2048, 256, 128, 1_048_576)
}

pub fn request(plan: Plan) -> Request {
  plan.request
}

pub fn validate_backend(backend: Backend) -> Result(Nil, String) {
  case absolute_path(backend.executable) && absolute_path(backend.socket) {
    True -> Ok(Nil)
    False -> Error("containment_backend_requires_explicit_absolute_local_paths")
  }
}

pub fn authorize(request: Request) -> Result(Plan, String) {
  use _ <- result.try(check(
    immutable_image(request.image),
    "containment_requires_local_immutable_image_id",
  ))
  use _ <- result.try(check(
    absolute_path(request.executable)
      && !string.starts_with(request.executable, "/containment/"),
    "containment_target_path_invalid",
  ))
  use _ <- result.try(check(
    list.length(request.args) <= 128
      && list.all(request.args, fn(arg) {
      string.byte_size(arg) <= 4096 && !string.contains(arg, "\u{0000}")
    }),
    "containment_target_arguments_invalid",
  ))
  use _ <- result.try(check(
    valid_ports(request.network.bind_ports)
      && valid_ports(request.network.connect_ports),
    "containment_fixture_ports_invalid",
  ))
  let limits = request.limits
  use _ <- result.try(check(
    limits.wall_ms >= 100
      && limits.wall_ms <= 300_000
      && limits.lease_ms >= 500
      && limits.lease_ms <= 5000
      && limits.memory_mb >= 64
      && limits.memory_mb <= 4096
      && limits.pids >= 8
      && limits.pids <= 512
      && limits.work_mb >= 1
      && limits.work_mb <= 256
      && limits.output_bytes >= 0
      && limits.output_bytes <= 1_048_576,
    "containment_resource_limits_invalid",
  ))
  Ok(Plan(request))
}

fn check(valid: Bool, error: String) -> Result(Nil, String) {
  case valid {
    True -> Ok(Nil)
    False -> Error(error)
  }
}

pub fn absolute_path(path: String) -> Bool {
  string.starts_with(path, "/")
  && path != "/"
  && !string.contains(path, "\u{0000}")
  && !string.contains(path, "\n")
  && !string.contains(path, ",")
  && !list.any(string.split(path, "/"), fn(part) { part == ".." || part == "." })
}

pub fn immutable_image(image: String) -> Bool {
  case string.split(image, ":") {
    ["sha256", digest] ->
      string.length(digest) == 64
      && list.all(string.to_graphemes(digest), fn(char) {
        string.contains("0123456789abcdef", char)
      })
    _ -> False
  }
}

fn valid_ports(ports: List(Int)) -> Bool {
  list.length(ports) <= 16
  && list.length(list.unique(ports)) == list.length(ports)
  && list.all(ports, fn(port) { port >= 1 && port <= 65_535 })
}

pub fn port_argument(ports: List(Int)) -> String {
  case ports {
    [] -> "-"
    _ -> ports |> list.map(int.to_string) |> string.join(",")
  }
}
