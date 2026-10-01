import gleam/dynamic/decode
import gleam/json
import gleam/result

pub type Receipt {
  Receipt(code: Int, reason: String, output: String, container: String)
}

pub fn encode(code: Int, reason: String, output: String) -> String {
  json.object([
    #("schema", json.string("mimic.containment/v1")),
    #("code", json.int(code)),
    #("reason", json.string(reason)),
    #("output", json.string(output)),
  ])
  |> json.to_string
}

pub fn decode(text: String, container: String) -> Result(Receipt, String) {
  let decoder = {
    use schema <- decode.field("schema", decode.string)
    use code <- decode.field("code", decode.int)
    use reason <- decode.field("reason", decode.string)
    use output <- decode.field("output", decode.string)
    decode.success(#(schema, code, reason, output))
  }
  use parsed <- result.try(
    json.parse(text, decoder)
    |> result.map_error(fn(_) { "containment_owner_report_invalid" }),
  )
  let #(schema, code, reason, output) = parsed
  case schema == "mimic.containment/v1" {
    True -> Ok(Receipt(code, reason, output, container))
    False -> Error("containment_owner_report_schema_invalid")
  }
}
