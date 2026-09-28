import gleam/int
import gleam/string
import gleeunit/should
import mimic/watch
import mimic/workshop

@external(erlang, "mimic_f_test_ffi", "dir")
fn test_dir() -> String

@external(erlang, "mimic_f_test_ffi", "symlink_state")
fn symlink_state(dir: String) -> String

fn run_id(config: watch.Watch, version: String) -> String {
  "watch:"
  <> int.to_string(string.length(config.provider))
  <> ":"
  <> config.provider
  <> ":"
  <> int.to_string(string.length(config.package))
  <> ":"
  <> config.package
  <> ":"
  <> version
}

pub fn debounce_and_durable_queue_test() {
  let dir = test_dir()
  let config =
    watch.Watch("@example/cli", "p", "https://registry.example/p", 7_200_000)
  let assert Ok(_) =
    watch.poll_with(dir, config, 100, fn(_) {
      Ok("{\"dist-tags\":{\"latest\":\"1.0\"}}")
    })
  let assert Error(_) = watch.ready(dir, config, 101)
  let assert Ok(_) =
    watch.poll_with(dir, config, 200, fn(_) {
      Ok("{\"dist-tags\":{\"latest\":\"2.0\"}}")
    })
  let assert Error(_) = watch.ready(dir, config, 7_200_100)
  let assert Ok(pending) = watch.ready(dir, config, 7_200_200)
  pending.version |> should.equal("2.0")
  let assert Ok(run) = watch.enqueue(dir, config, 7_200_200)
  run.kind |> should.equal(workshop.PB)
  let assert Error(_) = watch.ready(dir, config, 7_200_200)
  let assert Error(_) =
    watch.poll_with(dir, config, 7_200_201, fn(_) {
      Ok("{\"dist-tags\":{\"latest\":\"2.0\"}}")
    })
}

pub fn start_ack_restart_recognizes_only_exact_release_test() {
  let dir = test_dir()
  let config = watch.Watch("@example/a", "p", "https://registry.example/a", 1)
  let assert Ok(_) = watch.observe(dir, config, "2.0", 100)
  let id = run_id(config, "2.0")
  let assert Ok(_) =
    workshop.start_with_goal(dir, id, "p", workshop.PB, "watch:@example/a:2.0")
  let assert Ok(run) = watch.enqueue(dir, config, 101)
  run.id |> should.equal(id)
  let assert Error(_) = watch.ready(dir, config, 101)
}

pub fn mismatched_run_id_does_not_ack_test() {
  let dir = test_dir()
  let config = watch.Watch("@example/a", "p", "https://registry.example/a", 1)
  let assert Ok(_) = watch.observe(dir, config, "2.0", 100)
  let id = run_id(config, "2.0")
  let assert Ok(_) = workshop.start(dir, id, "p", workshop.PB)
  let assert Error(_) = watch.enqueue(dir, config, 101)
  let assert Ok(_) = watch.ready(dir, config, 101)
}

pub fn packages_with_same_version_have_distinct_run_ids_test() {
  let first = watch.Watch("@example/a", "p", "https://registry.example/a", 1)
  let second = watch.Watch("@example/b", "p", "https://registry.example/b", 1)
  let assert False = run_id(first, "2.0") == run_id(second, "2.0")
}

pub fn symlinked_watch_state_root_fails_closed_test() {
  let dir = test_dir()
  let config = watch.Watch("@example/a", "p", "https://registry.example/a", 1)
  let assert Ok(_) = watch.observe(dir, config, "1.0", 100)
  let link = symlink_state(dir)
  let assert Error(_) = watch.observe(link, config, "2.0", 200)
  let assert Error(_) = watch.ready(link, config, 200)
}
