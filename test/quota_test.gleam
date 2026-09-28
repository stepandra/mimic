import gleam/option.{Some}
import gleeunit
import gleeunit/should
import mimic/auth/storage
import mimic/quota
import mimic/quota/worker
import mimic/types.{Header, WireResponse}

pub fn main() {
  gleeunit.main()
}

@external(erlang, "mimic_auth_test_ffi", "state_directory")
fn test_directory() -> String

pub fn unified_windows_and_persistence_test() {
  let response =
    WireResponse(
      429,
      [
        Header("Anthropic-Ratelimit-Unified-5h-Utilization", "0.92"),
        Header("Anthropic-Ratelimit-Unified-5h-Reset", "2000000000"),
        Header("Anthropic-Ratelimit-Unified-5h-Status", "rejected"),
        Header("Anthropic-Ratelimit-Unified-7d-Utilization", "0.45"),
        Header("Anthropic-Ratelimit-Unified-7d-Status", "allowed_warning"),
        Header("Retry-After", "45"),
      ],
      "",
      0,
    )
  let ledger = quota.observe(quota.empty(), "synthetic", response, 1000)
  quota.cooldown_until(ledger, "synthetic") |> should.equal(2_000_000_000_000)
  let assert Some(entry) = quota.lookup(ledger, "synthetic")
  let assert [five_hour, seven_day, _] = entry.windows
  five_hour.utilization |> should.equal(Some(0.92))
  seven_day.status |> should.equal("allowed_warning")
  let assert Ok(store) = storage.new(test_directory())
  quota.load_or_empty(store) |> should.equal(Ok(quota.empty()))
  quota.save(store, ledger) |> should.equal(Ok(Nil))
  quota.load(store) |> should.equal(Ok(ledger))
  let assert Ok(writer) = worker.start(store, ledger)
  let second =
    WireResponse(
      200,
      [
        Header("Anthropic-Ratelimit-Unified-7d-Status", "allowed"),
      ],
      "",
      0,
    )
  let assert Ok(next) = worker.record(writer, "another-synthetic", second, 2000)
  worker.snapshot(writer) |> should.equal(next)
  quota.load(store) |> should.equal(Ok(next))
}

pub fn http_date_retry_after_and_global_status_test() {
  let response =
    WireResponse(
      200,
      [
        Header("Anthropic-Ratelimit-Unified-Status", "rejected"),
        Header("Retry-After", "Wed, 21 Oct 2015 07:28:00 GMT"),
      ],
      "",
      0,
    )
  quota.observe(quota.empty(), "synthetic", response, 0)
  |> quota.cooldown_until("synthetic")
  |> should.equal(1_445_412_480_000)
}

pub fn rfc3339_reset_test() {
  let response =
    WireResponse(
      200,
      [
        Header("Anthropic-Ratelimit-Unified-7d-Status", "rejected"),
        Header("Anthropic-Ratelimit-Unified-7d-Reset", "2026-09-28T00:00:00Z"),
      ],
      "",
      0,
    )
  quota.observe(quota.empty(), "synthetic", response, 0)
  |> quota.cooldown_until("synthetic")
  |> should.equal(1_790_553_600_000)
}
