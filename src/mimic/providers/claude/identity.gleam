/// Identity is supplied by the runtime, scoped to the selected credential.
/// No secret hashing, random process state, storage, or fabricated fingerprint.
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import mimic/ir

pub type Account {
  Account(device_id: String, account_uuid: String)
}

pub fn validate(account: Account) -> Result(Nil, String) {
  let hex = string.to_graphemes("0123456789abcdef")
  case
    string.length(account.device_id) == 64
    && list.all(string.to_graphemes(account.device_id), fn(c) {
      list.contains(hex, c)
    })
    && string.trim(account.account_uuid) != ""
  {
    True -> Ok(Nil)
    False -> Error("Invalid Claude credential identity")
  }
}

/// Modern JSON-in-string metadata.user_id. Legacy opaque user IDs are rejected
/// rather than silently copied across credentials or losing extension fields.
pub fn apply(
  body: ir.Value,
  account: Account,
  session: String,
) -> Result(ir.Value, String) {
  use _ <- result.try(validate(account))
  use metadata <- result.try(case ir.field(body, "metadata") {
    None -> Ok([])
    Some(value) -> ir.as_object(value)
  })
  let metadata_value = ir.Object(metadata)
  use extensions <- result.try(case ir.field(metadata_value, "user_id") {
    None -> Ok([])
    Some(ir.String(value)) -> {
      use value <- result.try(
        ir.parse(value)
        |> result.map_error(fn(_) {
          "Unsupported Claude metadata.user_id encoding"
        }),
      )
      use _ <- result.try(ir.as_object(value))
      Ok(ir.extras(value, ["device_id", "account_uuid", "session_id"]))
    }
    _ -> Error("Unsupported Claude metadata.user_id encoding")
  })
  let user_id =
    ir.Object(list.append(
      [
        #("device_id", ir.String(account.device_id)),
        #("account_uuid", ir.String(account.account_uuid)),
        #("session_id", ir.String(session)),
      ],
      extensions,
    ))
    |> ir.stringify
  let metadata =
    ir.Object(
      list.append(ir.extras(metadata_value, ["user_id"]), [
        #("user_id", ir.String(user_id)),
      ]),
    )
  Ok(
    ir.Object(
      list.append(ir.extras(body, ["metadata"]), [#("metadata", metadata)]),
    ),
  )
}
