/// Entirely synthetic local scenario data. Not captures or measured profiles.
import gleam/bit_array
import mimic/ir

pub const request = "{\"model\":\"gpt-5.5\",\"instructions\":\"Synthetic local exercise only\",\"input\":\"Run synthetic lookup\",\"tools\":[{\"type\":\"function\",\"name\":\"lookup\",\"parameters\":{\"type\":\"object\",\"properties\":{}}}],\"reasoning\":{\"effort\":\"high\",\"summary\":\"auto\"}}"

pub const continuation = "{\"model\":\"gpt-5.5\",\"previous_response_id\":\"resp_synthetic\",\"input\":[{\"type\":\"function_call_output\",\"call_id\":\"call_synthetic\",\"output\":\"synthetic-result\"}]}"

pub const completed = "{\"id\":\"resp_synthetic\",\"object\":\"response\",\"model\":\"gpt-5.5\",\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"id\":\"rs_synthetic\",\"encrypted_content\":\"synthetic-opaque-not-a-signature\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"Synthetic summary\"}]},{\"type\":\"function_call\",\"id\":\"fc_synthetic\",\"call_id\":\"call_synthetic\",\"name\":\"lookup\",\"arguments\":\"{}\",\"status\":\"completed\"}],\"usage\":{\"input_tokens\":12,\"output_tokens\":4,\"total_tokens\":16,\"input_tokens_details\":{\"cached_tokens\":3},\"output_tokens_details\":{\"reasoning_tokens\":2}}}"

pub const compact = "{\"id\":\"cmp_synthetic\",\"object\":\"response.compaction\",\"output\":[{\"type\":\"compaction\",\"id\":\"cmp_item_synthetic\",\"encrypted_content\":\"synthetic-compacted-content\"}],\"usage\":{\"input_tokens\":16,\"output_tokens\":3,\"total_tokens\":19}}"

pub fn sse() -> String {
  "event: response.created\ndata: {\"type\":\"response.created\",\"sequence_number\":0,\"response\":{\"id\":\"resp_synthetic\",\"object\":\"response\",\"model\":\"gpt-5.5\",\"status\":\"in_progress\",\"output\":[]}}\n\n"
  <> "event: response.output_item.added\ndata: {\"type\":\"response.output_item.added\",\"sequence_number\":1,\"output_index\":0,\"item\":{\"type\":\"reasoning\",\"id\":\"rs_synthetic\",\"summary\":[]}}\n\n"
  <> "event: response.output_item.done\ndata: {\"type\":\"response.output_item.done\",\"sequence_number\":2,\"output_index\":0,\"item\":{\"type\":\"reasoning\",\"id\":\"rs_synthetic\",\"encrypted_content\":\"synthetic-opaque-not-a-signature\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"Synthetic summary\"}]}}\n\n"
  <> "event: response.output_item.added\ndata: {\"type\":\"response.output_item.added\",\"sequence_number\":3,\"output_index\":1,\"item\":{\"type\":\"function_call\",\"id\":\"fc_synthetic\",\"call_id\":\"call_synthetic\",\"name\":\"lookup\",\"arguments\":\"\",\"status\":\"in_progress\"}}\n\n"
  <> "event: response.function_call_arguments.delta\ndata: {\"type\":\"response.function_call_arguments.delta\",\"sequence_number\":4,\"output_index\":1,\"item_id\":\"fc_synthetic\",\"delta\":\"{}\"}\n\n"
  <> "event: response.function_call_arguments.done\ndata: {\"type\":\"response.function_call_arguments.done\",\"sequence_number\":5,\"output_index\":1,\"item_id\":\"fc_synthetic\",\"arguments\":\"{}\"}\n\n"
  <> "event: response.output_item.done\ndata: {\"type\":\"response.output_item.done\",\"sequence_number\":6,\"output_index\":1,\"item\":{\"type\":\"function_call\",\"id\":\"fc_synthetic\",\"call_id\":\"call_synthetic\",\"name\":\"lookup\",\"arguments\":\"{}\",\"status\":\"completed\"}}\n\n"
  <> "event: response.completed\ndata: {\"type\":\"response.completed\",\"sequence_number\":7,\"response\":"
  <> completed
  <> "}\n\n"
}

pub fn tokens() -> String {
  let claims =
    ir.Object([
      #(
        "https://api.openai.com/auth",
        ir.Object([
          #("chatgpt_account_id", ir.String("synthetic-chatgpt-account")),
        ]),
      ),
    ])
  let payload =
    ir.stringify(claims)
    |> bit_array.from_string
    |> bit_array.base64_url_encode(False)
  ir.stringify(
    ir.Object([
      #("access_token", ir.String("synthetic-access-not-a-secret")),
      #("refresh_token", ir.String("synthetic-refresh-not-a-secret")),
      #("expires_in", ir.Integer(3600)),
      #("token_type", ir.String("Bearer")),
      #("id_token", ir.String("synthetic." <> payload <> ".not-a-signature")),
    ]),
  )
}
