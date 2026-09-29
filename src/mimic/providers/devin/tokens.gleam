/// CPA CountTokens uses request byte length / 4, not a native tokenizer call.
import gleam/string

pub type Estimate {
  Estimate(input_tokens: Int, payload_bytes: Int)
}

pub fn estimate(payload: String) -> Estimate {
  let bytes = string.byte_size(payload)
  Estimate(bytes / 4, bytes)
}

pub fn exact_native_count(_payload: String) -> Result(Int, String) {
  Error("Devin exact native token counting is unsupported")
}
