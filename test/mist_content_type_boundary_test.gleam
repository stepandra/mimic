/// Synthetic raw HTTP controls: Content-Type is one media type, not a list.
/// The shared malformed-head policy is peer closure with zero route dispatch,
/// not a route-level HTTP 400 that canonicalization can bypass.
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/response
import gleam/list
import gleam/string
import gleeunit/should
import mist

@external(erlang, "mimic_mist_chunk_cancellation_test_ffi", "run_headers")
pub fn main() -> Nil

@external(erlang, "mimic_mist_chunk_cancellation_test_ffi", "with_cleanup")
fn with_cleanup(work: fn() -> Nil, cleanup: fn() -> Nil) -> Nil

@external(erlang, "mimic_mist_chunk_cancellation_test_ffi", "stop_server")
fn stop_server(pid: process.Pid) -> Nil

@external(erlang, "mimic_mist_chunk_cancellation_test_ffi", "raw_exchange")
fn raw_exchange(port: Int, parts: List(String)) -> Result(String, String)

type Server {
  Server(port: Int, dispatched: process.Subject(Nil))
}

fn with_server(work: fn(Server) -> Nil) -> Nil {
  let ready = process.new_subject()
  let dispatched = process.new_subject()
  let assert Ok(server) =
    mist.new(fn(req) {
      process.send(dispatched, Nil)
      let assert Ok(_) = mist.read_body(req, 4096)
      response.new(200)
      |> response.set_header("connection", "close")
      |> response.set_body(
        mist.Bytes(bytes_tree.from_string("synthetic accepted")),
      )
    })
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _, _) { process.send(ready, port) })
    |> mist.start
  process.unlink(server.pid)
  let assert Ok(port) = process.receive(ready, 1000)
  with_cleanup(fn() { work(Server(port, dispatched)) }, fn() {
    stop_server(server.pid)
  })
}

const head = "POST /synthetic HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n"

fn rejected(server: Server, parts: List(String)) -> Nil {
  raw_exchange(server.port, parts) |> should.equal(Ok(""))
  process.receive(server.dispatched, 0) |> should.equal(Error(Nil))
}

pub fn conflicting_content_type_duplicates_both_orders_and_case_test() {
  with_server(fn(server) {
    list.each(
      [
        ["Content-Type: application/json\r\n", "cOnTeNt-TyPe: text/plain\r\n"],
        ["cOnTeNt-TyPe: text/plain\r\n", "Content-Type: application/json\r\n"],
      ],
      fn(fields) {
        rejected(server, [head <> string.concat(fields) <> "\r\n{}"])
      },
    )
  })
}

pub fn identical_content_type_duplicates_are_not_canonicalized_test() {
  with_server(fn(server) {
    rejected(server, [
      head
      <> "Content-Type: application/json\r\nCONTENT-TYPE: application/json\r\n\r\n{}",
    ])
  })
}

pub fn fragmented_content_type_duplicate_is_rejected_before_dispatch_test() {
  with_server(fn(server) {
    rejected(server, [
      head <> "Content-Type: application/json\r\ncont",
      "ent-type: text/plain\r\n\r\n{}",
    ])
  })
}

pub fn single_mixed_case_content_type_remains_supported_test() {
  with_server(fn(server) {
    let assert Ok(reply) =
      raw_exchange(server.port, [
        head <> "cOnTeNt-TyPe:\tapplication/json \t\r\n\r\n{}",
      ])
    string.contains(reply, " 200 ") |> should.be_true
    string.ends_with(reply, "synthetic accepted") |> should.be_true
    process.receive(server.dispatched, 0) |> should.equal(Ok(Nil))
    process.receive(server.dispatched, 0) |> should.equal(Error(Nil))
  })
}

pub fn repeatable_accept_fields_still_dispatch_once_test() {
  with_server(fn(server) {
    let assert Ok(reply) =
      raw_exchange(server.port, [
        head
        <> "Content-Type: application/json\r\nAccept: application/json\r\naccept: text/plain\r\n\r\n{}",
      ])
    string.contains(reply, " 200 ") |> should.be_true
    process.receive(server.dispatched, 0) |> should.equal(Ok(Nil))
    process.receive(server.dispatched, 0) |> should.equal(Error(Nil))
  })
}
