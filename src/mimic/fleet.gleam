import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/uri
import mimic/quota.{type Ledger}

pub type Egress {
  /// Safe local fixture default.
  LocalLoopback
  /// Explicit operator ownership approval. Direct TLS, never a proxy or redirect.
  OperatorHttps
  Proxy(url: String)
  BoundAddress(address: String)
}

pub type Profile {
  Profile(id: String, upstream_url: String, egress: Egress, max_in_flight: Int)
}

pub type Selection {
  Selection(profile: Profile, session_id: String, lease_id: Int)
}

pub type State {
  State(
    profiles: List(Profile),
    sticky: Dict(String, String),
    in_flight: Dict(String, Int),
    leases: Dict(Int, #(String, String)),
    next_lease_id: Int,
    cursor: Int,
  )
}

pub fn new(profiles: List(Profile)) -> Result(State, String) {
  case profiles {
    [] -> Error("Fleet requires at least one profile")
    _ -> {
      case validate_all(profiles, []) {
        Ok(_) -> Ok(State(profiles, dict.new(), dict.new(), dict.new(), 0, 0))
        Error(error) -> Error(error)
      }
    }
  }
}

fn validate_all(
  profiles: List(Profile),
  seen: List(String),
) -> Result(Nil, String) {
  case profiles {
    [] -> Ok(Nil)
    [profile, ..rest] -> {
      case validate(profile) {
        Error(error) -> Error(error)
        Ok(_) ->
          case list.contains(seen, profile.id) {
            True -> Error("Duplicate credential profile id")
            False -> validate_all(rest, [profile.id, ..seen])
          }
      }
    }
  }
}

pub fn validate(profile: Profile) -> Result(Nil, String) {
  case profile.id == "" || profile.max_in_flight <= 0 {
    True -> Error("Profile requires an id and positive concurrency limit")
    False ->
      case profile.egress {
        LocalLoopback ->
          case uri.parse(profile.upstream_url) {
            Ok(uri.Uri(
              scheme: Some("http"),
              host: Some("localhost"),
              userinfo: None,
              ..,
            )) -> Ok(Nil)
            Ok(uri.Uri(
              scheme: Some("http"),
              host: Some("127.0.0.1"),
              userinfo: None,
              ..,
            )) -> Ok(Nil)
            _ ->
              Error(
                "Local egress only supports explicit loopback HTTP upstream",
              )
          }
        OperatorHttps ->
          case uri.parse(profile.upstream_url) {
            Ok(uri.Uri(
              scheme: Some("https"),
              host: Some(host),
              port: port,
              path: path,
              query: None,
              fragment: None,
              userinfo: None,
            ))
              if host != "" && { path == "" || path == "/" }
            ->
              case port {
                None -> Ok(Nil)
                Some(p) if p > 0 && p < 65_536 -> Ok(Nil)
                _ -> Error("Invalid HTTPS upstream port")
              }
            _ ->
              Error("Operator HTTPS egress requires an explicit HTTPS origin")
          }
        Proxy(_) ->
          Error(
            "Proxy egress is unsupported; no proxy binding has been installed",
          )
        BoundAddress(_) ->
          Error(
            "Bound-address egress is unsupported; no bound transport has been installed",
          )
      }
  }
}

/// Acquiring a selection reserves one in-flight slot. Always call release
/// after completion or connection failure. Sticky sessions do not silently
/// switch identities while their credential is cooling or saturated.
pub fn select(
  state: State,
  ledger: Ledger,
  session_id: String,
  now_ms: Int,
) -> Result(#(State, Selection), String) {
  case session_id {
    "" -> Error("Session id must not be empty")
    _ ->
      case dict.get(state.sticky, session_id) {
        Ok(id) ->
          case find_profile(state.profiles, id) {
            Some(profile) -> reserve(state, ledger, profile, session_id, now_ms)
            None -> Error("Sticky profile is not available")
          }
        Error(_) -> {
          let candidates =
            state.profiles
            |> list.filter(fn(profile) {
              available(state, ledger, profile, now_ms)
            })
          case candidates {
            [] -> Error("No available credential profile")
            _ -> {
              let index = state.cursor % list.length(candidates)
              case list.drop(candidates, index) {
                [profile, ..] ->
                  reserve(
                    State(..state, cursor: state.cursor + 1),
                    ledger,
                    profile,
                    session_id,
                    now_ms,
                  )
                [] -> Error("No available credential profile")
              }
            }
          }
        }
      }
  }
}

fn reserve(
  state: State,
  ledger: Ledger,
  profile: Profile,
  session_id: String,
  now_ms: Int,
) -> Result(#(State, Selection), String) {
  case available(state, ledger, profile, now_ms) {
    False -> Error("Sticky credential is cooling or at capacity")
    True -> {
      let count = active(state, profile.id)
      let state =
        State(
          ..state,
          sticky: dict.insert(state.sticky, session_id, profile.id),
          in_flight: dict.insert(state.in_flight, profile.id, count + 1),
          leases: dict.insert(state.leases, state.next_lease_id, #(
            profile.id,
            session_id,
          )),
          next_lease_id: state.next_lease_id + 1,
        )
      Ok(#(state, Selection(profile, session_id, state.next_lease_id - 1)))
    }
  }
}

fn available(
  state: State,
  ledger: Ledger,
  profile: Profile,
  now_ms: Int,
) -> Bool {
  quota.cooldown_until(ledger, profile.id) <= now_ms
  && active(state, profile.id) < profile.max_in_flight
}

fn active(state: State, id: String) -> Int {
  dict.get(state.in_flight, id) |> result_unwrap(0)
}

fn result_unwrap(value: Result(a, e), default: a) -> a {
  case value {
    Ok(v) -> v
    Error(_) -> default
  }
}

fn find_profile(profiles: List(Profile), id: String) -> Option(Profile) {
  case list.find(profiles, fn(profile) { profile.id == id }) {
    Ok(profile) -> Some(profile)
    Error(_) -> None
  }
}

pub fn release(state: State, selection: Selection) -> State {
  let id = selection.profile.id
  case dict.get(state.leases, selection.lease_id) {
    Ok(#(lease_id, session_id))
      if lease_id == id && session_id == selection.session_id
    ->
      State(
        ..state,
        leases: dict.delete(state.leases, selection.lease_id),
        in_flight: dict.insert(
          state.in_flight,
          id,
          max(0, active(state, id) - 1),
        ),
      )
    _ -> state
  }
}

pub fn end_session(state: State, session_id: String) -> State {
  let has_active_lease =
    state.leases
    |> dict.values
    |> list.any(fn(lease) { lease.1 == session_id })
  case has_active_lease {
    True -> state
    False -> State(..state, sticky: dict.delete(state.sticky, session_id))
  }
}

/// Restrict selection to a provider/model's eligible accounts. A cooling sticky
/// account may be replaced only after all its session leases are released.
pub fn select_eligible(
  state: State,
  ledger: Ledger,
  session_id: String,
  eligible: List(String),
  now_ms: Int,
) -> Result(#(State, Selection), String) {
  let profiles =
    list.filter(state.profiles, fn(p) {
      list.contains(eligible, p.id) && available(state, ledger, p, now_ms)
    })
  let state = case dict.get(state.sticky, session_id) {
    Ok(id) ->
      case list.any(profiles, fn(p) { p.id == id }) {
        True -> state
        False -> end_session(state, session_id)
      }
    Error(_) -> state
  }
  case select(State(..state, profiles: profiles), ledger, session_id, now_ms) {
    Ok(#(next, selection)) ->
      Ok(#(State(..next, profiles: state.profiles), selection))
    Error(error) -> Error(error)
  }
}

fn max(a: Int, b: Int) -> Int {
  case a > b {
    True -> a
    False -> b
  }
}

pub type Message {
  Acquire(
    ledger: Ledger,
    session_id: String,
    now_ms: Int,
    reply: process.Subject(Result(Selection, String)),
  )
  Release(Selection)
  EndSession(String)
}

pub type Pool {
  Pool(subject: process.Subject(Message))
}

/// Pool actor owns sticky mappings and slot accounting. It does not pretend
/// to own sockets: only the loopback transport is currently supported.
pub fn start_pool(state: State) -> Result(Pool, String) {
  case actor.new(state) |> actor.on_message(handle) |> actor.start {
    Ok(started) -> Ok(Pool(started.data))
    Error(_) -> Error("Unable to start fleet pool")
  }
}

pub fn acquire(
  pool: Pool,
  ledger: Ledger,
  session_id: String,
  now_ms: Int,
) -> Result(Selection, String) {
  actor.call(pool.subject, waiting: 5000, sending: fn(reply) {
    Acquire(ledger, session_id, now_ms, reply)
  })
}

pub fn release_slot(pool: Pool, selection: Selection) -> Nil {
  actor.send(pool.subject, Release(selection))
}

pub fn forget_session(pool: Pool, session_id: String) -> Nil {
  actor.send(pool.subject, EndSession(session_id))
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Acquire(ledger, session_id, now_ms, reply) ->
      case select(state, ledger, session_id, now_ms) {
        Ok(#(next, selection)) -> {
          process.send(reply, Ok(selection))
          actor.continue(next)
        }
        Error(error) -> {
          process.send(reply, Error(error))
          actor.continue(state)
        }
      }
    Release(selection) -> actor.continue(release(state, selection))
    EndSession(session_id) -> actor.continue(end_session(state, session_id))
  }
}

pub fn cli(args: List(String)) -> Result(String, String) {
  case args {
    ["status"] ->
      Ok(
        "fleet status requires operator-configured profiles; no upstream pool is configured",
      )
    ["quotas"] -> Ok("fleet quotas requires an explicit state directory")
    _ -> Error("Usage: mimic fleet status|quotas")
  }
}
