import gleam/option.{type Option}

/// Ordered headers intentionally do not use a dictionary.
pub type Header {
  Header(name: String, value: String)
}

/// Unknown fingerprints stay unknown; never infer JA4 from an ALPN label.
pub type Transport {
  Transport(alpn: String, ja4: Option(String))
}

pub type Capture {
  Capture(
    client: String,
    version: String,
    endpoint: String,
    request_kind: String,
    method: String,
    target: String,
    http_version: String,
    headers: List(Header),
    body: String,
    transport: Transport,
  )
}

pub type WireResponse {
  WireResponse(status: Int, headers: List(Header), body: String, ttft_ms: Int)
}
