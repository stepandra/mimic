import gleam/list
import gleam/option.{None}
import gleeunit/should
import mimic/differ
import mimic/types.{type Capture, Capture, Header, Transport}

fn sample() -> Capture {
  Capture(
    client: "synthetic",
    version: "1",
    endpoint: "local",
    request_kind: "messages",
    method: "POST",
    target: "/v1/messages",
    http_version: "HTTP/1.1",
    headers: [
      Header("X-Example", "same"),
      Header("anthropic-beta", "one,two"),
      Header("Content-Type", "application/json"),
      Header("Content-Length", "7"),
    ],
    body: "{\"a\":1}",
    transport: Transport("http/1.1", None),
  )
}

pub fn casing_only_golden_test() {
  let old = sample()
  let updated =
    Capture(..old, headers: [
      Header("x-example", "same"),
      Header("anthropic-beta", "one,two"),
      Header("Content-Type", "application/json"),
      Header("Content-Length", "7"),
    ])
  let report = differ.diff(old, updated) |> should.be_ok
  let differ.Report(changes) = report
  changes
  |> should.equal([differ.Change("headers", "0/case", "X-Example", "x-example")])
}

pub fn beta_order_and_json_shape_test() {
  let old = sample()
  let updated =
    Capture(
      ..old,
      headers: [
        Header("X-Example", "same"),
        Header("anthropic-beta", "two,one"),
        Header("Content-Type", "application/json"),
        Header("Content-Length", "14"),
      ],
      body: "{\"a\":\"value\"}",
    )
  let report = differ.diff(old, updated) |> should.be_ok
  let differ.Report(changes) = report
  let axes =
    list.map(changes, fn(c) {
      let differ.Change(axis, _, _, _) = c
      axis
    })
  axes |> should.equal(["headers", "betas", "json"])
}
