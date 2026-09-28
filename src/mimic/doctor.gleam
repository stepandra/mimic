import gleam/json
import gleam/list

pub fn run() -> Result(String, String) {
  let tools =
    ["erl", "openssl", "b3sum", "zstd", "docker"]
    |> list.map(fn(name) {
      json.object([
        #("name", json.string(name)),
        #("available", json.bool(executable_available(name))),
        #("required", json.bool(name != "docker")),
      ])
    })
  Ok(
    json.object([
      #("version", json.string("0.1.0")),
      #("otp_release", json.string(otp_release())),
      #("tools", json.array(tools, fn(value) { value })),
      #(
        "notes",
        json.string(
          "Docker is needed for sandboxed drives. JA4/TLS impersonation and real upstream validation are not implied by tool availability.",
        ),
      ),
    ])
    |> json.to_string,
  )
}

@external(erlang, "mimic_cli_ffi", "executable_available")
fn executable_available(name: String) -> Bool

@external(erlang, "mimic_cli_ffi", "otp_release")
fn otp_release() -> String
