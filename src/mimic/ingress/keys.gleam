import gleam/list
import gleam/string

/// Only an identifier is exposed to management; neither the secret nor a
/// reusable verifier is returned or logged.
pub type Metadata {
  Metadata(id: String)
}

pub fn create(
  state_dir: String,
  id: String,
  secret: String,
) -> Result(Nil, String) {
  case valid_id(id) && string.length(secret) >= 16 {
    False ->
      Error(
        "key id required (at most 128 characters); secret must be at least 16 characters",
      )
    True -> store_hash(state_dir, id, secret)
  }
}

pub fn revoke(state_dir: String, id: String) -> Result(Nil, String) {
  case valid_id(id) {
    False -> Error("invalid key id")
    True -> remove_hash(state_dir, id)
  }
}

pub fn verify(state_dir: String, secret: String) -> Result(Bool, String) {
  case secret == "" {
    True -> Ok(False)
    False -> compare_hashes(state_dir, secret)
  }
}

pub fn list_metadata(state_dir: String) -> Result(List(Metadata), String) {
  case list_hashes(state_dir) {
    Ok(ids) -> Ok(list.map(ids, Metadata))
    Error(error) -> Error(error)
  }
}

fn valid_id(id: String) -> Bool {
  id != ""
  && string.length(id) <= 128
  && !string.contains(id, "\r")
  && !string.contains(id, "\n")
}

@external(erlang, "mimic_ingress_keys_ffi", "store")
fn store_hash(
  state_dir: String,
  id: String,
  secret: String,
) -> Result(Nil, String)

@external(erlang, "mimic_ingress_keys_ffi", "remove")
fn remove_hash(state_dir: String, id: String) -> Result(Nil, String)

@external(erlang, "mimic_ingress_keys_ffi", "verify")
fn compare_hashes(state_dir: String, secret: String) -> Result(Bool, String)

@external(erlang, "mimic_ingress_keys_ffi", "list")
fn list_hashes(state_dir: String) -> Result(List(String), String)
