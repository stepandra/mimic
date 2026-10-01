import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import mimic/ir
import mimic/providers/devin/auth
import mimic/providers/devin/connect
import mimic/providers/devin/continuation
import mimic/providers/devin/conversation
import mimic/providers/devin/identity as native_identity
import mimic/providers/devin/models
import mimic/providers/devin/protobuf as pb

pub const chat_path = "/exa.api_server_pb.ApiServerService/GetChatMessage"

/// Explicit inputs permit deterministic synthetic assertions, not fingerprints
/// purportedly measured from a native client. Production supplies fresh entropy.
pub type Identity {
  Identity(os: String, fingerprint: String, session: String, message: String)
}

/// Full submitted history, with a fresh native session unless the trusted caller
/// supplies scoped continuation metadata. No client-controlled UUID forwarding.
pub fn encode(
  request: ir.Request,
  session_token: String,
  identity: Identity,
) -> Result(BitArray, String) {
  encode_configured(request, session_token, identity, models.baseline())
}

pub fn encode_configured(
  request: ir.Request,
  session_token: String,
  identity: Identity,
  configured: List(models.Model),
) -> Result(BitArray, String) {
  encode_thread(
    request,
    session_token,
    identity,
    configured,
    identity.session,
    0,
  )
}

/// Trusted session-owner hook only. Scope must first be created/advanced under
/// the shared guard; this pure encoder does not grant continuation capability.
pub fn encode_continuation(
  request: ir.Request,
  session_token: String,
  identity: Identity,
  configured: List(models.Model),
  scope: continuation.Scope,
) -> Result(BitArray, String) {
  use _ <- result.try(
    case continuation.permits(scope, session_token, request.model) {
      True -> Ok(Nil)
      False -> Error("devin continuation credential or model changed")
    },
  )
  encode_thread(
    request,
    session_token,
    Identity(..identity, session: continuation.session(scope)),
    configured,
    continuation.cascade(scope),
    continuation.ordinal(scope),
  )
}

fn encode_thread(
  request: ir.Request,
  session_token: String,
  identity: Identity,
  configured: List(models.Model),
  cascade: String,
  ordinal: Int,
) -> Result(BitArray, String) {
  use model <- result.try(models.resolve(configured, request.model))
  use token <- result.try(auth.format_session_token(session_token))
  use history <- result.try(
    conversation.history(request.turns, fn(index) {
      case index {
        0 -> identity.message
        _ -> native_identity.uuid()
      }
    }),
  )
  use _ <- result.try(case model.images || !has_images(history) {
    True -> Ok(Nil)
    False -> Error("configured devin model does not support images")
  })
  use system <- result.try(case request.system {
    None -> Ok([])
    Some(value) ->
      conversation.system(value) |> result.map(fn(text) { [pb.text(2, text)] })
  })
  use options <- result.try(
    list.try_fold(request.extensions, #([], 1.0), fn(acc, entry) {
      case entry {
        #("tools", value) -> {
          use tools <- result.try(conversation.tools(value, request.origin))
          Ok(#(list.append(acc.0, tools), acc.1))
        }
        #("temperature", ir.Decimal(n)) if n >=. 0.0 && n <=. 2.0 ->
          Ok(#(acc.0, n))
        #("temperature", ir.Integer(0)) -> Ok(#(acc.0, 0.0))
        #("temperature", ir.Integer(1)) -> Ok(#(acc.0, 1.0))
        #("temperature", ir.Integer(2)) -> Ok(#(acc.0, 2.0))
        _ -> Error("unsupported devin request extension")
      }
    }),
  )
  let maximum = case request.max_tokens {
    Some(n) if n > 0 && n <= model.max_tokens -> n
    _ -> model.max_tokens
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
  let prefix = list.flatten([[pb.message(1, metadata)], system, history])
  let config = [
    pb.Varint(7, 5),
    pb.message(8, [
      pb.Varint(1, 1),
      pb.Varint(2, maximum),
      pb.Varint(3, 400),
      pb.Fixed64(5, <<options.1:float-little>>),
      pb.Varint(7, 40),
      // CPA promotes float32(0.95) to float64 on the wire.
      pb.Fixed64(8, <<0.949999988079071:float-little>>),
    ]),
  ]
  let previous_is_user = case list.reverse(history) {
    [_, pb.Bytes(3, previous), ..] ->
      case pb.decode(previous) {
        Ok(fields) -> list.contains(fields, pb.Varint(2, 1))
        Error(_) -> False
      }
    _ -> False
  }
  let boundary = case list.last(history) {
    Ok(pb.Bytes(3, prompt)) ->
      case pb.decode(prompt) {
        Ok(fields) ->
          case
            list.contains(fields, pb.Varint(2, 1))
            && { ordinal == 0 || !previous_is_user }
          {
            True -> [pb.Varint(4, 14)]
            False -> []
          }
        Error(_) -> []
      }
    _ -> []
  }
  let turn = case ordinal {
    0 -> []
    n -> [pb.Varint(2, n)]
  }
  let suffix = [
    pb.message(
      15,
      list.flatten([
        [pb.text(1, identity.session)],
        turn,
        [pb.Varint(3, 4)],
        boundary,
      ]),
    ),
    pb.text(16, cascade),
    pb.Varint(20, 1),
    pb.text(21, model.uid),
  ]
  let bytes = pb.encode(list.flatten([prefix, config, options.0, suffix]))
  case bit_array.byte_size(bytes) <= 8_388_608 {
    True -> Ok(connect.envelope(bytes))
    False -> Error("devin request frame limit")
  }
}

pub fn model_uid(model: String) -> Result(String, String) {
  models.resolve(models.baseline(), model)
  |> result.map(fn(model) { model.uid })
}

fn has_images(history: List(pb.Field)) -> Bool {
  list.any(history, fn(field) {
    case field {
      pb.Bytes(3, prompt) ->
        case pb.decode(prompt) {
          Ok(fields) ->
            list.any(fields, fn(f) {
              case f {
                pb.Bytes(10, _) -> True
                _ -> False
              }
            })
          Error(_) -> False
        }
      _ -> False
    }
  })
}
