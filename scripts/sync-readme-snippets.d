/+ dub.sdl:
name "sync-readme-snippets"
targetPath ".dub/bin"
+/
/**
Synchronize README.md code snippets from compilable example files.

Replaces fenced blocks after `<!-- snippet-source: ... | regions: Name -->`
markers with the matching `// region Name` ... `// endregion Name` body
from `examples/*.d`. Because those files are type-checked by
`make examples`, the README cannot drift from the real API.

Usage:
    dub run -q --single scripts/sync-readme-snippets.d              # update README.md
    dub run -q --single scripts/sync-readme-snippets.d -- --check   # CI: exit 1 if out of sync
*/
module sync_readme_snippets;

import std.algorithm : all, canFind, map, sort, startsWith;
import std.array : array, join, split;
import std.file : dirEntries, readText, SpanMode, write;
import std.format : format;
import std.path : buildPath, dirName, relativePath;
import std.regex : ctRegex, matchFirst;
import std.stdio : stderr, writeln;
import std.string : KeepTerminator, splitLines, strip, stripLeft, stripRight, toLower;

immutable string REPO_ROOT;
immutable string README_PATH;
immutable string EXAMPLES_DIR;

shared static this()
{
    REPO_ROOT = dirName(dirName(__FILE_FULL_PATH__));
    README_PATH = buildPath(REPO_ROOT, "README.md");
    EXAMPLES_DIR = buildPath(REPO_ROOT, "examples");
}

enum OPEN_RE = ctRegex!`^//\s*#?region\s+([\w.\-]+)\s*$`;
enum CLOSE_RE = ctRegex!`^//\s*#?endregion\s+([\w.\-]+)\s*$`;
enum NEW_MARKER = ctRegex!`^<!--\s*snippet-source:\s*\S+\s*\|\s*regions:\s*([\w.+\-]+)\s*-->$`;
enum OLD_MARKER = ctRegex!`^<!--\s*snippet:([\w.+\-]+)\s*-->$`;
enum EXEMPT_MARKER = ctRegex!`^<!--\s*snippet-exempt:.*-->$`;

immutable CHECKED_LANGUAGES = ["d"];

noreturn fail()
{
    import core.stdc.stdlib : exit;
    exit(1);
    assert(0);
}

/// Python's `textwrap.dedent`: strip the common leading whitespace.
string dedent(string text)
{
    auto lines = text.split("\n");
    foreach (ref l; lines)
        if (l.length && l.all!(c => c == ' ' || c == '\t'))
            l = "";
    string margin = null;
    foreach (l; lines)
    {
        if (!l.length)
            continue;
        const indent = l[0 .. l.length - l.stripLeft(" \t").length];
        if (margin is null)
            margin = indent;
        else if (indent.startsWith(margin))
        {
        }
        else if (margin.startsWith(indent))
            margin = indent;
        else
        {
            size_t i = 0;
            while (i < margin.length && i < indent.length && margin[i] == indent[i])
                i++;
            margin = margin[0 .. i];
        }
    }
    if (margin.length)
        foreach (ref l; lines)
            if (l.startsWith(margin))
                l = l[margin.length .. $];
    return lines.join("\n");
}

string stripNewlines(string s) { return s.strip("\n"); }

string[string] parseRegionTags(string path)
{
    string[string] regions;
    string current;
    string[] lines;
    foreach (line; readText(path).splitLines)
    {
        const stripped = line.strip;
        auto opened = matchFirst(stripped, OPEN_RE);
        auto closed = matchFirst(stripped, CLOSE_RE);
        if (!opened.empty)
        {
            current = opened[1];
            lines = null;
        }
        else if (!closed.empty && current !is null && current == closed[1])
        {
            regions[current] = stripNewlines(dedent(lines.join("\n")));
            current = null;
            lines = null;
        }
        else if (current !is null)
            lines ~= line;
    }
    return regions;
}

void loadAllRegions(out string[string] allRegions, out string[string] regionSource)
{
    string[] duplicates;
    auto sources = dirEntries(EXAMPLES_DIR, "*.d", SpanMode.shallow).map!(e => e.name).array.sort;
    foreach (src; sources)
    {
        const rel = relativePath(src, REPO_ROOT);
        auto found = parseRegionTags(src);
        foreach (name; found.keys.sort)
        {
            if (name in allRegions)
                duplicates ~= format(`region "%s" defined in both %s and %s`, name, regionSource[name], rel);
            allRegions[name] = found[name];
            regionSource[name] = rel;
        }
    }
    if (duplicates.length)
    {
        foreach (msg; duplicates)
            stderr.writeln("ERROR: duplicate ", msg);
        fail();
    }
}

/// The region name of a snippet marker line, or null.
string matchMarker(string line)
{
    auto m = matchFirst(line, NEW_MARKER);
    if (m.empty)
        m = matchFirst(line, OLD_MARKER);
    return m.empty ? null : m[1];
}

string buildMarker(string regionName, string[string] regionSource)
{
    auto parts = regionName.canFind('+') ? regionName.split("+") : [regionName];
    bool[string] sources;
    foreach (p; parts)
        if (auto s = p in regionSource)
            sources[*s] = true;
    string sourceFile;
    if (sources.length == 1)
        sourceFile = sources.keys[0];
    else if (sources.length)
        sourceFile = sources.keys.sort.join(",");
    else
        sourceFile = "examples/?.d";
    return "<!-- snippet-source: " ~ sourceFile ~ " | regions: " ~ regionName ~ " -->";
}

string resolveRegion(string name, string[string] regions)
{
    if (!name.canFind('+'))
        return name in regions ? regions[name] : null;
    string[] resolved;
    foreach (p; name.split("+"))
    {
        if (p !in regions)
            return null;
        if (regions[p].length)
            resolved ~= regions[p];
    }
    return resolved.join("\n\n");
}

bool syncReadme(string[string] regions, string[string] regionSource, bool check)
{
    auto lines = readText(README_PATH).splitLines(KeepTerminator.yes);
    string[] out_;
    size_t i = 0;
    bool changed;
    string[] missing, errors;
    size_t snippetCount;

    while (i < lines.length)
    {
        const regionName = matchMarker(lines[i].stripRight("\n").strip);
        if (regionName is null)
        {
            out_ ~= lines[i++];
            continue;
        }
        const content = resolveRegion(regionName, regions);
        if (content is null)
        {
            missing ~= regionName;
            out_ ~= lines[i++];
            continue;
        }

        snippetCount++;
        const newMarker = buildMarker(regionName, regionSource) ~ "\n";
        if (lines[i] != newMarker)
            changed = true;
        out_ ~= newMarker;
        i++;

        while (i < lines.length && lines[i].strip == "")
            out_ ~= lines[i++];

        if (i >= lines.length || !lines[i].strip.startsWith("```"))
        {
            errors ~= "snippet:" ~ regionName ~ " — expected ``` after marker";
            continue;
        }

        const fenceLang = lines[i].strip;
        size_t closeIdx = i + 1;
        while (closeIdx < lines.length && lines[closeIdx].strip != "```")
            closeIdx++;
        if (closeIdx >= lines.length)
        {
            errors ~= "snippet:" ~ regionName ~ " — no closing ``` found";
            out_ ~= lines[i++];
            continue;
        }

        const newBlock = fenceLang ~ "\n" ~ content ~ "\n```\n";
        if (lines[i .. closeIdx + 1].join != newBlock)
            changed = true;
        out_ ~= newBlock;
        i = closeIdx + 1;
    }

    foreach (err; errors)
        stderr.writeln("ERROR: ", err);
    if (missing.length)
        stderr.writeln("ERROR: missing regions: ", missing.join(", "));
    if (errors.length || missing.length)
        fail();

    if (check)
    {
        if (changed)
        {
            writeln("README.md is out of sync with example snippets. Run:");
            writeln("  make sync-readme");
        }
        return changed;
    }
    if (changed)
    {
        write(README_PATH, out_.join);
        writeln(format("README.md updated (%s snippets synced)", snippetCount));
    }
    else
        writeln("README.md is already up to date");
    return changed;
}

struct Uninjected
{
    size_t line;
    string fence;
}

Uninjected[] detectUninjectedCodeBlocks(string readmePath)
{
    auto lines = readText(readmePath).splitLines;
    Uninjected[] found;
    foreach (idx, line; lines)
    {
        const stripped = line.strip;
        if (!stripped.startsWith("```"))
            continue;
        const lang = stripped[3 .. $].strip.toLower;
        if (!CHECKED_LANGUAGES.canFind(lang))
            continue;
        long prev = cast(long) idx - 1;
        while (prev >= 0 && lines[prev].strip == "")
            prev--;
        if (prev >= 0)
        {
            const prevStripped = lines[prev].strip;
            if (matchMarker(prevStripped) !is null || !matchFirst(prevStripped, EXEMPT_MARKER).empty)
                continue;
        }
        found ~= Uninjected(idx + 1, stripped);
    }
    return found;
}

int main(string[] argv)
{
    const check = argv[1 .. $].canFind("--check");
    string[string] regions, regionSource;
    loadAllRegions(regions, regionSource);
    writeln(format("Loaded %s regions from examples/*.d", regions.length));
    const changed = syncReadme(regions, regionSource, check);
    auto uninjected = detectUninjectedCodeBlocks(README_PATH);
    if (uninjected.length)
    {
        stderr.writeln(format("\nWARNING: %s D code block(s) in README.md are NOT "
            ~ "snippet-injected (not type-checked):", uninjected.length));
        foreach (u; uninjected)
            stderr.writeln(format("  line %s: %s", u.line, u.fence));
        if (check)
        {
            stderr.writeln("\nAll D code blocks must be injected from compilable examples in "
                ~ "examples/. Add a snippet marker above each block, move the code to "
                ~ "examples/readme.d with region tags, or mark it "
                ~ "<!-- snippet-exempt: reason -->.");
            return 1;
        }
    }
    return check && changed ? 1 : 0;
}
