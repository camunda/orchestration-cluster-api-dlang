/// Unit tests for the hardened OpenAPI reader: key order, `$ref`/`allOf`
/// resolution, cycle and limit enforcement, and a fuzz-style corpus of
/// truncated / garbled JSON that must throw rather than crash.
module camunda.openapi.tests;

@safe:

import std.conv : to;
import std.exception : assertThrown, assertNotThrown;

import camunda.openapi.errors
    : OpenApiCycleException, OpenApiException, OpenApiLimitException;
import camunda.openapi.json
    : J, Kind, Limits, get, parseJson;
import camunda.openapi.spec : COMPONENT_PREFIX, Props, Spec;

private J specWith(string schemasJson)
{
    return parseJson(`{"openapi":"3.0.0","components":{"schemas":` ~ schemasJson ~ `}}`);
}

// --- key order --------------------------------------------------------------

unittest
{
    auto doc = parseJson(`{"b":1,"a":2,"z":3,"m":4}`);
    assert(doc.keys == ["b", "a", "z", "m"], doc.keys.to!string);
    // Nested objects keep their own order.
    auto nested = parseJson(`{"outer":{"y":1,"x":2},"first":0}`);
    assert(nested.keys == ["outer", "first"]);
    assert(nested.get("outer").keys == ["y", "x"]);
}

// --- $ref resolution --------------------------------------------------------

unittest
{
    auto spec = new Spec(specWith(`{"Foo":{"type":"object"},"Bar":{"type":"string"}}`));
    auto refNode = parseJson(`{"$ref":"#/components/schemas/Foo"}`);
    assert(spec.refName(refNode) == "Foo");
    // Non-component refs resolve to their last segment.
    auto ext = parseJson(`{"$ref":"#/paths/~1things/get"}`);
    assert(spec.refName(ext) == "get");
    // No $ref -> null.
    assert(spec.refName(parseJson(`{"type":"object"}`)) is null);
}

// Deep $ref into a component is followed to the component it names.
unittest
{
    auto spec = new Spec(specWith(
        `{"Base":{"type":"object"},`
        ~ `"Wrap":{"allOf":[{"$ref":"#/components/schemas/Base"}]}}`));
    auto deep = parseJson(`{"$ref":"#/components/schemas/Wrap/allOf/0"}`);
    assert(spec.refName(deep) == "Base");
}

// A deep $ref to an inline (non-$ref) schema is rejected, not mishandled.
unittest
{
    auto spec = new Spec(specWith(
        `{"Wrap":{"allOf":[{"type":"object","properties":{"x":{"type":"string"}}}]}}`));
    auto deep = parseJson(`{"$ref":"#/components/schemas/Wrap/allOf/0"}`);
    assertThrown!OpenApiException(spec.refName(deep));
}

// --- allOf / flattening -----------------------------------------------------

unittest
{
    auto spec = new Spec(specWith(`{
        "Base":{"type":"object","properties":{"id":{"type":"string"},"n":{"type":"integer"}}},
        "Child":{"allOf":[{"$ref":"#/components/schemas/Base"}],
                 "type":"object","properties":{"extra":{"type":"boolean"}}}
    }`));
    bool[string] seen;
    auto props = spec.collectProperties("Child", spec.schema("Child"), seen);
    // Parent props first (document order), then own props.
    assert(props.names == ["id", "n", "extra"], props.names.to!string);
}

// allOf of a single $ref unwraps to an alias target.
unittest
{
    auto spec = new Spec(specWith(`{
        "LongKey":{"type":"string"},
        "AgentKey":{"allOf":[{"$ref":"#/components/schemas/LongKey"}]}
    }`));
    assert(spec.unwrapAllofRef(spec.schema("AgentKey")) == "LongKey");
}

// Own properties win over allOf parents on a name clash.
unittest
{
    auto spec = new Spec(specWith(`{
        "Base":{"type":"object","properties":{"v":{"type":"string"}}},
        "Child":{"allOf":[{"$ref":"#/components/schemas/Base"}],
                 "type":"object","properties":{"v":{"type":"integer"}}}
    }`));
    bool[string] seen;
    auto props = spec.collectProperties("Child", spec.schema("Child"), seen);
    assert(props.names == ["v"]);
    assert(props.map["v"].get("type").text == "integer");
}

// --- cycles -----------------------------------------------------------------

unittest
{
    // A -> B -> A through allOf refs.
    auto spec = new Spec(specWith(`{
        "A":{"allOf":[{"$ref":"#/components/schemas/B"}]},
        "B":{"allOf":[{"$ref":"#/components/schemas/A"}]}
    }`));
    bool[string] seen;
    // collectProperties guards with `seen`, so it terminates; refName on a
    // self-referential chain throws.
    assertNotThrown(spec.collectProperties("A", spec.schema("A"), seen));
    // A direct cyclic $ref (a schema whose $ref resolves to itself) throws.
    // A single-segment ref returns its name immediately, so build the cycle
    // through deep refs: X/allOf/0 -> Y, Y/allOf/0 -> X.
    auto cyclic = new Spec(specWith(`{
        "X":{"allOf":[{"$ref":"#/components/schemas/Y/allOf/0"}]},
        "Y":{"allOf":[{"$ref":"#/components/schemas/X/allOf/0"}]}
    }`));
    assertThrown!OpenApiCycleException(cyclic.refName(parseJson(`{"$ref":"#/components/schemas/X/allOf/0"}`)));
}

// --- limits -----------------------------------------------------------------

unittest
{
    // Depth limit: deeply nested arrays exceed maxDepth and throw, not crash.
    auto limits = Limits.init;
    limits.maxDepth = 8;
    string deep = "[";
    foreach (_; 0 .. 32)
        deep ~= "[";
    assertThrown!OpenApiLimitException(parseJson(deep, limits));
    // A shallow document under the limit parses fine.
    assertNotThrown(parseJson("[[[[1]]]]", limits));
}

unittest
{
    // Size limit.
    auto limits = Limits.init;
    limits.maxBytes = 16;
    assertThrown!OpenApiLimitException(parseJson(`{"key":"a much longer value"}`, limits));
    assertNotThrown(parseJson(`{"a":1}`, limits));
}

unittest
{
    // $ref chain length limit. Single-segment refs return their name at once,
    // so build a chain of deep refs: A -> B -> C -> D, each via allOf/0.
    auto limits = Limits.init;
    limits.maxRefChain = 2;
    auto spec = new Spec(specWith(`{
        "A":{"allOf":[{"$ref":"#/components/schemas/B/allOf/0"}]},
        "B":{"allOf":[{"$ref":"#/components/schemas/C/allOf/0"}]},
        "C":{"allOf":[{"$ref":"#/components/schemas/D/allOf/0"}]},
        "D":{"allOf":[{"$ref":"#/components/schemas/E"}]},
        "E":{"type":"object"}
    }`), null, limits);
    assertThrown!OpenApiLimitException(spec.refName(parseJson(`{"$ref":"#/components/schemas/A/allOf/0"}`)));
}

// --- malformed input / fuzz corpus -----------------------------------------

unittest
{
    // Truncations of a valid document must throw, never crash.
    enum doc = `{"openapi":"3.0.0","info":{"title":"t","version":"1"},"paths":{"/x":{"get":{"operationId":"op"}}},"components":{"schemas":{"A":{"type":"object"}}}}`;
    foreach (len; 0 .. doc.length)
    {
        // The document is one object, so no proper prefix is valid JSON.
        assertThrown!OpenApiException(parseJson(doc[0 .. len]), doc[0 .. len]);
    }
    assertNotThrown(parseJson(doc));
}

unittest
{
    // Garbled / hostile inputs: all throw OpenApiException, none crash.
    string[] bad = [
        "", " ", "{", "}", "[", "]", "{{", "[[]", `{"a"`, `{"a":`, `{"a":1`,
        `{"a":1,`, `{"a":1,}`, `[,]`, `[1,,2]`, `{,}`, `"\`, `"abc`, `"a\q"`,
        `"\u12"`, `"\uZZZZ"`, `"\uD800"`, `"\uDC00"`, `"\uD800\uD800"`,
        "nul", "nulll", "truee", "fals", "01", "-", "+1", ".5", "1.", "1e",
        "1e+", "--1", "1.2.3", "NaN", "Infinity", "0x1", "\"a\x01b\"",
        `{"a":1} trailing`, `[1] [2]`, "null null", "\x00", "\xff\xfe",
    ];
    foreach (b; bad)
        assertThrown!OpenApiException(parseJson(b), b);
}

// A valid document with every JSON kind round-trips through the parser.
unittest
{
    auto v = parseJson(`{"s":"x","n":-1.5e3,"b":true,"f":false,"z":null,"a":[1,2],"o":{"k":"v"}}`);
    assert(v.kind == Kind.object);
    assert(v.get("s").text == "x");
    assert(v.get("n").text == "-1.5e3");
    assert(v.get("b").boolean && !v.get("f").boolean);
    assert(v.get("z").kind == Kind.null_);
    assert(v.get("a").items.length == 2);
    assert(v.get("o").get("k").text == "v");
}

// --- review regressions -----------------------------------------------------

// Invalid UTF-8 inside strings is a typed error (lone byte, truncated
// sequence, overlong, encoded surrogate); valid multibyte text survives.
unittest
{
    foreach (bad; ["\"a\xffb\"", "\"\xc3\"", "\"\xe2\x82\"", "\"\xc0\xaf\"", "\"\xed\xa0\x80\""])
        assertThrown!OpenApiException(parseJson(bad), bad);
    assert(parseJson("\"caf\u00e9 \u20ac \U0001F600\"").text == "caf\u00e9 \u20ac \U0001F600");
}

// Without metadata, operations come from `paths` in document order.
unittest
{
    auto spec = new Spec(parseJson(`{"openapi":"3.0.0","paths":{
        "/b":{"servers":[{"url":"http://p"}],"parameters":[{"name":"pp","in":"query"}],
              "post":{"operationId":"postB","requestBody":{"content":{}},"x-flag":true,
                      "parameters":[{"name":"q","in":"query"}]},
              "summary":"not an op"},
        "/a/{k}":{"get":{"operationId":"getA","servers":[{"url":"http://o"}]}}}}`));
    assert(spec.operations.length == 2);
    auto b = spec.operations[0];
    assert(b.get("operationId").text == "postB" && b.get("method").text == "post" && b.get("path").text == "/b");
    assert(b.get("hasRequestBody").boolean && b.get("requestBody") !is null);
    assert(b.get("parameters").items.length == 2);
    assert(b.get("servers").items[0].get("url").text == "http://p");
    assert(b.get("vendorExtensions").get("x-flag").boolean);
    auto a = spec.operations[1];
    assert(a.get("operationId").text == "getA" && !a.get("hasRequestBody").boolean);
    assert(a.get("servers").items[0].get("url").text == "http://o");
    // Metadata, when present, still wins (even if empty).
    auto withMeta = new Spec(spec.spec, parseJson(`{"operations":[]}`));
    assert(withMeta.operations.length == 0);
    // A non-object operation is a typed error.
    assertThrown!OpenApiException(new Spec(parseJson(`{"paths":{"/x":{"get":1}}}`)));
}

// Metadata entries without a string name are typed errors.
unittest
{
    foreach (m; [`{"semanticKeys":[{}]}`, `{"semanticKeys":[null]}`, `{"unions":[null]}`,
            `{"unions":[{"name":1}]}`])
        assertThrown!OpenApiException(new Spec(null, parseJson(m)), m);
}

// Single-component refs are pointer-unescaped.
unittest
{
    auto spec = new Spec(specWith(`{"Foo/Bar":{"type":"object"},"A~B":{"type":"object"}}`));
    assert(spec.refName(parseJson(`{"$ref":"#/components/schemas/Foo~1Bar"}`)) == "Foo/Bar");
    assert(spec.refName(parseJson(`{"$ref":"#/components/schemas/A~0B"}`)) == "A~B");
}

// Malformed array indices in deep refs are typed errors.
unittest
{
    auto spec = new Spec(specWith(`{"Wrap":{"allOf":[{"$ref":"#/components/schemas/W"}]},"W":{}}`));
    foreach (r; ["nope", "-1", "1x", "99999999999999999999999"])
        assertThrown!OpenApiException(spec.refName(parseJson(
            `{"$ref":"#/components/schemas/Wrap/allOf/` ~ r ~ `"}`)), r);
}

// Flattening follows a $ref on the schema itself and inline nested allOf,
// and unions required names (kept even when a property is overridden).
unittest
{
    auto spec = new Spec(specWith(`{
        "Base":{"type":"object","required":["id"],"properties":{"id":{"type":"string"}}},
        "Alias":{"$ref":"#/components/schemas/Base"},
        "Via":{"allOf":[{"$ref":"#/components/schemas/Alias"}],"properties":{"id":{"type":"integer"}}},
        "Nested":{"allOf":[{"allOf":[{"required":["x"],"properties":{"x":{"type":"string"}}}]}]}
    }`));
    bool[string] s1;
    auto alias_ = spec.collectProperties("Alias", spec.schema("Alias"), s1);
    assert(alias_.names == ["id"] && alias_.isRequired("id"));
    bool[string] s2;
    auto via = spec.collectProperties("Via", spec.schema("Via"), s2);
    assert(via.names == ["id"] && via.isRequired("id"));
    assert(via.map["id"].get("type").text == "integer");
    bool[string] s3;
    auto nested = spec.collectProperties("Nested", spec.schema("Nested"), s3);
    assert(nested.names == ["x"] && nested.isRequired("x"));
}

// A long acyclic allOf chain is bounded by a typed limit, not the stack.
unittest
{
    auto limits = Limits.init;
    limits.maxDepth = 50;
    string schemas = "{";
    foreach (i; 0 .. 200)
        schemas ~= `"S` ~ i.to!string ~ `":{"allOf":[{"$ref":"#/components/schemas/S` ~ (i + 1).to!string ~ `"}]},`;
    schemas ~= `"S200":{"properties":{"z":{}}}}`;
    auto spec = new Spec(specWith(schemas), null, limits);
    bool[string] seen;
    assertThrown!OpenApiLimitException(spec.collectProperties("S0", spec.schema("S0"), seen));
    // Same depth via inline nesting (document parsed with default limits).
    string inline = `{"properties":{"z":{}}}`;
    foreach (_; 0 .. 30)
        inline = `{"allOf":[` ~ inline ~ `]}`;
    auto limits2 = Limits.init;
    limits2.maxDepth = 20;
    auto spec2 = new Spec(specWith(`{"I":` ~ inline ~ `}`), null, limits2);
    bool[string] seen2;
    assertThrown!OpenApiLimitException(spec2.collectProperties("I", spec2.schema("I"), seen2));
}

// Operation-level parameters override path-level ones by (name, in), through
// $refs; servers fall back operation -> path item -> document.
unittest
{
    auto spec = new Spec(parseJson(`{"openapi":"3.0.0","servers":[{"url":"http://doc"}],
        "components":{"parameters":{"Q":{"name":"q","in":"query","required":false}}},
        "paths":{"/x":{"parameters":[{"name":"q","in":"query","required":true},
                                     {"name":"q","in":"header"}],
            "get":{"operationId":"getX","parameters":[{"$ref":"#/components/parameters/Q"}]}}}}`));
    auto x = spec.operations[0];
    auto ps = x.get("parameters").items;
    assert(ps.length == 2, ps.length.to!string);
    assert(ps[0].get("in").text == "header");
    assert(ps[1].get("$ref").text == "#/components/parameters/Q");
    assert(x.get("servers").items[0].get("url").text == "http://doc");
    // Unresolvable / cyclic parameter refs and nameless parameters are typed errors.
    assertThrown!OpenApiException(new Spec(parseJson(
        `{"paths":{"/x":{"get":{"parameters":[{"$ref":"#/components/parameters/Nope"}]}}}}`)));
    assertThrown!OpenApiCycleException(new Spec(parseJson(
        `{"components":{"parameters":{"A":{"$ref":"#/components/parameters/A"}}},
          "paths":{"/x":{"get":{"parameters":[{"$ref":"#/components/parameters/A"}]}}}}`)));
    assertThrown!OpenApiException(new Spec(parseJson(
        `{"paths":{"/x":{"get":{"parameters":[{"in":"query"}]}}}}`)));
}

// Percent-encoded fragments are decoded before JSON-pointer interpretation
// (schema and parameter refs); malformed encodings are typed errors.
unittest
{
    auto spec = new Spec(specWith(`{"Foo.Bar":{"properties":{"a":{}}},
        "Use":{"allOf":[{"$ref":"#/components/schemas/Foo%2EBar"}]}}`));
    bool[string] seen;
    assert(spec.collectProperties("Use", spec.schema("Use"), seen).names == ["a"]);
    assertThrown!OpenApiException(spec.refName(parseJson(`{"$ref":"#/components/schemas/Foo%2"}`)));
    assertThrown!OpenApiException(spec.refName(parseJson(`{"$ref":"#/components/schemas/%ZZ"}`)));
    assertThrown!OpenApiException(spec.refName(parseJson(`{"$ref":"#/components/schemas/%FF"}`)));

    auto p = new Spec(parseJson(`{"openapi":"3.0.0","components":{"parameters":{"q.x":{"name":"q","in":"query"}}},
        "paths":{"/x":{"get":{"operationId":"x","parameters":[{"$ref":"#/components/parameters/q%2Ex"}]}}}}`));
    assert(p.operations.length == 1);
}

// Path Item $refs are rejected rather than silently dropping operations.
unittest
{
    assertThrown!OpenApiException(new Spec(parseJson(`{"openapi":"3.0.0","paths":{
        "/base":{"get":{"operationId":"b"}},"/alias":{"$ref":"#/paths/~1base"}}}`)));
}

// Flattening rejects missing components and non-component refs (direct,
// in allOf, and via a deep alias) instead of producing empty/wrong props.
unittest
{
    bool[string] seen;
    auto missing = new Spec(specWith(`{"A":{"allOf":[{"$ref":"#/components/schemas/Missing"}]},
        "B":{"$ref":"#/components/schemas/Missing"}}`));
    assertThrown!OpenApiException(missing.collectProperties("A", missing.schema("A"), seen));
    seen = null;
    assertThrown!OpenApiException(missing.collectProperties("B", missing.schema("B"), seen));
    seen = null;
    auto nonComp = new Spec(specWith(`{"schema":{"properties":{"wrong":{}}},
        "A":{"allOf":[{"$ref":"#/paths/~1x/get/responses/200/content/application~1json/schema"}]},
        "D":{"allOf":[{"$ref":"#/components/schemas/Alias/allOf/0"}]},
        "Alias":{"allOf":[{"$ref":"#/paths/~1x/schema"}]}}`));
    assertThrown!OpenApiException(nonComp.collectProperties("A", nonComp.schema("A"), seen));
    seen = null;
    assertThrown!OpenApiException(nonComp.collectProperties("D", nonComp.schema("D"), seen));
}

// OpenAPI 3.1: siblings of $ref inside an allOf member contribute.
unittest
{
    auto spec = new Spec(specWith(`{"Base":{"properties":{"id":{}}},
        "S":{"allOf":[{"$ref":"#/components/schemas/Base","required":["id"],"properties":{"extra":{}}}]}}`));
    bool[string] seen;
    auto props = spec.collectProperties("S", spec.schema("S"), seen);
    assert(props.isRequired("id"));
    assert(props.names == ["id", "extra"], props.names.to!string);
}
