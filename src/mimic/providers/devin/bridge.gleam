import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import mimic/dialect/anthropic
import mimic/dialect/openai
import mimic/egress
import mimic/ir
import mimic/providers/contracts as c
import mimic/providers/devin/auth
import mimic/providers/devin/identity
import mimic/providers/devin/models as catalog
import mimic/providers/devin/request as wire
import mimic/providers/devin/response
import mimic/providers/devin/stream
import mimic/providers/registry
import mimic/providers/runtime
import mimic/providers/transport
import mimic/types.{type Header, Header}

/// Local-only registration. No implicit provider discovery. Stream is absent
/// until a shared client event codec is qualified; native events are not SSE.
pub fn models() -> List(registry.Model) {
  configured_models(catalog.baseline())
}

pub fn configured_models(
  configured: List(catalog.Model),
) -> List(registry.Model) {
  list.map(configured, fn(model) {
    registry.Model(
      provider: "devin",
      id: model.id,
      auth_modes: ["session_token"],
      protocols: ["openai-chat", "anthropic-messages"],
      operations: ["generate"],
      capabilities: case model.images {
        True -> [c.Buffer, c.Tools, c.Images]
        False -> [c.Buffer, c.Tools]
      },
    )
  })
}

pub fn adapter(ca_file: Option(String)) -> c.Adapter(egress.Stream) {
  transport.binary_http(prepare, rejection, ca_file)
}

pub fn configured_adapter(
  ca_file: Option(String),
  configured: List(catalog.Model),
) -> c.Adapter(egress.Stream) {
  transport.binary_http(
    fn(context, request) { prepare_configured(context, request, configured) },
    rejection,
    ca_file,
  )
}

pub fn prepare(
  context: c.Context,
  request: c.Request,
) -> Result(c.HttpRequest, c.Failure) {
  prepare_configured(context, request, catalog.baseline())
}

pub fn prepare_configured(
  context: c.Context,
  request: c.Request,
  configured: List(catalog.Model),
) -> Result(c.HttpRequest, c.Failure) {
  use _ <- result.try(
    case
      context.provider == "devin"
      && context.auth_mode == "session_token"
      && context.account != ""
      && context.session_key != ""
      && request.session != ""
      && string.byte_size(request.body) <= 8_388_608
      && request.provider == "devin"
      && request.auth_mode == "session_token"
      && request.operation == "generate"
      && list.all(request.required, fn(cap) {
        cap == c.Buffer || cap == c.Stream || cap == c.Tools || cap == c.Images
      })
      && request.pinned_account == None
    {
      True -> Ok(Nil)
      False -> unsupported()
    },
  )
  use token <- result.try(case context.credential {
    c.SessionToken(token, _) ->
      auth.format_session_token(token)
      |> result.replace_error(c.Failure(
        c.CredentialUnavailable,
        c.NotSent,
        None,
      ))
    _ -> Error(c.Failure(c.CredentialUnavailable, c.NotSent, None))
  })
  use input <- result.try(
    case request.protocol {
      "openai-chat" -> openai.decode_request(request.body)
      "anthropic-messages" -> anthropic.decode_request(request.body)
      _ -> Error("unsupported")
    }
    |> result.replace_error(c.Failure(c.Unsupported, c.NotSent, None)),
  )
  use _ <- result.try(
    case
      input.model == request.model
      && { input.stream == Some(True) } == { request.mode == c.Streaming }
    {
      True -> Ok(Nil)
      False -> unsupported()
    },
  )
  use host <- result.try(authority(context.origin))
  let os = identity.os_name()
  use _ <- result.try(case os == "unsupported" {
    True -> unsupported()
    False -> Ok(Nil)
  })
  use body <- result.try(
    wire.encode_configured(
      input,
      token,
      wire.Identity(
        os,
        identity.hex(identity.random_bytes(366)),
        identity.uuid(),
        identity.uuid(),
      ),
      configured,
    )
    |> result.replace_error(c.Failure(c.Unsupported, c.NotSent, None)),
  )
  Ok(c.HttpRequest(
    endpoint: context.origin,
    method: "POST",
    target: wire.chat_path,
    headers: [
      Header("Host", host),
      Header("Authorization", "Basic " <> token <> "-" <> token),
      Header("Content-Type", "application/connect+proto"),
      Header("Connect-Protocol-Version", "1"),
      Header("Accept", "*/*"),
      Header("Sentry-Trace", identity.sentry_trace()),
      Header("Content-Length", int.to_string(bit_array.byte_size(body))),
    ],
    body: body,
    protocol: c.Http1,
    media: c.ConnectProto,
  ))
}

/// Defense in depth: even a direct prepare call cannot select a remote origin.
fn authority(origin: String) -> Result(String, c.Failure) {
  use parsed <- result.try(
    uri.parse(origin)
    |> result.replace_error(c.Failure(c.InvalidConfiguration, c.NotSent, None)),
  )
  case parsed {
    uri.Uri(
      scheme: Some(scheme),
      host: Some("127.0.0.1"),
      userinfo: None,
      path: "",
      query: None,
      fragment: None,
      ..,
    )
      if scheme == "http" || scheme == "https"
    -> {
      use port <- result.try(case parsed.port {
        None -> Ok("")
        Some(port) if port > 0 && port < 65_536 -> Ok(":" <> int.to_string(port))
        _ -> unsupported()
      })
      Ok("127.0.0.1" <> port)
    }
    _ -> unsupported()
  }
}

/// Only an explicit HTTP 429 before accepted output is retryable. Trailer
/// errors and codec failures occur after Started and must never replay.
pub fn rejection(status: Int, headers: List(Header)) -> Option(c.Failure) {
  case status {
    429 -> {
      let delay =
        headers
        |> list.find(fn(h) { string.lowercase(h.name) == "retry-after" })
        |> result.try(fn(h) { int.parse(string.trim(h.value)) })
        |> result.try(fn(seconds) {
          case seconds >= 0 && seconds <= 86_400 {
            True -> Ok(seconds * 1000)
            False -> Error(Nil)
          }
        })
        |> option.from_result
      Some(c.Failure(c.Quota, c.Rejected, delay))
    }
    _ -> None
  }
}

pub fn execute(
  owner: runtime.Runtime,
  ca_file: Option(String),
  request: c.Request,
) -> Result(String, c.Failure) {
  execute_configured(owner, ca_file, request, catalog.baseline())
}

pub fn execute_configured(
  owner: runtime.Runtime,
  ca_file: Option(String),
  request: c.Request,
  configured: List(catalog.Model),
) -> Result(String, c.Failure) {
  use _ <- result.try(case request.mode {
    c.Buffered -> Ok(Nil)
    c.Streaming -> unsupported()
  })
  use output <- result.try(runtime.execute(
    owner,
    configured_adapter(ca_file, configured),
    request,
  ))
  use _ <- result.try(case output.status >= 200 && output.status < 300 {
    True -> Ok(Nil)
    False -> Error(c.Failure(c.Unavailable, c.Started, None))
  })
  use decoded <- result.try(
    response.buffered(output.body, "devin-" <> identity.uuid(), request.model)
    |> result.replace_error(c.Failure(c.InvalidResponse, c.Started, None)),
  )
  // Native accounting/signature markers are preserved by the native decoder,
  // but are not vendor JSON fields. Shared codecs have no faithful mapping
  // yet; never emit numeric zeros for unknown counts or invented cache keys.
  use _ <- result.try(case projectable(decoded) {
    True -> Ok(Nil)
    False -> Error(c.Failure(c.Unsupported, c.Started, None))
  })
  case request.protocol {
    "openai-chat" -> openai.encode_response(decoded)
    "anthropic-messages" -> anthropic.encode_response(decoded)
    _ -> Error("unsupported")
  }
  |> result.replace_error(c.Failure(c.Unsupported, c.Started, None))
}

fn projectable(decoded: ir.Response) -> Bool {
  let usage = case decoded.usage {
    None | Some(ir.Usage(_, _, [])) -> True
    _ -> False
  }
  usage
  && decoded.stop_reason != Some("content_filter")
  && list.all(decoded.content, fn(part) {
    case part {
      ir.Thinking(_, _, [_, ..]) -> False
      ir.Unknown(_) -> False
      _ -> True
    }
  })
}

/// Native events only. Registry Stream opt-in and a qualified client codec are
/// integration-owner responsibilities; this is not a public SSE route.
pub fn open_native_stream(
  owner: runtime.Runtime,
  ca_file: Option(String),
  request: c.Request,
  configured: List(catalog.Model),
) -> Result(#(String, stream.Stream), c.Failure) {
  use _ <- result.try(case request.mode {
    c.Streaming -> Ok(Nil)
    _ -> unsupported()
  })
  use output <- result.try(runtime.open(
    owner,
    configured_adapter(ca_file, configured),
    request,
  ))
  case output.status >= 200 && output.status < 300 {
    True -> Ok(#(output.account, stream.new(output.stream)))
    False -> {
      runtime.cancel(output.stream)
      Error(c.Failure(c.Unavailable, c.Started, None))
    }
  }
}

fn unsupported() -> Result(a, c.Failure) {
  Error(c.Failure(c.Unsupported, c.NotSent, None))
}

pub fn cli(args: List(String)) -> Result(String, String) {
  case args {
    [] | ["help"] ->
      Ok(
        "Devin: source-backed local Connect adapter; remote and client-stream codec qualification required",
      )
    _ -> Error("unsupported Devin CLI operation")
  }
}
