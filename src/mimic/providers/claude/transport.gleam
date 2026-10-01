/// Conservative release policy for ambiguous Claude HTTP 429 responses.
/// The generic runtime observes every successful Opened before rejection, so
/// a rejection callback alone cannot prevent credential cooldown.
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import mimic/egress
import mimic/providers/claude/adapter
import mimic/providers/claude/rejection
import mimic/providers/contracts
import mimic/providers/transport as shared_transport
import mimic/types.{type Capture}

/// Every production Claude route must use this constructor, including routes
/// with a custom prepare policy. No response body is read, retained or exposed.
/// Tradeoff: genuine quota 429s also lose automatic cooldown/failover until a
/// bounded, source-backed credential-scope distinction is separately qualified.
pub fn http(
  prepare: fn(contracts.Context, contracts.Request) ->
    Result(Capture, contracts.Failure),
  ca_file: Option(String),
) -> contracts.Adapter(egress.Stream) {
  let base = shared_transport.http(prepare, adapter.rejection, ca_file)
  contracts.Adapter(..base, open: fn(context, request) {
    use opened <- result.try(base.open(context, request))
    case opened.status {
      429 -> {
        // No handle is transferred to runtime on Error; close exactly here.
        // Error skips Observe and Unsupported is explicitly non-retryable.
        base.cancel(opened.handle)
        Error(contracts.Failure(contracts.Unsupported, contracts.Rejected, None))
      }
      _ -> Ok(opened)
    }
  })
}

/// An actual consumed rejection has no socket. No dummy/reopened stream, body
/// or secret header survives this state; runtime cancellation is a no-op.
pub opaque type Handle {
  Live(egress.Stream)
  Closed
}

@external(erlang, "mimic_egress_ffi", "now_ms")
fn monotonic_ms() -> Int

@external(erlang, "mimic_auth_ffi", "now_ms")
fn wall_ms() -> Int

/// F10 additive opt-in. Keep `http` and the default root conservative until the
/// coordinator admits the real configured gateway/CLI/shipment route matrix.
/// Classify inside open, BEFORE runtime can Observe or decide to retry.
pub fn http_classified(
  prepare: fn(contracts.Context, contracts.Request) ->
    Result(Capture, contracts.Failure),
  ca_file: Option(String),
) -> contracts.Adapter(Handle) {
  let base = shared_transport.http(prepare, adapter.rejection, ca_file)
  contracts.Adapter(
    open: fn(context, request) {
      use opened <- result.try(base.open(context, request))
      case opened.status {
        429 -> classify_opened(opened)
        _ ->
          Ok(contracts.Opened(
            opened.status,
            opened.headers,
            Live(opened.handle),
          ))
      }
    },
    next: fn(handle) {
      case handle {
        Closed -> Ok(None)
        Live(stream) ->
          base.next(stream)
          |> result.map(fn(next) {
            option.map(next, fn(pair) { #(pair.0, Live(pair.1)) })
          })
      }
    },
    cancel: fn(handle) {
      case handle {
        Closed -> Nil
        Live(stream) -> base.cancel(stream)
      }
    },
    rejection: fn(status, headers) {
      case status {
        429 ->
          case rejection.retry_after(headers) {
            Some(ms) ->
              Some(contracts.Failure(
                contracts.Quota,
                contracts.Rejected,
                Some(ms),
              ))
            None ->
              Some(contracts.Failure(
                contracts.Unsupported,
                contracts.Uncertain,
                None,
              ))
          }
        _ -> adapter.rejection(status, headers)
      }
    },
  )
}

fn classify_opened(
  opened: contracts.Opened(egress.Stream),
) -> Result(contracts.Opened(Handle), contracts.Failure) {
  // One clock/deadline for the entire body, EOF, UTF-8, JSON and scope decision.
  // Monotonic absolute values can legitimately be negative.
  let deadline = monotonic_ms() + rejection.total_time_ms
  let decision = case rejection.admissible_headers(opened.headers) {
    False -> Error(Nil)
    True ->
      case collect(opened.handle, deadline, [], 0, 0) {
        Error(_) -> Error(Nil)
        Ok(body) -> {
          let decision = rejection.classify(opened.headers, body, wall_ms())
          case monotonic_ms() < deadline {
            True -> Ok(decision)
            False -> Error(Nil)
          }
        }
      }
  }
  // Neither reader nor classifier closes. No handle escapes on Error; close
  // here exactly once, including time/byte/work/parser failures.
  egress.stream_cancel(opened.handle)
  case decision {
    Ok(rejection.SharedQuota(ms, windows)) ->
      Ok(contracts.Opened(429, rejection.sanitized_headers(ms, windows), Closed))
    Ok(rejection.RequestScoped) ->
      Error(contracts.Failure(
        contracts.RequestLimited,
        contracts.Rejected,
        None,
      ))
    Ok(rejection.Unknown) ->
      Error(contracts.Failure(contracts.Unsupported, contracts.Uncertain, None))
    Error(_) ->
      Error(contracts.Failure(
        contracts.InvalidResponse,
        contracts.Uncertain,
        None,
      ))
  }
}

fn collect(
  stream: egress.Stream,
  deadline: Int,
  chunks: List(BitArray),
  bytes: Int,
  events: Int,
) -> Result(String, Nil) {
  use _ <- result.try(
    case
      bytes <= rejection.max_body_bytes
      && bytes + 16_384 <= rejection.max_read_bytes
      && events < rejection.max_read_events
      && monotonic_ms() < deadline
    {
      True -> Ok(Nil)
      False -> Error(Nil)
    },
  )
  use next <- result.try(
    egress.stream_next_before(stream, deadline) |> result.replace_error(Nil),
  )
  case next {
    None ->
      list.reverse(chunks)
      |> bit_array.concat
      |> bit_array.to_string
      |> result.replace_error(Nil)
    Some(#(chunk, stream)) ->
      collect(
        stream,
        deadline,
        [chunk, ..chunks],
        bytes + bit_array.byte_size(chunk),
        events + 1,
      )
  }
}
