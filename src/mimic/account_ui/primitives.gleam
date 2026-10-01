/// Reuse the application's OS/crypto/atomic-filesystem primitives. These are
/// capabilities, not a second credential persistence or refresh implementation.
import gleam/option.{type Option, None, Some}

@external(erlang, "mimic_gateway_ffi", "private_read")
pub fn private_read(path: String) -> Result(BitArray, String)

@external(erlang, "mimic_management_ffi", "equal")
pub fn equal(left: String, right: String) -> Bool

@external(erlang, "mimic_auth_ffi", "now_ms")
pub fn epoch_ms() -> Int

type Unit {
  Millisecond
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: Unit) -> Int

pub fn monotonic_ms() -> Int {
  monotonic_time(Millisecond)
}

/// The existing atomic primitive also protects this non-credential bootstrap
/// file. A distinct filename keeps it out of runtime and legacy credential lists.
@external(erlang, "mimic_provider_runtime_ffi", "create_runtime")
pub fn create_private(
  directory: String,
  name: String,
  contents: String,
) -> Result(Nil, String)

@external(erlang, "mimic_provider_runtime_ffi", "mutate_runtime")
fn mutate(
  directory: String,
  name: String,
  expected: Option(String),
  contents: Option(String),
) -> Result(Nil, String)

@external(erlang, "mimic_provider_runtime_ffi", "read_runtime_slot")
fn read_slot(directory: String, name: String) -> Result(Option(String), String)

pub fn remove_private(
  directory: String,
  name: String,
  contents: String,
) -> Result(Nil, String) {
  case read_slot(directory, name) {
    Ok(None) -> Ok(Nil)
    Ok(Some(current)) if current == contents ->
      mutate(directory, name, Some(contents), None)
    _ -> Error("private cleanup unconfirmed")
  }
}

@external(erlang, "mimic_provider_runtime_ffi", "protect")
pub fn protect(callback: fn() -> value) -> Result(value, Nil)

@external(erlang, "mimic_gateway_ffi", "install_signal")
pub fn install_signal() -> Result(Nil, String)

@external(erlang, "mimic_gateway_ffi", "await_signal")
pub fn await_signal() -> Result(Nil, String)

@external(erlang, "mimic_gateway_ffi", "restore_signal")
pub fn restore_signal() -> Nil
