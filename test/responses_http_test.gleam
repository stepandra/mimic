import gleam/bit_array
import gleam/erlang/process
import gleam/option.{Some}
import gleeunit/should
import mimic/protocol/responses/http
import mimic/protocol/responses/stream
import mimic/types.{Header}
import responses_scenario

pub fn actual_http_sse_delivered_before_terminal_and_closed_test() {
  responses_scenario.exercise(responses_scenario.Complete)
  |> should.equal(["response.created", "response.completed"])
}

pub fn actual_http_incomplete_not_success_test() {
  responses_scenario.exercise(responses_scenario.Incomplete)
  |> should.equal(["response.created", "response.incomplete"])
}

pub fn actual_http_remote_error_not_success_test() {
  responses_scenario.exercise(responses_scenario.RemoteError)
  |> should.equal(["response.created", "error"])
}

pub fn actual_http_early_disconnect_fails_test() {
  responses_scenario.exercise(responses_scenario.Disconnect)
  |> should.equal(["response.created"])
}

pub fn actual_http_cancellation_closes_upstream_test() {
  responses_scenario.exercise(responses_scenario.Cancel)
  |> should.equal(["response.created"])
}

pub fn actual_http_downstream_failure_closes_upstream_test() {
  responses_scenario.exercise(responses_scenario.DownstreamFailure)
  |> should.equal(["response.created"])
}

pub fn http_validates_status_content_type_and_encoding_before_stream_test() {
  http.open_sse(401, [Header("Content-Type", "text/event-stream")])
  |> should.be_error
  http.open_sse(200, []) |> should.be_error
  http.open_sse(200, [Header("Content-Type", "application/json")])
  |> should.be_error
  http.open_sse(200, [
    Header("Content-Type", "text/event-stream"),
    Header("content-type", "text/event-stream"),
  ])
  |> should.be_error
  http.open_sse(200, [
    Header("Content-Type", "text/event-stream"),
    Header("Content-Encoding", "gzip"),
  ])
  |> should.be_error
  http.open_sse(200, [
    Header("Content-Type", "text/event-stream; charset=utf-8"),
  ])
  |> should.be_ok
}

pub fn pump_emits_valid_prefix_once_then_cancels_without_another_pull_test() {
  let observed = process.new_subject()
  let bytes =
    bit_array.from_string(
      "data: {\"type\":\"response.created\",\"response\":{\"id\":\"r\",\"object\":\"response\",\"status\":\"in_progress\",\"output\":[]}}\n\ndata: {\"type\":\n\n",
    )
  let result =
    http.run(
      stream.new(),
      False,
      fn(already_read) {
        already_read |> should.be_false
        process.send(observed, "pull")
        Ok(Some(#(bytes, True)))
      },
      fn(current) {
        current |> should.be_true
        process.send(observed, "cancel")
      },
      fn(event) {
        process.send(observed, event.name)
        Ok(http.Continue)
      },
    )
  result |> should.equal(Error(http.Protocol("invalid JSON")))
  process.receive(observed, 0) |> should.equal(Ok("pull"))
  process.receive(observed, 0) |> should.equal(Ok("response.created"))
  process.receive(observed, 0) |> should.equal(Ok("cancel"))
  process.receive(observed, 0) |> should.be_error
}
