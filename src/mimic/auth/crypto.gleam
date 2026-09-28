import gleam/bit_array

pub fn random_url_token() -> String {
  strong_random_bytes(32) |> bit_array.base64_url_encode(False)
}

pub fn pkce_challenge(verifier: String) -> String {
  sha256(bit_array.from_string(verifier))
  |> bit_array.base64_url_encode(False)
}

@external(erlang, "mimic_auth_ffi", "strong_random_bytes")
fn strong_random_bytes(size: Int) -> BitArray

@external(erlang, "mimic_auth_ffi", "sha256")
fn sha256(input: BitArray) -> BitArray
