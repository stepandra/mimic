import gleam/option.{type Option}
import gleam/result
import mimic/egress
import mimic/providers/contracts.{
  type Adapter, type Context, type Failure, type HttpRequest, type Request,
  Adapter, Opened,
}
import mimic/types.{type Capture, type Header}

/// The provider owns serialization/auth headers; runtime owns the approved
/// destination, TLS validation, socket lifetime, framing and replay policy.
/// A private CA file supplements operator configuration, never verify_none.
pub fn http(
  prepare: fn(Context, Request) -> Result(Capture, Failure),
  rejection: fn(Int, List(Header)) -> Option(Failure),
  ca_file: Option(String),
) -> Adapter(egress.Stream) {
  Adapter(
    open: fn(context, request) {
      use capture <- result.try(prepare(context, request))
      use response <- result.try(egress.stream_open(
        context.origin,
        capture,
        ca_file,
      ))
      Ok(Opened(response.0, response.1, response.2))
    },
    next: egress.stream_next,
    cancel: egress.stream_cancel,
    rejection: rejection,
  )
}

/// Opt-in binary HTTP transport. The entire plan/body is secret, including
/// embedded protobuf credentials. It must never enter captures or diagnostics.
/// Provider code, not this transport, owns Connect framing and EOS validation.
pub fn binary_http(
  prepare: fn(Context, Request) -> Result(HttpRequest, Failure),
  rejection: fn(Int, List(Header)) -> Option(Failure),
  ca_file: Option(String),
) -> Adapter(egress.Stream) {
  Adapter(
    open: fn(context, request) {
      use plan <- result.try(prepare(context, request))
      use response <- result.try(egress.stream_open_binary(
        context.origin,
        plan,
        ca_file,
      ))
      Ok(Opened(response.0, response.1, response.2))
    },
    next: egress.stream_next,
    cancel: egress.stream_cancel,
    rejection: rejection,
  )
}
