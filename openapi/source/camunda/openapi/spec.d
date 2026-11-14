/**
OpenAPI spec model: `$ref` / `allOf` resolution and schema flattening.

Built on the ordered JSON reader in `camunda.openapi.json`. Hardened for
untrusted documents:

  * `$ref` chains are bounded (`Limits.maxRefChain`) and cycles are detected;
  * deep `$ref` pointers into a component are followed to the component they
    finally name; an inline (non-`$ref`) deep target is rejected with a clear
    error rather than silently mishandled;
  * every failure is an `OpenApiException` carrying a JSON-pointer path;
  * there is no process exit and no unbounded recursion.
*/
module camunda.openapi.spec;

@safe:

import std.array : split;
import std.conv : ConvException, to;
import std.string : startsWith;

import camunda.openapi.errors
    : OpenApiCycleException, OpenApiException, OpenApiLimitException;
import camunda.openapi.json
    : J, Kind, Limits, fragmentDecode, get, has, itemsOf, keysOf, pointerEscape, pointerUnescape, pyStrOrNull, truthy;

/// Component path prefix for local schema `$ref`s.
enum COMPONENT_PREFIX = "#/components/schemas/";

/**
A parsed OpenAPI document plus its (optional) spec-metadata sidecar.

`meta` carries the Camunda `spec-metadata.json`; for a plain OpenAPI document
pass `J.obj()` (or omit it) and the metadata-driven sets stay empty.
*/
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
    Limits limits;

    this(J spec, J meta = null, Limits limits = Limits.init)
    {
        this.spec = spec is null ? J.obj() : spec;
        this.meta = meta is null ? J.obj() : meta;
        this.limits = limits;
        schemas = this.spec.get("components").get("schemas");
        if (schemas is null)
            schemas = J.obj();
        foreach (i, k; itemsOf(this.meta.get("semanticKeys")))
            semantic[metaName(k, "#/semanticKeys/" ~ i.to!string)] = k;
        auto metaOps = this.meta.get("operations");
        operations = metaOps !is null ? itemsOf(metaOps).dup : operationsFromPaths();
        foreach (i, u; itemsOf(this.meta.get("unions")))
            unions[metaName(u, "#/unions/" ~ i.to!string)] = u;
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

    /// The `name` of a metadata entry; a typed error when it is missing.
    private static string metaName(J entry, string path)
    {
        auto n = entry.get("name");
        if (n is null || !n.isStr)
            throw new OpenApiException("metadata entry has no string \"name\"", path);
        return n.text;
    }

    /**
    Operations derived from `paths` (document order) when no metadata sidecar
    supplies them. Each entry carries `operationId`, `path`, `method`, `tags`,
    `summary`, `description`, `parameters` (path-level merged with
    operation-level), `requestBody`, `hasRequestBody`, `servers`
    (operation-level, else path-level) and `vendorExtensions` (`x-*` keys).
    */
    private J[] operationsFromPaths()
    {
        static immutable methods = ["get", "put", "post", "delete", "options", "head", "patch", "trace"];
        J[] ops;
        auto paths = spec.get("paths");
        foreach (p; keysOf(paths))
        {
            auto item = paths.fields[p];
            if (item is null || !item.isObj)
                continue;
            if (item.has("$ref"))
                throw new OpenApiException("unsupported Path Item $ref (operations would be dropped)",
                    "#/paths/" ~ pointerEscape(p));
            foreach (m; item.keys)
            {
                import std.algorithm.searching : canFind;
                if (!methods.canFind(m))
                    continue;
                auto op = item.fields[m];
                const where = "#/paths/" ~ pointerEscape(p) ~ "/" ~ m;
                if (op is null || !op.isObj)
                    throw new OpenApiException("operation is not an object", where);
                auto o = J.obj();
                foreach (k; ["operationId", "tags", "summary", "description", "requestBody"])
                    if (auto v = op.get(k))
                        o.set(k, v);
                o.set("path", J.str(p));
                o.set("method", J.str(m));
                o.set("parameters", J.arr(mergeParameters(item.get("parameters"), "#/paths/" ~ pointerEscape(p), op.get("parameters"), where)));
                auto hasBody = new J(Kind.bool_);
                hasBody.boolean = op.has("requestBody");
                o.set("hasRequestBody", hasBody);
                auto sv = op.get("servers");
                if (sv is null)
                    sv = item.get("servers");
                if (sv is null)
                    sv = spec.get("servers");
                if (sv !is null)
                    o.set("servers", sv);
                auto ext = J.obj();
                foreach (k; op.keys)
                    if (k.startsWith("x-"))
                        ext.set(k, op.fields[k]);
                o.set("vendorExtensions", ext);
                ops ~= o;
            }
        }
        return ops;
    }

    /// Resolve a parameter, following `#/components/parameters/*` `$ref`s
    /// (bounded by `limits.maxRefChain`, cycles detected).
    private J resolveParameter(J p, string where)
    {
        enum PARAM_PREFIX = "#/components/parameters/";
        bool[string] seen;
        size_t chain = 0;
        while (p !is null && p.isObj && p.get("$ref") !is null && p.get("$ref").isStr)
        {
            auto r = fragmentDecode(p.get("$ref").text);
            if (r in seen)
                throw new OpenApiCycleException("cyclic parameter $ref: " ~ r, r);
            seen[r] = true;
            if (++chain > limits.maxRefChain)
                throw new OpenApiLimitException(
                    "$ref chain longer than " ~ limits.maxRefChain.to!string ~ " at " ~ r, r);
            if (!r.startsWith(PARAM_PREFIX))
                throw new OpenApiException("unsupported parameter $ref: " ~ r, where);
            p = spec.get("components").get("parameters").get(pointerUnescape(r[PARAM_PREFIX.length .. $]));
            if (p is null)
                throw new OpenApiException("unresolvable parameter $ref: " ~ r, where);
        }
        return p;
    }

    /// `(in, name)` identity of a parameter; a typed error when either is missing.
    private string parameterId(J p, string where)
    {
        auto r = resolveParameter(p, where);
        if (r is null || !r.isObj)
            throw new OpenApiException("parameter is not an object", where);
        auto n = r.get("name");
        auto i = r.get("in");
        if (n is null || !n.isStr || i is null || !i.isStr)
            throw new OpenApiException("parameter has no string \"name\" and \"in\"", where);
        return i.text ~ "\0" ~ n.text;
    }

    /**
    Path-level parameters overridden by operation-level ones with the same
    `(name, in)` (OpenAPI 3 semantics). Unmatched path-level parameters come
    first in order; entries are returned as written (`$ref`s kept).
    */
    private J[] mergeParameters(J pathParams, string pathWhere, J opParams, string opWhere)
    {
        bool[string] overridden;
        foreach (i, p; itemsOf(opParams))
            overridden[parameterId(p, opWhere ~ "/parameters/" ~ i.to!string)] = true;
        J[] merged;
        foreach (i, p; itemsOf(pathParams))
            if (parameterId(p, pathWhere ~ "/parameters/" ~ i.to!string) !in overridden)
                merged ~= p;
        return merged ~ itemsOf(opParams);
    }

    J schema(string name)
    {
        auto s = schemas.get(name);
        return s !is null && s.isObj ? s : J.obj();
    }

    bool isEnum(string n) { return (n in enumNames) !is null; }
    bool isKey(string n) { return (n in keyNames) !is null; }

    /**
    Component name a `$ref` resolves to.

    The bundler can emit pointers *into* a component (e.g.
    `#/components/schemas/X/allOf/0`) when dedup matched a nested member.
    Follow those to the component they finally name, instead of taking the
    last path segment (which would be `0`).

    Bounds the chain at `limits.maxRefChain` and detects cycles; a deep `$ref`
    to an inline (non-`$ref`) schema is rejected with a clear error.
    */
    string refName(J node)
    {
        return resolveRef(node, false);
    }

    /// Like `refName`, but rejects any `$ref` (including one reached through
    /// a deep alias) that does not name an existing schema component.
    string componentRef(J node, string where)
    {
        auto n = resolveRef(node, true);
        if (n !is null && schemas.get(n) is null)
            throw new OpenApiException("$ref to missing schema component: " ~ COMPONENT_PREFIX ~ pointerEscape(n), where);
        return n;
    }

    private string resolveRef(J node, bool componentsOnly)
    {
        bool[string] seen;
        size_t chain = 0;
        while (node !is null && node.isObj && node.get("$ref") !is null && node.get("$ref").isStr)
        {
            auto r = fragmentDecode(node.get("$ref").text);
            if (r in seen)
                throw new OpenApiCycleException("cyclic $ref: " ~ r, r);
            seen[r] = true;
            if (++chain > limits.maxRefChain)
                throw new OpenApiLimitException(
                    "$ref chain longer than " ~ limits.maxRefChain.to!string ~ " at " ~ r, r);
            if (!r.startsWith(COMPONENT_PREFIX))
            {
                if (componentsOnly)
                    throw new OpenApiException("unsupported non-component schema $ref: " ~ r, r);
                return pointerUnescape(r.split("/")[$ - 1]);
            }
            auto parts = r[COMPONENT_PREFIX.length .. $].split("/");
            if (parts.length == 1)
                return pointerUnescape(parts[0]);
            J target = spec.get("components").get("schemas");
            foreach (part; parts)
            {
                part = pointerUnescape(part);
                if (target is null)
                    throw new OpenApiException("unresolvable $ref: " ~ r, r);
                if (target.isArr)
                {
                    size_t idx;
                    try
                        idx = part.to!size_t;
                    catch (ConvException)
                        throw new OpenApiException("$ref array index is not a number: " ~ r, r);
                    if (idx >= target.items.length)
                        throw new OpenApiException("$ref array index out of range: " ~ r, r);
                    target = target.items[idx];
                }
                else if (target.isObj)
                {
                    auto p = part in target.fields;
                    target = p is null ? null : *p;
                }
                else
                    target = null;
            }
            if (!(target !is null && target.isObj && target.has("$ref")))
                throw new OpenApiException("unsupported deep $ref to an inline schema: " ~ r, r);
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

    /**
    Merge own properties with allOf parents (depth-first, own props win).

    Follows a `$ref` on the schema itself, `$ref` members of `allOf` and
    inline `allOf` members at any nesting. `required` names are unioned from
    every contributor. Traversal depth is bounded by `limits.maxDepth`.
    */
    Props collectProperties(string name, J schema, ref bool[string] seen)
    {
        return collect(name, schema, seen, 0, name is null ? "#" : COMPONENT_PREFIX ~ pointerEscape(name));
    }

    private Props collect(string name, J schema, ref bool[string] seen, size_t depth, string where)
    {
        Props props;
        if (depth > limits.maxDepth)
            throw new OpenApiLimitException(
                "allOf/$ref flattening deeper than " ~ limits.maxDepth.to!string, where);
        if (name !is null)
        {
            if (name in seen)
                return props;
            seen[name] = true;
        }
        if (schema is null || !schema.isObj)
            return props;
        Props sub(string r)
        {
            return collect(r, this.schema(r), seen, depth + 1, COMPONENT_PREFIX ~ pointerEscape(r));
        }
        auto self = componentRef(schema, where);
        if (self !is null)
            props.mergeParent(sub(self));
        // Members are traversed whole: in OpenAPI 3.1 `$ref` siblings
        // (`required`, `properties`, nested `allOf`) also apply.
        foreach (i, part; itemsOf(schema.get("allOf")))
            if (part.isObj)
                props.mergeParent(collect(null, part, seen, depth + 1, where ~ "/allOf/" ~ i.to!string));
        auto own = schema.get("properties");
        foreach (k; keysOf(own))
            props.put(k, own.fields[k]);
        foreach (req; itemsOf(schema.get("required")))
            if (req.isStr)
                props.required[req.text] = true;
        return props;
    }
}

/// Ordered set of schema properties: `names` in document order, `map` by name.
struct Props
{
    string[] names;
    J[string] map;
    /// Names listed in `required` by the schema or any flattened contributor.
    bool[string] required;

    bool isRequired(string k) const { return (k in required) !is null; }

    /// Add a parent's properties (existing ones win) and its required names.
    void mergeParent(Props parent)
    {
        foreach (k; parent.names)
            setDefault(k, parent.map[k]);
        foreach (k; parent.required.byKey)
            required[k] = true;
    }

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
