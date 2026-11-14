/+ dub.sdl:
name "check-example-coverage"
targetPath ".dub/bin"
+/
/**
Verify every spec operation has a compilable example region.

Usage:
    dub run -q --single scripts/check-example-coverage.d
*/
module check_example_coverage;

import std.algorithm : canFind, map, sort;
import std.array : array;
import std.file : dirEntries, readText, SpanMode;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : lrint;
import std.path : baseName, buildPath, dirName;
import std.regex : ctRegex, matchFirst;
import std.stdio : stderr, writeln;
import std.string : lineSplitter, strip;

/// Region names opened and closed in `path` (`// region X` ... `// endregion X`).
bool[string] regionsIn(string path)
{
    bool[string] found;
    string current;
    foreach (line; readText(path).lineSplitter)
    {
        const stripped = line.strip;
        auto opened = matchFirst(stripped, ctRegex!`^//\s*#?region\s+([\w.\-]+)\s*$`);
        auto closed = matchFirst(stripped, ctRegex!`^//\s*#?endregion\s+([\w.\-]+)\s*$`);
        if (!opened.empty)
            current = opened[1];
        else if (!closed.empty && current !is null && current == closed[1])
        {
            found[current] = true;
            current = null;
        }
    }
    return found;
}

string field(JSONValue entry, string key)
{
    if (entry.type != JSONType.object)
        return null;
    if (auto p = key in entry.object)
        return p.type == JSONType.string ? p.str : null;
    return null;
}

int main()
{
    const root = dirName(dirName(__FILE_FULL_PATH__));
    const examples = buildPath(root, "examples");
    auto meta = parseJSON(readText(buildPath(root, "external-spec", "bundled", "spec-metadata.json")));
    auto operations = meta["operations"].array.map!(op => op["operationId"].str).array;
    bool[string] opSet;
    foreach (op; operations)
        opSet[op] = true;
    auto mapping = parseJSON(readText(buildPath(examples, "operation-map.json"))).object;

    bool[string][string] fileRegions;
    foreach (src; dirEntries(examples, "*.d", SpanMode.shallow))
        fileRegions[baseName(src.name)] = regionsIn(src.name);

    string[] errors;
    foreach (opId; mapping.keys.sort)
    {
        auto entries = mapping[opId];
        if (opId !in opSet)
        {
            errors ~= format("'%s' is not a known exact OpenAPI operationId.", opId);
            continue;
        }
        if (entries.type != JSONType.array || entries.array.length == 0)
        {
            errors ~= format("'%s' must map to a non-empty list of examples.", opId);
            continue;
        }
        foreach (entry; entries.array)
        {
            const fname = field(entry, "file");
            const region = field(entry, "region");
            if (!fname.length || !region.length)
            {
                errors ~= format("'%s' has an entry without file/region.", opId);
                continue;
            }
            if (fname !in fileRegions)
            {
                errors ~= format("'%s' references missing file '%s'.", opId, fname);
                continue;
            }
            if (region !in fileRegions[fname])
                errors ~= format("'%s' references missing region '%s' in %s.", opId, region, fname);
        }
    }

    if (errors.length)
    {
        stderr.writeln("Example map integrity errors:");
        foreach (e; errors)
            stderr.writeln("  - ", e);
        return 1;
    }

    string[] missing;
    foreach (op; operations)
        if (op !in mapping)
            missing ~= op;
    const covered = operations.length - missing.length;
    const pct = operations.length ? lrint(100.0 * covered / operations.length) : 0;
    writeln("Spec operations: ", operations.length);
    writeln("Covered:         ", covered);
    writeln("Missing:         ", missing.length);
    writeln("Coverage:        ", pct, "%");
    if (missing.length)
    {
        stderr.writeln("\nMissing examples for:");
        foreach (op; missing)
            stderr.writeln("  - ", op);
        return 1;
    }
    writeln("\nExample coverage is complete.");
    return 0;
}
