import gleam/int
import gleam/list
import gleam/result
import gleam/string
import mimic/containment/docker
import mimic/containment/policy
import mimic/containment/protocol
import mimic/containment/selftest

/// Public execution seam. Selftests are mandatory, not caller-supplied status.
/// No image acquisition, credential discovery or uncontained host fallback.
pub fn execute(
  backend: policy.Backend,
  plan: policy.Plan,
) -> Result(protocol.Receipt, String) {
  let request = policy.request(plan)
  use _ <- result.try(selftest.run(backend, request.image))
  docker.run(backend, plan, False)
}

pub fn cli(args: List(String)) -> Result(String, String) {
  case args {
    ["selftest", docker_path, socket, image] -> {
      use report <- result.try(selftest.run(
        policy.Backend(docker_path, socket),
        image,
      ))
      Ok(selftest.encode(report))
    }
    ["run", docker_path, socket, image, bind, connect, executable, ..args] -> {
      use bind <- result.try(parse_ports(bind))
      use connect <- result.try(parse_ports(connect))
      use plan <- result.try(
        policy.authorize(policy.Request(
          image,
          executable,
          args,
          policy.Network(bind, connect),
          policy.default_limits(),
        )),
      )
      use receipt <- result.try(execute(
        policy.Backend(docker_path, socket),
        plan,
      ))
      Ok(protocol.encode(receipt.code, receipt.reason, receipt.output))
    }
    _ ->
      Error(
        "containment: selftest <docker-path> <unix-socket> <image-id> | run <docker-path> <unix-socket> <image-id> <bind-ports-or-dash> <connect-ports-or-dash> <executable> [args]",
      )
  }
}

fn parse_ports(text) {
  case text {
    "-" -> Ok([])
    _ ->
      text
      |> string.split(",")
      |> list.try_map(fn(port) {
        int.parse(port)
        |> result.map_error(fn(_) { "containment_fixture_ports_invalid" })
      })
  }
}
