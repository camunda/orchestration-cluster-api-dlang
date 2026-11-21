/+ dub.sdl:
name "api-compat"
targetPath ".dub/bin"
+/
/**
Public-API compatibility checker for the D SDK.

Extracts the public API of the `camunda` packages (the root package, `:runtime`
and `:openapi`) as data with `ldc2 -X` and compares a baseline against the
current tree. It reports changes that can stop customer code from compiling:

  - a public/protected/export symbol (module, aggregate, function, variable,
    alias, enum, enum member, template) removed or renamed, or made less visible
  - a function overload with a changed signature: parameter types/order, return
    type, `ref`/`scope`/`return` storage, or a removed default argument
  - narrowed function attributes: dropped `@safe`/`@trusted`, `pure`, `nothrow`
    or `@nogc` (adding them is fine)
  - a changed enum member value, enum base type, variable/field type or alias
  - a reordered or removed public struct/union field (positional struct
    literals depend on the order); appending fields is fine
  - a changed template parameter list, or a dropped base class / interface

Additions are not breaks.

Usage (run from the repository root; `make api-compat` wraps the first form):

  dub run -q --single scripts/api-compat.d -- --baseline-dir DIR [--repo DIR]
      Compare the API in --repo (default: .) with the API in DIR (a checkout of
      the baseline). Exit 0: compatible, 1: breaking changes, 2: error.

  dub run -q --single scripts/api-compat.d -- --print-baseline-major N [--repo DIR]
      Print the newest published N.x.y release (no prerelease) tagged in the
      git repository DIR, without the leading `v`; print nothing if none.

  dub run -q --single scripts/api-compat.d -- --dump [--repo DIR]
      Print the normalised API (debugging aid).

Unit tests: dub run -q --build=unittest --single scripts/api-compat.d -- --DRT-testmode=test-only
*/
module api_compat;

import std.algorithm : all, any, canFind, filter, map, sort, startsWith;
import std.array : array, join, replace;
import std.conv : to;
import std.file : exists, isDir, dirEntries, SpanMode, readText, tempDir, mkdirRecurse, rmdirRecurse, write;
import std.format : format;
import std.json : JSONValue, JSONType, parseJSON;
import std.path : buildPath, absolutePath;
import std.process : execute;
import std.regex : matchFirst, ctRegex;
import std.stdio : writeln, stderr;
import std.string : strip, splitLines;

/// Source roots compiled separately (they mirror the dub sub-packages).
/// Each group is `[sourceRoots...]`; every group sees all roots as imports.
immutable string[][] sourceGroups = [
    ["source", "runtime/source"],
    ["openapi/source"],
];
immutable string[] importRoots = ["source", "runtime/source", "openapi/source"];

/// One normalised public symbol.
struct Sym
{
    string kind;        /// function, variable, struct, enum, enum member, …
    string path;        /// fully qualified, e.g. camunda.client.CamundaClient.fromEnv
    string protection;  /// public, protected, export
    string[] overloads; /// functions/constructors/templates: one signature each
    string type;        /// variables, aliases, enum base type
    string value;       /// enum members
    string[] fields;    /// structs/unions: public instance fields in layout order
    string[] bases;     /// classes/interfaces: base class + interfaces
    string[string] display; /// overload signature -> source-like text for messages
}

alias Api = Sym[string]; // key: "<kind> <path>"

string keyOf(string kind, string path) => kind ~ " " ~ path;

// ---------------------------------------------------------------- extraction

/// Normalise the JSON produced by `ldc2 -X` (an array of modules).
Api normalise(JSONValue modules)
{
    Api api;
    foreach (m; modules.array)
    {
        const name = str(m, "name");
        if (name.length == 0)
            continue;
        add(api, Sym("module", name, "public"));
        if (auto mem = "members" in m)
            walk(api, name, *mem, "module");
    }
    return api;
}

private string str(JSONValue v, string field)
{
    if (auto p = field in v)
        if (p.type == JSONType.string)
            return p.str;
    return "";
}

private void add(ref Api api, Sym s)
{
    const k = keyOf(s.kind, s.path);
    if (auto existing = k in api)
    {
        existing.overloads ~= s.overloads;
        foreach (k2, v; s.display)
            existing.display[k2] = v;
        return;
    }
    api[k] = s;
}

private bool visible(string protection)
{
    return protection == "" || protection == "public" || protection == "protected"
        || protection == "export";
}

/// Signature of one function/constructor overload. With semantic info the
/// mangled type (`deco`) is exact; template members only carry source text.
/// A trailing `|defaults=` mask records which parameters have defaults.
private string signature(JSONValue f)
{
    string mask;
    string text = str(f, "type");
    if (auto ps = "parameters" in f)
        foreach (p; ps.array)
        {
            const d = str(p, "default");
            mask ~= d.length ? "1" : "0";
            if (d.length)
                text = text.replace(" = " ~ d, "");
        }
    auto core = str(f, "deco");
    if (core.length == 0)
        core = "text:" ~ (text.length ? text : str(f, "originalType"));
    return core ~ "|defaults=" ~ mask;
}

private void walk(ref Api api, string parent, JSONValue members, string parentKind)
{
    string[] fieldOrder;
    long[] fieldOffsets;
    foreach (m; members.array)
    {
        const kind = str(m, "kind");
        const name = str(m, "name");
        const prot = str(m, "protection");
        if (kind == "import" || kind == "static import" || kind == "mixin")
            continue;
        if (!visible(prot))
            continue;
        // Anonymous enums put their members in the enclosing scope.
        if (kind == "enum" && name.length == 0)
        {
            if (auto mem = "members" in m)
                walk(api, parent, *mem, parentKind);
            continue;
        }
        if (name.length == 0 || name.startsWith("__"))
            continue;
        const path = parent ~ "." ~ name;
        Sym s = Sym(kind, path, prot.length ? prot : "public");
        switch (kind)
        {
        case "function", "constructor":
            s.overloads = [signature(m)];
            {
                auto shown = str(m, "originalType");
                if (!shown.length)
                    shown = str(m, "type");
                if (!shown.length)
                {
                    string[] ps;
                    if (auto params = "parameters" in m)
                        foreach (p; params.array)
                            ps ~= str(p, "name");
                    shown = "(" ~ ps.join(", ") ~ ") [" ~ str(m, "deco") ~ "]";
                }
                s.display[s.overloads[0]] = name ~ " " ~ shown;
            }
            break;
        case "template":
            string[] ps;
            if (auto tp = "parameters" in m)
                foreach (p; tp.array)
                    ps ~= str(p, "kind") ~ ":" ~ str(p, "name") ~ ":" ~ str(p, "type")
                        ~ ":" ~ str(p, "deco") ~ ":" ~ (("default" in p) ? "d" : "");
            s.overloads = [ps.join(",")];
            break;
        case "variable":
            s.type = str(m, "deco").length ? str(m, "deco") : str(m, "originalType");
            if (auto off = "offset" in m)
            {
                fieldOrder ~= name;
                fieldOffsets ~= off.integer;
            }
            break;
        case "alias":
            s.type = str(m, "deco").length ? str(m, "deco") : str(m, "originalType");
            break;
        case "enum":
            s.type = str(m, "baseDeco");
            break;
        case "enum member":
            s.value = str(m, "value");
            break;
        case "class", "interface":
            if (str(m, "base").length)
                s.bases ~= str(m, "base");
            if (auto ifs = "interfaces" in m)
                foreach (i; ifs.array)
                    s.bases ~= i.str;
            break;
        default:
            break;
        }
        add(api, s);
        if (auto mem = "members" in m)
            walk(api, path, *mem, kind);
    }
    if (parentKind == "struct" || parentKind == "union")
    {
        auto idx = new size_t[fieldOrder.length];
        foreach (i, ref x; idx)
            x = i;
        // Stable: union members share offset 0 and keep source order.
        import std.algorithm : sort, SwapStrategy;
        idx.sort!((a, b) => fieldOffsets[a] < fieldOffsets[b], SwapStrategy.stable);
        if (auto p = keyOf(parentKind, parent) in api)
            p.fields = idx.map!(i => fieldOrder[i]).array;
    }
}

/// Run `ldc2 -X` over the source roots that exist under `repo`.
Api extract(string repo, string compiler = "ldc2")
{
    repo = absolutePath(repo);
    string[] imports;
    foreach (r; importRoots)
        if (exists(buildPath(repo, r)))
            imports ~= "-I" ~ buildPath(repo, r);
    const tmp = buildPath(tempDir, format("api-compat-%s", randomSuffix()));
    mkdirRecurse(tmp);
    scope (exit)
        rmdirRecurse(tmp);
    Api api;
    foreach (gi, group; sourceGroups)
    {
        string[] files;
        foreach (root; group)
        {
            const dir = buildPath(repo, root);
            if (!exists(dir) || !isDir(dir))
                continue;
            foreach (e; dirEntries(dir, "*.d", SpanMode.depth))
                files ~= e.name;
        }
        if (!files.length)
            continue;
        files.sort();
        const json = buildPath(tmp, format("api-%s.json", gi));
        auto r = execute([compiler, "-o-", "-X", "-Xf=" ~ json,
            "-preview=dip1000", "-preview=nosharedaccess"] ~ imports ~ files);
        if (r.status != 0)
            throw new Exception(format("%s -X failed in %s:\n%s", compiler, repo, r.output));
        foreach (k, v; normalise(parseJSON(readText(json))))
            api[k] = v;
    }
    if (!api.length)
        throw new Exception("no D sources found under " ~ repo);
    return api;
}

private string randomSuffix()
{
    import std.random : uniform;
    import std.process : thisProcessID;
    return format("%s-%s", thisProcessID, uniform(0, uint.max));
}

// ---------------------------------------------------------------- comparison

private immutable string[] attrCodes = ["Na", "Nb", "Nc", "Nd", "Ne", "Nf", "Ni", "Nj", "Nl", "Nm", "Nn"];

/// Split a function deco into (prefix, attribute set, rest). Returns false
/// if the deco is not a function type.
private bool splitFuncDeco(string deco, out string prefix, out string[] attrs, out string rest)
{
    size_t i;
    while (i < deco.length)
    {
        if (deco[i] == 'x' || deco[i] == 'y' || deco[i] == 'O')
            i++;
        else if (i + 1 < deco.length && deco[i .. i + 2] == "Ng")
            i += 2;
        else
            break;
    }
    if (i >= deco.length || !"FUWRY".canFind(deco[i]))
        return false;
    i++;
    prefix = deco[0 .. i];
    while (i + 1 < deco.length && attrCodes.canFind(deco[i .. i + 2]))
    {
        attrs ~= deco[i .. i + 2];
        i += 2;
    }
    rest = deco[i .. $];
    return true;
}

/// Can callers of `old` keep calling `neu` unchanged?
bool overloadCompatible(string old, string neu)
{
    import std.string : lastIndexOf;
    const oi = old.lastIndexOf("|defaults=");
    const ni = neu.lastIndexOf("|defaults=");
    const oCore = old[0 .. oi], nCore = neu[0 .. ni];
    const oMask = old[oi + 10 .. $], nMask = neu[ni + 10 .. $];
    if (oMask.length != nMask.length)
        return false;
    foreach (i; 0 .. oMask.length)
        if (oMask[i] == '1' && nMask[i] != '1')
            return false; // a default argument was removed
    if (oCore == nCore)
        return true;
    string op, orest, np, nrest;
    string[] oa, na;
    if (!splitFuncDeco(oCore, op, oa, orest) || !splitFuncDeco(nCore, np, na, nrest))
        return false;
    if (op != np || orest != nrest)
        return false;
    // Guarantees callers may rely on must not be dropped.
    foreach (g; ["Na", "Nb", "Ni"])
        if (oa.canFind(g) && !na.canFind(g))
            return false;
    const oSafe = oa.canFind("Nf") || oa.canFind("Ne");
    const nSafe = na.canFind("Nf") || na.canFind("Ne");
    if (oSafe && !nSafe)
        return false;
    // These change how a call is written or what callers may do with it.
    foreach (g; ["Nc", "Nd"])
        if (oa.canFind(g) != na.canFind(g))
            return false;
    if (oa.canFind("Nl") && !na.canFind("Nl"))
        return false; // `scope` this dropped
    if (!oa.canFind("Nj") && na.canFind("Nj"))
        return false; // `return` this added
    return true;
}

/// Human-readable form of a signature for messages.
private string show(string sig)
{
    import std.string : lastIndexOf;
    auto s = sig[0 .. sig.lastIndexOf("|defaults=")];
    return s.startsWith("text:") ? s[5 .. $] : s;
}

/// All breaking changes from `old` to `neu`, sorted.
string[] compare(Api old, Api neu)
{
    string[] out_;
    void brk(string path, string what)
    {
        out_ ~= format("BREAK %s: %s", path, what);
    }

    foreach (k, o; old)
    {
        auto np = k in neu;
        if (np is null)
        {
            brk(o.path, format("%s removed", o.kind));
            continue;
        }
        auto n = *np;
        if (o.protection != n.protection && !(o.protection == "protected"
                && n.protection != "protected"))
            brk(o.path, format("visibility narrowed from %s to %s", o.protection, n.protection));
        switch (o.kind)
        {
        case "function", "constructor":
            foreach (ov; o.overloads)
                if (!n.overloads.any!(nv => overloadCompatible(ov, nv)))
                    brk(o.path, format("%s overload `%s` changed or removed", o.kind,
                            (ov in o.display) ? o.display[ov] : show(ov)));
            break;
        case "template":
            foreach (ov; o.overloads)
                if (!n.overloads.canFind(ov))
                    brk(o.path, format("template parameters `%s` changed", ov));
            break;
        case "variable", "alias":
            if (o.type != n.type)
                brk(o.path, format("type changed from `%s` to `%s`", o.type, n.type));
            break;
        case "enum":
            if (o.type != n.type)
                brk(o.path, format("base type changed from `%s` to `%s`", o.type, n.type));
            break;
        case "enum member":
            if (o.value != n.value)
                brk(o.path, format("value changed from %s to %s", o.value, n.value));
            break;
        case "struct", "union":
            if (o.fields.length > n.fields.length || n.fields[0 .. o.fields.length] != o.fields)
                brk(o.path, format("public field layout changed from (%s) to (%s)",
                        o.fields.join(", "), n.fields.join(", ")));
            break;
        case "class", "interface":
            foreach (b; o.bases)
                if (!n.bases.canFind(b))
                    brk(o.path, format("no longer derives from %s", b));
            break;
        default:
            break;
        }
    }
    out_.sort();
    return out_;
}

// ---------------------------------------------------------------- baselines

/// Newest `vN.x.y` tag (no prerelease) among `tags`, without the `v`.
string newestRelease(string[] tags, string major)
{
    import std.algorithm : maxElement;
    auto re = ctRegex!`^v(\d+)\.(\d+)\.(\d+)$`;
    int[3][] found;
    foreach (t; tags)
    {
        auto c = matchFirst(t.strip, re);
        if (!c.empty && c[1] == major)
            found ~= [c[1].to!int, c[2].to!int, c[3].to!int];
    }
    if (!found.length)
        return "";
    auto best = found.maxElement!(a => cast(long) a[1] * 1_000_000 + a[2]);
    return format("%s.%s.%s", best[0], best[1], best[2]);
}

// ---------------------------------------------------------------- main

int main(string[] args)
{
    string baselineDir, repo = ".", major, compiler = "ldc2";
    bool dump;
    for (size_t i = 1; i < args.length; i++)
    {
        string next()
        {
            if (i + 1 >= args.length)
                throw new Exception(args[i] ~ " needs a value");
            return args[++i];
        }

        switch (args[i])
        {
        case "--baseline-dir": baselineDir = next(); break;
        case "--repo": repo = next(); break;
        case "--print-baseline-major": major = next(); break;
        case "--compiler": compiler = next(); break;
        case "--dump": dump = true; break;
        default:
            stderr.writeln("api-compat: unknown argument ", args[i]);
            return 2;
        }
    }
    try
    {
        if (major.length)
        {
            auto r = execute(["git", "-C", repo, "tag", "--list", "v" ~ major ~ ".*"]);
            if (r.status != 0)
                throw new Exception("git tag failed: " ~ r.output);
            const v = newestRelease(r.output.splitLines, major);
            if (v.length)
                writeln(v);
            return 0;
        }
        if (dump)
        {
            auto api = extract(repo, compiler);
            foreach (k; api.keys.sort)
                writeln(k, " ", api[k].overloads, api[k].type, api[k].value, api[k].fields);
            return 0;
        }
        if (!baselineDir.length)
        {
            stderr.writeln("api-compat: need --baseline-dir, --print-baseline-major or --dump");
            return 2;
        }
        auto breaks = compare(extract(baselineDir, compiler), extract(repo, compiler));
        foreach (b; breaks)
            writeln(b);
        if (breaks.length)
        {
            writeln(format("%s breaking API change(s) compared with %s.", breaks.length, baselineDir));
            return 1;
        }
        writeln("No breaking API changes.");
        return 0;
    }
    catch (Exception e)
    {
        stderr.writeln("api-compat: ", e.msg);
        return 2;
    }
}

// ---------------------------------------------------------------- tests

version (unittest)
{
    /// Compile a one-module `camunda.t` before/after pair and compare.
    string[] diff(string before, string after)
    {
        Api ex(string src)
        {
            const dir = buildPath(tempDir, format("api-compat-test-%s", randomSuffix()));
            mkdirRecurse(buildPath(dir, "source", "camunda"));
            scope (exit)
                rmdirRecurse(dir);
            write(buildPath(dir, "source", "camunda", "t.d"), "module camunda.t;\n" ~ src);
            return extract(dir);
        }

        return compare(ex(before), ex(after));
    }

    bool has(string[] breaks, string needle)
    {
        return breaks.any!(b => b.canFind(needle));
    }
}

unittest // no break: identical, additions, widened attributes, added defaults
{
    enum before = q{
        struct S { int a; int b; void m() {} }
        enum E { x, y }
        int f(int a, string b) { return a; }
        class C { this(int) {} }
        alias A = int;
        template T(X) { alias T = X; }
    };
    enum after = q{
        struct S { int a; int b; int c; void m() {} void m2() {} }
        enum E { x, y, z }
        int f(int a, string b = "") pure nothrow @safe @nogc { return a; }
        int f(double) { return 0; }
        int g() { return 1; }
        class C { this(int) {} this() {} }
        alias A = int;
        template T(X) { alias T = X; }
        private int hidden;
    };
    assert(diff(before, before) == [], diff(before, before).join("\n"));
    auto d = diff(before, after);
    assert(d == [], d.join("\n"));
}

unittest // removed and renamed symbols
{
    auto d = diff(q{ int f() { return 0; } struct S {} }, q{ int g() { return 0; } });
    assert(has(d, "camunda.t.f: function removed"), d.join("\n"));
    assert(has(d, "camunda.t.S: struct removed"), d.join("\n"));
}

unittest // symbol made private
{
    auto d = diff(q{ int f() { return 0; } }, q{ private int f() { return 0; } });
    assert(has(d, "camunda.t.f: function removed"), d.join("\n"));
}

unittest // changed parameter type, parameter order, return type
{
    assert(has(diff(q{ void f(int) {} }, q{ void f(long) {} }), "camunda.t.f: function overload"));
    assert(has(diff(q{ void f(int, string) {} }, q{ void f(string, int) {} }), "camunda.t.f"));
    assert(has(diff(q{ int f() { return 0; } }, q{ long f() { return 0; } }), "camunda.t.f"));
    assert(has(diff(q{ void f(int) {} }, q{ void f(ref int) {} }), "camunda.t.f"));
}

unittest // removed default argument
{
    assert(has(diff(q{ void f(int a = 1) {} }, q{ void f(int a) {} }), "camunda.t.f"));
}

unittest // narrowed attributes
{
    assert(has(diff(q{ void f() @safe {} }, q{ void f() @system {} }), "camunda.t.f"));
    assert(has(diff(q{ void f() nothrow {} }, q{ void f() {} }), "camunda.t.f"));
    assert(has(diff(q{ void f() pure {} }, q{ void f() {} }), "camunda.t.f"));
    assert(has(diff(q{ void f() @nogc {} }, q{ void f() {} }), "camunda.t.f"));
    // @safe -> @trusted is still callable from @safe code.
    assert(diff(q{ void f() @safe {} }, q{ void f() @trusted {} }) == []);
}

unittest // removed enum member, changed value, changed base type
{
    assert(has(diff(q{ enum E { x, y } }, q{ enum E { x } }), "camunda.t.E.y: enum member removed"));
    assert(has(diff(q{ enum E { x = 1 } }, q{ enum E { x = 2 } }), "camunda.t.E.x: value changed"));
    assert(has(diff(q{ enum E : int { x } }, q{ enum E : long { x } }), "camunda.t.E: base type"));
}

unittest // struct / class layout
{
    assert(has(diff(q{ struct S { int a; int b; } }, q{ struct S { int b; int a; } }),
            "camunda.t.S: public field layout"));
    assert(has(diff(q{ struct S { int a; } }, q{ struct S { long a; } }), "camunda.t.S.a: type changed"));
    assert(has(diff(q{ struct S { int a; } }, q{ class S { int a; } }), "camunda.t.S: struct removed"));
    assert(has(diff(q{ interface I {} class C : I {} }, q{ interface I {} class C {} }),
            "camunda.t.C: no longer derives"));
}

unittest // aliases and templates
{
    assert(has(diff(q{ alias A = int; }, q{ alias A = long; }), "camunda.t.A: type changed"));
    assert(has(diff(q{ template T(X) { enum T = 1; } }, q{ template T(X, Y) { enum T = 1; } }),
            "camunda.t.T: template parameters"));
    // Template members (e.g. the generated operations mixin) carry source text only.
    assert(has(diff(q{ mixin template M() { void op(int a) {} } },
            q{ mixin template M() { void op(string a) {} } }), "camunda.t.M.op"));
    assert(diff(q{ mixin template M() { void op(int a) {} } },
            q{ mixin template M() { void op(int a = 0) {} } }) == []);
}

unittest // baseline selection ignores prereleases and other majors
{
    assert(newestRelease(["v11.0.0-alpha.9", "v8.8.0"], "11") == "");
    assert(newestRelease(["v11.0.0", "v11.2.0", "v11.10.1", "v11.10.0-rc.1", "v12.0.0"], "11") == "11.10.1");
}
