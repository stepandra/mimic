import gleam/bit_array
import gleam/list

/// Store directories must be pre-created by the operator with mode 0700.
/// Contents are plaintext; filesystem permissions are the protection boundary.
pub type Store {
  Store(directory: String)
}

pub fn new(directory: String) -> Result(Store, String) {
  case directory {
    "" -> Error("An explicit auth state directory is required")
    _ ->
      case validate_directory(directory) {
        Ok(_) -> Ok(Store(directory))
        Error(error) -> Error(error)
      }
  }
}

fn filename(id: String) -> Result(String, String) {
  case id {
    "" -> Error("Credential id must not be empty")
    _ ->
      Ok(
        "credential-"
        <> bit_array.base64_url_encode(bit_array.from_string(id), False)
        <> ".json",
      )
  }
}

pub fn read(store: Store, id: String) -> Result(String, String) {
  use name <- result_try(filename(id))
  secure_read(store.directory, name)
}

pub fn write(
  store: Store,
  id: String,
  contents: String,
) -> Result(Nil, String) {
  use name <- result_try(filename(id))
  secure_write(store.directory, name, contents)
}

pub fn delete(store: Store, id: String) -> Result(Nil, String) {
  use name <- result_try(filename(id))
  secure_delete(store.directory, name)
}

pub fn list_ids(store: Store) -> Result(List(String), String) {
  use encoded <- result_try(secure_list(store.directory))
  list.try_map(encoded, fn(value) {
    use bytes <- result_try(
      bit_array.base64_url_decode(value)
      |> map_error("Invalid credential filename"),
    )
    bit_array.to_string(bytes) |> map_error("Invalid credential filename")
  })
}

pub fn read_quota_ledger(store: Store) -> Result(String, String) {
  secure_read_quota(store.directory)
}

pub fn write_quota_ledger(
  store: Store,
  contents: String,
) -> Result(Nil, String) {
  secure_write(store.directory, "quota-ledger.json", contents)
}

fn map_error(value: Result(a, e), message: String) -> Result(a, String) {
  case value {
    Ok(v) -> Ok(v)
    Error(_) -> Error(message)
  }
}

fn result_try(
  value: Result(a, e),
  next: fn(a) -> Result(b, e),
) -> Result(b, e) {
  case value {
    Ok(v) -> next(v)
    Error(e) -> Error(e)
  }
}

@external(erlang, "mimic_auth_ffi", "secure_read")
fn secure_read(directory: String, filename: String) -> Result(String, String)

@external(erlang, "mimic_auth_ffi", "secure_read_quota")
fn secure_read_quota(directory: String) -> Result(String, String)

@external(erlang, "mimic_auth_ffi", "validate_directory")
fn validate_directory(directory: String) -> Result(Nil, String)

@external(erlang, "mimic_auth_ffi", "secure_list")
fn secure_list(directory: String) -> Result(List(String), String)

@external(erlang, "mimic_auth_ffi", "secure_delete")
fn secure_delete(directory: String, filename: String) -> Result(Nil, String)

@external(erlang, "mimic_auth_ffi", "secure_write")
fn secure_write(
  directory: String,
  filename: String,
  contents: String,
) -> Result(Nil, String)
