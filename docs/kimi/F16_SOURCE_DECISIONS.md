# F16 historical source decisions — compiling API, admission pending

**Recovered historical source memo.** Packet revision:
`d6f307a72a395a137126016362297884e1061a8a`. The original bytes/hash were
verified before this provenance note was added. The prior base, missing-F01
observation and validation attempts below are historical, not claims about the
current checkout. The pinned source inventory, excerpts and deliberate fidelity
differences are retained unchanged. Current attached-root evidence is in
[F16_ADMISSION.md](F16_ADMISSION.md); no new CPA/reference qualification follows
from recovery or synthetic validation.

Base: `47d9c7cb607ad49cfbe65ddf962c432def3f6a02` (F14 library over F15).
Only F16. Historical public source pin:
`acdace936fa7df2905500c7f5e0a97d683138dea`.

**F01's hash-bound source map is missing.** This independently inspected,
hash-bound historical source does not qualify the current pin, port 8317,
Foundation drift freeze or a reference runtime. No CPA execution, differential
comparison, live provider, real credential or native-client claim is made.

## Compiled API and rule

```gleam
// mimic/providers/kimi/schema
normalize(parameters: ir.Value) -> Result(ir.Value, String)
normalize_bounded(
  parameters: ir.Value, depth: Int, nodes: Int, bytes: Int,
) -> Result(ir.Value, String)
// Fixed ceilings: depth 64, 16_384 JSON values, 262_144 UTF-8 JSON bytes.
// normalize_bounded may tighten, but not raise, these ceilings.

// Existing mimic/providers/kimi/transform API is unchanged.
request(body: String, model: String, protocol: String, streaming: Bool)
  -> Result(String, String)
```

Initial format/build passed using `mise exec gleam@1.18.1`, after two retained
failed attempts (reserved `opaque` identifier, then unavailable `list.at` and
missing recursive tuple annotation). Focused tests and actual root workflows
are not claimed by this early memo.

There is one schema normalizer and one temperature validator for **both Chat
and Responses**. Their native tool envelopes differ; their schema rule does
not. Generic Kimi, model registration, response adapters, Messages delegation,
F14 streaming and F15 are not changed.

## Source reproduced vs deliberate fidelity differences

| Area | Historical source | F16 |
| --- | --- | --- |
| Schema invocation | Chat 159/296, Responses 426/537 call `normalizeKimiTools` | Same shared native rule on both routes |
| Local refs | Original-document JSON Pointer resolution; independent expansion; sibling keywords override target | Reproduced for bounded object-schema targets in schema positions |
| Root schema | Inline, strip root `$defs`/`definitions`, add missing `"type":"object"` | Reproduced; non-object roots denied rather than advertised as usable tools |
| Source traversal | `resolveLocalRefs` visits every object/array, including opaque defaults/vendor data | **Deliberate difference:** reference semantics only in schema-defined positions; opaque values preserved |
| Cycles | Source replaces cycle with type/nullable/description hint, potentially losing constraints | **Loss-error difference:** cycles, dangling/external/anchor refs, non-object or non-schema targets denied; no fabricated hints |
| Limits | Source helper has no explicit expansion budget | **Safety difference:** depth/node/byte work ceilings, including unused definitions and overridden expansions; final schema checked again; normalized request at most 1 MiB |
| Schema scope | Source helper resolves `#/...` against original JSON | `$id`, `$dynamicRef`, `$recursiveRef` at schema positions denied; no new base, dynamic/recursive scope, URI decoding, network or filesystem resolver |
| Temperature | Both native executors invoke 1272–1289; absent or 1 unless top-level `thinking.type` is disabled, then 0.6; other values dropped | Accepted values preserved. **Loss-error difference:** wrong value/type denied, never silently removed. Responses `reasoning.effort:none` is not a native `thinking.type:disabled` control |
| Thinking | Chat targets Kimi applier; Responses explicitly targets Codex applier via `toFormat`, while registry lookup uses provider key `"kimi"` | Existing native Chat effort mapping and Responses `reasoning` envelope retained; known levels validated against existing catalog |
| Unsupported thinking intent | Source supports suffix parsing, clamping, budget conversion, strips unsupported controls | **Loss-error difference:** unsupported levels, budgets, simultaneous controls and unregistered/suffixed aliases denied; no catalog invention |
| Chat history | 673–939 drops empty assistant messages, copies previous reasoning/content or invents `"[reasoning unavailable]"`, aliases/infer result IDs | **Deliberate difference:** preserve admitted history; require explicit matching IDs and reasoning for tool calls unless thinking disabled. Never invent/copy reasoning, infer IDs or drop user content |
| Responses history | Native document is cloned, not projected through Chat | Preserve explicit reasoning summaries/encrypted strings, IDs and raw argument strings; existing shared pairing/media validation stays authoritative |
| Messages | Source delegates to Claude executor (98–116/232+) | Existing signed/redacted thinking and explicit tool IDs preserved; no application of Chat schema helpers to native `input_schema`; F14 request mode/streaming untouched |
| State | Compact explicitly denied (395–396/506–507) | Compact, `previous_response_id`, conversation handles and implicit thinking replay remain denied; opaque continuation needs independent evidence |
| Media | Model metadata is not upstream acceptance evidence | Existing supported image forms preserved without fetching; unknown/audio/video/file content denied at protocol positions before transport. No arbitrary argument/schema-vendor media scan |

Schema positions: `properties`, `patternProperties`, `dependentSchemas`,
`$defs`, `definitions`, schema-valued `dependencies`; `items` (single or
legacy tuple), `prefixItems`, `allOf`, `anyOf`, `oneOf`; `additionalProperties`,
`unevaluatedProperties`, `propertyNames`, `contains`, `not`, `if`, `then`,
`else`, `additionalItems`, `unevaluatedItems`, `contentSchema`. Boolean
schemas are preserved directly but are not supported reference targets.
Property-dependency string arrays are preserved.

`default`, `enum`, `const`, `examples`, unknown keywords and extension objects
are opaque. They are counted only for resource ceilings; no key inside them
has reference/model/media semantics. Percent-containing URI fragments and
noncanonical array indices are explicitly outside the supported pointer subset.
Only root definition containers are stripped, matching the historical Kimi
normalizer; nested definition containers remain.

This supersedes native-v2's source summary that Responses tools/temperature
were not normalized. That summary and the former source comment were inaccurate:
both buffered and streamed Responses call the helpers. Fidelity differences
in this table are **not normalization parity** and not measured acceptance.

## Immutable source inventory

Every downloaded Go/JSON source file is listed, including dependency lookups
that did not supply implementation evidence. Raw URL for each path:
`https://raw.githubusercontent.com/router-for-me/CLIProxyAPI/acdace936fa7df2905500c7f5e0a97d683138dea/<path>`.
No repository clone, credential scan or current-branch fetch was used.

```text
73286d375d8341b273d17de45aaa2e20e0790f9f30353b1d1e8eeb955d0e068b  internal/runtime/executor/kimi_executor.go
ff61bd530ad229b3ef03a300a47994e2ec89f4a404d656d27d0c485150e3c52c  internal/runtime/executor/helps/kimi_responses.go
2e672f03143493bd6b9aa1468af98da9bcd550a8f85a5ec9856b0b3946888a03  internal/thinking/provider/kimi/apply.go
3efff25d86e6bba951560bd16049c9af8923912b46bcd5ae6db27c56e4e37b87  internal/registry/models/models.json
09a3091cfbfb2af9318fbf97cc7b0d74e39bea41b6173f1ae9ae63489bb6f7d3  internal/runtime/executor/kimi_executor_test.go
67b06ec76652ab71e372488b2d5d38963d0d61ad14ea76c887c5d1468a715253  internal/util/gemini_schema.go
d6f171bb2eb4c677c50f52734767faec4016ad37c8076cd21caf5c013f2fd96f  internal/runtime/executor/helps/thinking.go
ec2e5f64228039074e0f669f564e72825d00ff23c386de8bcfbbb2042e3f53ec  internal/runtime/executor/helps/model_capabilities.go
ceceb5282def5a594ee9b274c0d3fdcc591f1819ca2797d4c1325de9c5fede72  internal/thinking/apply.go
793ee27e32497a0039de1cc737a969cad0895eb125a1fe66e498197c6cc24a21  internal/thinking/provider/codex/apply.go
c6e629a7a81c9dcd65f6e7b41f861e1dd0995a83a90b4cd5efb738c1651cee53  internal/runtime/executor/helps/payload_helpers.go
1788786834db9cbc2b53b196c16c28beb15b3277b1dba483b51c25bc5b40124d  internal/runtime/executor/helps/payload_mutations.go
ee94b2a27e74974f772bde36b1fa9748a8187415f977ff913a9b74b39474a8d2  internal/runtime/executor/helps/plugin_executor_usage.go
2b08788a75393a1a5ffc730459a32a84c5f81fb6d87a14ef6e9e81eb3dea470e  internal/runtime/executor/helps/thinking_providers.go
```

The last four files were lookup-only, not normalization evidence. Immutable
GitHub API directory listings located the called helper and thinking entrypoint:
`internal/runtime/executor/helps` SHA-256
`eabaed3aabfbdc543fe61790d34675b2ad770f6d6260a7f54faab0c6944b2970`;
`internal/thinking` SHA-256
`cf6be91f58c9f374255f0d37d05952e084dbddcbef3232ffaab33829e3be83ae`.
The immutable util directory page identified `gemini_schema.go`.
One helps HTML fetch exceeded the fetch tool's 512 KiB limit; the bounded
directory API lookup and all necessary immutable raw fetches succeeded.

## Verbatim source excerpts

`internal/runtime/executor/kimi_executor.go:394-396`

```go
func (e *KimiExecutor) executeResponses(ctx context.Context, auth *cliproxyauth.Auth, req cliproxyexecutor.Request, opts cliproxyexecutor.Options) (resp cliproxyexecutor.Response, err error) {
	if opts.Alt == "responses/compact" {
		return resp, statusErr{code: http.StatusNotImplemented, msg: "/responses/compact not supported"}
```

`internal/runtime/executor/kimi_executor.go:415-427`

```go
	body = helps.SetBoolIfDifferent(body, "stream", false)

	var errThinking error
	body, errThinking = helps.ApplyRequestThinking(body, req, opts, opts.SourceFormat.String(), sdktranslator.FormatCodex.String(), e.Identifier())
	if errThinking != nil {
		return resp, errThinking
	}

	requestedModel := helps.PayloadRequestedModel(opts, req.Model)
	requestPath := helps.PayloadRequestPath(opts)
	body = helps.ApplyPayloadConfigWithRequest(e.cfg, baseModel, "openai-response", opts.SourceFormat.String(), "", body, req.Payload, requestedModel, requestPath, opts.Headers)
	body = normalizeKimiTools(body)
	body = normalizeKimiTemperature(body)
```

`internal/runtime/executor/kimi_executor.go:505-507`

```go
func (e *KimiExecutor) executeResponsesStream(ctx context.Context, auth *cliproxyauth.Auth, req cliproxyexecutor.Request, opts cliproxyexecutor.Options) (_ *cliproxyexecutor.StreamResult, err error) {
	if opts.Alt == "responses/compact" {
		return nil, statusErr{code: http.StatusBadRequest, msg: "streaming not supported for /responses/compact"}
```

`internal/runtime/executor/kimi_executor.go:535-538`

```go
	requestPath := helps.PayloadRequestPath(opts)
	body = helps.ApplyPayloadConfigWithRequest(e.cfg, baseModel, "openai-response", opts.SourceFormat.String(), "", body, req.Payload, requestedModel, requestPath, opts.Headers)
	body = normalizeKimiTools(body)
	body = normalizeKimiTemperature(body)
```

`internal/runtime/executor/kimi_executor.go:1244-1264`

```go
func normalizeKimiParametersSchema(paramsRaw string) string {
	if strings.TrimSpace(paramsRaw) == "" {
		return paramsRaw
	}

	inlined := util.InlineLocalRefs(paramsRaw)
	paramBytes := []byte(inlined)

	if inlinedDefs := gjson.GetBytes(paramBytes, "$defs"); inlinedDefs.Exists() {
		paramBytes, _ = sjson.DeleteBytes(paramBytes, "$defs")
	}
	if inlinedDefinitions := gjson.GetBytes(paramBytes, "definitions"); inlinedDefinitions.Exists() {
		paramBytes, _ = sjson.DeleteBytes(paramBytes, "definitions")
	}

	if rootType := gjson.GetBytes(paramBytes, "type"); !rootType.Exists() {
		paramBytes, _ = sjson.SetBytes(paramBytes, "type", "object")
	}

	return string(paramBytes)
}
```

`internal/util/gemini_schema.go:726-749`

```go
	case map[string]any:
		ref, hasRef := node["$ref"].(string)
		if hasRef && strings.HasPrefix(ref, "#/") {
			if target, ok := resolveJSONPointer(root, ref); ok {
				if active[ref] {
					return cyclicRefFallback(node, target, ref)
				}
				active[ref] = true
				resolvedTarget := resolveLocalRefs(root, target, active)
				delete(active, ref)
				if targetMap, okTarget := resolvedTarget.(map[string]any); okTarget {
					out := make(map[string]any, len(targetMap)+len(node))
					for key, item := range targetMap {
						out[key] = item
					}
					for key, item := range node {
						if key == "$ref" {
							continue
						}
						out[key] = resolveLocalRefs(root, item, active)
					}
					return out
				}
			}
```

`internal/util/gemini_schema.go:786-808`

```go
func cyclicRefFallback(node map[string]any, target any, ref string) map[string]any {
	out := make(map[string]any, len(node)+2)
	if targetMap, ok := target.(map[string]any); ok {
		for _, key := range []string{"type", "nullable", "description"} {
			if value, exists := targetMap[key]; exists {
				out[key] = value
			}
		}
	}
	for key, value := range node {
		if key != "$ref" {
			out[key] = value
		}
	}
	name := refName(ref)
	hint := "See: " + name
	if description, _ := out["description"].(string); description != "" {
		out["description"] = mergeHint(description, hint)
	} else {
		out["description"] = hint
	}
	return out
}
```

`internal/runtime/executor/kimi_executor.go:1272-1289`

```go
func normalizeKimiTemperature(body []byte) []byte {
	tempRes := gjson.GetBytes(body, "temperature")
	if !tempRes.Exists() {
		return body
	}
	thinkingType := gjson.GetBytes(body, "thinking.type").String()
	if strings.EqualFold(thinkingType, "disabled") {
		if tempRes.Float() != 0.6 {
			body, _ = sjson.DeleteBytes(body, "temperature")
		}
		return body
	}
	// Default / enabled thinking requires temperature 1.0.
	if tempRes.Float() != 1.0 {
		body, _ = sjson.DeleteBytes(body, "temperature")
	}
	return body
}
```

Thinking path qualification: `helps/model_capabilities.go:18-31` passes both
`toFormat` and provider through; `internal/thinking/apply.go:207-228,250-252`
selects the applier using `toFormat`, while provider key chooses registry
metadata. `provider/kimi/apply.go:59-171` writes native `thinking` for Chat;
`provider/codex/apply.go:46-90` preserves/writes native `reasoning.effort` for
Responses. F16 does not introduce a cross-dialect reasoning conversion.
