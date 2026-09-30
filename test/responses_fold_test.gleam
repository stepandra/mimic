import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import mimic/protocol/responses/http
import mimic/protocol/responses/stream

fn terminal() -> BitArray {
  bit_array.from_string(
    "data: {\"type\":\"response.created\",\"response\":{\"id\":\"synth\",\"object\":\"response\",\"status\":\"in_progress\",\"output\":[]}}\n\n"
    <> "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"synth\",\"object\":\"response\",\"status\":\"completed\",\"output\":[]}}\n\n",
  )
}

pub fn fold_returns_accumulator_only_after_clean_eof_test() {
  let observed = process.new_subject()
  let result =
    http.run_fold(
      stream.new(),
      [terminal()],
      fn(chunks) {
        process.send(observed, "pull")
        case chunks {
          [] -> Ok(None)
          [chunk, ..rest] -> Ok(Some(#(chunk, rest)))
        }
      },
      fn(_) { process.send(observed, "cancel") },
      [],
      fn(acc, event) { Ok(#(list.append(acc, [event.name]), http.Continue)) },
    )
  result
  |> should.equal(
    Ok(#(stream.Completed, ["response.created", "response.completed"])),
  )
  process.receive(observed, 0) |> should.equal(Ok("pull"))
  process.receive(observed, 0) |> should.equal(Ok("pull"))
  process.receive(observed, 0) |> should.equal(Ok("cancel"))
  process.receive(observed, 0) |> should.be_error
}

pub fn later_io_or_protocol_error_never_returns_receipt_state_test() {
  let observed = process.new_subject()
  let result =
    http.run_fold(
      stream.new(),
      False,
      fn(read) {
        case read {
          False -> Ok(Some(#(terminal(), True)))
          True -> Error("synthetic transport failure")
        }
      },
      fn(_) { process.send(observed, "cancel") },
      0,
      fn(acc, _) { Ok(#(acc + 1, http.Continue)) },
    )
  result |> should.equal(Error(http.Upstream("synthetic transport failure")))
  process.receive(observed, 0) |> should.equal(Ok("cancel"))
  process.receive(observed, 0) |> should.be_error

  let result =
    http.run_fold(
      stream.new(),
      [terminal(), <<"data: invalid\n\n":utf8>>],
      fn(chunks) {
        case chunks {
          [] -> Ok(None)
          [chunk, ..rest] -> Ok(Some(#(chunk, rest)))
        }
      },
      fn(_) { Nil },
      0,
      fn(acc, _) { Ok(#(acc + 1, http.Continue)) },
    )
  result |> should.equal(Error(http.Protocol("invalid JSON")))
}

pub fn cancelled_fold_cannot_be_confused_with_completed_test() {
  let result =
    http.run_fold(
      stream.new(),
      Nil,
      fn(_) { Ok(Some(#(terminal(), Nil))) },
      fn(_) { Nil },
      0,
      fn(acc, _) { Ok(#(acc + 1, http.Cancel)) },
    )
  result |> should.equal(Ok(#(stream.Cancelled, 1)))
}
