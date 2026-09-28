import gleam/bit_array
import gleam/string

@external(erlang, "mimic_devin_crypto_ffi", "random_bytes")
pub fn random_bytes(size: Int) -> BitArray

@external(erlang, "mimic_devin_crypto_ffi", "sha256")
pub fn sha256(bytes: BitArray) -> BitArray

@external(erlang, "mimic_devin_crypto_ffi", "os_name")
pub fn os_name() -> String

pub fn hex(bytes: BitArray) -> String {
  bit_array.base16_encode(bytes) |> string.lowercase
}

/// Fresh RFC4122 v4 identifier. One-shot chat does not reuse upstream state.
pub fn uuid() -> String {
  let assert <<a:48, _:4, b:12, _:2, c:62>> = random_bytes(16)
  let raw = hex(<<a:48, 4:4, b:12, 2:2, c:62>>)
  string.slice(raw, 0, 8)
  <> "-"
  <> string.slice(raw, 8, 4)
  <> "-"
  <> string.slice(raw, 12, 4)
  <> "-"
  <> string.slice(raw, 16, 4)
  <> "-"
  <> string.slice(raw, 20, 12)
}

pub fn sentry_trace() -> String {
  let raw = hex(random_bytes(24))
  string.slice(raw, 0, 32) <> "-" <> string.slice(raw, 32, 16) <> "-1"
}
