import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import gleeunit/should
import mimic/auth
import mimic/auth/runtime as credentials
import mimic/auth/runtime_store as records
import mimic/auth/storage
import mimic/providers/contracts.{ApiKey, OAuth, OAuthData}

// Synthetic grants only. These tests exercise the shared store seam, not OAuth.
@external(erlang, "mimic_auth_test_ffi", "state_directory")
fn directory() -> String

@external(erlang, "mimic_auth_test_ffi", "make_symlink")
fn symlink(target: String, link: String) -> Nil

@external(erlang, "mimic_provider_runtime_test_ffi", "chmod")
fn chmod(path: String, mode: Int) -> Nil

@external(erlang, "mimic_enrollment_test_ffi", "phase")
fn fresh_vm(directory: String, seed: Bool) -> Bool

fn store() -> storage.Store {
  let assert Ok(store) = storage.new(directory())
  store
}

fn key() -> String {
  credentials.key("synthetic-enrollment", "oauth", "account")
}

fn path(store: storage.Store) -> String {
  store.directory
  <> "/runtime-"
  <> bit_array.base64_url_encode(bit_array.from_string(key()), False)
  <> ".json"
}

fn oauth(token: String) -> contracts.AuthMaterial {
  OAuth(
    OAuthData(auth.Credential(token, "synthetic-refresh", 2_000_000), [
      #("identity", "synthetic-private"),
    ]),
  )
}

pub fn first_reservation_is_not_a_credential_and_commit_is_one_shot_test() {
  let store = store()
  storage.read_runtime_slot(store, key()) |> should.equal(Ok(None))
  let assert Ok(ticket) = records.begin_enrollment(store, key())
  records.load(store, key()) |> should.be_error
  records.metadata(store, key()) |> should.be_error
  records.begin_enrollment(store, key()) |> should.be_error
  records.commit_enrollment(ticket, oauth("synthetic-grant")) |> should.be_ok
  records.load(store, key()) |> should.equal(Ok(oauth("synthetic-grant")))
  records.commit_enrollment(ticket, oauth("late-grant")) |> should.be_error
  records.cancel_enrollment(ticket) |> should.be_error
  records.load(store, key()) |> should.equal(Ok(oauth("synthetic-grant")))
}

pub fn two_concurrent_first_begins_have_one_reservation_test() {
  let store = store()
  let replies = process.new_subject()
  list.each([Nil, Nil], fn(_) {
    process.spawn_unlinked(fn() {
      process.send(replies, records.begin_enrollment(store, key()))
    })
  })
  let assert Ok(first) = process.receive(replies, 5000)
  let assert Ok(second) = process.receive(replies, 5000)
  list.count([first, second], result.is_ok) |> should.equal(1)
  let assert Ok(ticket) = case first {
    Ok(_) -> first
    Error(_) -> second
  }
  records.cancel_enrollment(ticket) |> should.be_ok
}

pub fn first_admin_delete_save_and_aba_defeat_late_commit_test() {
  list.each(["delete", "save", "aba"], fn(action) {
    let store = store()
    let assert Ok(ticket) = records.begin_enrollment(store, key())
    case action {
      "delete" -> records.delete(store, key()) |> should.be_ok
      "save" -> records.save(store, key(), oauth("admin-grant")) |> should.be_ok
      _ -> {
        records.save(store, key(), oauth("admin-grant")) |> should.be_ok
        records.delete(store, key()) |> should.be_ok
        records.save(store, key(), oauth("admin-grant")) |> should.be_ok
      }
    }
    records.commit_enrollment(ticket, oauth("late-grant")) |> should.be_error
    records.cancel_enrollment(ticket) |> should.be_error
    case action {
      "delete" ->
        storage.read_runtime_slot(store, key()) |> should.equal(Ok(None))
      _ -> records.load(store, key()) |> should.equal(Ok(oauth("admin-grant")))
    }
  })
}

pub fn first_cancel_and_restart_never_reuse_the_old_reservation_test() {
  let store = store()
  let assert Ok(ticket) = records.begin_enrollment(store, key())
  records.cancel_enrollment(ticket) |> should.be_ok
  storage.read_runtime_slot(store, key()) |> should.equal(Ok(None))
  records.cancel_enrollment(ticket) |> should.be_error
  let assert Ok(restarted) = records.begin_enrollment(store, key())
  records.commit_enrollment(ticket, oauth("late-grant")) |> should.be_error
  records.commit_enrollment(restarted, oauth("new-grant")) |> should.be_ok
}

pub fn existing_admin_mutations_defeat_exact_ticket_test() {
  list.each(["delete", "replace", "same-token", "aba"], fn(action) {
    let store = store()
    records.save(store, key(), oauth("original")) |> should.be_ok
    let assert Ok(ticket) = records.begin_enrollment(store, key())
    case action {
      "delete" -> records.delete(store, key()) |> should.be_ok
      "replace" -> records.save(store, key(), oauth("admin")) |> should.be_ok
      "same-token" ->
        records.save(store, key(), oauth("original")) |> should.be_ok
      _ -> {
        records.delete(store, key()) |> should.be_ok
        records.save(store, key(), oauth("original")) |> should.be_ok
      }
    }
    let before = storage.read_runtime_slot(store, key())
    records.commit_enrollment(ticket, oauth("late-grant")) |> should.be_error
    records.cancel_enrollment(ticket) |> should.be_error
    storage.read_runtime_slot(store, key()) |> should.equal(before)
  })
}

pub fn existing_cancel_preserves_material_and_gate_but_changes_generation_test() {
  list.each(
    [records.Ready, records.Deferred(9_999_999), records.NeedsReauthorization],
    fn(gate) {
      let store = store()
      records.save(store, key(), oauth("original")) |> should.be_ok
      let assert Ok(original) = records.load_record(store, key())
      let assert Ok(before) =
        records.transition(store, key(), original, oauth("original"), gate)
      let assert Ok(ticket) = records.begin_enrollment(store, key())
      records.cancel_enrollment(ticket) |> should.be_ok
      let assert Ok(after) = records.load_record(store, key())
      records.record_material(after)
      |> should.equal(records.record_material(before))
      records.record_status(after) |> should.equal(gate)
      records.revision(after) |> should.not_equal(records.revision(before))
      records.commit_enrollment(ticket, oauth("late-grant")) |> should.be_error
      records.transition(
        store,
        key(),
        before,
        oauth("stale-refresh"),
        records.Ready,
      )
      |> should.be_error
    },
  )
}

pub fn commit_and_cancel_have_one_winner_for_both_slot_kinds_test() {
  list.each([False, True], fn(existing) {
    let store = store()
    case existing {
      True -> records.save(store, key(), oauth("original")) |> should.be_ok
      False -> Nil
    }
    let assert Ok(ticket) = records.begin_enrollment(store, key())
    let replies = process.new_subject()
    process.spawn_unlinked(fn() {
      process.send(replies, #(
        "commit",
        records.commit_enrollment(ticket, oauth("new-grant")),
      ))
    })
    process.spawn_unlinked(fn() {
      process.send(replies, #("cancel", records.cancel_enrollment(ticket)))
    })
    let assert Ok(first) = process.receive(replies, 5000)
    let assert Ok(second) = process.receive(replies, 5000)
    list.count([first.1, second.1], result.is_ok) |> should.equal(1)
    let assert Ok(winner) =
      list.find([first, second], fn(pair) { result.is_ok(pair.1) })
    case winner.0, existing {
      "commit", _ ->
        records.load(store, key()) |> should.equal(Ok(oauth("new-grant")))
      _, True ->
        records.load(store, key()) |> should.equal(Ok(oauth("original")))
      _, False ->
        storage.read_runtime_slot(store, key()) |> should.equal(Ok(None))
    }
  })
}

pub fn corrupt_ambiguous_nonprivate_and_symlink_slots_are_not_missing_test() {
  list.each(
    [
      "not-json",
      "{\"version\":2,\"kind\":\"api_key\",\"secret\":\"synthetic\",\"secret\":\"other\"}",
      "{\"version\":999,\"kind\":\"api_key\",\"secret\":\"synthetic\"}",
    ],
    fn(raw) {
      let store = store()
      storage.write_runtime(store, key(), raw) |> should.be_ok
      records.begin_enrollment(store, key()) |> should.be_error
      storage.read_runtime(store, key()) |> should.equal(Ok(raw))
    },
  )
  list.each([0, 420], fn(mode) {
    let store = store()
    records.save(store, key(), oauth("original")) |> should.be_ok
    chmod(path(store), mode)
    storage.read_runtime_slot(store, key()) |> should.be_error
    records.begin_enrollment(store, key()) |> should.be_error
    chmod(path(store), 384)
    records.load(store, key()) |> should.equal(Ok(oauth("original")))
  })
  let store = store()
  symlink(store.directory <> "/missing-target", path(store))
  storage.read_runtime_slot(store, key()) |> should.be_error
  records.begin_enrollment(store, key()) |> should.be_error
  let assert Ok(store) = storage.new(directory())
  chmod(store.directory, 493)
  storage.read_runtime_slot(store, key()) |> should.be_error
  records.begin_enrollment(store, key()) |> should.be_error
  chmod(store.directory, 448)
}

pub fn invalid_material_does_not_consume_a_ticket_test() {
  let store = store()
  let assert Ok(ticket) = records.begin_enrollment(store, key())
  records.commit_enrollment(ticket, ApiKey("")) |> should.be_error
  records.load(store, key()) |> should.be_error
  records.commit_enrollment(ticket, oauth("valid")) |> should.be_ok
}

pub fn valid_record_with_duplicate_decoded_key_is_not_an_enrollment_snapshot_test() {
  let store = store()
  records.save(store, key(), ApiKey("synthetic")) |> should.be_ok
  let assert Ok(raw) = storage.read_runtime(store, key())
  let ambiguous =
    string.replace(raw, "\"secret\":", "\"\\u0073ecret\":\"other\",\"secret\":")
  storage.write_runtime(store, key(), ambiguous) |> should.be_ok
  records.load_record(store, key()) |> should.be_error
  records.begin_enrollment(store, key()) |> should.be_error
  storage.read_runtime(store, key()) |> should.equal(Ok(ambiguous))
}

pub fn record_budget_accepts_maximum_material_even_with_json_escaping_test() {
  let store = store()
  let escaped = string.repeat("\u{0000}", 16_384)
  let metadata =
    list.repeat(Nil, 16)
    |> list.index_map(fn(_, index) {
      #("key-" <> int.to_string(index), escaped)
    })
  let material =
    OAuth(OAuthData(auth.Credential(escaped, escaped, 1), metadata))
  records.save(store, key(), material) |> should.be_ok
  let assert Ok(ticket) = records.begin_enrollment(store, key())
  records.cancel_enrollment(ticket) |> should.be_ok
  // Never print even synthetic credential material in an assertion failure.
  let assert Ok(restored) = records.load(store, key())
  { restored == material } |> should.be_true
}

pub fn pending_marker_survives_vm_exit_until_explicit_admin_cleanup_test() {
  let directory = directory()
  fresh_vm(directory, True) |> should.be_true
  fresh_vm(directory, False) |> should.be_true
}

pub fn phase(directory: String, seed: Bool) {
  let assert Ok(store) = storage.new(directory)
  case seed {
    True -> {
      let _ = records.begin_enrollment(store, key()) |> should.be_ok
      Nil
    }
    False -> {
      records.load(store, key()) |> should.be_error
      records.begin_enrollment(store, key()) |> should.be_error
      records.delete(store, key()) |> should.be_ok
      let assert Ok(ticket) = records.begin_enrollment(store, key())
      records.cancel_enrollment(ticket) |> should.be_ok
      storage.read_runtime_slot(store, key()) |> should.equal(Ok(None))
    }
  }
}
