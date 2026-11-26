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
    (the generated spec hash/operation count and the release-stamped version
    constants are exempt: their values intentionally change on regeneration
    and release)
  - a reordered or removed public struct/union field (positional struct
    literals depend on the order); appending fields is fine
  - a changed template parameter list, specialisation or constraint, or a
    removed template default (adding one is fine)
  - a dropped base class / interface, a class made `final` or `abstract`, or
    a new abstract (required) member on an existing interface or class
  - a public import that no longer re-exports a name, or a removed `mixin`
    invocation (which drops the members it mixed in)

The host target and Windows (`x86_64-windows-msvc`) are both compared, so
`version (Windows)` declarations are covered.

Additions are not breaks.

Usage (run from the repository root; `make api-compat` wraps the first form):

  dub run -q --single scripts/api-compat.d -- --baseline-dir DIR [--repo DIR]
      Compare the API in --repo (default: .) with the API in DIR (a checkout of
      the baseline). Exit 0: compatible, 1: breaking changes, 2: error.

      Breaks listed in the suppressions file (default:
      <repo>/api-compat-suppressions.txt, override with --suppressions FILE)
      are approved: they are printed as `APPROVED ...` and do not fail.

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
import std.regex : matchAll, matchFirst, ctRegex;
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
    string[] modifiers; /// classes: `final` / `abstract`
    string[] required;  /// interfaces/classes: abstract members (name + signature)
    string[string] display; /// overload signature -> source-like text for messages
    string[string] overloadProtection; /// overload signature -> its own visibility
    bool overridable;   /// functions: a non-final class/interface method a subclass may override
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
            {
            const file = str(m, "file");
            const src = file.length && exists(file) ? readText(file) : "";
            walk(api, name, *mem, "module", src);
        }
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
        existing.overridable |= s.overridable; // conservative across overloads
        foreach (k2, v; s.overloadProtection)
            if (auto cur = k2 in existing.overloadProtection)
            {
                // Identical signatures: the most visible declaration counts.
                if (visRank(v) > visRank(*cur))
                    *cur = v;
            }
            else
                existing.overloadProtection[k2] = v;
        foreach (k2, v; s.display)
            existing.display[k2] = v;
        return;
    }
    api[k] = s;
}

/// Visibility ordering: public/export > protected.
private int visRank(string protection)
{
    return protection == "protected" ? 1 : 2;
}

private bool visible(string protection)
{
    return protection == "" || protection == "public" || protection == "protected"
        || protection == "export";
}

/// The word characters D identifiers (and mangle codes) are made of.
private bool isWordChar(char c)
{
    return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9');
}

/// Strip the parameter name that trails a type in a parameter list. A name
/// is the last word of a parameter, preceded by whitespace and by a type
/// token in the same parameter; storage classes (`ref`, `const`, ...) are
/// not types, so `ref int` keeps `int`. Words glued to type punctuation
/// (`int[]`, `void delegate()`, `int[3]`) are part of the type, and an
/// unnamed parameter (`void(int, long)`) keeps its type. The last word
/// before `=` (a default) is always the name.
private string stripParamNames(string s)
{
    import std.algorithm.searching : canFind;

    static immutable storageClasses = ["ref", "out", "in", "lazy", "scope",
        "return", "const", "immutable", "shared", "inout", "auto", "final"];
    string outp;
    size_t wordStart;
    size_t wordEnd;
    bool inWord;
    bool spaceBefore; // whitespace directly before the current word
    bool typeSeen; // a type token precedes the current word in its parameter
    int depth;
    bool lastSpace;
    foreach (i, c; s)
    {
        const boundary = depth == 1 && (c == ',' || c == '=');
        if (isWordChar(c))
        {
            if (!inWord)
            {
                wordStart = i;
                inWord = true;
                spaceBefore = lastSpace;
            }
            wordEnd = i + 1;
        }
        if (inWord && (!isWordChar(c) || boundary))
        {
            const word = s[wordStart .. wordEnd];
            // A `)` that closes a nested type (`void delegate()`) never
            // ends a name; only the parameter list's own `)` does.
            const closesParam = c == ')' && depth == 1
                && (i + 1 >= s.length || s[i + 1] == ' ' || s[i + 1] == ',');
            const ends = c == ',' || closesParam;
            const isName = depth == 1
                && (c == '=' || (ends && spaceBefore && typeSeen));
            if (!isName)
                outp ~= word;
            if (depth >= 1 && !storageClasses.canFind(word))
                typeSeen = true;
            inWord = false;
        }
        else if (depth >= 1 && !isWordChar(c) && c != ' ' && c != ','
            && c != '(' && c != ')')
            typeSeen = true;
        if (boundary || !inWord)
            outp ~= c;
        if (c == '(' || c == '[')
        {
            depth++;
            if (depth == 1)
                typeSeen = false;
        }
        else if (c == ')' || c == ']')
            depth--;
        if (depth == 1 && c == ',')
            typeSeen = false;
        lastSpace = c == ' ';
    }
    if (inWord)
        outp ~= s[wordStart .. wordEnd];
    return outp;
}

/// Remove `= default` expressions at the top level of a parameter list, so
/// a changed default value is not a signature change (its availability is
/// tracked in the `|defaults=` mask).
private string stripDefaults(string s)
{
    string outp;
    int depth;
    bool skipping;
    char quote = 0; // open literal delimiter inside a skipped default, or 0
    bool escaped;
    foreach (c; s)
    {
        if (skipping)
        {
            // Delimiters, commas and parens inside a string or character
            // literal (`"a,b)"`, `','`, `` `x,y` ``) are not syntax.
            if (quote)
            {
                if (escaped)
                    escaped = false;
                else if (c == '\\' && quote != '`')
                    escaped = true;
                else if (c == quote)
                    quote = 0;
                continue;
            }
            if (c == '"' || c == '\'' || c == '`')
            {
                quote = c;
                continue;
            }
            if (c == '(' || c == '[' || c == '{')
                depth++;
            else if (c == ')' || c == ']' || c == '}')
                depth--;
            // The default runs to the next parameter or to the closing `)`
            // of the parameter list, which must be kept.
            if (depth == 1 && c == ',')
            {
                skipping = false;
                outp ~= c;
            }
            else if (depth == 0 && c == ')')
            {
                skipping = false;
                outp ~= c;
            }
            continue;
        }
        if (depth == 1 && c == '=')
        {
            // Drop the space between the name and `=` too, so the name is
            // still recognisable once the default is gone.
            if (outp.length && outp[$ - 1] == ' ')
                outp = outp[0 .. $ - 1];
            skipping = true;
            continue;
        }
        if (c == '(' || c == '[')
            depth++;
        else if (c == ')' || c == ']')
            depth--;
        outp ~= c;
    }
    return outp;
}

/// Signature of one function/constructor overload. With semantic info the
/// mangled type (`deco`) is exact; template members only carry source text,
/// from which parameter names and default values are removed so a rename or
/// a changed default is not reported as a break. A trailing `|defaults=`
/// mask records which parameters have defaults.
private string signature(JSONValue f)
{
    string mask;
    if (auto ps = "parameters" in f)
        foreach (p; ps.array)
            mask ~= str(p, "default").length ? "1" : "0";
    auto core = str(f, "deco");
    if (core.length == 0)
    {
        auto text = str(f, "type");
        if (!text.length)
            text = str(f, "originalType");
        // `extern (C)` etc. sit before the return type; the linkage is part
        // of the type, so keep the letters and drop the parens.
        core = "text:" ~ text.replace("extern (", "extern_").stripDefaults.stripParamNames;
    }
    // Staticness is a storage class, not part of the type: record it so a
    // static method turning into an instance method (or back) is caught.
    if (auto sc = "storageClass" in f)
        if (sc.type == JSONType.array && sc.array.any!(x => x.type == JSONType.string && x.str == "static"))
            core = "static:" ~ core;
    return core ~ "|defaults=" ~ mask;
}

/// Signature of a template: each parameter (kind, name, type, specialisation)
/// plus the constraint, with defaults in a separate `|defaults=` mask so an
/// added default is compatible and a removed one is not.
private string templateSignature(JSONValue t)
{
    import std.algorithm : among;
    string[] ps;
    string mask;
    if (auto tp = "parameters" in t)
        foreach (p; tp.array)
        {
            string[] parts;
            bool hasDefault;
            foreach (k; p.object.keys.sort)
            {
                if (k.startsWith("default"))
                {
                    hasDefault = true;
                    continue;
                }
                if (k.among("line", "char"))
                    continue;
                const v = p[k];
                parts ~= k ~ "=" ~ (v.type == JSONType.string ? v.str : v.toString);
            }
            ps ~= parts.join(";");
            mask ~= hasDefault ? "1" : "0";
        }
    return "template:(" ~ ps.join(",") ~ ") if(" ~ str(t, "constraint") ~ ")|defaults=" ~ mask;
}

/// `final` / `abstract` on a class declaration. `-X` does not record them, so
/// read the storage classes written before `class` in the source (back to the
/// previous `;`, `{` or `}`), which covers `final class C` and `abstract:`
/// labels in the same scope segment.
private string[] classModifiers(string src, JSONValue m)
{
    import std.regex : regex;
    if (!src.length || "line" !in m || "char" !in m)
        return [];
    const line = m["line"].integer, col = m["char"].integer;
    size_t off;
    long cur = 1;
    while (off < src.length && cur < line)
        if (src[off++] == '\n')
            cur++;
    off = off + (col > 0 ? col - 1 : 0);
    if (off > src.length)
        return [];
    import std.regex : replaceAll;
    // Doc comments may mention the words or braces; blank comments first,
    // keeping offsets (newlines preserved, everything else a space).
    char[] buf = src.dup;
    foreach (cm; matchAll(src, regex(`//[^\n]*|/\*[\s\S]*?\*/|/\+[\s\S]*?\+/`)))
    {
        const b = cm.pre.length;
        foreach (i; b .. b + cm.hit.length)
            if (buf[i] != '\n')
                buf[i] = ' ';
    }
    const clean = cast(string) buf.idup;
    // The attributes written directly before `class` (previous `;`/`{`/`}`).
    size_t start = off;
    while (start > 0 && !";{}".canFind(clean[start - 1]))
        start--;
    const seg = clean[start .. off];
    // Labels (`final:`) stay active for the rest of the enclosing scope, so
    // collect the scope's own text (nested bodies skipped) back to its `{`.
    string scopeText;
    int depth;
    for (size_t i = start; i > 0; i--)
    {
        const c = clean[i - 1];
        if (c == '}')
            depth++;
        else if (c == '{')
        {
            if (depth == 0)
                break;
            depth--;
        }
        else if (depth == 0)
            scopeText = c ~ scopeText;
    }
    string[] mods;
    foreach (w; ["final", "abstract"])
        if (!matchFirst(seg, regex(`(^|[^\w])` ~ w ~ `([^\w]|$)`)).empty
                || !matchFirst(scopeText, regex(`(^|[^\w])` ~ w ~ `\s*:`)).empty)
            mods ~= w;
    return mods;
}

/// `-X` flattens an anonymous enum's members into the enclosing scope and
/// drops the enum's base type. Read it from the source: the text between the
/// `enum` keyword and the `{` that opens the member's enum body.
private string anonymousEnumBase(string src, JSONValue m)
{
    import std.regex : regex, replaceAll;
    if (!src.length || "line" !in m || "char" !in m)
        return "";
    const line = m["line"].integer, col = m["char"].integer;
    size_t off;
    long cur = 1;
    while (off < src.length && cur < line)
        if (src[off++] == '\n')
            cur++;
    off = off + (col > 0 ? col - 1 : 0);
    if (off > src.length)
        return "";
    size_t brace = off;
    while (brace > 0 && src[brace - 1] != '{')
        brace--;
    if (brace == 0)
        return "";
    size_t start = brace - 1;
    while (start > 0 && !";{}".canFind(src[start - 1]))
        start--;
    const head = src[start .. brace - 1].replaceAll(regex(`//[^\n]*|/\*[\s\S]*?\*/|/\+[\s\S]*?\+/`), " ");
    auto c = matchFirst(head, regex(`(^|[^\w])enum\s*:\s*([^{]*)$`));
    if (c.empty)
        return "";
    return c[2].replaceAll(regex(`\s+`), " ").strip;
}

private void walk(ref Api api, string parent, JSONValue members, string parentKind, string src)
{
    string[] fieldOrder;
    long[] fieldOffsets;
    foreach (m; members.array)
    {
        const kind = str(m, "kind");
        const name = str(m, "name");
        const prot = str(m, "protection");
        if (!visible(prot))
            continue;
        if (kind == "import" || kind == "static import")
        {
            // Public imports re-export names through this scope.
            Sym s = Sym("import", parent ~ ":" ~ name, "public");
            const sel = "selective" in m, ren = "renamed" in m;
            if (sel is null && ren is null)
                s.overloads ~= "*";
            if (sel !is null)
                foreach (b; sel.array)
                    s.overloads ~= b.str;
            if (ren !is null)
                foreach (k2, v; ren.object)
                    s.overloads ~= k2 ~ "=" ~ v.str;
            add(api, s);
            continue;
        }
        if (kind == "mixin")
        {
            // Mixed-in members are not expanded by `-X`; track the
            // invocations so dropping one (and its members) is a break.
            add(api, Sym("mixin", parent ~ ":" ~ name, "public", ["1"]));
            continue;
        }
        // Anonymous enums put their members in the enclosing scope.
        if (kind == "enum" && name.length == 0)
        {
            if (auto mem = "members" in m)
                walk(api, parent, *mem, parentKind, src);
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
            s.overloadProtection[s.overloads[0]] = s.protection;
            if (kind == "function" && (parentKind == "class" || parentKind == "interface"))
            {
                auto fsc = "storageClass" in m;
                s.overridable = fsc is null || !fsc.array.any!(x => x.str == "final" || x.str == "static");
            }
            {
                auto shown = str(m, "originalType");
                if (!shown.length)
                    shown = str(m, "type");
                // The display text keys on the signature, so normalise it
                // the same way (no parameter names / default values) — a
                // rename must not orphan the message text.
                if (shown.length)
                    shown = shown.replace("extern (", "extern_")
                        .stripDefaults.stripParamNames;
                if (!shown.length)
                {
                    string[] ps;
                    if (auto params = "parameters" in m)
                        foreach (p; params.array)
                            ps ~= str(p, "name");
                    shown = "(" ~ ps.join(", ") ~ ") [" ~ str(m, "deco") ~ "]";
                }
                s.display[s.overloads[0]] = (s.overloads[0].startsWith("static:") ? "static " : "")
                    ~ name ~ " " ~ shown;
            }
            break;
        case "template":
            s.overloads = [templateSignature(m)];
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
            // Members of an anonymous enum are flattened into the enclosing
            // scope; keep that enum's base type as the member's type.
            if (parentKind != "enum")
                s.type = anonymousEnumBase(src, m);
            break;
        case "class", "interface":
            if (str(m, "base").length)
                s.bases ~= str(m, "base");
            if (auto ifs = "interfaces" in m)
                foreach (i; ifs.array)
                    s.bases ~= i.str;
            if (kind == "class")
                s.modifiers = classModifiers(src, m);
            if (auto mem = "members" in m)
                foreach (f; mem.array)
                    if (str(f, "kind") == "function" && visible(str(f, "protection")))
                        if (auto sc = "storageClass" in f)
                            if (sc.array.any!(x => x.str == "abstract")
                                    && !sc.array.any!(x => x.str == "final" || x.str == "static"))
                                s.required ~= str(f, "name") ~ " " ~ signature(f);
            s.required.sort();
            if (kind == "class" && s.required.length && !s.modifiers.canFind("abstract"))
                s.modifiers ~= "abstract";
            s.modifiers.sort();
            break;
        default:
            break;
        }
        add(api, s);
        if (auto mem = "members" in m)
            walk(api, path, *mem, kind, src);
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
Api extract(string repo, string compiler = "ldc2", string triple = "")
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
            "-preview=dip1000", "-preview=nosharedaccess"] ~ (triple.length ? ["-mtriple=" ~ triple] : []) ~ imports ~ files);
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

/// Source-text counterpart of `splitFuncDeco` for template members: pull the
/// function attributes outside the parameter list (e.g. `nothrow @safe
/// void(int a)`) into mangle codes and return the remaining text.
private bool splitTextSig(string text, out string[] attrs, out string rest)
{
    immutable string[string] codes = ["pure": "Na", "nothrow": "Nb", "ref": "Nc",
        "@property": "Nd", "@trusted": "Ne", "@safe": "Nf", "@nogc": "Ni",
        "return": "Nj", "scope": "Nl", "@live": "Nm", "@system": ""];
    string[] kept;
    size_t i;
    int depth;
    bool sawParams;
    while (i < text.length)
    {
        const c = text[i];
        if (c == ' ')
        {
            i++;
            continue;
        }
        if (depth == 0 && (c == '@' || c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')))
        {
            size_t j = i + 1;
            while (j < text.length && (text[j] == '_' || (text[j] >= 'a' && text[j] <= 'z')
                    || (text[j] >= 'A' && text[j] <= 'Z') || (text[j] >= '0' && text[j] <= '9')))
                j++;
            const w = text[i .. j];
            if (auto code = w in codes)
            {
                if ((*code).length && !attrs.canFind(*code))
                    attrs ~= *code;
            }
            else
                kept ~= w;
            i = j;
            continue;
        }
        size_t j = i;
        while (j < text.length)
        {
            const d = text[j];
            if (d == '(' || d == '[')
                depth++;
            else if (d == ')' || d == ']')
                depth--;
            j++;
            if (depth == 0 && (d == ')' || d == ']' || j >= text.length || text[j] == ' '))
                break;
        }
        if (text[i] == '(')
            sawParams = true;
        kept ~= text[i .. j];
        i = j;
    }
    attrs.sort();
    rest = kept.join(" ");
    return sawParams;
}

/// Can callers of `old` keep calling `neu` unchanged?
/// `overridable`: the old member is a virtual class/interface method, so a
/// subclass overriding it breaks if it turns static.
bool overloadCompatible(string old, string neu, bool overridable = false)
{
    import std.string : chompPrefix, lastIndexOf;
    const oi = old.lastIndexOf("|defaults=");
    const ni = neu.lastIndexOf("|defaults=");
    const oCore = old[0 .. oi].chompPrefix("static:"), nCore = neu[0 .. ni].chompPrefix("static:");
    const oMask = old[oi + 10 .. $], nMask = neu[ni + 10 .. $];
    if (oMask.length != nMask.length)
        return false;
    // A static member stays callable through an instance, so instance ->
    // static only breaks overriders; static -> instance breaks `T.f()` calls.
    if (old.startsWith("static:") && !neu.startsWith("static:"))
        return false;
    if (!old.startsWith("static:") && neu.startsWith("static:") && overridable)
        return false;
    foreach (i; 0 .. oMask.length)
        if (oMask[i] == '1' && nMask[i] != '1')
            return false; // a default argument was removed
    if (oCore == nCore)
        return true;
    string op, orest, np, nrest;
    string[] oa, na;
    if (oCore.startsWith("text:") && nCore.startsWith("text:"))
    {
        // Template members carry source text only: map the outer function
        // attributes to their mangle codes so the rules below apply.
        if (!splitTextSig(oCore[5 .. $], oa, orest) || !splitTextSig(nCore[5 .. $], na, nrest))
            return false;
    }
    else if (!splitFuncDeco(oCore, op, oa, orest) || !splitFuncDeco(nCore, np, na, nrest))
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

/// The signature without its `|defaults=` mask. Required-member comparison
/// uses this: adding a default to an existing abstract/interface method does
/// not force implementations to change, and a removed default is already
/// reported by the overload comparison.
private string withoutDefaults(string sig)
{
    import std.string : lastIndexOf;
    return sig[0 .. sig.lastIndexOf("|defaults=")];
}

/// Enum members whose *values* are intentionally changing metadata: the
/// generated spec hash/operation count change on every regeneration, and the
/// release-stamped SDK version changes on every release. Their presence and
/// type are still checked; only the value is exempt. Domain enum values stay
/// strictly checked.
private bool metadataEnumValue(string path)
{
    switch (path)
    {
    case "camunda.generated.generatedSpecHash",
         "camunda.generated.generatedOperationCount",
         "camunda.version_.sdkVersion",
         "camunda.version_.sdkUserAgent":
        return true;
    default:
        return false;
    }
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
            brk(o.path, o.kind == "mixin" ? "mixin invocation removed" : format("%s removed", o.kind));
            continue;
        }
        auto n = *np;
        // Functions/constructors are checked per overload below: the symbol's
        // own protection is just the first declaration's, so reordering
        // mixed-visibility overloads must not count as narrowing.
        const perOverload = o.kind == "function" || o.kind == "constructor";
        if (!perOverload && o.protection != n.protection && !(o.protection == "protected"
                && n.protection != "protected"))
            brk(o.path, format("visibility narrowed from %s to %s", o.protection, n.protection));
        switch (o.kind)
        {
        case "function", "constructor":
            foreach (ov; o.overloads)
            {
                const need = visRank(o.overloadProtection.get(ov, o.protection));
                if (!n.overloads.any!(nv => overloadCompatible(ov, nv, o.overridable)))
                    brk(o.path, format("%s overload `%s` changed or removed", o.kind,
                            (ov in o.display) ? o.display[ov] : show(ov)));
                else if (!n.overloads.any!(nv => overloadCompatible(ov, nv, o.overridable)
                        && visRank(n.overloadProtection.get(nv, n.protection)) >= need))
                    brk(o.path, format("%s overload `%s` visibility narrowed", o.kind,
                            (ov in o.display) ? o.display[ov] : show(ov)));
            }
            break;
        case "template":
            foreach (ov; o.overloads)
                if (!n.overloads.any!(nv => overloadCompatible(ov, nv)))
                    brk(o.path, format("template parameters or constraint `%s` changed", show(ov)));
            break;
        case "import":
            foreach (b; o.overloads)
                // A wildcard import re-exports names, never renamed bindings.
                if (!n.overloads.canFind(b) && !(n.overloads.canFind("*") && !b.canFind('=')))
                    brk(o.path, format("public import no longer re-exports `%s`", b));
            break;
        case "mixin":
            if (n.overloads.length < o.overloads.length)
                brk(o.path, "mixin invocation removed");
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
            if (o.value != n.value && !metadataEnumValue(o.path))
                brk(o.path, format("value changed from %s to %s", o.value, n.value));
            if (o.type != n.type)
                brk(o.path, format("type changed from `%s` to `%s`", o.type, n.type));
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
            foreach (mod; n.modifiers)
                if (!o.modifiers.canFind(mod))
                    brk(o.path, format("class made %s", mod));
            // Customer implementations of an existing interface / abstract
            // class do not provide newly required members. Compare without
            // the defaults mask: an added default requires nothing of
            // implementers.
            foreach (r; n.required)
                if (!o.required.any!(q => q.withoutDefaults == r.withoutDefaults))
                    brk(o.path, format("new required (abstract) member `%s`", r));
            break;
        default:
            break;
        }
    }
    out_.sort();
    return out_;
}

/// Extra targets whose `version` blocks are compared too (the host is always
/// compared). Breaks seen only there are tagged with the target.
immutable string[] extraTargets = ["x86_64-windows-msvc"];

string[] compareTargets(string baselineDir, string repo, string compiler)
{
    auto breaks = compare(extract(baselineDir, compiler), extract(repo, compiler));
    foreach (t; extraTargets)
        foreach (b; compare(extract(baselineDir, compiler, t), extract(repo, compiler, t)))
            if (!breaks.canFind(b))
                breaks ~= b ~ " [" ~ t ~ "]";
    breaks.sort();
    return breaks;
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

// ---------------------------------------------------------------- suppressions

/// Default suppressions file, relative to the repository root.
enum suppressionsFile = "api-compat-suppressions.txt";

/// Parse a suppressions file: one break line per entry, exactly as the
/// checker prints it (`BREAK <path>: <what>`), optionally with a trailing
/// ` [<target>]`. Blank lines and lines starting with `#` are ignored.
string[] parseSuppressions(string text)
{
    string[] out_;
    foreach (l; text.splitLines)
    {
        const t = l.strip;
        if (t.length && !t.startsWith("#"))
            out_ ~= t;
    }
    return out_;
}

/// Split `breaks` into those not covered by `suppressions` and those that are.
/// An entry without a target tag also covers the same break on every target.
void applySuppressions(string[] breaks, string[] suppressions,
    out string[] remaining, out string[] approved)
{
    foreach (b; breaks)
    {
        auto untagged = b;
        auto c = matchFirst(b, ctRegex!`^(.*) \[[^\]]+\]$`);
        if (!c.empty)
            untagged = c[1];
        if (suppressions.canFind(b) || suppressions.canFind(untagged))
            approved ~= b;
        else
            remaining ~= b;
    }
}

// ---------------------------------------------------------------- main

int main(string[] args)
{
    string baselineDir, repo = ".", major, compiler = "ldc2", suppressPath;
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
        case "--suppressions": suppressPath = next(); break;
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
        string[] suppressions;
        const sp = suppressPath.length ? suppressPath : buildPath(repo, suppressionsFile);
        if (exists(sp))
            suppressions = parseSuppressions(readText(sp));
        else if (suppressPath.length)
            throw new Exception("suppressions file not found: " ~ suppressPath);
        string[] breaks, approved;
        applySuppressions(compareTargets(baselineDir, repo, compiler), suppressions, breaks, approved);
        foreach (b; approved)
            writeln("APPROVED ", b);
        if (approved.length)
            writeln(format("%s approved break(s) listed in %s.", approved.length, sp));
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
    string[] diff(string before, string after, string triple = "")
    {
        Api ex(string src)
        {
            const dir = buildPath(tempDir, format("api-compat-test-%s", randomSuffix()));
            mkdirRecurse(buildPath(dir, "source", "camunda"));
            scope (exit)
                rmdirRecurse(dir);
            write(buildPath(dir, "source", "camunda", "t.d"), "module camunda.t;\n" ~ src);
            return extract(dir, "ldc2", triple);
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
            "camunda.t.T: template parameters or constraint"));
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

unittest // template defaults, constraints and specialisations
{
    assert(diff(q{ template T(X) { enum T = 1; } }, q{ template T(X = int) { enum T = 1; } }) == []);
    assert(has(diff(q{ template T(X = int) { enum T = 1; } }, q{ template T(X) { enum T = 1; } }),
            "camunda.t.T: template parameters"));
    assert(has(diff(q{ template T(X) { enum T = 1; } },
            q{ template T(X) if (is(X == int)) { enum T = 1; } }), "camunda.t.T: template parameters"));
    assert(has(diff(q{ template T(X) { enum T = 1; } }, q{ template T(X : int) { enum T = 1; } }),
            "camunda.t.T: template parameters"));
}

unittest // public re-exports
{
    assert(has(diff(q{ public import std.conv : to, text; }, q{ public import std.conv : to; }),
            "re-exports `text`"));
    assert(has(diff(q{ public import std.conv; }, q{ import std.conv; }), "import removed"));
    assert(diff(q{ public import std.conv : to; }, q{ public import std.conv; }) == []);
}

unittest // removing a mixin invocation while keeping its template
{
    enum tmpl = q{ mixin template M() { void op() {} } };
    assert(has(diff(tmpl ~ q{ class C { mixin M; } }, tmpl ~ q{ class C { } }),
            "mixin invocation removed"));
    assert(diff(tmpl ~ q{ class C { mixin M; } }, tmpl ~ q{ class C { mixin M; } }) == []);
}

unittest // Windows-only declarations are compared on the Windows target
{
    enum before = q{ version (Windows) { struct W { int a; } } };
    // The host build only sees `version (Windows)` code on Windows.
    version (Windows)
        assert(has(diff(before, "", ""), "camunda.t.W: struct removed"));
    else
        assert(diff(before, "", "") == []);
    assert(has(diff(before, "", "x86_64-windows-msvc"), "camunda.t.W: struct removed"));
}

unittest // final / abstract class modifiers
{
    assert(has(diff(q{ class C {} }, q{ final class C {} }), "camunda.t.C: class made final"));
    assert(has(diff(q{ class C {} }, q{ abstract class C {} }), "camunda.t.C: class made abstract"));
    assert(has(diff(q{ class C {} }, q{ abstract: class C {} }), "camunda.t.C: class made abstract"));
    // Dropping a modifier, or one only mentioned in a comment, is fine.
    assert(diff(q{ final class C {} }, q{ class C {} }) == []);
    assert(diff(q{ abstract class C {} }, q{ class C {} }) == []);
    assert(diff(q{ class C {} }, q{ /// not final
        class C {} }) == []);
}

unittest // new required members on existing interfaces and abstract classes
{
    auto d = diff(q{ interface I { void a(); } }, q{ interface I { void a(); void b(); } });
    assert(has(d, "camunda.t.I: new required (abstract) member `b"), d.join("\n"));
    assert(has(diff(q{ abstract class A { void a() {} } },
            q{ abstract class A { void a() {} abstract void b(); } }), "camunda.t.A: new required"));
    // A class gaining an abstract member becomes abstract.
    assert(has(diff(q{ class A { } }, q{ class A { abstract void b(); } }), "class made abstract"));
    // Members with a default implementation require nothing of implementers.
    assert(diff(q{ interface I { void a(); } },
            q{ interface I { void a(); final void c() {} static void s() {} } }) == []);
    assert(diff(q{ abstract class A { abstract void a(); } },
            q{ abstract class A { abstract void a(); void c() {} } }) == []);
}

unittest // function attributes in text-only (template member) signatures
{
    enum before = q{ mixin template M() { void op(int a) {} } };
    // Widening attributes is compatible.
    auto d = diff(before, q{ mixin template M() { void op(int a) @safe pure nothrow @nogc {} } });
    assert(d == [], d.join("\n"));
    // Narrowing is not.
    assert(has(diff(q{ mixin template M() { void op(int a) @safe nothrow {} } },
            q{ mixin template M() { void op(int a) @safe {} } }), "camunda.t.M.op"));
    assert(has(diff(q{ mixin template M() { void op(int a) @safe {} } },
            q{ mixin template M() { void op(int a) @system {} } }), "camunda.t.M.op"));
    // Attributes inside the parameter list are still part of the type.
    assert(has(diff(q{ mixin template M() { void op(void delegate() nothrow a) {} } },
            q{ mixin template M() { void op(void delegate() a) {} } }), "camunda.t.M.op"));
}

unittest // parameter names are not part of a signature
{
    // A rename is source-compatible for positional callers (named arguments
    // are not part of the stability contract), in plain functions and in the
    // text-only signatures of template members (the generated REST mixin).
    assert(diff(q{ void op(int a) {} }, q{ void op(int b) {} }) == []);
    assert(diff(q{ mixin template M() { void op(int a) {} } },
            q{ mixin template M() { void op(int b) {} } }) == []);
    // Names glued to type punctuation are part of the type, not a name.
    assert(diff(q{ mixin template M() { void op(int[] a, int[3] b, void delegate() c) {} } },
            q{ mixin template M() { void op(int[] d, int[3] e, void delegate() f) {} } }) == []);
    // A changed default value is not a break; removing one is.
    assert(diff(q{ mixin template M() { void op(int a = 1 + 1) {} } },
            q{ mixin template M() { void op(int b = 2) {} } }) == []);
    assert(has(diff(q{ mixin template M() { void op(int a = f(1, "x")) {} } },
            q{ mixin template M() { void op(int a) {} } }), "camunda.t.M.op"));
    // The type itself is still compared.
    assert(has(diff(q{ mixin template M() { void op(int a) {} } },
            q{ mixin template M() { void op(long a) {} } }), "camunda.t.M.op"));
    // Unnamed parameters keep their types (a bare type is never a name).
    assert(has(diff(q{ mixin template M() { void op(int) {} } },
            q{ mixin template M() { void op(long) {} } }), "camunda.t.M.op"));
    assert(has(diff(q{ mixin template M() { void op(int, long) {} } },
            q{ mixin template M() { void op(string, long) {} } }), "camunda.t.M.op"));
    assert(has(diff(q{ mixin template M() { void op(int, long) {} } },
            q{ mixin template M() { void op(int, string) {} } }), "camunda.t.M.op"));
    assert(has(diff(q{ mixin template M() { void op(ref int) {} } },
            q{ mixin template M() { void op(ref long) {} } }), "camunda.t.M.op"));
    assert(has(diff(q{ mixin template M() { void op(const int) {} } },
            q{ mixin template M() { void op(const long) {} } }), "camunda.t.M.op"));
    // Named storage-class parameters still treat a rename as compatible.
    assert(diff(q{ mixin template M() { void op(ref int a, const long b) {} } },
            q{ mixin template M() { void op(ref int c, const long d) {} } }) == []);
}

unittest // added defaults on required members are compatible
{
    // Implementations of `void a(int)` still satisfy `void a(int = 0)`.
    assert(diff(q{ interface I { void a(int x); } },
            q{ interface I { void a(int x = 0); } }) == []);
    assert(diff(q{ abstract class A { abstract void a(int x); } },
            q{ abstract class A { abstract void a(int x = 0); } }) == []);
    // A genuinely new abstract member is still a break.
    assert(has(diff(q{ interface I { void a(int x); } },
            q{ interface I { void a(int x); void b(int y = 0); } }), "new required"));
    // A removed default is caught by the overload comparison.
    assert(has(diff(q{ interface I { void a(int x = 0); } },
            q{ interface I { void a(int x); } }), "camunda.t.I.a"));
}

unittest // intentionally changing metadata values are exempt
{
    // Regeneration and release stamping change these values; their presence
    // and type are still checked.
    assert(diff(q{ enum generatedSpecHash = "sha256:a"; enum generatedOperationCount = 1; },
            q{ enum generatedSpecHash = "sha256:b"; enum generatedOperationCount = 2; }) == []);
    // A domain enum value change is still a break.
    assert(has(diff(q{ enum E { x = 1 } }, q{ enum E { x = 2 } }), "camunda.t.E.x: value changed"));
    // Removing the metadata is still a break.
    assert(has(diff(q{ enum generatedOperationCount = 1; }, q{ }), "generatedOperationCount"));
}

unittest // defaults containing literals with separators/delimiters are stripped whole
{
    assert(stripDefaults(`void(string a = "x,y", int b)`) == `void(string a, int b)`);
    assert(stripDefaults(`void(string a = "x,z")`) == `void(string a)`);
    assert(stripDefaults(`void(string a = "q\",)", int b)`) == `void(string a, int b)`);
    assert(stripDefaults(`void(char c = ',', int b)`) == `void(char c, int b)`);
    assert(stripDefaults(`void(char c = '\'', int b)`) == `void(char c, int b)`);
    assert(stripDefaults("void(string a = `x,)`, int b)") == `void(string a, int b)`);
    assert(stripDefaults(`void(int[] a = [1, 2], int b)`) == `void(int[] a, int b)`);
}

unittest // visibility is tracked per overload
{
    assert(has(diff(q{ class C { void f() {} void f(int a) {} } },
            q{ class C { void f() {} protected void f(int a) {} } }), "camunda.t.C.f: function overload"));
    assert(diff(q{ class C { void f() {} protected void f(int a) {} } },
            q{ class C { void f() {} void f(int a) {} } }) == []);
}

unittest // storage-class labels apply to every later declaration in the scope
{
    assert(has(diff(q{ final class A {} class B {} }, q{ final: class A {} class B {} }),
            "camunda.t.B: class made final"));
    assert(has(diff(q{ class A {} interface I {} class B {} },
            q{ abstract: class A {} interface I {} class B {} }), "camunda.t.B: class made abstract"));
    // A label inside a nested body does not leak out.
    assert(diff(q{ class A { } class B {} }, q{ class A { final: void f() {} } class B {} }) == []);
}

unittest // anonymous enum members keep their base type
{
    assert(has(diff(q{ enum : uint { x = 1 } }, q{ enum : ulong { x = 1 } }), "camunda.t.x: type changed"));
    assert(diff(q{ enum : uint { x = 1 } }, q{ enum : uint { x = 1, y = 2 } }) == []);
}

unittest // wildcard imports do not cover renamed bindings
{
    assert(has(diff(q{ public import std.conv : convert = to; }, q{ public import std.conv; }),
            "no longer re-exports `convert=to`"));
    assert(diff(q{ public import std.conv : to; }, q{ public import std.conv; }) == []);
}

unittest // reordering mixed-visibility overloads is not a visibility change
{
    assert(diff(q{ class C { void f() {} protected void f(int a) {} } },
            q{ class C { protected void f(int a) {} void f() {} } }) == []);
}

unittest // static -> instance breaks; instance -> static breaks only overriders
{
    assert(has(diff(q{ class C { static C make() { return null; } } },
            q{ class C { C make() { return null; } } }), "camunda.t.C.make: function overload"));
    assert(has(diff(q{ struct S { static S make() { return S.init; } } },
            q{ struct S { S make() { return S.init; } } }), "camunda.t.S.make: function overload"));
    // instance -> static: callers via an instance still compile ...
    assert(diff(q{ struct S { S make() { return S.init; } } },
            q{ struct S { static S make() { return S.init; } } }) == []);
    assert(diff(q{ class C { final C make() { return null; } } },
            q{ class C { static C make() { return null; } } }) == []);
    // ... but overriders of a virtual method break.
    assert(has(diff(q{ class C { C make() { return null; } } },
            q{ class C { static C make() { return null; } } }), "camunda.t.C.make: function overload"));
    assert(has(diff(q{ interface I { I make(); } },
            q{ interface I { static I make() { return null; } } }), "camunda.t.I.make: function overload"));
    assert(diff(q{ struct S { static S make() { return S.init; } } },
            q{ struct S { static S make() { return S.init; } } }) == []);
}

unittest // suppressions approve listed breaks only, on any target if untagged
{
    auto sup = parseSuppressions("# comment\n\n  BREAK camunda.t.f: function removed  \nBREAK camunda.t.g: x [x86_64-windows-msvc]\n");
    assert(sup == ["BREAK camunda.t.f: function removed", "BREAK camunda.t.g: x [x86_64-windows-msvc]"]);
    string[] rem, ok;
    applySuppressions([
        "BREAK camunda.t.f: function removed",
        "BREAK camunda.t.f: function removed [x86_64-windows-msvc]",
        "BREAK camunda.t.g: x",
        "BREAK camunda.t.g: x [x86_64-windows-msvc]",
        "BREAK camunda.t.h: function removed",
    ], sup, rem, ok);
    assert(rem == ["BREAK camunda.t.g: x", "BREAK camunda.t.h: function removed"], rem.join("\n"));
    assert(ok.length == 3);
}

unittest // a response field made optional/nullable is a break
{
    auto b = diff(q{ import std.typecons : Nullable; struct R { string id; } },
        q{ import std.typecons : Nullable; struct R { Nullable!string id; } });
    assert(has(b, "camunda.t.R.id"), b.join("\n"));
}
