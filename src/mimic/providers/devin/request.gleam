import gleam/list
import gleam/option.{None, Some}
import gleam/result
import mimic/ir
import mimic/providers/devin/auth
import mimic/providers/devin/connect
import mimic/providers/devin/protobuf as pb

pub const chat_path = "/exa.api_server_pb.ApiServerService/GetChatMessage"

/// Explicit inputs permit deterministic synthetic assertions, not fingerprints
/// purportedly measured from a native client. Production supplies fresh entropy.
pub type Identity {
  Identity(os: String, fingerprint: String, session: String, message: String)
}

/// Initial vertical slice: one user text turn, no upstream continuation.
/// Reject extensions rather than silently discard tools, thinking, or images.
pub fn encode(
  request: ir.Request,
  session_token: String,
  identity: Identity,
) -> Result(BitArray, String) {
  use token <- result.try(auth.format_session_token(session_token))
  use text <- result.try(one_shot_text(request))
  use model <- result.try(model_uid(request.model))
  // The pinned catalog caps SWE-1.7 at 64000, overriding the wire helper's
  // generic 128000 default in prepareDevinHTTPRequest.
  let maximum = case request.max_tokens {
    Some(n) if n > 0 && n <= 64_000 -> n
    _ -> 64_000
  }
  let metadata = [
    pb.text(1, "chisel"),
    pb.text(2, "3000.10.21"),
    pb.text(3, token),
    pb.text(4, "en"),
    pb.text(5, identity.os),
    pb.text(7, "3000.10.21"),
    pb.text(12, "chisel"),
    pb.text(31, identity.fingerprint),
  ]
  let fields = [
    pb.message(1, metadata),
    pb.message(3, [
      pb.text(1, identity.message),
      pb.Varint(2, 1),
      pb.text(3, text),
    ]),
    pb.Varint(7, 5),
    pb.message(8, [
      pb.Varint(1, 1),
      pb.Varint(2, maximum),
      pb.Varint(3, 400),
      pb.Fixed64(5, <<1.0:float-little>>),
      pb.Varint(7, 40),
      // CPA promotes float32(0.95) to float64 on the wire.
      pb.Fixed64(8, <<0.949999988079071:float-little>>),
    ]),
    pb.message(15, [
      pb.text(1, identity.session),
      pb.Varint(3, 4),
      pb.Varint(4, 14),
    ]),
    pb.text(16, identity.session),
    pb.Varint(20, 1),
    pb.text(21, model),
  ]
  Ok(connect.envelope(pb.encode(fields)))
}

pub fn model_uid(model: String) -> Result(String, String) {
  case model {
    "devin/swe-1-7" -> Ok("swe-1-7")
    _ -> Error("unsupported devin model")
  }
}

fn one_shot_text(request: ir.Request) -> Result(String, String) {
  case request.system, request.extensions, request.turns {
    None, [], [ir.Turn("user", content, _, [])] -> {
      use parts <- result.try(
        list.try_map(content, fn(part) {
          case part {
            ir.Text(text, []) -> Ok(text)
            _ -> Error("unsupported devin content")
          }
        }),
      )
      case parts {
        [] -> Error("devin user text required")
        _ ->
          Ok(
            list.fold(parts, "", fn(acc, text) {
              case acc {
                "" -> text
                _ -> acc <> "\n" <> text
              }
            }),
          )
      }
    }
    _, _, _ -> Error("devin supports one-shot user text only")
  }
}
