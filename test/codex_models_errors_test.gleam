import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import mimic/ir
import mimic/providers/codex/errors
import mimic/providers/codex/models
import mimic/types.{Header}

pub fn codex_catalog_source_and_runtime_capability_intersection_test() {
  let catalog = models.pinned()
  catalog.source |> should.equal(models.PinnedCpa)
  let assert Ok(model) = models.lookup(catalog, "gpt-5.5")
  model.reasoning_efforts |> should.equal(["low", "medium", "high", "xhigh"])
  model.context_window |> should.equal(272_000)
  model.input_modalities |> should.equal(["text", "image"])
  models.lookup(catalog, "gpt-made-up") |> should.be_error
  let empty = models.available(catalog, [], False, False)
  ir.field(empty, "models") |> should.equal(Some(ir.Array([])))
  let available =
    models.available(
      catalog,
      ["gpt-5.5", "gpt-6-astra", "gpt-made-up"],
      False,
      False,
    )
  let assert Some(ir.Array([entry])) = ir.field(available, "models")
  ir.field(entry, "slug") |> should.equal(Some(ir.String("gpt-5.5")))
  ir.field(entry, "prefer_websockets") |> should.equal(Some(ir.Boolean(False)))
  let assert Ok(decoded) =
    models.decode(ir.stringify(available), models.OperatorSupplied)
  list.length(decoded.models) |> should.equal(1)
}

pub fn codex_unknown_catalog_fields_preserved_and_duplicate_slugs_rejected_test() {
  let fixture =
    "{\"slug\":\"synthetic-model\",\"context_window\":4096,\"default_reasoning_level\":\"low\",\"supported_reasoning_levels\":[{\"effort\":\"low\"}],\"input_modalities\":[\"text\"],\"synthetic_extension\":{\"keep\":true}}"
  let assert Ok(catalog) =
    models.decode("{\"models\":[" <> fixture <> "]}", models.Synthetic)
  let assert Ok(model) = models.lookup(catalog, "synthetic-model")
  ir.field(model.raw, "synthetic_extension") |> should.not_equal(None)
  model.prefers_websocket |> should.be_false
  models.decode(
    "{\"models\":[" <> fixture <> "," <> fixture <> "]}",
    models.Synthetic,
  )
  |> should.be_error
  models.decode(
    "{\"models\":[{\"slug\":\"gpt-prefix-is-not-metadata\"}]}",
    models.Synthetic,
  )
  |> should.be_error
}

pub fn codex_quota_reset_layouts_and_units_test() {
  let now = 1_700_000_000_000
  let absolute =
    "{\"type\":\" USAGE_LIMIT_REACHED \",\"resets_at\":1700000300,\"resets_in_seconds\":1}"
  list.each([absolute, "{\"error\":" <> absolute <> "}"], fn(body) {
    let error = errors.classify(400, [], body, now)
    error.category |> should.equal(errors.AccountQuota)
    error.retry_after_ms |> should.equal(Some(300_000))
  })
  let expired =
    errors.classify(
      429,
      [],
      "{\"error\":{\"type\":\"usage_limit_reached\",\"resets_at\":1699999940,\"resets_in_seconds\":77}}",
      now,
    )
  expired.retry_after_ms |> should.equal(Some(77_000))
  let transient =
    errors.classify(
      429,
      [],
      "{\"error\":{\"type\":\"rate_limit_error\",\"resets_in_seconds\":30}}",
      now,
    )
  transient.category |> should.equal(errors.RateLimit)
  transient.retry_after_ms |> should.equal(None)
}

pub fn codex_safe_retry_before_output_only_test() {
  let quota =
    errors.classify(
      429,
      [Header("Retry-After", "7")],
      "{\"error\":{\"type\":\"rate_limit_error\"}}",
      0,
    )
  quota.retry_after_ms |> should.equal(Some(7000))
  errors.permits_retry(quota, False, False) |> should.be_true
  errors.permits_retry(quota, True, False) |> should.be_false
  errors.permits_retry(quota, False, True) |> should.be_false
  let uncertain =
    errors.classify(
      503,
      [],
      "{\"error\":{\"message\":\"model is at capacity\"}}",
      0,
    )
  errors.permits_retry(uncertain, False, False) |> should.be_false
  let terminal =
    errors.classify(
      200,
      [],
      "{\"error\":{\"type\":\"usage_limit_reached\"}}",
      0,
    )
  errors.permits_retry(terminal, False, False) |> should.be_false
}

pub fn codex_retry_after_http_dates_test() {
  let headers = [Header("Retry-After", "Wed, 21 Oct 2015 07:28:00 GMT")]
  errors.classify(429, headers, "{}", 1_445_412_470_000).retry_after_ms
  |> should.equal(Some(10_000))
  errors.classify(429, headers, "{}", 1_445_412_500_000).retry_after_ms
  |> should.equal(Some(0))
  errors.classify(429, [Header("Retry-After", "invalid")], "{}", 0).retry_after_ms
  |> should.equal(None)
  errors.classify(429, list.append(headers, headers), "{}", 0).retry_after_ms
  |> should.equal(None)
}

pub fn codex_pinned_visibility_is_source_data_test() {
  list.each(models.pinned().models, fn(model) {
    let expected = case model.slug {
      "gpt-reserve" | "codex-auto-review" -> "hide"
      _ -> "list"
    }
    ir.field(model.raw, "visibility") |> should.equal(Some(ir.String(expected)))
  })
}

pub fn codex_provider_failure_taxonomy_test() {
  list.each(
    [
      #(401, "{}", errors.Authentication),
      #(413, "{}", errors.ContextTooLarge),
      #(
        400,
        "{\"error\":{\"code\":\"invalid_encrypted_content\"}}",
        errors.InvalidReasoning,
      ),
      #(
        400,
        "{\"error\":{\"message\":\"Invalid signature in thinking block\"}}",
        errors.InvalidReasoning,
      ),
      #(
        400,
        "{\"error\":{\"code\":\"previous_response_not_found\"}}",
        errors.MissingContinuation,
      ),
      #(
        400,
        "{\"error\":{\"message\":\"Selected model is at capacity. Please try a different model.\"}}",
        errors.ModelCapacity,
      ),
      #(500, "not-json", errors.Unavailable),
      #(
        400,
        "{\"error\":{\"message\":\"arbitrary secret must not escape\"}}",
        errors.InvalidRequest,
      ),
    ],
    fn(case_) {
      errors.classify(case_.0, [], case_.1, 0).category |> should.equal(case_.2)
    },
  )
}
