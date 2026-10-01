/// Synthetic schemas. Source inspection is not live acceptance or CPA execution.
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import mimic/ir
import mimic/providers/kimi/schema

fn parse(source: String) -> ir.Value {
  let assert Ok(value) = ir.parse(source)
  value
}

fn ref(path: String) -> ir.Value {
  ir.Object([#("$ref", ir.String(path))])
}

pub fn local_defs_chain_and_root_sibling_override_test() {
  let input =
    parse(
      "{\"$ref\":\"#/$defs/root\",\"description\":\"synthetic sibling\",\"$defs\":{\"root\":{\"type\":\"object\",\"description\":\"synthetic target\",\"properties\":{\"q\":{\"$ref\":\"#/definitions/text\",\"description\":\"synthetic property\"}}}},\"definitions\":{\"text\":{\"type\":\"string\",\"minLength\":2}},\"additionalProperties\":false}",
    )
  schema.normalize(input)
  |> should.equal(
    Ok(parse(
      "{\"type\":\"object\",\"description\":\"synthetic sibling\",\"properties\":{\"q\":{\"type\":\"string\",\"minLength\":2,\"description\":\"synthetic property\"}},\"additionalProperties\":false}",
    )),
  )
}

pub fn pointer_escapes_and_empty_definition_name_test() {
  let input =
    parse(
      "{\"$defs\":{\"a/b~c\":{\"type\":\"string\"},\"\":{\"type\":\"integer\"},\"~1\":{\"type\":\"boolean\"}},\"properties\":{\"a\":{\"$ref\":\"#/$defs/a~1b~0c\"},\"b\":{\"$ref\":\"#/$defs/\"},\"c\":{\"$ref\":\"#/$defs/~01\"}}}",
    )
  schema.normalize(input)
  |> should.equal(
    Ok(parse(
      "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"string\"},\"b\":{\"type\":\"integer\"},\"c\":{\"type\":\"boolean\"}}}",
    )),
  )
}

pub fn array_pointer_and_nested_definitions_test() {
  let input =
    parse(
      "{\"allOf\":[{\"properties\":{\"q\":{\"type\":\"string\"}}}],\"properties\":{\"q\":{\"$ref\":\"#/allOf/0/properties/q\"},\"nested\":{\"$defs\":{\"leaf\":{\"type\":\"integer\"}},\"properties\":{\"n\":{\"$ref\":\"#/properties/nested/$defs/leaf\"}}}}}",
    )
  let assert Ok(output) = schema.normalize(input)
  let assert Some(properties) = ir.field(output, "properties")
  ir.field(properties, "q")
  |> should.equal(Some(parse("{\"type\":\"string\"}")))
  let assert Some(nested) = ir.field(properties, "nested")
  ir.field(nested, "$defs") |> should.not_equal(None)
  ir.field(nested, "properties")
  |> should.equal(Some(parse("{\"n\":{\"type\":\"integer\"}}")))
}

pub fn repeated_references_have_independent_siblings_test() {
  schema.normalize(parse(
    "{\"$defs\":{\"leaf\":{\"type\":\"string\",\"description\":\"synthetic original\"}},\"properties\":{\"a\":{\"$ref\":\"#/$defs/leaf\",\"description\":\"synthetic a\"},\"b\":{\"$ref\":\"#/$defs/leaf\",\"description\":\"synthetic b\"},\"c\":{\"$ref\":\"#/$defs/leaf\"}}}",
  ))
  |> should.equal(
    Ok(parse(
      "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"string\",\"description\":\"synthetic a\"},\"b\":{\"type\":\"string\",\"description\":\"synthetic b\"},\"c\":{\"type\":\"string\",\"description\":\"synthetic original\"}}}",
    )),
  )
}

pub fn every_supported_single_schema_position_test() {
  list.each(
    [
      "items", "additionalProperties", "unevaluatedProperties", "propertyNames",
      "contains", "not", "if", "then", "else", "additionalItems",
      "unevaluatedItems", "contentSchema",
    ],
    fn(key) {
      let input =
        ir.Object([
          #("$defs", parse("{\"leaf\":{\"type\":\"string\"}}")),
          #(key, ref("#/$defs/leaf")),
        ])
      let assert Ok(output) = schema.normalize(input)
      ir.field(output, key)
      |> should.equal(Some(parse("{\"type\":\"string\"}")))
    },
  )
}

pub fn every_supported_schema_array_and_map_position_test() {
  list.each(["items", "prefixItems", "allOf", "anyOf", "oneOf"], fn(key) {
    let input =
      ir.Object([
        #("$defs", parse("{\"leaf\":{\"type\":\"string\"}}")),
        #(key, ir.Array([ref("#/$defs/leaf"), ir.Boolean(False)])),
      ])
    let assert Ok(output) = schema.normalize(input)
    ir.field(output, key)
    |> should.equal(Some(parse("[{\"type\":\"string\"},false]")))
  })
  list.each(
    ["properties", "patternProperties", "dependentSchemas", "dependencies"],
    fn(key) {
      let input =
        ir.Object([
          #("$defs", parse("{\"leaf\":{\"type\":\"string\"}}")),
          #(key, ir.Object([#("$ref", ref("#/$defs/leaf"))])),
        ])
      let assert Ok(output) = schema.normalize(input)
      ir.field(output, key)
      |> should.equal(Some(parse("{\"$ref\":{\"type\":\"string\"}}")))
    },
  )
}

pub fn vendor_default_enum_const_and_examples_are_opaque_test() {
  let data =
    parse(
      "{\"$ref\":\"https://synthetic.invalid/schema\",\"$defs\":{\"x\":{\"$ref\":\"#/missing\"}},\"definitions\":true,\"model\":\"user-model\",\"$id\":\"file:///synthetic\",\"type\":\"input_audio\"}",
    )
  let input =
    ir.Object([
      #("type", ir.String("object")),
      #("default", data),
      #("const", data),
      #("enum", ir.Array([data])),
      #("examples", ir.Array([data])),
      #("x-vendor", ir.Object([#("properties", data)])),
      #("futureSchemaKeyword", data),
      #("properties", ir.Object([#("q", ir.Object([#("default", data)]))])),
    ])
  let assert Ok(canonical) = ir.parse(ir.stringify(input))
  schema.normalize(input) |> should.equal(Ok(canonical))
}

pub fn boolean_schemas_and_property_dependencies_are_preserved_test() {
  let input =
    parse(
      "{\"type\":\"object\",\"properties\":{\"allowed\":true,\"denied\":false},\"dependencies\":{\"a\":[\"b\",\"$ref\"]},\"additionalProperties\":false}",
    )
  schema.normalize(input) |> should.equal(Ok(input))
}

pub fn cycles_are_errors_not_constraint_losing_hints_test() {
  list.each(
    [
      "{\"$defs\":{\"x\":{\"$ref\":\"#/$defs/x\",\"type\":\"object\"}},\"$ref\":\"#/$defs/x\"}",
      "{\"$defs\":{\"x\":{\"$ref\":\"#/$defs/y\"},\"y\":{\"$ref\":\"#/$defs/x\"}},\"$ref\":\"#/$defs/x\"}",
      "{\"properties\":{\"x\":{\"$ref\":\"#/properties/x\"}}}",
      "{\"$defs\":{\"unused\":{\"properties\":{\"x\":{\"$ref\":\"#/$defs/unused\"}}}}}",
      "{\"$defs\":{\"x\":{\"$ref\":\"#/$defs/x\"}},\"$ref\":\"#/$defs/x\",\"type\":\"object\",\"description\":\"synthetic override\"}",
    ],
    fn(source) { schema.normalize(parse(source)) |> should.be_error },
  )
}

pub fn unsupported_and_dangling_refs_fail_explicitly_test() {
  list.each(
    [
      "#", "#leaf", "#/$defs/missing", "#/$defs/x~2", "#/$defs/%78",
      "https://synthetic.invalid/schema#/$defs/x", "file:///synthetic/schema",
      "../synthetic.json", "#/allOf/00", "#/allOf/-1", "#/allOf/1", "#/default",
      "#/enum/0", "#/x-vendor", "#/properties/bool", "#/properties/string",
      "#/$defs",
    ],
    fn(path) {
      let input =
        ir.Object([
          #("$ref", ir.String(path)),
          #("$defs", parse("{\"x\":{\"type\":\"object\"}}")),
          #("allOf", parse("[{\"type\":\"object\"}]")),
          #("default", parse("{\"type\":\"object\"}")),
          #("enum", parse("[{\"type\":\"object\"}]")),
          #("x-vendor", parse("{\"type\":\"object\"}")),
          #("properties", parse("{\"bool\":true}")),
        ])
      schema.normalize(input) |> should.be_error
    },
  )
  schema.normalize(parse("{\"$ref\":42}")) |> should.be_error
}

pub fn reference_scope_features_are_denied_only_in_schema_positions_test() {
  list.each(["$id", "$dynamicRef", "$recursiveRef"], fn(key) {
    schema.normalize(ir.Object([#(key, ir.String("#/synthetic"))]))
    |> should.be_error
    schema.normalize(
      ir.Object([
        #("x-vendor", ir.Object([#(key, ir.String("#/synthetic"))])),
      ]),
    )
    |> should.be_ok
  })
}

pub fn invalid_schema_positions_and_roots_are_errors_test() {
  list.each(
    [
      "null", "false", "[]", "{\"type\":\"string\"}", "{\"properties\":[]}",
      "{\"properties\":{\"q\":42}}", "{\"allOf\":{}}",
      "{\"items\":\"synthetic\"}", "{\"dependencies\":{\"a\":[1]}}",
      "{\"$defs\":false}",
    ],
    fn(source) { schema.normalize(parse(source)) |> should.be_error },
  )
}

fn chain(length: Int, branch: Bool) -> ir.Value {
  let definitions =
    list.repeat(Nil, length)
    |> list.index_map(fn(_, index) {
      let name = "d" <> int.to_string(index)
      let target = ref("#/$defs/d" <> int.to_string(index + 1))
      let value = case index == length - 1, branch {
        True, _ -> parse("{\"type\":\"object\"}")
        False, False -> target
        False, True -> ir.Object([#("anyOf", ir.Array([target, target]))])
      }
      #(name, value)
    })
  ir.Object([
    #("$ref", ir.String("#/$defs/d0")),
    #("$defs", ir.Object(definitions)),
  ])
}

pub fn reference_chain_depth_is_bounded_test() {
  schema.normalize(chain(8, False)) |> should.be_ok
  schema.normalize(chain(66, False)) |> should.be_error
}

pub fn exponential_expansion_has_a_node_work_bound_test() {
  schema.normalize(chain(3, True)) |> should.be_ok
  // Tighten only nodes, with ample bytes/depth and an input below the node cap.
  schema.normalize_bounded(chain(3, True), 64, 32, 262_144)
  |> should.equal(Error("Kimi schema expansion limit exceeded"))
  // Below 256 KiB output but exceeds 16,384 expanded/work JSON values.
  schema.normalize(chain(13, True))
  |> should.equal(Error("Kimi schema expansion limit exceeded"))
}

pub fn repeated_large_definitions_have_a_byte_bound_test() {
  let description = ir.String(string.repeat("🌍", 1024))
  let input =
    ir.Object([
      #(
        "$defs",
        ir.Object([
          #(
            "leaf",
            ir.Object([
              #("type", ir.String("string")),
              #("description", description),
            ]),
          ),
        ]),
      ),
      #(
        "properties",
        ir.Object(
          list.repeat(Nil, 70)
          |> list.index_map(fn(_, index) {
            #("p" <> int.to_string(index), ref("#/$defs/leaf"))
          }),
        ),
      ),
    ])
  let below_input_limit =
    string.byte_size(ir.stringify(input)) < schema.max_bytes
  below_input_limit |> should.be_true
  schema.normalize(input)
  |> should.equal(Error("Kimi schema expansion limit exceeded"))
}

pub fn tight_bounds_include_final_type_and_cannot_raise_ceilings_test() {
  schema.normalize_bounded(parse("{}"), 64, 16_384, 17)
  |> should.equal(Ok(parse("{\"type\":\"object\"}")))
  schema.normalize_bounded(parse("{}"), 64, 16_384, 16) |> should.be_error
  schema.normalize_bounded(parse("{}"), 64, 1, 100) |> should.be_error
  schema.normalize_bounded(parse("{}"), 65, 16_384, 262_144) |> should.be_error
  schema.normalize_bounded(parse("{}"), 64, 16_385, 262_144) |> should.be_error
  schema.normalize_bounded(parse("{}"), 64, 16_384, 262_145) |> should.be_error
  schema.normalize_bounded(parse("{}"), 0, 1, 1) |> should.be_error
}

pub fn duplicate_constructed_keys_are_rejected_before_merge_test() {
  schema.normalize(
    ir.Object([
      #("$ref", ir.String("#/$defs/x")),
      #("$ref", ir.String("#/$defs/y")),
    ]),
  )
  |> should.be_error
}
