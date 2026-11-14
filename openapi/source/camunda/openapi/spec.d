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
import std.conv : to;
import std.string : startsWith;

import camunda.openapi.errors
    : OpenApiCycleException, OpenApiException, OpenApiLimitException;
import camunda.openapi.json
    : J, Kind, Limits, get, has, itemsOf, keysOf, pointerUnescape, pyStrOrNull, truthy;

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
        foreach (k; itemsOf(this.meta.get("semanticKeys")))
            semantic[k.get("name").text] = k;
        operations = itemsOf(this.meta.get("operations")).dup;
        foreach (u; itemsOf(this.meta.get("unions")))
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
        bool[string] seen;
        size_t chain = 0;
        while (node !is null && node.isObj && node.get("$ref") !is null && node.get("$ref").isStr)
        {
            auto r = node.get("$ref").text;
            if (r in seen)
                throw new OpenApiCycleException("cyclic $ref: " ~ r, r);
            seen[r] = true;
            if (++chain > limits.maxRefChain)
                throw new OpenApiLimitException(
                    "$ref chain longer than " ~ limits.maxRefChain.to!string ~ " at " ~ r, r);
            if (!r.startsWith(COMPONENT_PREFIX))
                return r.split("/")[$ - 1];
            auto parts = r[COMPONENT_PREFIX.length .. $].split("/");
            if (parts.length == 1)
                return parts[0];
            J target = spec.get("components").get("schemas");
            foreach (part; parts)
            {
                part = pointerUnescape(part);
                if (target is null)
                    throw new OpenApiException("unresolvable $ref: " ~ r, r);
                if (target.isArr)
                {
                    const idx = part.to!size_t;
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

    /// Merge own properties with allOf parents (depth-first, own props win).
    Props collectProperties(string name, J schema, ref bool[string] seen)
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
                auto parent = collectProperties(r, this.schema(r), seen);
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
                        auto inner = collectProperties(r2, this.schema(r2), seen);
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
}

/// Ordered set of schema properties: `names` in document order, `map` by name.
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
