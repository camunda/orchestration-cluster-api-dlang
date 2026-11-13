#!/usr/bin/env python3
"""Generate the D SDK from the bundled OpenAPI spec + spec-metadata.

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
`topology.d`). Change this script and re-run `make generate`.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC_PATH = ROOT / "external-spec" / "bundled" / "rest-api.bundle.json"
META_PATH = ROOT / "external-spec" / "bundled" / "spec-metadata.json"
OUT_DIR = ROOT / "source" / "camunda" / "generated"
DOCS_DIR = ROOT / "docs"

D_KEYWORDS = {
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
}

# Hand-written curated methods on CamundaClient. The generated facade still
# emits the operation (so the surface stays complete) but uses a different
# D name when it would collide; curated wrappers keep the nicer name.
CURATED_NAMES = {
    "getTopology": "getTopologyOp",
    "createDeployment": "createDeploymentOp",
    "createDocument": "createDocumentOp",
    "createDocuments": "createDocumentsOp",
}


# multipart/form-data operations go through hand-written CamundaClient methods
# (the generic request* path is JSON only). The generated `<op>Op` stays for
# source compatibility but is deprecated and throws. A new multipart operation
# without an entry here stops generation (#7).
MULTIPART_CURATED = {
    "createDeployment": "deployResources",
    "createDocument": "createDocument",
    "createDocuments": "createDocuments",
}

# Example signature + call for each multipart operation (hand-written method).
MULTIPART_EXAMPLES = {
    "createDeployment": ("string[] paths", "client.deployResources(paths)"),
    "createDocument": ("string path, string storeId = null",
                       "client.createDocument(path, null, storeId)"),
    "createDocuments": ("string[] paths, string storeId = null",
                        "client.createDocuments(paths, storeId)"),
}
assert MULTIPART_EXAMPLES.keys() == MULTIPART_CURATED.keys()


def log(hook: str, msg: str) -> None:
    print(f"  [{hook}] {msg}")


def d_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def d_ident(name: str) -> str:
    if name.startswith("$"):
        ident = name[1:]
    elif "." in name or "-" in name:
        parts = re.split(r"[.\-]+", name)
        ident = parts[0] + "".join(p[:1].upper() + p[1:] for p in parts[1:] if p)
    else:
        ident = name
    if not ident:
        ident = "value"
    if ident[0].isdigit():
        ident = "_" + ident
    if ident in D_KEYWORDS:
        ident += "_"
    return ident


def camel(name: str) -> str:
    if not name:
        return name
    return name[0].lower() + name[1:]


# Set by load(): the bundled spec, for following deep JSON-pointer refs.
_SPEC: dict = {}
_COMPONENT_PREFIX = "#/components/schemas/"


def ref_name(node: object) -> str | None:
    """Component name a `$ref` resolves to.

    The bundler can emit pointers *into* a component (e.g.
    `#/components/schemas/X/allOf/0`) when dedup matched a nested member.
    Follow those to the component they finally name, instead of taking the
    last path segment (which would be `0`).
    """
    seen: set[str] = set()
    while isinstance(node, dict) and isinstance(node.get("$ref"), str):
        ref = node["$ref"]
        if ref in seen:
            sys.exit(f"cyclic $ref: {ref}")
        seen.add(ref)
        if not ref.startswith(_COMPONENT_PREFIX):
            return ref.rsplit("/", 1)[-1]
        parts = ref[len(_COMPONENT_PREFIX):].split("/")
        if len(parts) == 1:
            return parts[0]
        target: object = _SPEC.get("components", {}).get("schemas", {})
        for part in parts:
            part = part.replace("~1", "/").replace("~0", "~")
            target = target[int(part)] if isinstance(target, list) else target[part]
        if not (isinstance(target, dict) and "$ref" in target):
            sys.exit(f"unsupported deep $ref to an inline schema: {ref}")
        node = target
    return None


def unwrap_allof_ref(schema: dict) -> str | None:
    """If schema is `{allOf: [{$ref}]}` (optionally with type/description), return the ref."""
    refs = [ref_name(p) for p in (schema.get("allOf") or [])]
    refs = [r for r in refs if r]
    extras = [p for p in (schema.get("allOf") or []) if ref_name(p) is None and isinstance(p, dict) and p]
    if len(refs) == 1 and not extras and not schema.get("properties") and not schema.get("oneOf"):
        return refs[0]
    return None


class Spec:
    def __init__(self, spec: dict, meta: dict) -> None:
        self.spec = spec
        self.meta = meta
        self.schemas: dict[str, dict] = spec.get("components", {}).get("schemas", {})
        self.semantic = {k["name"]: k for k in meta.get("semanticKeys", [])}
        self.operations = list(meta.get("operations", []))
        self.unions = {u["name"]: u for u in meta.get("unions", [])}
        self.enum_names = {
            n for n, s in self.schemas.items()
            if isinstance(s, dict) and "enum" in s and isinstance(s["enum"], list)
        }
        # String schemas that are branded keys (semantic + format-named leftovers).
        self.key_names: set[str] = set(self.semantic)
        for n, s in self.schemas.items():
            if not isinstance(s, dict):
                continue
            if s.get("type") == "string" and s.get("x-semantic-type"):
                self.key_names.add(n)
            if n in {"ResourceKey", "ScopeKey", "LongKey"}:
                self.key_names.add(n)

    def schema(self, name: str) -> dict:
        s = self.schemas.get(name)
        return s if isinstance(s, dict) else {}


def load() -> Spec:
    if not SPEC_PATH.is_file():
        sys.exit(f"missing bundled spec: {SPEC_PATH}")
    if not META_PATH.is_file():
        sys.exit(f"missing spec metadata: {META_PATH}")
    spec = json.loads(SPEC_PATH.read_text(encoding="utf-8"))
    _SPEC.update(spec)
    meta = json.loads(META_PATH.read_text(encoding="utf-8"))
    return Spec(spec, meta)


# ---------------------------------------------------------------------------
# 01 keys
# ---------------------------------------------------------------------------

KEYS_HEADER = """\
/// Generated by scripts/generate.py (hook 01) — DO NOT EDIT.
///
/// The Camunda Domain Type System: a distinct newtype for every semantic key
/// in the OpenAPI spec. Construct with `tryNew` (validates) or `assumeExists`
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

"""


def render_key(key: dict) -> str:
    name = key["name"]
    constraints = key.get("constraints") or {}
    pattern = constraints.get("pattern") or ""
    min_len = constraints.get("minLength")
    max_len = constraints.get("maxLength")
    desc = (key.get("description") or "").strip().replace("\r", " ").replace("\n", " ")
    examples = key.get("examples") or []
    example = examples[0] if examples else None
    min_expr = str(int(min_len)) if min_len is not None else "-1"
    max_expr = str(int(max_len)) if max_len is not None else "-1"
    pat_lit = d_string(pattern)
    lines = []
    lines.append(f"/// {desc or ('Camunda domain type `' + name + '`.')}")
    if example is not None:
        lines.append(f"/// Example: `{example}`")
    lines.append(f"struct {name}")
    lines.append("{")
    lines.append("    private string _value;")
    lines.append(f"    enum semanticType = {d_string(name)};")
    lines.append("    /// Construct without validation.")
    lines.append(f"    static {name} assumeExists(string value) pure nothrow")
    lines.append("    {")
    lines.append(f"        {name} k;")
    lines.append("        k._value = value;")
    lines.append("        return k;")
    lines.append("    }")
    lines.append("    /// Construct with constraint validation.")
    lines.append(f"    static {name} tryNew(string value)")
    lines.append("    {")
    lines.append(f"        checkConstraints(semanticType, value, {pat_lit}, {min_expr}, {max_expr}, true);")
    lines.append("        return assumeExists(value);")
    lines.append("    }")
    lines.append("    /// True if `value` satisfies this type's constraints.")
    lines.append("    static bool isValid(string value)")
    lines.append("    {")
    lines.append(f"        return checkConstraints(semanticType, value, {pat_lit}, {min_expr}, {max_expr}, false);")
    lines.append("    }")
    lines.append("    string value() const pure nothrow @nogc { return _value; }")
    lines.append("    string toString() const pure nothrow @nogc { return _value; }")
    lines.append("    bool opEquals(const {name} other) const pure nothrow @nogc { return _value == other._value; }")
    lines.append("    bool isEmpty() const pure nothrow @nogc { return _value.length == 0; }")
    lines.append("    static {name} fromJson(JSONValue v)")
    lines.append("    {")
    lines.append("        auto s = v.type == JSONType.string ? v.str : v.toString;")
    lines.append("        return assumeExists(s);")
    lines.append("    }")
    lines.append("    JSONValue toJson() const { return JSONValue(_value); }")
    lines.append("}")
    lines.append("")
    return "\n".join(lines).replace("{name}", name)


def extra_string_key(name: str, schema: dict) -> dict:
    return {
        "name": name,
        "description": (schema.get("description") or f"Camunda domain type `{name}`.").strip(),
        "constraints": {
            "pattern": schema.get("pattern"),
            "minLength": schema.get("minLength"),
            "maxLength": schema.get("maxLength"),
        },
        "examples": [schema["example"]] if "example" in schema else [],
    }


def hook_01_keys(spec: Spec) -> None:
    keys = list(spec.meta.get("semanticKeys") or [])
    seen = {k["name"] for k in keys}
    for extra in ("ResourceKey", "ScopeKey", "LongKey"):
        if extra not in seen and extra in spec.schemas:
            keys.append(extra_string_key(extra, spec.schema(extra)))
            seen.add(extra)
    body = KEYS_HEADER + "\n".join(render_key(k) for k in keys)
    path = OUT_DIR / "keys.d"
    path.write_text(body, encoding="utf-8")
    log("01-keys", f"wrote {path.relative_to(ROOT)} ({len(keys)} types)")


# ---------------------------------------------------------------------------
# 02 enums
# ---------------------------------------------------------------------------

ENUMS_HEADER = """\
/// Generated by scripts/generate.py (hook 02) — DO NOT EDIT.
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

"""


def render_enum(name: str, schema: dict) -> str:
    values = schema.get("enum") or []
    desc = (schema.get("description") or "").strip().replace("\n", " ")
    lines = [f"/// {desc}" if desc else f"/// `{name}`"]
    lines.append(f"enum {name} : string")
    lines.append("{")
    seen = set()
    for v in values:
        ident = d_ident(str(v))
        # CloudStage.int -> int_
        orig = ident
        n = 2
        while ident in seen:
            ident = f"{orig}{n}"
            n += 1
        seen.add(ident)
        lines.append(f"    {ident} = {d_string(str(v))},")
    lines.append("}")
    lines.append("")
    lines.append(f"{name} parse{name}(string value)")
    lines.append("{")
    lines.append(f"    switch (value)")
    lines.append("    {")
    seen = set()
    for v in values:
        ident = d_ident(str(v))
        orig = ident
        n = 2
        while ident in seen:
            ident = f"{orig}{n}"
            n += 1
        seen.add(ident)
        lines.append(f"    case {d_string(str(v))}: return {name}.{ident};")
    lines.append(f"    default: throw new EnumDecodeError({d_string(name)}, value);")
    lines.append("    }")
    lines.append("}")
    lines.append("")
    lines.append(f"{name} fromJson({name})(JSONValue v)")
    lines.append("{")
    lines.append(f"    return parse{name}(v.type == JSONType.string ? v.str : v.toString);")
    lines.append("}")
    lines.append(f"JSONValue toJson({name} value) {{ return JSONValue(cast(string) value); }}")
    lines.append("")
    return "\n".join(lines)


def hook_02_enums(spec: Spec) -> None:
    chunks = [ENUMS_HEADER]
    count = 0
    for name in sorted(spec.enum_names):
        chunks.append(render_enum(name, spec.schema(name)))
        count += 1
    path = OUT_DIR / "enums.d"
    path.write_text("\n".join(chunks), encoding="utf-8")
    log("02-enums", f"wrote {path.relative_to(ROOT)} ({count} enums)")


# ---------------------------------------------------------------------------
# 03 models
# ---------------------------------------------------------------------------

MODELS_HEADER = """\
/// Generated by scripts/generate.py (hook 03) — DO NOT EDIT.
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

"""


def classify(spec: Spec, name: str) -> str:
    if name in spec.key_names:
        return "key"
    if name in spec.enum_names:
        return "enum"
    schema = spec.schema(name)
    if not schema:
        return "unknown"
    if name in spec.unions or schema.get("oneOf") or schema.get("anyOf") or schema.get("x-polymorphic-schema"):
        return "union"
    if schema.get("type") == "array":
        return "array"
    if schema.get("type") == "integer":
        return "integer"
    if schema.get("type") == "string" and "enum" not in schema:
        # ExactMatch wrappers: allOf -> key/enum
        target = unwrap_allof_ref(schema)
        if target:
            return "alias:" + target
        return "string"
    if schema.get("type") == "boolean":
        return "boolean"
    if schema.get("type") == "number":
        return "number"
    return "object"


def d_type_for_schema(spec: Spec, schema: dict, visiting: set[str] | None = None) -> str:
    """Map an OpenAPI schema fragment to a D type used in accessors."""
    ref = ref_name(schema)
    if ref:
        kind = classify(spec, ref)
        if kind == "key":
            return ref
        if kind == "enum":
            return ref
        if kind.startswith("alias:"):
            return kind.split(":", 1)[1]
        if kind == "string":
            return "string"
        if kind == "integer":
            return "long"
        if kind == "array":
            items = spec.schema(ref).get("items") or {}
            return d_type_for_schema(spec, items) + "[]"
        return ref  # object / union wrapper
    if "allOf" in schema and unwrap_allof_ref(schema):
        return d_type_for_schema(spec, {"$ref": "#/components/schemas/" + unwrap_allof_ref(schema)})
    if schema.get("oneOf") or schema.get("anyOf"):
        return "JSONValue"
    t = schema.get("type")
    if t == "string":
        if "enum" in schema:
            return "string"
        if schema.get("format") == "binary":
            return "string"
        return "string"
    if t == "integer":
        return "long" if schema.get("format") == "int64" else "int"
    if t == "number":
        return "double"
    if t == "boolean":
        return "bool"
    if t == "array":
        return d_type_for_schema(spec, schema.get("items") or {}) + "[]"
    if t == "object" or schema.get("properties") or schema.get("additionalProperties") is not None:
        return "JSONValue"
    return "JSONValue"


def collect_properties(spec: Spec, name: str, schema: dict, seen: set[str] | None = None) -> dict[str, dict]:
    """Merge own properties with allOf parents (depth-first, own props win)."""
    if seen is None:
        seen = set()
    if name in seen:
        return {}
    seen.add(name)
    props: dict[str, dict] = {}
    for part in schema.get("allOf") or []:
        ref = ref_name(part)
        if ref:
            parent = spec.schema(ref)
            for k, v in collect_properties(spec, ref, parent, seen).items():
                props.setdefault(k, v)
        elif isinstance(part, dict):
            for k, v in (part.get("properties") or {}).items():
                props.setdefault(k, v)
            for sub in part.get("allOf") or []:
                r = ref_name(sub)
                if r:
                    for k, v in collect_properties(spec, r, spec.schema(r), seen).items():
                        props.setdefault(k, v)
    for k, v in (schema.get("properties") or {}).items():
        props[k] = v
    return props


def collect_required(spec: Spec, name: str, schema: dict, seen: set[str] | None = None) -> set[str]:
    if seen is None:
        seen = set()
    if name in seen:
        return set()
    seen.add(name)
    req = set(schema.get("required") or [])
    for part in schema.get("allOf") or []:
        ref = ref_name(part)
        if ref:
            req |= collect_required(spec, ref, spec.schema(ref), seen)
        elif isinstance(part, dict):
            req |= set(part.get("required") or [])
    return req


def accessor_read(spec: Spec, dty: str, json_key: str) -> str:
    lit = d_string(json_key)
    if dty == "string":
        return f"jsonGetString(raw, {lit})"
    if dty == "int":
        return f"cast(int) jsonGetLong(raw, {lit})"
    if dty == "long":
        return f"jsonGetLong(raw, {lit})"
    if dty == "double":
        return f"jsonGetDouble(raw, {lit})"
    if dty == "bool":
        return f"jsonGetBool(raw, {lit})"
    if dty == "JSONValue":
        return f"jsonGet(raw, {lit})"
    if dty.endswith("[]"):
        inner = dty[:-2]
        if inner == "string":
            return f"jsonGetStringArray(raw, {lit})"
        if inner == "int":
            return f"jsonGetIntArray(raw, {lit})"
        if inner == "long":
            return f"jsonGetLongArray(raw, {lit})"
        if inner == "JSONValue":
            return f"jsonGetArray(raw, {lit})"
        # array of models / keys / enums
        if inner in spec.enum_names:
            return f"jsonMapArray(raw, {lit}, (JSONValue v) => parse{inner}(v.type == JSONType.string ? v.str : v.toString))"
        return f"jsonMapArray(raw, {lit}, (JSONValue v) => {inner}.fromJson(v))"
    # key, enum, or model
    if dty in spec.enum_names:
        return f"parse{dty}(jsonGetString(raw, {lit}))"
    return f"{dty}.fromJson(jsonGet(raw, {lit}))"


def accessor_write(spec: Spec, dty: str, json_key: str, var: str = "value") -> str:
    lit = d_string(json_key)
    if dty in {"string", "int", "long", "double", "bool", "JSONValue"}:
        return f"jsonSet(raw, {lit}, JSONValue({var}))"
    if dty.endswith("[]"):
        inner = dty[:-2]
        if inner in {"string", "int", "long", "JSONValue"}:
            return f"jsonSet(raw, {lit}, JSONValue({var}))"
        if inner in spec.enum_names:
            return f"jsonSet(raw, {lit}, jsonFromMapped({var}, ({inner} x) => JSONValue(cast(string) x)))"
        return f"jsonSet(raw, {lit}, jsonFromMapped({var}, ({inner} x) => x.toJson()))"
    if dty in spec.enum_names:
        return f"jsonSet(raw, {lit}, JSONValue(cast(string) {var}))"
    return f"jsonSet(raw, {lit}, {var}.toJson())"


def render_object_model(spec: Spec, name: str, schema: dict) -> str:
    desc = (schema.get("description") or f"`{name}`").strip().replace("\n", " ")
    props = collect_properties(spec, name, schema)
    lines = [f"/// {desc}", f"struct {name}", "{", "    JSONValue raw;", ""]
    lines.append(f"    static {name} fromJson(JSONValue value)")
    lines.append("    {")
    lines.append(f"        {name} m;")
    lines.append("        m.raw = value.type == JSONType.null_ ? emptyObject() : value;")
    lines.append("        return m;")
    lines.append("    }")
    lines.append("    JSONValue toJson() const { return raw; }")
    lines.append(f"    static {name} initEmpty()")
    lines.append("    {")
    lines.append(f"        {name} m;")
    lines.append("        m.raw = emptyObject();")
    lines.append("        return m;")
    lines.append("    }")
    lines.append("")
    used = set()
    for pname, pschema in props.items():
        ident = d_ident(pname)
        orig = ident
        n = 2
        while ident in used or ident == "raw":
            ident = f"{orig}{n}"
            n += 1
        used.add(ident)
        dty = d_type_for_schema(spec, pschema if isinstance(pschema, dict) else {})
        pdesc = ""
        if isinstance(pschema, dict):
            pdesc = (pschema.get("description") or "").strip().replace("\n", " ")
        if pdesc:
            lines.append(f"    /// {pdesc}")
        lines.append(f"    bool has_{ident}() const {{ return jsonHas(raw, {d_string(pname)}); }}")
        lines.append(f"    {dty} {ident}() const {{ return {accessor_read(spec, dty, pname)}; }}")
        lines.append(f"    ref {name} {ident}({dty} value) return")
        lines.append("    {")
        lines.append(f"        {accessor_write(spec, dty, pname)};")
        lines.append("        return this;")
        lines.append("    }")
        lines.append("")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def render_union_model(spec: Spec, name: str, schema: dict) -> str:
    desc = (schema.get("description") or f"`{name}`").strip().replace("\n", " ")
    branches = []
    for part in schema.get("oneOf") or schema.get("anyOf") or []:
        ref = ref_name(part)
        if ref:
            branches.append(ref)
    disc = (schema.get("discriminator") or {}).get("propertyName")
    lines = [f"/// {desc}", f"struct {name}", "{", "    JSONValue raw;", ""]
    lines.append(f"    static {name} fromJson(JSONValue value)")
    lines.append("    {")
    lines.append(f"        {name} m; m.raw = value; return m;")
    lines.append("    }")
    lines.append("    JSONValue toJson() const { return raw; }")
    # hybrid unions also accept a raw scalar
    lines.append(f"    static {name} of(JSONValue value) {{ return fromJson(value); }}")
    for b in branches:
        kind = classify(spec, b)
        if kind == "key" or kind == "enum" or kind == "object" or kind == "union" or kind.startswith("alias:"):
            tname = kind.split(":", 1)[1] if kind.startswith("alias:") else b
            ident = d_ident(camel(tname))
            lines.append(f"    static {name} from{tname}({tname} value)")
            lines.append("    {")
            lines.append(f"        return fromJson(value.toJson());")
            lines.append("    }")
        elif kind == "string":
            lines.append(f"    static {name} fromString(string value) {{ return fromJson(JSONValue(value)); }}")
        elif kind == "integer":
            lines.append(f"    static {name} fromInt(long value) {{ return fromJson(JSONValue(value)); }}")
    if disc:
        lines.append(f"    string discriminator() const {{ return jsonGetString(raw, {d_string(disc)}); }}")
    # hybrid: also allow constructing from a string (exact match)
    meta_u = spec.unions.get(name)
    if meta_u and meta_u.get("kind") == "hybrid-union":
        lines.append(f"    static {name} exactString(string value) {{ return fromJson(JSONValue(value)); }}")
        lines.append(f"    static {name} exactInt(long value) {{ return fromJson(JSONValue(value)); }}")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def render_alias(name: str, target: str) -> str:
    return f"/// Alias of `{target}`.\nalias {name} = {target};\n\n"


def render_string_model(name: str, schema: dict) -> str:
    desc = (schema.get("description") or f"`{name}`").strip().replace("\n", " ")
    return (
        f"/// {desc}\n"
        f"struct {name}\n"
        "{\n"
        "    string value;\n"
        f"    static {name} fromJson(JSONValue v) {{ {name} m; m.value = v.type == JSONType.string ? v.str : v.toString; return m; }}\n"
        "    JSONValue toJson() const { return JSONValue(value); }\n"
        "    string toString() const { return value; }\n"
        "}\n\n"
    )


def render_integer_model(name: str, schema: dict) -> str:
    desc = (schema.get("description") or f"`{name}`").strip().replace("\n", " ")
    dty = "long" if schema.get("format") == "int64" else "int"
    return (
        f"/// {desc}\n"
        f"struct {name}\n"
        "{\n"
        f"    {dty} value;\n"
        f"    static {name} fromJson(JSONValue v) {{ {name} m; m.value = cast({dty}) jsonValueLong(v); return m; }}\n"
        "    JSONValue toJson() const { return JSONValue(value); }\n"
        "}\n\n"
    )


def hook_03_models(spec: Spec) -> None:
    chunks = [MODELS_HEADER]
    emitted = set(spec.key_names) | set(spec.enum_names)
    count = 0
    for name in sorted(spec.schemas):
        if name in emitted:
            continue
        kind = classify(spec, name)
        schema = spec.schema(name)
        if kind.startswith("alias:"):
            chunks.append(render_alias(name, kind.split(":", 1)[1]))
        elif kind == "string":
            chunks.append(render_string_model(name, schema))
        elif kind == "integer":
            chunks.append(render_integer_model(name, schema))
        elif kind == "union":
            chunks.append(render_union_model(spec, name, schema))
        elif kind == "array":
            # Rare top-level array schema: wrap as JSONValue model
            chunks.append(render_string_model(name, schema).replace("string value", "JSONValue raw")
                          .replace("m.value = v.type == JSONType.string ? v.str : v.toString", "m.raw = v")
                          .replace("JSONValue(value)", "raw")
                          .replace("return value", "return raw.toString"))
        elif kind in {"boolean", "number"}:
            chunks.append(render_string_model(name, schema))
        else:
            chunks.append(render_object_model(spec, name, schema))
        emitted.add(name)
        count += 1
    path = OUT_DIR / "models.d"
    path.write_text("".join(chunks), encoding="utf-8")
    log("03-models", f"wrote {path.relative_to(ROOT)} ({count} schemas)")


# ---------------------------------------------------------------------------
# 04 operations
# ---------------------------------------------------------------------------

OPS_HEADER = """\
/// Generated by scripts/generate.py (hook 04) — DO NOT EDIT.
///
/// One method per REST operation, mixed into `CamundaClient`. Every call goes
/// through `requestJson` / `requestVoid` / `requestBytes` (auth, retry,
/// backpressure).
module camunda.generated.operations;

@safe:

import camunda.generated.enums;
import camunda.generated.keys;
import camunda.generated.models;
import camunda.jsonx;
import std.json;

"""


def path_expr(path: str, params: list[str]) -> str:
    """Build a D expression that interpolates path params into `path`."""
    # path like /jobs/{jobKey}/completion
    parts = re.split(r"\{([^}]+)\}", path)
    # even: literal, odd: param
    if len(parts) == 1:
        return d_string(path)
    bits = []
    for i, part in enumerate(parts):
        if i % 2 == 0:
            if part:
                bits.append(d_string(part))
        else:
            ident = d_ident(part)
            bits.append(f"encodeComponent({ident}Path)")
    return " ~ ".join(bits) if bits else d_string("/")


def op_success_schema(spec: Spec, op: dict) -> tuple[str | None, str]:
    """Return (d_type or None for void, kind: json|bytes|text|void|array)."""
    status = op.get("successStatus") or 200
    if status == 204:
        return None, "void"
    ref = op.get("successResponseSchemaRef")
    # camunda-schema-bundler <=2.4.5 records the last pointer segment for deep
    # refs (e.g. "0" for #/components/schemas/X/allOf/0). Trust the metadata
    # only when it names a real component; otherwise resolve from the spec.
    if ref and ref not in (spec.spec.get("components") or {}).get("schemas", {}):
        ref = None
    if ref:
        kind = classify(spec, ref)
        if kind == "key":
            return ref, "json"
        if kind == "enum":
            return ref, "json"
        if kind.startswith("alias:"):
            return kind.split(":", 1)[1], "json"
        return ref, "json"
    # Fall back to the OpenAPI document.
    path = op.get("path")
    method = (op.get("method") or "get").lower()
    item = (spec.spec.get("paths") or {}).get(path) or {}
    operation = item.get(method) or {}
    responses = operation.get("responses") or {}
    resp = responses.get(str(status)) or responses.get("default") or {}
    if "$ref" in resp:
        # skip unresolved
        resp = {}
    content = resp.get("content") or {}
    if "application/octet-stream" in content:
        return "immutable(ubyte)[]", "bytes"
    if "text/xml" in content or "text/plain" in content:
        return "string", "text"
    app = content.get("application/json") or {}
    schema = app.get("schema") or {}
    if schema.get("type") == "array":
        items = schema.get("items") or {}
        inner = d_type_for_schema(spec, items)
        return inner + "[]", "array"
    if schema.get("type") == "object" and not schema.get("properties") and schema.get("additionalProperties"):
        return "JSONValue", "json"
    ref = ref_name(schema)
    if ref:
        return ref, "json"
    if not content:
        return None, "void"
    return "JSONValue", "json"


def _server_path(servers: list | None) -> str | None:
    """Path part of the first server URL (`{schema}://{host}:{port}/v2` -> `/v2`)."""
    if not servers:
        return None
    url = servers[0].get("url") or ""
    rest = url.split("://", 1)[-1]
    i = rest.find("/")
    return "" if i < 0 else rest[i:].rstrip("/")


def op_server_arg(spec: Spec, op: dict) -> str:
    """`, ServerBase.root` when the operation (or its path) declares the bare-root
    server instead of the top-level `/v2` one (cluster-admin ops, #6)."""
    item = (spec.spec.get("paths") or {}).get(op.get("path")) or {}
    operation = item.get((op.get("method") or "get").lower()) or {}
    own = _server_path(operation.get("servers") or item.get("servers"))
    top = _server_path(spec.spec.get("servers")) or ""
    if own is None or own == top:
        return ""
    if own == "":
        return ", ServerBase.root"
    sys.exit(f"unsupported server path {own!r} for {op.get('operationId')} (top-level {top!r})")


def render_operation(spec: Spec, op: dict) -> str:
    op_id = op["operationId"]
    method = (op.get("method") or "get").upper()
    path = op.get("path") or "/"
    summary = (op.get("summary") or op.get("description") or op_id).strip().replace("\n", " ")
    fn = CURATED_NAMES.get(op_id, op_id)
    path_params = list(op.get("pathParams") or [])
    query_params = list(op.get("queryParams") or [])
    has_body = bool(op.get("hasRequestBody"))
    body_ref = op.get("requestBodySchemaRef")
    ctypes = op.get("requestBodyContentTypes") or []
    is_multipart = any("multipart" in c for c in ctypes)
    ret, rkind = op_success_schema(spec, op)

    args = []
    prelude = []
    for p in path_params:
        ident = d_ident(p)
        # Prefer semantic key type when the name matches
        key_type = None
        cand = p[0].upper() + p[1:] if p else p
        if cand in spec.key_names:
            key_type = cand
        elif p.endswith("Key"):
            guess = p[0].upper() + p[1:]
            if guess in spec.key_names:
                key_type = guess
        if key_type:
            args.append(f"{key_type} {ident}")
            prelude.append(f"    const {ident}Path = {ident}.value;")
        else:
            args.append(f"string {ident}")
            prelude.append(f"    const {ident}Path = {ident};")

    body_arg = None
    if has_body and not is_multipart:
        if body_ref:
            kind = classify(spec, body_ref)
            bty = kind.split(":", 1)[1] if kind.startswith("alias:") else body_ref
            if kind in {"string", "integer"}:
                bty = "JSONValue"
            args.append(f"{bty} body_ = {bty}.init")
            body_arg = "body_.toJson()"
            # keys/enums/models all have toJson; JSONValue too via jsonx? we'll add
        elif op.get("requestBodyUnion") and op.get("requestBodyUnionRefs"):
            args.append("JSONValue body_ = JSONValue.init")
            body_arg = "body_"
        else:
            args.append("JSONValue body_ = JSONValue.init")
            body_arg = "body_"
    elif is_multipart:
        args.append("JSONValue body_ = JSONValue.init")
        body_arg = "body_"

    qnames = []
    for q in query_params:
        qn = q["name"] if isinstance(q, dict) else str(q)
        required = bool(q.get("required")) if isinstance(q, dict) else False
        ident = d_ident(qn)
        qnames.append((qn, ident, required))
        if required:
            args.append(f"string {ident}")
        else:
            args.append(f"string {ident} = null")

    sig_args = ", ".join(args)
    ret_ty = ret or "void"
    if is_multipart:
        curated = MULTIPART_CURATED.get(op_id)
        if not curated:
            sys.exit(f"multipart operation {op_id} has no hand-written method; add it to MULTIPART_CURATED and CamundaClient")
        msg = f"{op_id} is multipart/form-data: use CamundaClient.{curated}(...)"
        return "\n".join([
            f"    /// {summary} (`{method} {path}`). Multipart: use `{curated}`.",
            f"    deprecated({d_string(msg)})",
            f"    {ret_ty} {fn}({sig_args})",
            "    {",
            f"        throw new ConfigException({d_string(msg)});",
            "    }",
            "",
        ])
    lines = [
        f"    /// {summary} (`{method} {path}`).",
        f"    {ret_ty} {fn}({sig_args})",
        "    {",
    ]
    lines.extend(prelude)
    path_e = path_expr(path, path_params)
    lines.append(f"        const path_ = {path_e};")
    if qnames:
        lines.append("        string[string] query;")
        for qn, ident, required in qnames:
            if required:
                lines.append(f"        query[{d_string(qn)}] = {ident};")
            else:
                lines.append(f"        if ({ident} !is null) query[{d_string(qn)}] = {ident};")
        query_e = "query"
    else:
        query_e = "null"

    body_e = body_arg if body_arg else "JSONValue.init"
    server_e = op_server_arg(spec, op)

    if rkind == "void":
        lines.append(f"        this.requestVoid({d_string(method)}, path_, {body_e}, {query_e}{server_e});")
    elif rkind == "bytes":
        lines.append(f"        return this.requestBytes({d_string(method)}, path_, {body_e}, {query_e}{server_e});")
    elif rkind == "text":
        lines.append(f"        return this.requestText({d_string(method)}, path_, {body_e}, {query_e}{server_e});")
    elif rkind == "array":
        inner = (ret or "JSONValue[]")[:-2]
        lines.append(f"        auto payload = this.requestJson({d_string(method)}, path_, {body_e}, {query_e}{server_e});")
        if inner == "JSONValue":
            lines.append("        return jsonAsArray(payload);")
        elif inner == "string":
            lines.append("        return jsonArrayOfString(payload);")
        else:
            lines.append(f"        return jsonMapValues(payload, (JSONValue v) => {inner}.fromJson(v));")
    else:
        # json object / key / enum / JSONValue
        lines.append(f"        auto payload = this.requestJson({d_string(method)}, path_, {body_e}, {query_e}{server_e});")
        if ret == "JSONValue":
            lines.append("        return payload;")
        else:
            lines.append(f"        return {ret}.fromJson(payload);")
    lines.append("    }")
    lines.append("")
    return "\n".join(lines)


def hook_04_operations(spec: Spec) -> None:
    methods = []
    for op in spec.operations:
        methods.append(render_operation(spec, op))
    body = (
        OPS_HEADER
        + "mixin template GeneratedOperations()\n{\n"
        + "    import std.uri : encodeComponent;\n\n"
        + "\n".join(methods)
        + "}\n"
    )
    path = OUT_DIR / "operations.d"
    path.write_text(body, encoding="utf-8")
    log("04-operations", f"wrote {path.relative_to(ROOT)} ({len(spec.operations)} operations)")


# ---------------------------------------------------------------------------
# 05 package
# ---------------------------------------------------------------------------

def hook_05_package(spec: Spec) -> None:
    spec_hash = spec.meta.get("specHash") or ""
    body = f"""\
/// Generated by scripts/generate.py (hook 05) — DO NOT EDIT.
module camunda.generated;

@safe:

public import camunda.generated.keys;
public import camunda.generated.enums;
public import camunda.generated.models;
public import camunda.generated.operations;

/// SHA-256 of the bundled OpenAPI spec this tree was generated from.
enum generatedSpecHash = {d_string(spec_hash)};

/// Number of REST operations in the generated facade.
enum generatedOperationCount = {len(spec.operations)};
"""
    path = OUT_DIR / "package.d"
    path.write_text(body, encoding="utf-8")
    log("05-package", f"wrote {path.relative_to(ROOT)}")


# ---------------------------------------------------------------------------
# 06 markdown docs
# ---------------------------------------------------------------------------

def _md_escape(text: str) -> str:
    return (text or "").replace("|", "\\|").replace("\n", " ").strip()


def hook_06_docs(spec: Spec) -> None:
    DOCS_DIR.mkdir(parents=True, exist_ok=True)

    by_tag: dict[str, list[dict]] = {}
    for op in spec.operations:
        tags = op.get("tags") or ["Untagged"]
        by_tag.setdefault(tags[0], []).append(op)

    lines = [
        "# API Reference",
        "",
        f"> {len(spec.operations)} operations across {len(by_tag)} API groups. "
        "Generated by `scripts/generate.py` (hook 06). Do not edit by hand.",
        "",
        "Every REST operation is a method on `CamundaClient` (mixed in from "
        "`camunda.generated.operations`). Curated wrappers (`topology`, "
        "`deployResources`) sit on top of the generated names.",
        "",
        "```d",
        "auto client = CamundaClient.fromEnv();",
        "auto topology = client.topology();",
        "auto page = client.searchProcessInstances(ProcessInstanceSearchQuery.initEmpty());",
        "```",
        "",
    ]
    for tag in sorted(by_tag):
        lines.append(f"## {tag}")
        lines.append("")
        lines.append("| Method | HTTP | Path |")
        lines.append("| --- | --- | --- |")
        for op in by_tag[tag]:
            name = CURATED_NAMES.get(op["operationId"], op["operationId"])
            method = (op.get("method") or "get").upper()
            path = op.get("path") or "/"
            summary = _md_escape(op.get("summary") or "")
            cell = f"`{name}()`"
            if summary:
                cell += f" — {summary}"
            lines.append(f"| {cell} | `{method}` | `{path}` |")
        lines.append("")
    api_path = DOCS_DIR / "api-reference.md"
    api_path.write_text("\n".join(lines), encoding="utf-8")
    log("06-docs", f"wrote {api_path.relative_to(ROOT)} ({len(spec.operations)} operations)")

    sem = [
        "# Semantic Types",
        "",
        "> Generated by `scripts/generate.py` (hook 06). Do not edit by hand.",
        "",
        "Each identifier is a distinct D struct in `camunda.generated.keys`. "
        "Construct with `tryNew` (validates) or `assumeExists` (side-load). "
        "All expose `.value` and serialize as their string.",
        "",
        "| Type | Pattern | Length | Description |",
        "| --- | --- | --- | --- |",
    ]
    keys = list(spec.meta.get("semanticKeys") or [])
    for extra in ("ResourceKey", "ScopeKey", "LongKey"):
        if extra not in spec.semantic and extra in spec.schemas:
            keys.append(extra_string_key(extra, spec.schema(extra)))
    for key in keys:
        name = key["name"]
        constraints = key.get("constraints") or {}
        pattern = constraints.get("pattern")
        pat = f"`{pattern}`" if pattern else "—"
        min_len = constraints.get("minLength")
        max_len = constraints.get("maxLength")
        if min_len is not None and max_len is not None:
            length = f"{min_len}–{max_len}"
        elif max_len is not None:
            length = f"≤ {max_len}"
        elif min_len is not None:
            length = f"≥ {min_len}"
        else:
            length = "—"
        desc = _md_escape(key.get("description") or "")
        sem.append(f"| `{name}` | {pat} | {length} | {desc} |")
    sem.append("")
    sem_path = DOCS_DIR / "semantic-types.md"
    sem_path.write_text("\n".join(sem), encoding="utf-8")
    log("06-docs", f"wrote {sem_path.relative_to(ROOT)} ({len(keys)} types)")


# ---------------------------------------------------------------------------
# 07 per-tag examples + operation-map
# ---------------------------------------------------------------------------

HAND_WRITTEN_EXAMPLES = {"readme.d", "topology.d", "operation-map.json"}


def tag_to_filename(tag: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "_", tag.lower()).strip("_")
    return f"{slug}.d"


def snake_ident(name: str) -> str:
    s = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", name)
    s = re.sub(r"[^a-zA-Z0-9]+", "_", s)
    s = s.lower().strip("_")
    if s in D_KEYWORDS or s[0].isdigit():
        s = s + "_"
    return s


def example_call_args(spec: Spec, op: dict) -> tuple[list[str], list[str]]:
    """Return (param_decls, call_args) for a generated operation."""
    decls: list[str] = []
    args: list[str] = []
    for p in op.get("pathParams") or []:
        ident = d_ident(p)
        cand = p[0].upper() + p[1:] if p else p
        key_type = cand if cand in spec.key_names else None
        if key_type is None and p.endswith("Key"):
            guess = p[0].upper() + p[1:]
            if guess in spec.key_names:
                key_type = guess
        if key_type:
            decls.append(f"{key_type} {ident}")
            args.append(ident)
        else:
            decls.append(f"string {ident}")
            args.append(ident)

    has_body = bool(op.get("hasRequestBody"))
    ctypes = op.get("requestBodyContentTypes") or []
    is_multipart = any("multipart" in c for c in ctypes)
    body_ref = op.get("requestBodySchemaRef")
    if has_body and not is_multipart:
        if body_ref:
            kind = classify(spec, body_ref)
            bty = kind.split(":", 1)[1] if kind.startswith("alias:") else body_ref
            if kind in {"string", "integer"}:
                bty = "JSONValue"
            decls.append(f"{bty} body_")
            args.append("body_")
        else:
            decls.append("JSONValue body_")
            args.append("body_")
    elif is_multipart:
        decls.append("JSONValue body_")
        args.append("body_")

    for q in op.get("queryParams") or []:
        qn = q["name"] if isinstance(q, dict) else str(q)
        required = bool(q.get("required")) if isinstance(q, dict) else False
        ident = d_ident(qn)
        decls.append(f"string {ident}" + ("" if required else " = null"))
        args.append(ident)
    return decls, args


def render_example_fn(spec: Spec, op: dict) -> str:
    op_id = op["operationId"]
    fn = CURATED_NAMES.get(op_id, op_id)
    region = op_id[0].upper() + op_id[1:] if op_id else op_id
    summary = (op.get("summary") or op_id).strip().replace("\n", " ")
    method = (op.get("method") or "get").upper()
    path = op.get("path") or "/"
    if op_id in MULTIPART_EXAMPLES:
        params, call = MULTIPART_EXAMPLES[op_id]
        return "\n".join([
            f"// region {region}",
            f"/// {summary} (`{method} {path}`).",
            f"void {snake_ident(op_id)}(CamundaClient client, {params})",
            "{",
            f"    auto result = {call};",
            "    cast(void) result;",
            "}",
            f"// endregion {region}",
            "",
        ])
    decls, call_args = example_call_args(spec, op)
    d_fn = snake_ident(op_id)
    param_list = ", ".join(["CamundaClient client"] + decls)
    call = f"client.{fn}({', '.join(call_args)})" if call_args else f"client.{fn}()"
    ret, rkind = op_success_schema(spec, op)
    lines = [
        f"// region {region}",
        f"/// {summary} (`{method} {path}`).",
        f"void {d_fn}({param_list})",
        "{",
    ]
    if rkind == "void":
        lines.append(f"    {call};")
    else:
        lines.append(f"    auto result = {call};")
        lines.append("    cast(void) result;")
    lines += ["}", f"// endregion {region}", ""]
    return "\n".join(lines)


def hook_07_examples(spec: Spec) -> None:
    examples_dir = ROOT / "examples"
    examples_dir.mkdir(parents=True, exist_ok=True)

    by_tag: dict[str, list[dict]] = {}
    for op in spec.operations:
        tag = (op.get("tags") or ["Untagged"])[0]
        by_tag.setdefault(tag, []).append(op)

    wanted_files: set[str] = set()
    op_map: dict[str, list[dict]] = {}

    for tag, ops in sorted(by_tag.items()):
        filename = tag_to_filename(tag)
        wanted_files.add(filename)
        module = filename[:-2]
        if module in D_KEYWORDS:
            module = module + "_"
        chunks = [
            "/+ dub.sdl:",
            f'name "example-{module}"',
            'dependency "camunda-orchestration-sdk" path=".."',
            "+/",
            f"/// Compilable usage examples for {tag} operations.",
            f"/// Generated by scripts/generate.py (hook 07) — DO NOT EDIT.",
            f"module example_{module};",
            "",
            "import camunda;",
            "import std.json;",
            "",
        ]
        for op in ops:
            chunks.append(render_example_fn(spec, op))
            region = op["operationId"][0].upper() + op["operationId"][1:]
            op_map[op["operationId"]] = [{
                "file": filename,
                "region": region,
                "label": (op.get("summary") or op["operationId"]).strip(),
            }]
        chunks.append("void main() {}")
        chunks.append("")
        path = examples_dir / filename
        path.write_text("\n".join(chunks), encoding="utf-8")
        log("07-examples", f"wrote {path.relative_to(ROOT)} ({len(ops)} regions)")

    # Remove stale generated example files (keep hand-written ones).
    for existing in examples_dir.glob("*.d"):
        if existing.name in HAND_WRITTEN_EXAMPLES:
            continue
        if existing.name not in wanted_files:
            existing.unlink()
            log("07-examples", f"removed stale {existing.relative_to(ROOT)}")

    map_path = examples_dir / "operation-map.json"
    map_path.write_text(json.dumps(op_map, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    log("07-examples", f"wrote {map_path.relative_to(ROOT)} ({len(op_map)} operations)")


def main() -> int:
    spec = load()
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    print(f"generate: {len(spec.schemas)} schemas, {len(spec.operations)} operations, "
          f"{len(spec.semantic)} semantic keys")
    hook_01_keys(spec)
    hook_02_enums(spec)
    hook_03_models(spec)
    hook_04_operations(spec)
    hook_05_package(spec)
    hook_06_docs(spec)
    hook_07_examples(spec)
    print("generate: done")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
