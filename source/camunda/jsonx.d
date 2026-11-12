/// @safe JSON helpers. Phobos's `JSONValue.object` / `.array` are `@system`
/// because they return `ref`; these wrappers copy through `objectNoRef` /
/// `arrayNoRef` or mutate behind a small `@trusted` boundary.
module camunda.jsonx;

@safe:

import std.json;

JSONValue emptyObject()
{
    JSONValue[string] obj;
    return JSONValue(obj);
}

bool jsonHas(const JSONValue obj, string key) pure
{
    if (obj.type != JSONType.object) return false;
    return (key in obj.objectNoRef) !is null;
}

JSONValue jsonGet(const JSONValue obj, string key)
{
    if (obj.type != JSONType.object) return JSONValue(null);
    auto p = key in obj.objectNoRef;
    return p is null ? JSONValue(null) : *p;
}

string jsonGetString(const JSONValue obj, string key)
{
    return jsonValueString(jsonGet(obj, key));
}

long jsonGetLong(const JSONValue obj, string key)
{
    return jsonValueLong(jsonGet(obj, key));
}

double jsonGetDouble(const JSONValue obj, string key)
{
    return jsonValueDouble(jsonGet(obj, key));
}

bool jsonGetBool(const JSONValue obj, string key)
{
    return jsonValueBool(jsonGet(obj, key));
}

string jsonValueString(const JSONValue v)
{
    if (v.type == JSONType.string) return v.str;
    if (v.type == JSONType.null_) return null;
    return v.toString;
}

long jsonValueLong(const JSONValue v)
{
    if (v.type == JSONType.integer) return v.integer;
    if (v.type == JSONType.uinteger) return cast(long) v.uinteger;
    if (v.type == JSONType.float_) return cast(long) v.floating;
    if (v.type == JSONType.string)
    {
        import std.conv : to;
        try return v.str.to!long;
        catch (Exception) return 0;
    }
    return 0;
}

double jsonValueDouble(const JSONValue v)
{
    if (v.type == JSONType.float_) return v.floating;
    if (v.type == JSONType.integer) return cast(double) v.integer;
    if (v.type == JSONType.uinteger) return cast(double) v.uinteger;
    if (v.type == JSONType.string)
    {
        import std.conv : to;
        try return v.str.to!double;
        catch (Exception) return 0;
    }
    return 0;
}

bool jsonValueBool(const JSONValue v)
{
    if (v.type == JSONType.true_) return true;
    if (v.type == JSONType.false_ || v.type == JSONType.null_) return false;
    if (v.type == JSONType.integer) return v.integer != 0;
    if (v.type == JSONType.string) return v.str == "true" || v.str == "1";
    return false;
}

JSONValue[] jsonAsArray(const JSONValue v)
{
    if (v.type != JSONType.array) return null;
    return v.arrayNoRef.dup;
}

string[] jsonGetStringArray(const JSONValue obj, string key)
{
    return jsonArrayOfString(jsonGet(obj, key));
}

int[] jsonGetIntArray(const JSONValue obj, string key)
{
    auto arr = jsonAsArray(jsonGet(obj, key));
    auto out_ = new int[](arr.length);
    foreach (i, item; arr) out_[i] = cast(int) jsonValueLong(item);
    return out_;
}

long[] jsonGetLongArray(const JSONValue obj, string key)
{
    auto arr = jsonAsArray(jsonGet(obj, key));
    auto out_ = new long[](arr.length);
    foreach (i, item; arr) out_[i] = jsonValueLong(item);
    return out_;
}

JSONValue[] jsonGetArray(const JSONValue obj, string key)
{
    return jsonAsArray(jsonGet(obj, key));
}

string[] jsonArrayOfString(const JSONValue v)
{
    auto arr = jsonAsArray(v);
    auto out_ = new string[](arr.length);
    foreach (i, item; arr) out_[i] = jsonValueString(item);
    return out_;
}

T[] jsonMapArray(T)(const JSONValue obj, string key, scope T delegate(JSONValue) @safe map)
{
    return jsonMapValues(jsonGet(obj, key), map);
}

T[] jsonMapValues(T)(const JSONValue v, scope T delegate(JSONValue) @safe map)
{
    auto arr = jsonAsArray(v);
    auto out_ = new T[](arr.length);
    foreach (i, item; arr) out_[i] = map(item);
    return out_;
}

JSONValue jsonFromMapped(T)(const T[] items, scope JSONValue delegate(T) @safe map)
{
    auto arr = new JSONValue[](items.length);
    foreach (i, item; items) arr[i] = map(item);
    return JSONValue(arr);
}

/// `@trusted`: `JSONValue.object` is `@system` because it returns `ref`. We
/// only write `value` under `key` on an object this function owns or that the
/// caller passed in to be mutated.
void jsonSet(ref JSONValue obj, string key, JSONValue value) @trusted
{
    if (obj.type != JSONType.object) obj = emptyObject();
    obj.object[key] = value;
}

JSONValue toJson(JSONValue v)
{
    return v;
}

unittest
{
    auto o = emptyObject();
    jsonSet(o, "n", JSONValue(3));
    assert(jsonGetLong(o, "n") == 3);
    assert(jsonHas(o, "n"));
    assert(!jsonHas(o, "missing"));
    jsonSet(o, "s", JSONValue("hi"));
    assert(jsonGetString(o, "s") == "hi");
}
