import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mimic/auth
import mimic/auth/crypto
import mimic/auth/storage.{type Store}
import mimic/providers/contracts.{
  type AuthMaterial, ApiKey, OAuth, OAuthData, SessionToken,
}

pub const max_timestamp_ms = 9_223_372_036_854_775_807

pub type RefreshStatus {
  Ready
  Deferred(until_ms: Int)
  NeedsReauthorization
}

pub opaque type Revision {
  Revision(String)
}

/// Private snapshot for generation-aware transitions. Never log this value.
pub opaque type CredentialRecord {
  Record(
    material: AuthMaterial,
    gate: RefreshStatus,
    revision: Revision,
    raw: String,
  )
}

pub fn record_material(record: CredentialRecord) -> AuthMaterial {
  record.material
}

pub fn record_status(record: CredentialRecord) -> RefreshStatus {
  record.gate
}

pub fn revision(record: CredentialRecord) -> Revision {
  record.revision
}

pub fn refresh_status(
  store: Store,
  key: String,
) -> Result(RefreshStatus, String) {
  load_record(store, key) |> result.map(record_status)
}

/// Separate versioned namespace; never puts API keys in legacy OAuth files.
pub fn save(
  store: Store,
  key: String,
  material: AuthMaterial,
) -> Result(Nil, String) {
  use _ <- result.try(validate(material))
  let record = new_record(material, Ready)
  storage.write_runtime(store, key, record.raw)
}

/// A concurrent admin replacement/deletion must win over an older refresh.
/// The filesystem comparison and replacement share one atomic mutation guard.
pub fn save_if_unchanged(
  store: Store,
  key: String,
  previous: AuthMaterial,
  updated: AuthMaterial,
) -> Result(Nil, String) {
  // Compatibility value-CAS. Never clears a gate. Async refresh/enrichment must
  // instead retain load_record's opaque snapshot and use transition below.
  use record <- result.try(load_record(store, key))
  case record.material == previous {
    False -> Error("Runtime credential changed during refresh")
    True ->
      transition(store, key, record, updated, record.gate)
      |> result.map(fn(_) { Nil })
  }
}

/// Atomic exact-generation transition. A same-token admin save is a new
/// generation and defeats this CAS just like replacement or deletion.
pub fn transition(
  store: Store,
  key: String,
  previous: CredentialRecord,
  updated: AuthMaterial,
  gate: RefreshStatus,
) -> Result(CredentialRecord, String) {
  use _ <- result.try(validate(updated))
  use _ <- result.try(validate_gate(updated, gate))
  let next = new_record(updated, gate)
  use _ <- result.try(storage.compare_write_runtime(
    store,
    key,
    previous.raw,
    next.raw,
  ))
  Ok(next)
}

pub fn delete(store: Store, key: String) -> Result(Nil, String) {
  storage.delete_runtime(store, key)
}

pub type Metadata {
  Metadata(kind: String, expires_at_ms: Option(Int))
}

/// Safe management hook; contains no secret or private identity fields.
pub fn metadata(store: Store, key: String) -> Result(Metadata, String) {
  use material <- result.try(load(store, key))
  case material {
    ApiKey(_) -> Ok(Metadata("api_key", None))
    OAuth(data) -> Ok(Metadata("oauth", Some(data.credential.expires_at_ms)))
    SessionToken(_, _) -> Ok(Metadata("session_token", None))
  }
}

fn encode_material(material: AuthMaterial) -> List(#(String, json.Json)) {
  let fields = case material {
    ApiKey(secret) -> [
      #("kind", json.string("api_key")),
      #("secret", json.string(secret)),
    ]
    SessionToken(token, metadata) -> [
      #("kind", json.string("session_token")),
      #("token", json.string(token)),
      #("private_metadata", encode_metadata(metadata)),
    ]
    OAuth(data) -> [
      #("kind", json.string("oauth")),
      #("access_token", json.string(data.credential.access_token)),
      #("refresh_token", json.string(data.credential.refresh_token)),
      #("expires_at_ms", json.int(data.credential.expires_at_ms)),
      #("private_metadata", encode_metadata(data.private_metadata)),
    ]
  }
  fields
}

fn new_record(material: AuthMaterial, gate: RefreshStatus) -> CredentialRecord {
  let generation = crypto.random_url_token()
  let gate_json = case gate {
    Ready -> json.object([#("state", json.string("ready"))])
    Deferred(until) ->
      json.object([
        #("state", json.string("deferred")),
        #("until_ms", json.int(until)),
      ])
    NeedsReauthorization ->
      json.object([#("state", json.string("needs_reauthorization"))])
  }
  let raw =
    json.object([
      #("version", json.int(2)),
      #("generation", json.string(generation)),
      #("refresh_gate", gate_json),
      ..encode_material(material)
    ])
    |> json.to_string
  Record(material, gate, Revision(generation), raw)
}

fn encode_metadata(metadata: List(#(String, String))) -> json.Json {
  json.array(metadata, fn(pair) { json.array([pair.0, pair.1], json.string) })
}

fn decode_metadata() -> decode.Decoder(List(#(String, String))) {
  let pair = {
    use key <- decode.then(decode.at([0], decode.string))
    use value <- decode.then(decode.at([1], decode.string))
    decode.success(#(key, value))
  }
  decode.list(pair)
}

pub fn load(store: Store, key: String) -> Result(AuthMaterial, String) {
  load_record(store, key) |> result.map(record_material)
}

pub fn load_record(
  store: Store,
  key: String,
) -> Result(CredentialRecord, String) {
  use raw <- result.try(storage.read_runtime(store, key))
  let decoder = {
    use version <- decode.field("version", decode.int)
    use material <- decode.then(material_decoder())
    case version {
      1 ->
        decode.success(Record(
          material,
          Ready,
          Revision("legacy:" <> crypto.pkce_challenge(raw)),
          raw,
        ))
      2 -> {
        use generation <- decode.field("generation", decode.string)
        use gate <- decode.field("refresh_gate", gate_decoder())
        case
          string.byte_size(generation) == 43
          && list.all(string.to_graphemes(generation), fn(c) {
            string.contains(
              "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_",
              c,
            )
          })
        {
          True ->
            decode.success(Record(material, gate, Revision(generation), raw))
          False ->
            decode.failure(
              Record(material, gate, Revision(""), raw),
              "runtime generation",
            )
        }
      }
      _ ->
        decode.failure(
          Record(material, Ready, Revision(""), raw),
          "runtime credential version",
        )
    }
  }
  use record <- result.try(
    json.parse(raw, decoder)
    |> result.replace_error("Invalid runtime credential"),
  )
  use _ <- result.try(validate(record.material))
  use _ <- result.try(validate_gate(record.material, record.gate))
  Ok(record)
}

fn material_decoder() -> decode.Decoder(AuthMaterial) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "api_key" -> {
      use secret <- decode.field("secret", decode.string)
      decode.success(ApiKey(secret))
    }
    "session_token" -> {
      use token <- decode.field("token", decode.string)
      use metadata <- decode.field("private_metadata", decode_metadata())
      decode.success(SessionToken(token, metadata))
    }
    "oauth" -> {
      use access <- decode.field("access_token", decode.string)
      use refresh <- decode.field("refresh_token", decode.string)
      use expires <- decode.field("expires_at_ms", decode.int)
      use metadata <- decode.field("private_metadata", decode_metadata())
      decode.success(
        OAuth(OAuthData(auth.Credential(access, refresh, expires), metadata)),
      )
    }
    _ -> decode.failure(ApiKey(""), "runtime credential kind")
  }
}

fn gate_decoder() -> decode.Decoder(RefreshStatus) {
  use state <- decode.field("state", decode.string)
  case state {
    "ready" -> decode.success(Ready)
    "needs_reauthorization" -> decode.success(NeedsReauthorization)
    "deferred" -> {
      use until <- decode.field("until_ms", decode.int)
      decode.success(Deferred(until))
    }
    _ -> decode.failure(Ready, "runtime refresh gate")
  }
}

pub fn valid_timestamp(value: Int) -> Bool {
  value >= 0 && value <= max_timestamp_ms
}

fn validate_gate(
  material: AuthMaterial,
  gate: RefreshStatus,
) -> Result(Nil, String) {
  case material, gate {
    _, Ready -> Ok(Nil)
    OAuth(_), NeedsReauthorization -> Ok(Nil)
    OAuth(_), Deferred(until) if until >= 0 && until <= max_timestamp_ms ->
      Ok(Nil)
    _, _ -> Error("Invalid runtime refresh gate")
  }
}

fn validate(material: AuthMaterial) -> Result(Nil, String) {
  let valid = case material {
    ApiKey(secret) -> secret != "" && string.byte_size(secret) <= 16_384
    SessionToken(token, metadata) ->
      token != ""
      && string.byte_size(token) <= 16_384
      && valid_metadata(metadata)
    OAuth(data) ->
      data.credential.access_token != ""
      && string.byte_size(data.credential.access_token) <= 16_384
      && string.byte_size(data.credential.refresh_token) <= 16_384
      && valid_timestamp(data.credential.expires_at_ms)
      && valid_metadata(data.private_metadata)
  }
  case valid {
    True -> Ok(Nil)
    False -> Error("Invalid runtime credential")
  }
}

fn valid_metadata(metadata: List(#(String, String))) -> Bool {
  list.length(metadata) <= 16
  && list.length(list.unique(list.map(metadata, fn(p) { p.0 })))
  == list.length(metadata)
  && list.all(metadata, fn(p) {
    p.0 != "" && string.byte_size(p.0) <= 128 && string.byte_size(p.1) <= 16_384
  })
}

/// Explicit migration only; missing/deleted runtime records never fall back to
/// stale legacy credentials. Identity metadata must come from the provider.
pub fn import_legacy_oauth(
  store: Store,
  legacy_id: String,
  key: String,
  metadata: List(#(String, String)),
) -> Result(Nil, String) {
  use credential <- result.try(auth.load(store, legacy_id))
  save(store, key, OAuth(OAuthData(credential, metadata)))
}
