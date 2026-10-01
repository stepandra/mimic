/// Provider-neutral, private enrollment work. The coordinator reserves S5
/// before invoking an adapter and alone commits/cancels its returned material.
/// Adapters must not save credentials or start a second refresh manager.
import gleam/option.{type Option}
import mimic/providers/contracts.{type AuthMaterial}

/// The only provider-owned values allowed in authenticated UI status.
pub type Prompt {
  DeviceCode(user_code: String, verification_uri: String)
  BrowserLogin(authorization_url: String)
}

pub type Emit =
  fn(Option(Prompt), Int) -> Nil

pub type Clock =
  fn() -> Int

/// Deadline and emitted prompt deadlines are monotonic integer milliseconds.
/// Errors are public phase names, never provider bodies or exception details.
pub type Adapter {
  Adapter(run: fn(Emit, Int, Clock) -> Result(AuthMaterial, String))
}
