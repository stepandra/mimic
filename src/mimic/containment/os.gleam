/// Narrow, bounded OS primitives. Orchestration stays in Gleam.
pub type Handle

pub type Event {
  Data(String)
  Exited(Int)
  Closed
  Idle
  Fault
}

@external(erlang, "mimic_containment_ffi", "open")
pub fn open(executable: String, args: List(String)) -> Result(Handle, String)

@external(erlang, "mimic_containment_ffi", "receive_event")
pub fn receive_event(handle: Handle, wait_ms: Int) -> Event

@external(erlang, "mimic_containment_ffi", "send")
pub fn send(handle: Handle, data: String) -> Result(Nil, String)

@external(erlang, "mimic_containment_ffi", "close")
pub fn close(handle: Handle) -> Nil

@external(erlang, "mimic_containment_ffi", "clock")
pub fn clock() -> Int

@external(erlang, "mimic_containment_ffi", "nonce")
pub fn nonce() -> String

@external(erlang, "mimic_containment_ffi", "utf8")
pub fn utf8(data: String) -> Result(String, String)

@external(erlang, "mimic_containment_ffi", "stdin")
pub fn stdin() -> Result(Handle, String)

@external(erlang, "mimic_containment_ffi", "owner_boundary")
pub fn owner_boundary() -> Result(Nil, String)

@external(erlang, "mimic_containment_ffi", "fixtures")
pub fn fixtures() -> Result(Nil, String)

@external(erlang, "mimic_containment_ffi", "record_boundary")
pub fn record_boundary(data: String) -> Result(Nil, String)

@external(erlang, "mimic_containment_ffi", "companion")
pub fn companion(args: List(String)) -> Result(Handle, String)

@external(erlang, "mimic_containment_ffi", "kill_owned")
pub fn kill_owned(handle: Handle) -> Result(Nil, String)

pub fn command(
  executable: String,
  args: List(String),
  timeout_ms: Int,
  output_bytes: Int,
) -> Result(#(Int, String), String) {
  case open(executable, args) {
    Error(error) -> Error(error)
    Ok(handle) -> wait(handle, timeout_ms, output_bytes)
  }
}

pub fn wait(
  handle: Handle,
  timeout_ms: Int,
  output_bytes: Int,
) -> Result(#(Int, String), String) {
  collect(handle, clock() + timeout_ms, output_bytes, "", 0)
}

fn collect(handle, deadline, limit, output, bytes) {
  case clock() >= deadline {
    True -> {
      close(handle)
      Error("containment_os_command_timeout")
    }
    False ->
      case receive_event(handle, 50) {
        Data(data) -> {
          let size = bytes + byte_size(data)
          case size <= limit {
            True -> collect(handle, deadline, limit, output <> data, size)
            False -> {
              close(handle)
              Error("containment_os_output_limit")
            }
          }
        }
        Exited(code) -> {
          case utf8(output) {
            Ok(output) -> Ok(#(code, output))
            Error(error) -> Error(error)
          }
        }
        Idle -> collect(handle, deadline, limit, output, bytes)
        Closed | Fault -> {
          close(handle)
          Error("containment_os_command_failed")
        }
      }
  }
}

@external(erlang, "erlang", "byte_size")
fn byte_size(data: String) -> Int
