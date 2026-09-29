/// CPA's generic openai-compatible-kimi identity, NOT the native Kimi adapter.
/// No OAuth/device metadata, coding path, model aliases or thinking transforms.
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import mimic/dialect/openai
import mimic/egress
import mimic/ir
import mimic/providers/contracts
import mimic/providers/kimi/json_guard
import mimic/providers/registry
import mimic/providers/transport
import mimic/types.{type Capture, type Header, Capture, Header, Transport}

pub const provider = "openai-compatible-kimi"

pub fn registration(model: String) -> Result(registry.Model, String) {
  case string.trim(model) {
    "" -> Error("Generic Kimi model must be explicitly configured")
    _ ->
      Ok(
        registry.Model(
          provider,
          model,
          ["api_key"],
          ["chat"],
          ["chat/completions"],
          [contracts.Buffer, contracts.Tools, contracts.Images],
        ),
      )
  }
}

pub fn http_at(
  base_path: fn(contracts.Context) -> Result(String, contracts.Failure),
  ca_file: Option(String),
) -> contracts.Adapter(egress.Stream) {
  transport.http(
    fn(context, request) {
      use path <- result.try(base_path(context))
      prepare_at(path, context, request)
    },
    rejection,
    ca_file,
  )
}

/// base_path is an API prefix (e.g. "/v1"), unlike native Kimi's coding base.
pub fn prepare_at(
  base_path: String,
  context: contracts.Context,
  request: contracts.Request,
) -> Result(Capture, contracts.Failure) {
  let plan = {
    use _ <- result.try(check(
      context.provider == provider
      && request.provider == provider
      && context.auth_mode == "api_key"
      && request.auth_mode == "api_key"
      && request.protocol == "chat"
      && request.operation == "chat/completions"
      && request.mode == contracts.Buffered
      && request.pinned_account == None
      && context.account != ""
      && context.session_key != ""
      && request.session != ""
      && list.all(request.required, fn(capability) {
        list.contains(
          [contracts.Buffer, contracts.Tools, contracts.Images],
          capability,
        )
      }),
    ))
    use token <- result.try(case context.credential {
      contracts.ApiKey(token) -> {
        use _ <- result.try(check(string.trim(token) != "" && safe(token)))
        Ok(token)
      }
      _ -> Error(Nil)
    })
    use origin <- result.try(uri.parse(context.origin))
    use host <- result.try(case origin {
      uri.Uri(scheme, None, Some(host), port, path, None, None)
        if {
          scheme == Some("https")
          || {
            scheme == Some("http")
            && { host == "127.0.0.1" || host == "localhost" }
          }
        }
        && { path == "" || path == "/" }
      ->
        case port {
          None -> Ok(host)
          Some(port) if port > 0 && port <= 65_535 ->
            Ok(host <> ":" <> int.to_string(port))
          _ -> Error(Nil)
        }
      _ -> Error(Nil)
    })
    use _ <- result.try(check(
      safe(context.origin)
      && safe(base_path)
      && { base_path == "" || string.starts_with(base_path, "/") }
      && !string.ends_with(base_path, "/")
      && !list.any(["//", "..", "\\", "?", "#", "%", " "], fn(part) {
        string.contains(base_path, part)
      }),
    ))
    use decoded <- result.try(
      openai.decode_request(request.body) |> result.replace_error(Nil),
    )
    use _ <- result.try(check(
      decoded.model == request.model && decoded.stream != Some(True),
    ))
    // This adapter is native Chat passthrough, not a multimodal translator.
    // Unsupported audio and server-side state must not look like text success.
    use value <- result.try(
      json_guard.parse(request.body) |> result.replace_error(Nil),
    )
    use _ <- result.try(
      check(
        list.all(
          ["audio", "modalities", "previous_response_id", "conversation"],
          fn(key) { ir.field(value, key) == None },
        ),
      ),
    )
    use messages <- result.try(
      ir.required(value, "messages")
      |> result.try(ir.as_array)
      |> result.replace_error(Nil),
    )
    use _ <- result.try(list.try_each(messages, validate_message_media))
    Ok(Capture(
      "mimic-kimi-compat",
      "generic-openai",
      context.origin,
      request.operation,
      "POST",
      base_path <> "/chat/completions",
      "HTTP/1.1",
      [
        Header("Host", host),
        Header("Authorization", "Bearer " <> token),
        Header("Content-Type", "application/json"),
        Header("Accept", "application/json"),
        Header("Accept-Encoding", "identity"),
        Header("Content-Length", int.to_string(string.byte_size(request.body))),
      ],
      request.body,
      Transport("http/1.1", None),
    ))
  }
  result.map_error(plan, fn(_) {
    contracts.Failure(contracts.Unsupported, contracts.NotSent, None)
  })
}

/// Request.required is caller-supplied, not proof that the native body is
/// within registered capabilities. Inspect protocol-owned content positions
/// equally for user/system/assistant messages and role=tool results. Never
/// descend into schema, function arguments, text strings or vendor extensions.
fn validate_message_media(message: ir.Value) -> Result(Nil, Nil) {
  use _ <- result.try(check(ir.field(message, "audio") == None))
  case ir.field(message, "content") {
    None | Some(ir.Null) | Some(ir.String(_)) -> Ok(Nil)
    Some(ir.Array(parts)) -> list.try_each(parts, validate_content_part)
    _ -> Error(Nil)
  }
}

fn validate_content_part(part: ir.Value) -> Result(Nil, Nil) {
  case ir.field(part, "type") {
    Some(ir.String("text")) ->
      ir.string_field(part, "text")
      |> result.map(fn(_) { Nil })
      |> result.replace_error(Nil)
    Some(ir.String("image_url")) -> {
      use image <- result.try(
        ir.required(part, "image_url") |> result.replace_error(Nil),
      )
      use url <- result.try(
        ir.string_field(image, "url") |> result.replace_error(Nil),
      )
      validate_image_url(url)
    }
    // Audio/video/file/unknown forms are unsupported, not opaque text.
    _ -> Error(Nil)
  }
}

fn validate_image_url(url: String) -> Result(Nil, Nil) {
  use _ <- result.try(check(safe(url)))
  case string.starts_with(url, "data:") {
    True ->
      check(
        list.any(["png", "jpeg", "webp", "gif"], fn(kind) {
          let prefix = "data:image/" <> kind <> ";base64,"
          string.starts_with(url, prefix)
          && string.length(url) > string.length(prefix)
        }),
      )
    False -> {
      use parsed <- result.try(uri.parse(url))
      check(
        parsed.scheme == Some("https")
        && parsed.host != None
        && parsed.host != Some("")
        && parsed.userinfo == None
        && parsed.fragment == None,
      )
    }
  }
}

pub fn rejection(
  status: Int,
  _headers: List(Header),
) -> Option(contracts.Failure) {
  case status {
    401 ->
      Some(contracts.Failure(
        contracts.CredentialUnavailable,
        contracts.Rejected,
        None,
      ))
    429 -> Some(contracts.Failure(contracts.Quota, contracts.Uncertain, None))
    _ -> None
  }
}

fn safe(value: String) -> Bool {
  !list.any(["\r", "\n", "\u{0000}"], fn(part) { string.contains(value, part) })
}

fn check(condition: Bool) {
  case condition {
    True -> Ok(Nil)
    False -> Error(Nil)
  }
}

pub fn cli(_args: List(String)) -> Result(String, String) {
  Ok(
    "openai-compatible-kimi: explicit API-key Chat registration; not native Kimi OAuth",
  )
}
