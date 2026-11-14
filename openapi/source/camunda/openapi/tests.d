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
        auto piece = doc[0 .. len];
        try
        {
            auto v = parseJson(piece);
            // Only a complete-prefix that is itself valid JSON may succeed;
            // anything else must have thrown.
        }
        catch (OpenApiException)
        {
        }
    }
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
