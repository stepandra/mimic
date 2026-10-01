import argv
import gleam/dynamic/decode
import gleam/io
import gleam/json
import mimic/containment

/// Standalone executable seam, independent of parent-owned root CLI wiring.
/// The shell/erl executable wrapper owns its VM exit, not this feature module.
pub fn boot() -> Int {
  case containment.cli(argv.load().arguments) {
    Ok(text) -> {
      io.println(text)
      let decoder = {
        use code <- decode.field("code", decode.int)
        decode.success(code)
      }
      case json.parse(text, decoder) {
        Ok(code) -> code
        Error(_) -> 0
      }
    }
    Error(reason) -> {
      json.object([
        #("schema", json.string("mimic.containment/v1")),
        #("status", json.string("blocked")),
        #("reason", json.string(reason)),
      ])
      |> json.to_string
      |> io.println
      2
    }
  }
}
