/+ dub.sdl:
name "generate"
targetPath ".dub/bin"
+/
/**
Generate the D SDK from the bundled OpenAPI spec + spec-metadata.

Numbered hooks (lexicographic, like the sibling SDKs):

  01  Domain Type System   source/camunda/generated/keys.d
  02  Enums                source/camunda/generated/enums.d
  03  Models               source/camunda/generated/models.d
  04  Operations facade    source/camunda/generated/operations.d
  05  Generated package    source/camunda/generated/package.d
  06  Markdown docs        docs/api-reference.md, docs/semantic-types.md
  07  Per-tag examples     examples/<tag>.d + examples/operation-map.json

Never hand-edit source/camunda/generated/, docs/*.md, examples/operation-map.json,
or the generated `examples/<tag>.d` files (everything except `readme.d` and
`topology.d`). Change this program and re-run `make generate`.

Run: `dub run -q --single scripts/generate.d` (or `make generate-local`).
*/
module generate;

import std.algorithm : all, canFind, endsWith, map, sort, startsWith;
import std.array : array, appender, join, replace, split;
import std.ascii : isDigit;
import std.conv : to;
import std.file : dirEntries, exists, isFile, mkdirRecurse, readText, remove, SpanMode, write;
import std.format : format;
import std.path : baseName, buildPath, dirName, relativePath;
import std.regex : ctRegex, matchAll, regex, replaceAll, splitter;
import std.stdio : stderr, writeln;
import std.string : indexOf, strip, stripRight, toLower, toUpper;
import std.utf : decode, stride;

// ---------------------------------------------------------------------------
// Order-preserving JSON (std.json uses associative arrays, which lose the
// key order the generator relies on for properties and operations).
// ---------------------------------------------------------------------------

enum Kind { null_, bool_, number, string_, array, object }

final class J
{
    Kind kind;
    bool boolean;
    string text; // string value, or the raw number literal
    J[] items;
    string[] keys;
    J[string] fields;

    this(Kind k) { kind = k; }

    static J str(string s) { auto j = new J(Kind.string_); j.text = s; return j; }
    static J obj() { return new J(Kind.object); }
    static J arr(J[] xs) { auto j = new J(Kind.array); j.items = xs; return j; }

    void set(string k, J v)
    {
        if (k !in fields)
            keys ~= k;
        fields[k] = v;
    }

    bool isObj() const { return kind == Kind.object; }
    bool isArr() const { return kind == Kind.array; }
    bool isStr() const { return kind == Kind.string_; }
}

/// `node.get(key)`; null when missing or `node` is not an object.
J get(J node, string key)
{
    if (node is null || node.kind != Kind.object)
        return null;
    if (auto p = key in node.fields)
        return *p;
    return null;
}

bool has(J node, string key) { return node !is null && node.isObj && (key in node.fields) !is null; }

/// Python truthiness.
bool truthy(J v)
{
    if (v is null)
        return false;
    final switch (v.kind)
    {
    case Kind.null_: return false;
    case Kind.bool_: return v.boolean;
    case Kind.number: return v.text.to!double != 0;
    case Kind.string_: return v.text.length > 0;
    case Kind.array: return v.items.length > 0;
    case Kind.object: return v.keys.length > 0;
    }
}

/// `a or b`.
J or(J a, J b) { return truthy(a) ? a : b; }

/// `value or fallback` for string-valued fields.
string orS(J v, string fallback) { return truthy(v) ? pyStr(v) : fallback; }

/// Python `str(value)`.
string pyStr(J v)
{
    if (v is null)
        return "None";
    final switch (v.kind)
    {
    case Kind.null_: return "None";
    case Kind.bool_: return v.boolean ? "True" : "False";
    case Kind.number: return v.text;
    case Kind.string_: return v.text;
    case Kind.array: case Kind.object:
        throw new Exception("unexpected container where a scalar was expected");
    }
}

J[] itemsOf(J v) { return v !is null && v.isArr ? v.items : null; }
string[] keysOf(J v) { return v !is null && v.isObj ? v.keys : null; }

struct Parser
{
    string s;
    size_t i;

    void ws()
    {
        while (i < s.length && (s[i] == ' ' || s[i] == '\n' || s[i] == '\r' || s[i] == '\t'))
            i++;
    }

    noreturn fail(string what) { throw new Exception(format("JSON: %s at offset %s", what, i)); }

    void expect(char c)
    {
        if (i >= s.length || s[i] != c)
            fail("expected '" ~ c ~ "'");
        i++;
    }

    J value()
    {
        ws();
        if (i >= s.length)
            fail("unexpected end");
        switch (s[i])
        {
        case '{':
        {
            i++;
            auto o = J.obj();
            ws();
            if (s[i] == '}') { i++; return o; }
            for (;;)
            {
                ws();
                auto k = str();
                ws();
                expect(':');
                o.set(k, value());
                ws();
                if (s[i] == ',') { i++; continue; }
                expect('}');
                return o;
            }
        }
        case '[':
        {
            i++;
            auto a = new J(Kind.array);
            ws();
            if (s[i] == ']') { i++; return a; }
            for (;;)
            {
                a.items ~= value();
                ws();
                if (s[i] == ',') { i++; continue; }
                expect(']');
                return a;
            }
        }
        case '"':
            return J.str(str());
        case 't': i += 4; { auto b = new J(Kind.bool_); b.boolean = true; return b; }
        case 'f': i += 5; return new J(Kind.bool_);
        case 'n': i += 4; return new J(Kind.null_);
        default:
            const start = i;
            while (i < s.length && "+-0123456789.eE".canFind(s[i]))
                i++;
            if (i == start)
                fail("unexpected character");
            auto n = new J(Kind.number);
            n.text = s[start .. i];
            return n;
        }
    }

    uint hex4()
    {
        auto v = s[i .. i + 4].to!uint(16);
        i += 4;
        return v;
    }

    string str()
    {
        expect('"');
        auto buf = appender!string;
        for (;;)
        {
            if (i >= s.length)
                fail("unterminated string");
            const c = s[i++];
            if (c == '"')
                return buf[];
            if (c != '\\')
            {
                buf.put(c);
                continue;
            }
            const e = s[i++];
            switch (e)
            {
            case '"': buf.put('"'); break;
            case '\\': buf.put('\\'); break;
            case '/': buf.put('/'); break;
            case 'b': buf.put('\b'); break;
            case 'f': buf.put('\f'); break;
            case 'n': buf.put('\n'); break;
            case 'r': buf.put('\r'); break;
            case 't': buf.put('\t'); break;
            case 'u':
                dchar cp = hex4();
                if (cp >= 0xD800 && cp < 0xDC00 && i + 6 <= s.length && s[i] == '\\' && s[i + 1] == 'u')
                {
                    i += 2;
                    const lo = hex4();
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                }
                buf.put(cp);
                break;
            default: fail("bad escape");
            }
        }
    }
}

J parseJson(string text)
{
    auto p = Parser(text, 0);
    auto v = p.value();
    p.ws();
    if (p.i != text.length)
        p.fail("trailing data");
    return v;
}

/// Python `json.dumps(value, ensure_ascii=...)` for a string.
string jsonQuote(string value, bool ensureAscii)
{
    auto buf = appender!string;
    buf.put('"');
    size_t i = 0;
    while (i < value.length)
    {
        const dchar c = decode(value, i);
        switch (c)
        {
        case '"': buf.put(`\"`); break;
        case '\\': buf.put(`\\`); break;
        case '\n': buf.put(`\n`); break;
        case '\r': buf.put(`\r`); break;
        case '\t': buf.put(`\t`); break;
        case '\b': buf.put(`\b`); break;
        case '\f': buf.put(`\f`); break;
        default:
            if (c < 0x20)
                buf.put(format(`\u%04x`, cast(uint) c));
            else if (ensureAscii && c > 0x7f)
            {
                if (c >= 0x10000)
                {
                    const v = c - 0x10000;
                    buf.put(format(`\u%04x\u%04x`, 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF)));
                }
                else
                    buf.put(format(`\u%04x`, cast(uint) c));
            }
            else
                buf.put(c);
        }
    }
    buf.put('"');
    return buf[];
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

immutable string ROOT;
immutable string SPEC_PATH;
immutable string META_PATH;
immutable string OUT_DIR;
immutable string DOCS_DIR;

shared static this()
{
    ROOT = dirName(dirName(__FILE_FULL_PATH__));
    SPEC_PATH = buildPath(ROOT, "external-spec", "bundled", "rest-api.bundle.json");
    META_PATH = buildPath(ROOT, "external-spec", "bundled", "spec-metadata.json");
    OUT_DIR = buildPath(ROOT, "source", "camunda", "generated");
    DOCS_DIR = buildPath(ROOT, "docs");
}

immutable bool[string] D_KEYWORDS;
shared static this()
{
    bool[string] kw;
    foreach (w; [
        "abstract", "alias", "align", "asm", "assert", "auto", "body", "bool",
        "break", "byte", "case", "cast", "catch", "char", "class", "const",
        "continue", "debug", "default", "delete", "deprecated", "do", "double",
        "else", "enum", "export", "extern", "false", "final", "finally", "float",
        "for", "foreach", "foreach_reverse", "function", "goto", "if", "immutable",
        "import", "in", "inout", "int", "interface", "invariant", "is", "lazy",
        "long", "macro", "mixin", "module", "new", "nothrow", "null", "out",
        "override", "package", "pragma", "private", "protected", "public", "pure",
        "real", "ref", "return", "scope", "shared", "short", "static", "struct",
        "super", "switch", "synchronized", "template", "this", "throw", "true",
        "try", "typedef", "typeid", "typeof", "ubyte", "ucent", "uint", "ulong",
        "union", "unittest", "ushort", "version", "void", "wchar", "while", "with",
        "string", "wstring", "dstring", "init", "sizeof", "mangleof", "stringof",
    ])
        kw[w] = true;
    D_KEYWORDS = cast(immutable) kw;
}

bool isKeyword(string s) { return (s in D_KEYWORDS) !is null; }

// Hand-written curated methods on CamundaClient. The generated facade still
// emits the operation (so the surface stays complete) but uses a different
// D name when it would collide; curated wrappers keep the nicer name.
immutable string[string] CURATED_NAMES;

// multipart/form-data operations go through hand-written CamundaClient methods
// (the generic request* path is JSON only). The generated `<op>Op` stays for
// source compatibility but is deprecated and throws. A new multipart operation
// without an entry here stops generation (#7).
immutable string[string] MULTIPART_CURATED;

// Example signature + call for each multipart operation (hand-written method).
immutable string[2][string] MULTIPART_EXAMPLES;

shared static this()
{
    CURATED_NAMES = [
        "getTopology": "getTopologyOp",
        "createDeployment": "createDeploymentOp",
        "createDocument": "createDocumentOp",
        "createDocuments": "createDocumentsOp",
    ];
    MULTIPART_CURATED = [
        "createDeployment": "deployResources",
        "createDocument": "createDocument",
        "createDocuments": "createDocuments",
    ];
    MULTIPART_EXAMPLES = [
        "createDeployment": ["string[] paths", "client.deployResources(paths)"],
        "createDocument": ["string path, string storeId = null",
                           "client.createDocument(path, null, storeId)"],
        "createDocuments": ["string[] paths, string storeId = null",
                            "client.createDocuments(paths, storeId)"],
    ];
    assert(MULTIPART_EXAMPLES.keys.sort.array == MULTIPART_CURATED.keys.sort.array);
}

string curatedName(string opId) { return opId in CURATED_NAMES ? CURATED_NAMES[opId] : opId; }

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

noreturn die(string msg)
{
    stderr.writeln(msg);
    import core.stdc.stdlib : exit;
    exit(1);
    assert(0);
}

void log(string hook, string msg) { writeln("  [", hook, "] ", msg); }

string rel(string path) { return relativePath(path, ROOT); }

string dString(string value) { return jsonQuote(value, false); }

/// Upper-case the first character (`s[0].upper() + s[1:]`).
string capFirst(string s)
{
    if (!s.length)
        return s;
    const n = stride(s, 0);
    return toUpper(s[0 .. n]) ~ s[n .. $];
}

string dIdent(string name)
{
    string ident;
    if (name.startsWith("$"))
        ident = name[1 .. $];
    else if (name.canFind('.') || name.canFind('-'))
    {
        auto parts = splitter(name, regex(`[.\-]+`)).array;
        ident = parts[0];
        foreach (p; parts[1 .. $])
            if (p.length)
                ident ~= capFirst(p);
    }
    else
        ident = name;
    if (!ident.length)
        ident = "value";
    if (isDigit(ident[0]))
        ident = "_" ~ ident;
    if (isKeyword(ident))
        ident ~= "_";
    return ident;
}

string camel(string name)
{
    if (!name.length)
        return name;
    const n = stride(name, 0);
    return toLower(name[0 .. n]) ~ name[n .. $];
}

/// `(text or "").strip().replace("\n", " ")` style description cleanup.
string oneLine(string s) { return s.strip.replace("\n", " "); }

// Set by load(): the bundled spec, for following deep JSON-pointer refs.
J SPEC;
enum COMPONENT_PREFIX = "#/components/schemas/";

/**
Component name a `$ref` resolves to.

The bundler can emit pointers *into* a component (e.g.
`#/components/schemas/X/allOf/0`) when dedup matched a nested member.
Follow those to the component they finally name, instead of taking the
last path segment (which would be `0`).
*/
string refName(J node)
{
    bool[string] seen;
    while (node !is null && node.isObj && node.get("$ref") !is null && node.get("$ref").isStr)
    {
        auto r = node.get("$ref").text;
        if (r in seen)
            die("cyclic $ref: " ~ r);
        seen[r] = true;
        if (!r.startsWith(COMPONENT_PREFIX))
            return r.split("/")[$ - 1];
        auto parts = r[COMPONENT_PREFIX.length .. $].split("/");
        if (parts.length == 1)
            return parts[0];
        J target = SPEC.get("components").get("schemas");
        foreach (part; parts)
        {
            part = part.replace("~1", "/").replace("~0", "~");
            target = target.isArr ? target.items[part.to!size_t] : target.fields[part];
        }
        if (!(target.isObj && target.has("$ref")))
            die("unsupported deep $ref to an inline schema: " ~ r);
        node = target;
    }
    return null;
}

/// If schema is `{allOf: [{$ref}]}` (optionally with type/description), return the ref.
string unwrapAllofRef(J schema)
{
    string[] refs;
    bool extras;
    foreach (p; itemsOf(schema.get("allOf")))
    {
        auto r = refName(p);
        if (r !is null)
            refs ~= r;
        else if (p.isObj && truthy(p))
            extras = true;
    }
    if (refs.length == 1 && !extras && !truthy(schema.get("properties")) && !truthy(schema.get("oneOf")))
        return refs[0];
    return null;
}

final class Spec
{
    J spec;
    J meta;
    J schemas;
    J[string] semantic;
    J[] operations;
    J[string] unions;
    bool[string] enumNames;
    bool[string] keyNames;

    this(J spec, J meta)
    {
        this.spec = spec;
        this.meta = meta;
        schemas = spec.get("components").get("schemas");
        if (schemas is null)
            schemas = J.obj();
        foreach (k; itemsOf(meta.get("semanticKeys")))
            semantic[k.get("name").text] = k;
        operations = itemsOf(meta.get("operations")).dup;
        foreach (u; itemsOf(meta.get("unions")))
            unions[u.get("name").text] = u;
        foreach (n; schemas.keys)
        {
            auto s = schemas.fields[n];
            if (s.isObj && s.has("enum") && s.get("enum").isArr)
                enumNames[n] = true;
        }
        // String schemas that are branded keys (semantic + format-named leftovers).
        foreach (n; semantic.keys)
            keyNames[n] = true;
        foreach (n; schemas.keys)
        {
            auto s = schemas.fields[n];
            if (!s.isObj)
                continue;
            if (pyStrOrNull(s.get("type")) == "string" && truthy(s.get("x-semantic-type")))
                keyNames[n] = true;
            if (n == "ResourceKey" || n == "ScopeKey" || n == "LongKey")
                keyNames[n] = true;
        }
    }

    J schema(string name)
    {
        auto s = schemas.get(name);
        return s !is null && s.isObj ? s : J.obj();
    }

    bool isEnum(string n) { return (n in enumNames) !is null; }
    bool isKey(string n) { return (n in keyNames) !is null; }
}

/// String value of a JSON string, or null for anything else.
string pyStrOrNull(J v) { return v !is null && v.isStr ? v.text : null; }

Spec load()
{
    if (!exists(SPEC_PATH) || !isFile(SPEC_PATH))
        die("missing bundled spec: " ~ SPEC_PATH);
    if (!exists(META_PATH) || !isFile(META_PATH))
        die("missing spec metadata: " ~ META_PATH);
    auto spec = parseJson(readText(SPEC_PATH));
    SPEC = spec;
    auto meta = parseJson(readText(META_PATH));
    return new Spec(spec, meta);
}

// ---------------------------------------------------------------------------
// 01 keys
// ---------------------------------------------------------------------------

enum KEYS_HEADER = `/// Generated by scripts/generate.d (hook 01) — DO NOT EDIT.
///
/// The Camunda Domain Type System: a distinct newtype for every semantic key
/// in the OpenAPI spec. Construct with ` ~ "`tryNew`" ~ ` (validates) or ` ~ "`assumeExists`" ~ `
/// (side-load). Serializes as its string value.
module camunda.generated.keys;

@safe:

import std.format : format;
import std.json : JSONValue, JSONType;
import std.regex : regex, matchFirst;

/// Error returned when a value does not satisfy a Camunda Domain Type.
class CamundaKeyError : Exception
{
    string typeName;
    this(string typeName, string message)
    {
        this.typeName = typeName;
        super(format("invalid %s: %s", typeName, message));
    }
}

private bool checkConstraints(string typeName, string value,
    string pattern, int minLength, int maxLength, bool throwOnFail)
{
    const len = cast(int) value.length;
    if (minLength >= 0 && len < minLength)
    {
        if (throwOnFail)
            throw new CamundaKeyError(typeName,
                format("length %s is shorter than minimum %s", len, minLength));
        return false;
    }
    if (maxLength >= 0 && len > maxLength)
    {
        if (throwOnFail)
            throw new CamundaKeyError(typeName,
                format("length %s exceeds maximum %s", len, maxLength));
        return false;
    }
    if (pattern.length)
    {
        auto re = regex(pattern);
        if (matchFirst(value, re).empty)
        {
            if (throwOnFail)
                throw new CamundaKeyError(typeName,
                    format("value %s does not match required pattern", value));
            return false;
        }
    }
    return true;
}

`;

/// `str(int(n))` for a JSON number literal.
string intText(J n) { return (cast(long) n.text.to!double).to!string; }

string renderKey(J key)
{
    const name = key.get("name").text;
    auto constraints = key.get("constraints").or(J.obj());
    const pattern = constraints.get("pattern").orS("");
    auto minLen = constraints.get("minLength");
    auto maxLen = constraints.get("maxLength");
    const desc = key.get("description").orS("").strip.replace("\r", " ").replace("\n", " ");
    auto examples = itemsOf(key.get("examples").or(J.arr(null)));
    J example = examples.length ? examples[0] : null;
    const minExpr = minLen !is null && minLen.kind != Kind.null_ ? intText(minLen) : "-1";
    const maxExpr = maxLen !is null && maxLen.kind != Kind.null_ ? intText(maxLen) : "-1";
    const patLit = dString(pattern);
    string[] lines;
    lines ~= "/// " ~ (desc.length ? desc : "Camunda domain type `" ~ name ~ "`.");
    if (example !is null && example.kind != Kind.null_)
        lines ~= "/// Example: `" ~ pyStr(example) ~ "`";
    lines ~= "struct " ~ name;
    lines ~= "{";
    lines ~= "    private string _value;";
    lines ~= "    enum semanticType = " ~ dString(name) ~ ";";
    lines ~= "    /// Construct without validation.";
    lines ~= "    static " ~ name ~ " assumeExists(string value) pure nothrow";
    lines ~= "    {";
    lines ~= "        " ~ name ~ " k;";
    lines ~= "        k._value = value;";
    lines ~= "        return k;";
    lines ~= "    }";
    lines ~= "    /// Construct with constraint validation.";
    lines ~= "    static " ~ name ~ " tryNew(string value)";
    lines ~= "    {";
    lines ~= "        checkConstraints(semanticType, value, " ~ patLit ~ ", " ~ minExpr ~ ", " ~ maxExpr ~ ", true);";
    lines ~= "        return assumeExists(value);";
    lines ~= "    }";
    lines ~= "    /// True if `value` satisfies this type's constraints.";
    lines ~= "    static bool isValid(string value)";
    lines ~= "    {";
    lines ~= "        return checkConstraints(semanticType, value, " ~ patLit ~ ", " ~ minExpr ~ ", " ~ maxExpr ~ ", false);";
    lines ~= "    }";
    lines ~= "    string value() const pure nothrow @nogc { return _value; }";
    lines ~= "    string toString() const pure nothrow @nogc { return _value; }";
    lines ~= "    bool opEquals(const {name} other) const pure nothrow @nogc { return _value == other._value; }";
    lines ~= "    bool isEmpty() const pure nothrow @nogc { return _value.length == 0; }";
    lines ~= "    static {name} fromJson(JSONValue v)";
    lines ~= "    {";
    lines ~= "        auto s = v.type == JSONType.string ? v.str : v.toString;";
    lines ~= "        return assumeExists(s);";
    lines ~= "    }";
    lines ~= "    JSONValue toJson() const { return JSONValue(_value); }";
    lines ~= "}";
    lines ~= "";
    return lines.join("\n").replace("{name}", name);
}

J extraStringKey(string name, J schema)
{
    auto k = J.obj();
    k.set("name", J.str(name));
    k.set("description", J.str(schema.get("description").orS("Camunda domain type `" ~ name ~ "`.").strip));
    auto c = J.obj();
    c.set("pattern", schema.get("pattern"));
    c.set("minLength", schema.get("minLength"));
    c.set("maxLength", schema.get("maxLength"));
    k.set("constraints", c);
    k.set("examples", J.arr(schema.has("example") ? [schema.get("example")] : null));
    return k;
}

J[] allKeys(Spec spec)
{
    auto keys = itemsOf(spec.meta.get("semanticKeys")).dup;
    bool[string] seen;
    foreach (k; keys)
        seen[k.get("name").text] = true;
    foreach (extra; ["ResourceKey", "ScopeKey", "LongKey"])
        if (extra !in seen && spec.schemas.has(extra))
        {
            keys ~= extraStringKey(extra, spec.schema(extra));
            seen[extra] = true;
        }
    return keys;
}

void hook01Keys(Spec spec)
{
    auto keys = allKeys(spec);
    const body = KEYS_HEADER ~ keys.map!renderKey.join("\n");
    const path = buildPath(OUT_DIR, "keys.d");
    write(path, body);
    log("01-keys", format("wrote %s (%s types)", rel(path), keys.length));
}

// ---------------------------------------------------------------------------
// 02 enums
// ---------------------------------------------------------------------------

enum ENUMS_HEADER = `/// Generated by scripts/generate.d (hook 02) — DO NOT EDIT.
module camunda.generated.enums;

@safe:

import std.format : format;
import std.json : JSONValue, JSONType;

class EnumDecodeError : Exception
{
    this(string typeName, string value)
    {
        super(format("unknown %s value: %s", typeName, value));
    }
}

`;

/// Unique D identifiers for enum values, in order (`CloudStage.int` -> `int_`).
string[] enumIdents(J[] values)
{
    bool[string] seen;
    string[] out_;
    foreach (v; values)
    {
        auto ident = dIdent(pyStr(v));
        const orig = ident;
        int n = 2;
        while (ident in seen)
            ident = orig ~ (n++).to!string;
        seen[ident] = true;
        out_ ~= ident;
    }
    return out_;
}

string renderEnum(string name, J schema)
{
    auto values = itemsOf(schema.get("enum"));
    const desc = oneLine(schema.get("description").orS(""));
    string[] lines = [desc.length ? "/// " ~ desc : "/// `" ~ name ~ "`"];
    lines ~= "enum " ~ name ~ " : string";
    lines ~= "{";
    auto idents = enumIdents(values);
    foreach (i, v; values)
        lines ~= "    " ~ idents[i] ~ " = " ~ dString(pyStr(v)) ~ ",";
    lines ~= "}";
    lines ~= "";
    lines ~= name ~ " parse" ~ name ~ "(string value)";
    lines ~= "{";
    lines ~= "    switch (value)";
    lines ~= "    {";
    foreach (i, v; values)
        lines ~= "    case " ~ dString(pyStr(v)) ~ ": return " ~ name ~ "." ~ idents[i] ~ ";";
    lines ~= "    default: throw new EnumDecodeError(" ~ dString(name) ~ ", value);";
    lines ~= "    }";
    lines ~= "}";
    lines ~= "";
    lines ~= name ~ " fromJson(" ~ name ~ ")(JSONValue v)";
    lines ~= "{";
    lines ~= "    return parse" ~ name ~ "(v.type == JSONType.string ? v.str : v.toString);";
    lines ~= "}";
    lines ~= "JSONValue toJson(" ~ name ~ " value) { return JSONValue(cast(string) value); }";
    lines ~= "";
    return lines.join("\n");
}

void hook02Enums(Spec spec)
{
    string[] chunks = [ENUMS_HEADER];
    auto names = spec.enumNames.keys.sort.array;
    foreach (name; names)
        chunks ~= renderEnum(name, spec.schema(name));
    const path = buildPath(OUT_DIR, "enums.d");
    write(path, chunks.join("\n"));
    log("02-enums", format("wrote %s (%s enums)", rel(path), names.length));
}

// ---------------------------------------------------------------------------
// 03 models
// ---------------------------------------------------------------------------

enum MODELS_HEADER = `/// Generated by scripts/generate.d (hook 03) — DO NOT EDIT.
///
/// JSON-backed request/response models. Each schema is a distinct D type so
/// you cannot pass a TopologyResponse where an ActivatedJobResult is expected.
/// Accessors read and write the underlying JSON object.
module camunda.generated.models;

@safe:

import camunda.generated.enums;
import camunda.generated.keys;
import camunda.jsonx;
import std.json;
import std.typecons : Nullable, nullable;

`;

string classify(Spec spec, string name)
{
    if (spec.isKey(name))
        return "key";
    if (spec.isEnum(name))
        return "enum";
    auto schema = spec.schema(name);
    if (!truthy(schema))
        return "unknown";
    if ((name in spec.unions) || truthy(schema.get("oneOf")) || truthy(schema.get("anyOf"))
        || truthy(schema.get("x-polymorphic-schema")))
        return "union";
    const t = pyStrOrNull(schema.get("type"));
    if (t == "array")
        return "array";
    if (t == "integer")
        return "integer";
    if (t == "string" && !schema.has("enum"))
    {
        // ExactMatch wrappers: allOf -> key/enum
        auto target = unwrapAllofRef(schema);
        if (target !is null)
            return "alias:" ~ target;
        return "string";
    }
    if (t == "boolean")
        return "boolean";
    if (t == "number")
        return "number";
    return "object";
}

string aliasTarget(string kind) { return kind[kind.indexOf(':') + 1 .. $]; }

/// Map an OpenAPI schema fragment to a D type used in accessors.
string dTypeForSchema(Spec spec, J schema)
{
    if (schema is null)
        schema = J.obj();
    auto r = refName(schema);
    if (r !is null)
    {
        const kind = classify(spec, r);
        if (kind == "key" || kind == "enum")
            return r;
        if (kind.startsWith("alias:"))
            return aliasTarget(kind);
        if (kind == "string")
            return "string";
        if (kind == "integer")
            return "long";
        if (kind == "array")
            return dTypeForSchema(spec, spec.schema(r).get("items").or(J.obj())) ~ "[]";
        return r; // object / union wrapper
    }
    if (schema.has("allOf"))
    {
        auto target = unwrapAllofRef(schema);
        if (target !is null)
        {
            auto refNode = J.obj();
            refNode.set("$ref", J.str(COMPONENT_PREFIX ~ target));
            return dTypeForSchema(spec, refNode);
        }
    }
    if (truthy(schema.get("oneOf")) || truthy(schema.get("anyOf")))
        return "JSONValue";
    const t = pyStrOrNull(schema.get("type"));
    if (t == "string")
        return "string";
    if (t == "integer")
        return pyStrOrNull(schema.get("format")) == "int64" ? "long" : "int";
    if (t == "number")
        return "double";
    if (t == "boolean")
        return "bool";
    if (t == "array")
        return dTypeForSchema(spec, schema.get("items").or(J.obj())) ~ "[]";
    return "JSONValue";
}

/// Insertion-ordered property map.
struct Props
{
    string[] names;
    J[string] map;

    void setDefault(string k, J v)
    {
        if (k !in map)
        {
            names ~= k;
            map[k] = v;
        }
    }

    void put(string k, J v)
    {
        if (k !in map)
            names ~= k;
        map[k] = v;
    }
}

/// Merge own properties with allOf parents (depth-first, own props win).
Props collectProperties(Spec spec, string name, J schema, ref bool[string] seen)
{
    Props props;
    if (name in seen)
        return props;
    seen[name] = true;
    foreach (part; itemsOf(schema.get("allOf")))
    {
        auto r = refName(part);
        if (r !is null)
        {
            auto parent = collectProperties(spec, r, spec.schema(r), seen);
            foreach (k; parent.names)
                props.setDefault(k, parent.map[k]);
        }
        else if (part.isObj)
        {
            auto own = part.get("properties");
            foreach (k; keysOf(own))
                props.setDefault(k, own.fields[k]);
            foreach (sub; itemsOf(part.get("allOf")))
            {
                auto r2 = refName(sub);
                if (r2 !is null)
                {
                    auto inner = collectProperties(spec, r2, spec.schema(r2), seen);
                    foreach (k; inner.names)
                        props.setDefault(k, inner.map[k]);
                }
            }
        }
    }
    auto own = schema.get("properties");
    foreach (k; keysOf(own))
        props.put(k, own.fields[k]);
    return props;
}

string accessorRead(Spec spec, string dty, string jsonKey)
{
    const lit = dString(jsonKey);
    switch (dty)
    {
    case "string": return "jsonGetString(raw, " ~ lit ~ ")";
    case "int": return "cast(int) jsonGetLong(raw, " ~ lit ~ ")";
    case "long": return "jsonGetLong(raw, " ~ lit ~ ")";
    case "double": return "jsonGetDouble(raw, " ~ lit ~ ")";
    case "bool": return "jsonGetBool(raw, " ~ lit ~ ")";
    case "JSONValue": return "jsonGet(raw, " ~ lit ~ ")";
    default: break;
    }
    if (dty.endsWith("[]"))
    {
        const inner = dty[0 .. $ - 2];
        switch (inner)
        {
        case "string": return "jsonGetStringArray(raw, " ~ lit ~ ")";
        case "int": return "jsonGetIntArray(raw, " ~ lit ~ ")";
        case "long": return "jsonGetLongArray(raw, " ~ lit ~ ")";
        case "JSONValue": return "jsonGetArray(raw, " ~ lit ~ ")";
        default: break;
        }
        // array of models / keys / enums
        if (spec.isEnum(inner))
            return "jsonMapArray(raw, " ~ lit ~ ", (JSONValue v) => parse" ~ inner
                ~ "(v.type == JSONType.string ? v.str : v.toString))";
        return "jsonMapArray(raw, " ~ lit ~ ", (JSONValue v) => " ~ inner ~ ".fromJson(v))";
    }
    // key, enum, or model
    if (spec.isEnum(dty))
        return "parse" ~ dty ~ "(jsonGetString(raw, " ~ lit ~ "))";
    return dty ~ ".fromJson(jsonGet(raw, " ~ lit ~ "))";
}

string accessorWrite(Spec spec, string dty, string jsonKey, string var = "value")
{
    const lit = dString(jsonKey);
    if (["string", "int", "long", "double", "bool", "JSONValue"].canFind(dty))
        return "jsonSet(raw, " ~ lit ~ ", JSONValue(" ~ var ~ "))";
    if (dty.endsWith("[]"))
    {
        const inner = dty[0 .. $ - 2];
        if (["string", "int", "long", "JSONValue"].canFind(inner))
            return "jsonSet(raw, " ~ lit ~ ", JSONValue(" ~ var ~ "))";
        if (spec.isEnum(inner))
            return "jsonSet(raw, " ~ lit ~ ", jsonFromMapped(" ~ var ~ ", (" ~ inner ~ " x) => JSONValue(cast(string) x)))";
        return "jsonSet(raw, " ~ lit ~ ", jsonFromMapped(" ~ var ~ ", (" ~ inner ~ " x) => x.toJson()))";
    }
    if (spec.isEnum(dty))
        return "jsonSet(raw, " ~ lit ~ ", JSONValue(cast(string) " ~ var ~ "))";
    return "jsonSet(raw, " ~ lit ~ ", " ~ var ~ ".toJson())";
}

string renderObjectModel(Spec spec, string name, J schema)
{
    const desc = oneLine(schema.get("description").orS("`" ~ name ~ "`"));
    bool[string] seen;
    auto props = collectProperties(spec, name, schema, seen);
    string[] lines = ["/// " ~ desc, "struct " ~ name, "{", "    JSONValue raw;", ""];
    lines ~= "    static " ~ name ~ " fromJson(JSONValue value)";
    lines ~= "    {";
    lines ~= "        " ~ name ~ " m;";
    lines ~= "        m.raw = value.type == JSONType.null_ ? emptyObject() : value;";
    lines ~= "        return m;";
    lines ~= "    }";
    lines ~= "    JSONValue toJson() const { return raw; }";
    lines ~= "    static " ~ name ~ " initEmpty()";
    lines ~= "    {";
    lines ~= "        " ~ name ~ " m;";
    lines ~= "        m.raw = emptyObject();";
    lines ~= "        return m;";
    lines ~= "    }";
    lines ~= "";
    bool[string] used;
    foreach (pname; props.names)
    {
        auto pschema = props.map[pname];
        auto ident = dIdent(pname);
        const orig = ident;
        int n = 2;
        while ((ident in used) || ident == "raw")
            ident = orig ~ (n++).to!string;
        used[ident] = true;
        const dty = dTypeForSchema(spec, pschema.isObj ? pschema : J.obj());
        const pdesc = pschema.isObj ? oneLine(pschema.get("description").orS("")) : "";
        if (pdesc.length)
            lines ~= "    /// " ~ pdesc;
        lines ~= "    bool has_" ~ ident ~ "() const { return jsonHas(raw, " ~ dString(pname) ~ "); }";
        lines ~= "    " ~ dty ~ " " ~ ident ~ "() const { return " ~ accessorRead(spec, dty, pname) ~ "; }";
        lines ~= "    ref " ~ name ~ " " ~ ident ~ "(" ~ dty ~ " value) return";
        lines ~= "    {";
        lines ~= "        " ~ accessorWrite(spec, dty, pname) ~ ";";
        lines ~= "        return this;";
        lines ~= "    }";
        lines ~= "";
    }
    lines ~= "}";
    lines ~= "";
    return lines.join("\n");
}

string renderUnionModel(Spec spec, string name, J schema)
{
    const desc = oneLine(schema.get("description").orS("`" ~ name ~ "`"));
    string[] branches;
    foreach (part; itemsOf(schema.get("oneOf").or(schema.get("anyOf"))))
    {
        auto r = refName(part);
        if (r !is null)
            branches ~= r;
    }
    auto disc = pyStrOrNull(schema.get("discriminator").get("propertyName"));
    string[] lines = ["/// " ~ desc, "struct " ~ name, "{", "    JSONValue raw;", ""];
    lines ~= "    static " ~ name ~ " fromJson(JSONValue value)";
    lines ~= "    {";
    lines ~= "        " ~ name ~ " m; m.raw = value; return m;";
    lines ~= "    }";
    lines ~= "    JSONValue toJson() const { return raw; }";
    // hybrid unions also accept a raw scalar
    lines ~= "    static " ~ name ~ " of(JSONValue value) { return fromJson(value); }";
    foreach (b; branches)
    {
        const kind = classify(spec, b);
        if (kind == "key" || kind == "enum" || kind == "object" || kind == "union" || kind.startsWith("alias:"))
        {
            const tname = kind.startsWith("alias:") ? aliasTarget(kind) : b;
            lines ~= "    static " ~ name ~ " from" ~ tname ~ "(" ~ tname ~ " value)";
            lines ~= "    {";
            lines ~= "        return fromJson(value.toJson());";
            lines ~= "    }";
        }
        else if (kind == "string")
            lines ~= "    static " ~ name ~ " fromString(string value) { return fromJson(JSONValue(value)); }";
        else if (kind == "integer")
            lines ~= "    static " ~ name ~ " fromInt(long value) { return fromJson(JSONValue(value)); }";
    }
    if (disc.length)
        lines ~= "    string discriminator() const { return jsonGetString(raw, " ~ dString(disc) ~ "); }";
    // hybrid: also allow constructing from a string (exact match)
    if (auto metaU = name in spec.unions)
        if (pyStrOrNull((*metaU).get("kind")) == "hybrid-union")
        {
            lines ~= "    static " ~ name ~ " exactString(string value) { return fromJson(JSONValue(value)); }";
            lines ~= "    static " ~ name ~ " exactInt(long value) { return fromJson(JSONValue(value)); }";
        }
    lines ~= "}";
    lines ~= "";
    return lines.join("\n");
}

string renderAlias(string name, string target)
{
    return "/// Alias of `" ~ target ~ "`.\nalias " ~ name ~ " = " ~ target ~ ";\n\n";
}

string renderStringModel(string name, J schema)
{
    const desc = oneLine(schema.get("description").orS("`" ~ name ~ "`"));
    return "/// " ~ desc ~ "\n"
        ~ "struct " ~ name ~ "\n"
        ~ "{\n"
        ~ "    string value;\n"
        ~ "    static " ~ name ~ " fromJson(JSONValue v) { " ~ name
        ~ " m; m.value = v.type == JSONType.string ? v.str : v.toString; return m; }\n"
        ~ "    JSONValue toJson() const { return JSONValue(value); }\n"
        ~ "    string toString() const { return value; }\n"
        ~ "}\n\n";
}

string renderIntegerModel(string name, J schema)
{
    const desc = oneLine(schema.get("description").orS("`" ~ name ~ "`"));
    const dty = pyStrOrNull(schema.get("format")) == "int64" ? "long" : "int";
    return "/// " ~ desc ~ "\n"
        ~ "struct " ~ name ~ "\n"
        ~ "{\n"
        ~ "    " ~ dty ~ " value;\n"
        ~ "    static " ~ name ~ " fromJson(JSONValue v) { " ~ name ~ " m; m.value = cast(" ~ dty
        ~ ") jsonValueLong(v); return m; }\n"
        ~ "    JSONValue toJson() const { return JSONValue(value); }\n"
        ~ "}\n\n";
}

void hook03Models(Spec spec)
{
    string[] chunks = [MODELS_HEADER];
    bool[string] emitted;
    foreach (k; spec.keyNames.keys)
        emitted[k] = true;
    foreach (k; spec.enumNames.keys)
        emitted[k] = true;
    int count;
    foreach (name; spec.schemas.keys.dup.sort)
    {
        if (name in emitted)
            continue;
        const kind = classify(spec, name);
        auto schema = spec.schema(name);
        if (kind.startsWith("alias:"))
            chunks ~= renderAlias(name, aliasTarget(kind));
        else if (kind == "string")
            chunks ~= renderStringModel(name, schema);
        else if (kind == "integer")
            chunks ~= renderIntegerModel(name, schema);
        else if (kind == "union")
            chunks ~= renderUnionModel(spec, name, schema);
        else if (kind == "array")
            // Rare top-level array schema: wrap as JSONValue model
            chunks ~= renderStringModel(name, schema)
                .replace("string value", "JSONValue raw")
                .replace("m.value = v.type == JSONType.string ? v.str : v.toString", "m.raw = v")
                .replace("JSONValue(value)", "raw")
                .replace("return value", "return raw.toString");
        else if (kind == "boolean" || kind == "number")
            chunks ~= renderStringModel(name, schema);
        else
            chunks ~= renderObjectModel(spec, name, schema);
        emitted[name] = true;
        count++;
    }
    const path = buildPath(OUT_DIR, "models.d");
    write(path, chunks.join(""));
    log("03-models", format("wrote %s (%s schemas)", rel(path), count));
}

// ---------------------------------------------------------------------------
// 04 operations
// ---------------------------------------------------------------------------

enum OPS_HEADER = `/// Generated by scripts/generate.d (hook 04) — DO NOT EDIT.
///
/// One method per REST operation, mixed into ` ~ "`CamundaClient`" ~ `. Every call goes
/// through ` ~ "`requestJson` / `requestVoid` / `requestBytes`" ~ ` (auth, retry,
/// backpressure).
module camunda.generated.operations;

@safe:

import camunda.generated.enums;
import camunda.generated.keys;
import camunda.generated.models;
import camunda.jsonx;
import std.json;

`;

/// Build a D expression that interpolates path params into `path`.
string pathExpr(string path)
{
    // path like /jobs/{jobKey}/completion; split into literal / param pieces.
    string[] bits;
    size_t last = 0;
    bool any;
    foreach (m; matchAll(path, ctRegex!`\{([^}]+)\}`))
    {
        any = true;
        const lit = path[last .. m.pre.length];
        if (lit.length)
            bits ~= dString(lit);
        bits ~= "encodeComponent(" ~ dIdent(m[1]) ~ "Path)";
        last = m.pre.length + m.hit.length;
    }
    if (!any)
        return dString(path);
    if (last < path.length)
        bits ~= dString(path[last .. $]);
    return bits.length ? bits.join(" ~ ") : dString("/");
}

struct Success
{
    string type; // null for void
    string kind; // json | bytes | text | void | array
}

string opMethod(J op) { return op.get("method").orS("get"); }

/// The OpenAPI operation object for a metadata operation (or an empty object).
J specOperation(Spec spec, J op, out J item)
{
    item = spec.spec.get("paths").get(op.get("path").orS(null)).or(J.obj());
    return item.get(opMethod(op).toLower).or(J.obj());
}

Success opSuccessSchema(Spec spec, J op)
{
    auto statusJ = op.get("successStatus");
    const status = truthy(statusJ) ? pyStr(statusJ) : "200";
    if (status == "204")
        return Success(null, "void");
    auto r = op.get("successResponseSchemaRef").orS(null);
    // camunda-schema-bundler <=2.4.5 records the last pointer segment for deep
    // refs (e.g. "0" for #/components/schemas/X/allOf/0). Trust the metadata
    // only when it names a real component; otherwise resolve from the spec.
    if (r !is null && !spec.schemas.has(r))
        r = null;
    if (r !is null)
    {
        const kind = classify(spec, r);
        if (kind.startsWith("alias:"))
            return Success(aliasTarget(kind), "json");
        return Success(r, "json");
    }
    // Fall back to the OpenAPI document.
    J item;
    auto operation = specOperation(spec, op, item);
    auto responses = operation.get("responses").or(J.obj());
    auto resp = responses.get(status).or(responses.get("default")).or(J.obj());
    if (resp.has("$ref"))
        resp = J.obj(); // skip unresolved
    auto content = resp.get("content").or(J.obj());
    if (content.has("application/octet-stream"))
        return Success("immutable(ubyte)[]", "bytes");
    if (content.has("text/xml") || content.has("text/plain"))
        return Success("string", "text");
    auto app = content.get("application/json").or(J.obj());
    auto schema = app.get("schema").or(J.obj());
    const t = pyStrOrNull(schema.get("type"));
    if (t == "array")
        return Success(dTypeForSchema(spec, schema.get("items").or(J.obj())) ~ "[]", "array");
    if (t == "object" && !truthy(schema.get("properties")) && truthy(schema.get("additionalProperties")))
        return Success("JSONValue", "json");
    auto r2 = refName(schema);
    if (r2 !is null)
        return Success(r2, "json");
    if (!truthy(content))
        return Success(null, "void");
    return Success("JSONValue", "json");
}

/// Path part of the first server URL (`{schema}://{host}:{port}/v2` -> `/v2`).
string serverPath(J servers)
{
    if (!truthy(servers))
        return null;
    auto url = servers.items[0].get("url").orS("");
    const sep = url.indexOf("://");
    const rest = sep >= 0 ? url[sep + 3 .. $] : url;
    const i = rest.indexOf('/');
    return i < 0 ? "" : rest[i .. $].stripRight("/");
}

/// `, ServerBase.root` when the operation (or its path) declares the bare-root
/// server instead of the top-level `/v2` one (cluster-admin ops, #6).
string opServerArg(Spec spec, J op)
{
    J item;
    auto operation = specOperation(spec, op, item);
    const own = serverPath(operation.get("servers").or(item.get("servers")));
    auto top = serverPath(spec.spec.get("servers"));
    if (!top.length)
        top = "";
    if (own is null || own == top)
        return "";
    if (own == "")
        return ", ServerBase.root";
    die(format("unsupported server path '%s' for %s (top-level '%s')", own, op.get("operationId").orS(""), top));
}

/// "opt" / "req" for a body schema with a tenantId property, else null.
/// oneOf/anyOf is "opt" only when every variant has an optional tenantId.
string tenantKind(Spec spec, J schema, int depth = 0)
{
    auto comps = spec.spec.get("components").get("schemas").or(J.obj());
    while (schema !is null && schema.isObj && schema.has("$ref") && depth < 32)
    {
        const r = schema.get("$ref").text;
        if (!r.startsWith(COMPONENT_PREFIX))
            return null;
        schema = comps.get(r.split("/")[$ - 1]).or(J.obj());
        depth++;
    }
    if (schema is null || !schema.isObj)
        return null;
    auto variants = schema.get("oneOf").or(schema.get("anyOf"));
    if (truthy(variants))
        return variants.items.all!(v => tenantKind(spec, v, depth + 1) == "opt") ? "opt" : null;
    bool hasProp, required;
    bool[string] req;
    foreach (r; itemsOf(schema.get("required")))
        req[pyStr(r)] = true;
    foreach (part; itemsOf(schema.get("allOf")))
    {
        while (part !is null && part.isObj && part.has("$ref"))
            part = comps.get(part.get("$ref").text.split("/")[$ - 1]).or(J.obj());
        if (part.get("properties").has("tenantId"))
            hasProp = true;
        foreach (r; itemsOf(part.get("required")))
            req[pyStr(r)] = true;
    }
    if (schema.get("properties").has("tenantId"))
        hasProp = true;
    if (!hasProp)
        return null;
    return ("tenantId" in req) ? "req" : "opt";
}

/// JSON request body with an optional tenantId: the configured default
/// tenant is filled in when the caller leaves it unset (#8).
bool injectsDefaultTenant(Spec spec, J op)
{
    J item;
    auto operation = specOperation(spec, op, item);
    auto content = operation.get("requestBody").get("content").get("application/json");
    return truthy(content) && tenantKind(spec, content.get("schema").or(J.obj())) == "opt";
}

/// Key type for a path parameter whose capitalised name is a semantic key.
string pathKeyType(Spec spec, string p)
{
    const cand = capFirst(p);
    return spec.isKey(cand) ? cand : null;
}

bool isMultipart(J op)
{
    foreach (c; itemsOf(op.get("requestBodyContentTypes")))
        if (pyStr(c).canFind("multipart"))
            return true;
    return false;
}

/// D type of a JSON request body argument.
string bodyType(Spec spec, string bodyRef)
{
    const kind = classify(spec, bodyRef);
    if (kind == "string" || kind == "integer")
        return "JSONValue";
    return kind.startsWith("alias:") ? aliasTarget(kind) : bodyRef;
}

struct QueryParam
{
    string name, ident;
    bool required;
}

QueryParam[] queryParams(J op)
{
    QueryParam[] qs;
    foreach (q; itemsOf(op.get("queryParams")))
    {
        const qn = q.isObj ? q.get("name").text : pyStr(q);
        const required = q.isObj ? truthy(q.get("required")) : false;
        qs ~= QueryParam(qn, dIdent(qn), required);
    }
    return qs;
}

string renderOperation(Spec spec, J op)
{
    const opId = op.get("operationId").text;
    const method = opMethod(op).toUpper;
    const path = op.get("path").orS("/");
    const summary = oneLine(op.get("summary").or(op.get("description")).orS(opId));
    const fn = curatedName(opId);
    auto pathParams = itemsOf(op.get("pathParams")).map!(p => p.text).array;
    const hasBody = truthy(op.get("hasRequestBody"));
    const bodyRef = op.get("requestBodySchemaRef").orS(null);
    const multipart = isMultipart(op);
    auto ret = opSuccessSchema(spec, op);

    string[] args;
    string[] prelude;
    foreach (p; pathParams)
    {
        const ident = dIdent(p);
        // Prefer semantic key type when the name matches
        const keyType = pathKeyType(spec, p);
        if (keyType !is null)
        {
            args ~= keyType ~ " " ~ ident;
            prelude ~= "    const " ~ ident ~ "Path = " ~ ident ~ ".value;";
        }
        else
        {
            args ~= "string " ~ ident;
            prelude ~= "    const " ~ ident ~ "Path = " ~ ident ~ ";";
        }
    }

    string bodyArg;
    if (hasBody && !multipart)
    {
        if (bodyRef !is null)
        {
            const bty = bodyType(spec, bodyRef);
            args ~= bty ~ " body_ = " ~ bty ~ ".init";
            bodyArg = "body_.toJson()";
        }
        else
        {
            args ~= "JSONValue body_ = JSONValue.init";
            bodyArg = "body_";
        }
    }
    else if (multipart)
    {
        args ~= "JSONValue body_ = JSONValue.init";
        bodyArg = "body_";
    }

    auto qnames = queryParams(op);
    foreach (q; qnames)
        args ~= q.required ? "string " ~ q.ident : "string " ~ q.ident ~ " = null";

    const sigArgs = args.join(", ");
    const retTy = ret.type !is null ? ret.type : "void";
    if (multipart)
    {
        auto curated = opId in MULTIPART_CURATED;
        if (curated is null)
            die("multipart operation " ~ opId
                ~ " has no hand-written method; add it to MULTIPART_CURATED and CamundaClient");
        const msg = opId ~ " is multipart/form-data: use CamundaClient." ~ *curated ~ "(...)";
        return [
            "    /// " ~ summary ~ " (`" ~ method ~ " " ~ path ~ "`). Multipart: use `" ~ *curated ~ "`.",
            "    deprecated(" ~ dString(msg) ~ ")",
            "    " ~ retTy ~ " " ~ fn ~ "(" ~ sigArgs ~ ")",
            "    {",
            "        throw new ConfigException(" ~ dString(msg) ~ ");",
            "    }",
            "",
        ].join("\n");
    }
    string[] lines = [
        "    /// " ~ summary ~ " (`" ~ method ~ " " ~ path ~ "`).",
        "    " ~ retTy ~ " " ~ fn ~ "(" ~ sigArgs ~ ")",
        "    {",
    ];
    lines ~= prelude;
    lines ~= "        const path_ = " ~ pathExpr(path) ~ ";";
    string queryE;
    if (qnames.length)
    {
        lines ~= "        string[string] query;";
        foreach (q; qnames)
            lines ~= q.required
                ? "        query[" ~ dString(q.name) ~ "] = " ~ q.ident ~ ";"
                : "        if (" ~ q.ident ~ " !is null) query[" ~ dString(q.name) ~ "] = " ~ q.ident ~ ";";
        queryE = "query";
    }
    else
        queryE = "null";

    string bodyE = bodyArg !is null ? bodyArg : "JSONValue.init";
    if (bodyArg !is null && injectsDefaultTenant(spec, op))
        bodyE = "this.withDefaultTenant(" ~ bodyE ~ ")";
    const serverE = opServerArg(spec, op);
    const tail = dString(method) ~ ", path_, " ~ bodyE ~ ", " ~ queryE ~ serverE ~ ");";

    switch (ret.kind)
    {
    case "void":
        lines ~= "        this.requestVoid(" ~ tail;
        break;
    case "bytes":
        lines ~= "        return this.requestBytes(" ~ tail;
        break;
    case "text":
        lines ~= "        return this.requestText(" ~ tail;
        break;
    case "array":
    {
        const inner = (ret.type !is null ? ret.type : "JSONValue[]")[0 .. $ - 2];
        lines ~= "        auto payload = this.requestJson(" ~ tail;
        if (inner == "JSONValue")
            lines ~= "        return jsonAsArray(payload);";
        else if (inner == "string")
            lines ~= "        return jsonArrayOfString(payload);";
        else
            lines ~= "        return jsonMapValues(payload, (JSONValue v) => " ~ inner ~ ".fromJson(v));";
        break;
    }
    default:
        // json object / key / enum / JSONValue
        lines ~= "        auto payload = this.requestJson(" ~ tail;
        if (ret.type == "JSONValue")
            lines ~= "        return payload;";
        else
            lines ~= "        return " ~ ret.type ~ ".fromJson(payload);";
    }
    lines ~= "    }";
    lines ~= "";
    return lines.join("\n");
}

void hook04Operations(Spec spec)
{
    auto methods = spec.operations.map!(op => renderOperation(spec, op)).array;
    const body = OPS_HEADER
        ~ "mixin template GeneratedOperations()\n{\n"
        ~ "    import std.uri : encodeComponent;\n\n"
        ~ methods.join("\n")
        ~ "}\n";
    const path = buildPath(OUT_DIR, "operations.d");
    write(path, body);
    log("04-operations", format("wrote %s (%s operations)", rel(path), spec.operations.length));
}

// ---------------------------------------------------------------------------
// 05 package
// ---------------------------------------------------------------------------

void hook05Package(Spec spec)
{
    const specHash = spec.meta.get("specHash").orS("");
    const body = "/// Generated by scripts/generate.d (hook 05) — DO NOT EDIT.
module camunda.generated;

@safe:

public import camunda.generated.keys;
public import camunda.generated.enums;
public import camunda.generated.models;
public import camunda.generated.operations;

/// SHA-256 of the bundled OpenAPI spec this tree was generated from.
enum generatedSpecHash = " ~ dString(specHash) ~ ";

/// Number of REST operations in the generated facade.
enum generatedOperationCount = " ~ spec.operations.length.to!string ~ ";
";
    const path = buildPath(OUT_DIR, "package.d");
    write(path, body);
    log("05-package", "wrote " ~ rel(path));
}

// ---------------------------------------------------------------------------
// 06 markdown docs
// ---------------------------------------------------------------------------

string mdEscape(string text) { return text.replace("|", "\\|").replace("\n", " ").strip; }

/// Operations grouped by first tag, in first-seen order within each group.
J[][string] opsByTag(Spec spec)
{
    J[][string] byTag;
    foreach (op; spec.operations)
    {
        auto tags = itemsOf(op.get("tags"));
        const tag = tags.length ? tags[0].text : "Untagged";
        byTag[tag] ~= op;
    }
    return byTag;
}

/// The "Length" column for a semantic type.
string lengthCell(J constraints)
{
    auto minLen = constraints.get("minLength");
    auto maxLen = constraints.get("maxLength");
    const hasMin = minLen !is null && minLen.kind != Kind.null_;
    const hasMax = maxLen !is null && maxLen.kind != Kind.null_;
    if (hasMin && hasMax)
        return minLen.text ~ "–" ~ maxLen.text;
    if (hasMax)
        return "≤ " ~ maxLen.text;
    if (hasMin)
        return "≥ " ~ minLen.text;
    return "—";
}

void hook06Docs(Spec spec)
{
    mkdirRecurse(DOCS_DIR);
    auto byTag = opsByTag(spec);
    string[] lines = [
        "# API Reference",
        "",
        format("> %s operations across %s API groups. ", spec.operations.length, byTag.length)
            ~ "Generated by `scripts/generate.d` (hook 06). Do not edit by hand.",
        "",
        "Every REST operation is a method on `CamundaClient` (mixed in from "
            ~ "`camunda.generated.operations`). Curated wrappers (`topology`, "
            ~ "`deployResources`) sit on top of the generated names.",
        "",
        "```d",
        "auto client = CamundaClient.fromEnv();",
        "auto topology = client.topology();",
        "auto page = client.searchProcessInstances(ProcessInstanceSearchQuery.initEmpty());",
        "```",
        "",
    ];
    foreach (tag; byTag.keys.sort)
    {
        lines ~= "## " ~ tag;
        lines ~= "";
        lines ~= "| Method | HTTP | Path |";
        lines ~= "| --- | --- | --- |";
        foreach (op; byTag[tag])
        {
            const name = curatedName(op.get("operationId").text);
            const summary = mdEscape(op.get("summary").orS(""));
            auto cell = "`" ~ name ~ "()`";
            if (summary.length)
                cell ~= " — " ~ summary;
            lines ~= "| " ~ cell ~ " | `" ~ opMethod(op).toUpper ~ "` | `" ~ op.get("path").orS("/") ~ "` |";
        }
        lines ~= "";
    }
    const apiPath = buildPath(DOCS_DIR, "api-reference.md");
    write(apiPath, lines.join("\n"));
    log("06-docs", format("wrote %s (%s operations)", rel(apiPath), spec.operations.length));

    string[] sem = [
        "# Semantic Types",
        "",
        "> Generated by `scripts/generate.d` (hook 06). Do not edit by hand.",
        "",
        "Each identifier is a distinct D struct in `camunda.generated.keys`. "
            ~ "Construct with `tryNew` (validates) or `assumeExists` (side-load). "
            ~ "All expose `.value` and serialize as their string.",
        "",
        "| Type | Pattern | Length | Description |",
        "| --- | --- | --- | --- |",
    ];
    auto keys = allKeys(spec);
    foreach (key; keys)
    {
        auto constraints = key.get("constraints").or(J.obj());
        auto pattern = constraints.get("pattern");
        const pat = truthy(pattern) ? "`" ~ pyStr(pattern) ~ "`" : "—";
        const desc = mdEscape(key.get("description").orS(""));
        sem ~= "| `" ~ key.get("name").text ~ "` | " ~ pat ~ " | " ~ lengthCell(constraints) ~ " | " ~ desc ~ " |";
    }
    sem ~= "";
    const semPath = buildPath(DOCS_DIR, "semantic-types.md");
    write(semPath, sem.join("\n"));
    log("06-docs", format("wrote %s (%s types)", rel(semPath), keys.length));
}

// ---------------------------------------------------------------------------
// 07 per-tag examples + operation-map
// ---------------------------------------------------------------------------

immutable HAND_WRITTEN_EXAMPLES = ["readme.d", "topology.d", "operation-map.json"];

string tagToFilename(string tag)
{
    auto slug = replaceAll(tag.toLower, regex(`[^a-z0-9]+`), "_").strip("_");
    return slug ~ ".d";
}

string snakeIdent(string name)
{
    auto s = replaceAll(name, regex(`([a-z0-9])([A-Z])`), "$1_$2");
    s = replaceAll(s, regex(`[^a-zA-Z0-9]+`), "_");
    s = s.toLower.strip("_");
    if (isKeyword(s) || isDigit(s[0]))
        s ~= "_";
    return s;
}

/// (param_decls, call_args) for a generated operation.
void exampleCallArgs(Spec spec, J op, out string[] decls, out string[] args)
{
    foreach (pj; itemsOf(op.get("pathParams")))
    {
        const p = pj.text;
        const ident = dIdent(p);
        const keyType = pathKeyType(spec, p);
        decls ~= (keyType !is null ? keyType : "string") ~ " " ~ ident;
        args ~= ident;
    }
    const hasBody = truthy(op.get("hasRequestBody"));
    const multipart = isMultipart(op);
    const bodyRef = op.get("requestBodySchemaRef").orS(null);
    if (hasBody && !multipart)
    {
        decls ~= (bodyRef !is null ? bodyType(spec, bodyRef) : "JSONValue") ~ " body_";
        args ~= "body_";
    }
    else if (multipart)
    {
        decls ~= "JSONValue body_";
        args ~= "body_";
    }
    foreach (q; queryParams(op))
    {
        decls ~= "string " ~ q.ident ~ (q.required ? "" : " = null");
        args ~= q.ident;
    }
}

string renderExampleFn(Spec spec, J op)
{
    const opId = op.get("operationId").text;
    const fn = curatedName(opId);
    const region = capFirst(opId);
    const summary = oneLine(op.get("summary").orS(opId));
    const method = opMethod(op).toUpper;
    const path = op.get("path").orS("/");
    if (auto ex = opId in MULTIPART_EXAMPLES)
        return [
            "// region " ~ region,
            "/// " ~ summary ~ " (`" ~ method ~ " " ~ path ~ "`).",
            "void " ~ snakeIdent(opId) ~ "(CamundaClient client, " ~ (*ex)[0] ~ ")",
            "{",
            "    auto result = " ~ (*ex)[1] ~ ";",
            "    cast(void) result;",
            "}",
            "// endregion " ~ region,
            "",
        ].join("\n");
    string[] decls, callArgs;
    exampleCallArgs(spec, op, decls, callArgs);
    const paramList = (["CamundaClient client"] ~ decls).join(", ");
    const call = "client." ~ fn ~ "(" ~ callArgs.join(", ") ~ ")";
    auto ret = opSuccessSchema(spec, op);
    string[] lines = [
        "// region " ~ region,
        "/// " ~ summary ~ " (`" ~ method ~ " " ~ path ~ "`).",
        "void " ~ snakeIdent(opId) ~ "(" ~ paramList ~ ")",
        "{",
    ];
    if (ret.kind == "void")
        lines ~= "    " ~ call ~ ";";
    else
    {
        lines ~= "    auto result = " ~ call ~ ";";
        lines ~= "    cast(void) result;";
    }
    lines ~= ["}", "// endregion " ~ region, ""];
    return lines.join("\n");
}

struct MapEntry
{
    string file, region, label;
}

/// `json.dumps(op_map, indent=2, sort_keys=True)`.
string renderOperationMap(MapEntry[string] opMap)
{
    string[] blocks;
    foreach (opId; opMap.keys.sort)
    {
        const e = opMap[opId];
        blocks ~= "  " ~ jsonQuote(opId, true) ~ ": [\n"
            ~ "    {\n"
            ~ "      \"file\": " ~ jsonQuote(e.file, true) ~ ",\n"
            ~ "      \"label\": " ~ jsonQuote(e.label, true) ~ ",\n"
            ~ "      \"region\": " ~ jsonQuote(e.region, true) ~ "\n"
            ~ "    }\n"
            ~ "  ]";
    }
    return blocks.length ? "{\n" ~ blocks.join(",\n") ~ "\n}" : "{}";
}

void hook07Examples(Spec spec)
{
    const examplesDir = buildPath(ROOT, "examples");
    mkdirRecurse(examplesDir);
    auto byTag = opsByTag(spec);
    bool[string] wantedFiles;
    MapEntry[string] opMap;

    foreach (tag; byTag.keys.sort)
    {
        auto ops = byTag[tag];
        const filename = tagToFilename(tag);
        wantedFiles[filename] = true;
        auto module_ = filename[0 .. $ - 2];
        if (isKeyword(module_))
            module_ ~= "_";
        string[] chunks = [
            "/+ dub.sdl:",
            `name "example-` ~ module_ ~ `"`,
            `dependency "camunda-orchestration-sdk" path=".."`,
            "+/",
            "/// Compilable usage examples for " ~ tag ~ " operations.",
            "/// Generated by scripts/generate.d (hook 07) — DO NOT EDIT.",
            "module example_" ~ module_ ~ ";",
            "",
            "import camunda;",
            "import std.json;",
            "",
        ];
        foreach (op; ops)
        {
            chunks ~= renderExampleFn(spec, op);
            const opId = op.get("operationId").text;
            opMap[opId] = MapEntry(filename, capFirst(opId), op.get("summary").orS(opId).strip);
        }
        chunks ~= "void main() {}";
        chunks ~= "";
        const path = buildPath(examplesDir, filename);
        write(path, chunks.join("\n"));
        log("07-examples", format("wrote %s (%s regions)", rel(path), ops.length));
    }

    // Remove stale generated example files (keep hand-written ones).
    foreach (existing; dirEntries(examplesDir, "*.d", SpanMode.shallow).map!(e => e.name).array.sort)
    {
        const name = baseName(existing);
        if (HAND_WRITTEN_EXAMPLES.canFind(name) || (name in wantedFiles))
            continue;
        remove(existing);
        log("07-examples", "removed stale " ~ rel(existing));
    }

    const mapPath = buildPath(examplesDir, "operation-map.json");
    write(mapPath, renderOperationMap(opMap) ~ "\n");
    log("07-examples", format("wrote %s (%s operations)", rel(mapPath), opMap.length));
}

int main()
{
    auto spec = load();
    mkdirRecurse(OUT_DIR);
    writeln(format("generate: %s schemas, %s operations, %s semantic keys",
        spec.schemas.keys.length, spec.operations.length, spec.semantic.length));
    hook01Keys(spec);
    hook02Enums(spec);
    hook03Models(spec);
    hook04Operations(spec);
    hook05Package(spec);
    hook06Docs(spec);
    hook07Examples(spec);
    writeln("generate: done");
    return 0;
}
