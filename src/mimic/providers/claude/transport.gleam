/// Conservative release policy for ambiguous Claude HTTP 429 responses.
/// The generic runtime observes every successful Opened before rejection, so
/// a rejection callback alone cannot prevent credential cooldown.
import gleam/option.{type Option, None}
import gleam/result
import mimic/egress
import mimic/providers/claude/adapter
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
