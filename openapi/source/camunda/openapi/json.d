/**
Order-preserving JSON reading for untrusted OpenAPI documents.

`std.json` stores objects in associative arrays, which lose the key order the
generator relies on for properties and operations. This module keeps object
keys in document order (`J.keys`) and is hardened for untrusted input:

  * nesting depth is bounded (`Limits.maxDepth`);
  * the document size is bounded (`Limits.maxBytes`);
  * every failure is an `OpenApiException` carrying a JSON-pointer path;
  * there is no process exit and no unbounded recursion.
*/
module camunda.openapi.json;

@safe:

import std.array : appender;
import std.conv : to;
import std.format : format;
import std.utf : decode, UTFException;

import camunda.openapi.errors : OpenApiException, OpenApiLimitException;

enum Kind { null_, bool_, number, string_, array, object }

/// Reader limits. Defaults are generous enough for the bundled Camunda spec
/// yet small enough to reject pathological documents.
struct Limits
{
    /// Maximum nesting depth of arrays/objects.
    size_t maxDepth = 200;
    /// Maximum input size in bytes.
    size_t maxBytes = 64 * 1024 * 1024;
    /// Maximum `$ref` chain length followed during resolution.
    size_t maxRefChain = 100;
}

/// A JSON value with document-ordered object keys.
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
        throw new OpenApiException("unexpected container where a scalar was expected");
    }
}

J[] itemsOf(J v) { return v !is null && v.isArr ? v.items : null; }
string[] keysOf(J v) { return v !is null && v.isObj ? v.keys : null; }

/// String value of a JSON string, or null for anything else.
string pyStrOrNull(J v) { return v !is null && v.isStr ? v.text : null; }

/// Escape a single path segment as an RFC 6901 JSON-pointer token.
string pointerEscape(string segment)
{
    import std.array : replace;
    return segment.replace("~", "~0").replace("/", "~1");
}

/// Unescape an RFC 6901 JSON-pointer token (`~1` -> `/`, `~0` -> `~`).
string pointerUnescape(string segment)
{
    import std.array : replace;
    return segment.replace("~1", "/").replace("~0", "~");
}

/**
Percent-decode a URI fragment (RFC 3986) so it can be read as an RFC 6901
JSON pointer. Malformed escapes and non-UTF-8 results are typed errors.
*/
string fragmentDecode(string fragment)
{
    import std.utf : validate, UTFException;
    static int hex(char c)
    {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return -1;
    }
    char[] o;
    for (size_t i = 0; i < fragment.length; i++)
    {
        if (fragment[i] != '%')
        {
            o ~= fragment[i];
            continue;
        }
        if (i + 2 >= fragment.length || hex(fragment[i + 1]) < 0 || hex(fragment[i + 2]) < 0)
            throw new OpenApiException("malformed percent-encoding in $ref: " ~ fragment, fragment);
        o ~= cast(char)(hex(fragment[i + 1]) * 16 + hex(fragment[i + 2]));
        i += 2;
    }
    string r = o.idup;
    try
        validate(r);
    catch (UTFException)
        throw new OpenApiException("$ref is not valid UTF-8 after percent-decoding: " ~ fragment, fragment);
    return r;
}

struct Parser
{
    string s;
    size_t i;
    Limits limits;
    string path = "#"; // JSON-pointer of the value being read

    void ws()
    {
        while (i < s.length && (s[i] == ' ' || s[i] == '\n' || s[i] == '\r' || s[i] == '\t'))
            i++;
    }

    noreturn fail(string what)
    {
        throw new OpenApiException(format("JSON: %s at offset %s", what, i), path);
    }

    char peek()
    {
        if (i >= s.length)
            fail("unexpected end");
        return s[i];
    }

    J literal(string word, Kind k, bool b = false)
    {
        if (s.length - i < word.length || s[i .. i + word.length] != word)
            fail("invalid literal");
        i += word.length;
        auto n = new J(k);
        n.boolean = b;
        return n;
    }

    bool isDigit(size_t at) const { return at < s.length && s[at] >= '0' && s[at] <= '9'; }

    /// Strict RFC 8259 number: -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?
    J number()
    {
        const start = i;
        if (i < s.length && s[i] == '-')
            i++;
        if (!isDigit(i))
            fail("invalid number");
        if (s[i] == '0')
        {
            i++;
            if (isDigit(i))
                fail("invalid number (leading zero)");
        }
        else
            while (isDigit(i))
                i++;
        if (i < s.length && s[i] == '.')
        {
            i++;
            if (!isDigit(i))
                fail("invalid number (fraction)");
            while (isDigit(i))
                i++;
        }
        if (i < s.length && (s[i] == 'e' || s[i] == 'E'))
        {
            i++;
            if (i < s.length && (s[i] == '+' || s[i] == '-'))
                i++;
            if (!isDigit(i))
                fail("invalid number (exponent)");
            while (isDigit(i))
                i++;
        }
        auto n = new J(Kind.number);
        n.text = s[start .. i];
        return n;
    }

    void expect(char c)
    {
        if (i >= s.length || s[i] != c)
            fail("expected '" ~ c ~ "'");
        i++;
    }

    J value(size_t depth)
    {
        if (depth > limits.maxDepth)
            throw new OpenApiLimitException(
                format("JSON: nesting deeper than %s", limits.maxDepth), path);
        ws();
        if (i >= s.length)
            fail("unexpected end");
        switch (s[i])
        {
        case '{':
        {
            i++;
            auto o = J.obj();
            const objPath = path;
            ws();
            if (peek() == '}') { i++; return o; }
            for (;;)
            {
                ws();
                auto k = str();
                ws();
                expect(':');
                path = objPath ~ "/" ~ pointerEscape(k);
                o.set(k, value(depth + 1));
                path = objPath;
                ws();
                if (peek() == ',') { i++; continue; }
                expect('}');
                return o;
            }
        }
        case '[':
        {
            i++;
            auto a = new J(Kind.array);
            const arrPath = path;
            ws();
            if (peek() == ']') { i++; return a; }
            size_t index = 0;
            for (;;)
            {
                path = arrPath ~ "/" ~ index.to!string;
                a.items ~= value(depth + 1);
                path = arrPath;
                index++;
                ws();
                if (peek() == ',') { i++; continue; }
                expect(']');
                return a;
            }
        }
        case '"':
            return J.str(str());
        case 't': return literal("true", Kind.bool_, true);
        case 'f': return literal("false", Kind.bool_);
        case 'n': return literal("null", Kind.null_);
        case '-': case '0': .. case '9':
            return number();
        default:
            fail("unexpected character");
        }
    }

    uint hex4()
    {
        if (s.length - i < 4)
            fail("truncated \\u escape");
        uint v;
        foreach (ch; s[i .. i + 4])
        {
            if (!((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F')))
                fail("invalid \\u escape");
        }
        v = s[i .. i + 4].to!uint(16);
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
            if (c < 0x20)
                fail("unescaped control character in string");
            if (c >= 0x80)
            {
                // Validate the multibyte sequence; reject invalid UTF-8.
                size_t at = i - 1;
                try
                    decode(s, at);
                catch (UTFException)
                    fail("invalid UTF-8 in string");
                buf.put(s[i - 1 .. at]);
                i = at;
                continue;
            }
            if (c != '\\')
            {
                buf.put(c);
                continue;
            }
            if (i >= s.length)
                fail("unterminated string");
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
                if (cp >= 0xDC00 && cp < 0xE000)
                    fail("unpaired low surrogate");
                if (cp >= 0xD800 && cp < 0xDC00)
                {
                    if (!(i + 6 <= s.length && s[i] == '\\' && s[i + 1] == 'u'))
                        fail("unpaired high surrogate");
                    i += 2;
                    const lo = hex4();
                    if (lo < 0xDC00 || lo >= 0xE000)
                        fail("high surrogate not followed by low surrogate");
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                }
                buf.put(cp);
                break;
            default: fail("bad escape");
            }
        }
    }
}

unittest
{
    import std.exception : assertThrown;
    foreach (bad; ["truX", "tru", "fals", "nul", "nulx", "01", "+1", "-", "1.", ".5", "1e", "1e+",
            "--1", "1.2.3", "[1,", "{\"a\":1", "[", "{", "\"\\u12\"", "\"\\uZZZZ\"", "\"\\", "x",
            "\"a\nb\"", "\"a\tb\"", "\"a\x00b\"", `"\uD800\u0041"`, `"\uD800"`, `"\uDC00"`])
        assertThrown!OpenApiException(parseJson(bad), bad);
    assert(parseJson("true").boolean && !parseJson("false").boolean);
    assert(parseJson("null").kind == Kind.null_);
    foreach (ok; ["0", "-0", "10", "-1.5e+3", "2E-2", "0.25"])
        assert(parseJson(ok).text == ok, ok);
    assert(parseJson(`{"a":[1,true,null]}`).isObj);
    assert(parseJson(`"a\nb\t"`).text == "a\nb\t");
    assert(parseJson(`"\uD83D\uDE00"`).text == "\U0001F600");
}

/// Parse a JSON document, preserving object key order.
///
/// Throws `OpenApiException` (or a subclass) on malformed input or when a
/// reader limit is exceeded; never exits the process and never recurses
/// without a bound.
J parseJson(string text, Limits limits = Limits.init)
{
    if (text.length > limits.maxBytes)
        throw new OpenApiLimitException(
            format("JSON: document of %s bytes exceeds the %s-byte limit",
                text.length, limits.maxBytes));
    auto p = Parser(text, 0, limits);
    auto v = p.value(0);
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
