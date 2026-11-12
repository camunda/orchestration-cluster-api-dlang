#!/usr/bin/env python3
"""Synchronize README.md code snippets from compilable example files.

Replaces fenced blocks after ``<!-- snippet-source: ... | regions: Name -->``
markers with the matching ``// region Name`` ... ``// endregion Name`` body
from ``examples/*.d``. Because those files are type-checked by
``make examples``, the README cannot drift from the real API.

Usage:
    python3 scripts/sync-readme-snippets.py          # update README.md
    python3 scripts/sync-readme-snippets.py --check  # CI: exit 1 if out of sync
"""

from __future__ import annotations

import re
import sys
import textwrap
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
README_PATH = REPO_ROOT / "README.md"
EXAMPLES_DIR = REPO_ROOT / "examples"

_OPEN_RE = re.compile(r"^//\s*#?region\s+([\w.-]+)\s*$")
_CLOSE_RE = re.compile(r"^//\s*#?endregion\s+([\w.-]+)\s*$")

_NEW_MARKER = re.compile(
    r"^<!--\s*snippet-source:\s*\S+\s*\|\s*regions:\s*([\w.+-]+)\s*-->$"
)
_OLD_MARKER = re.compile(r"^<!--\s*snippet:([\w.+-]+)\s*-->$")
_EXEMPT_MARKER = re.compile(r"^<!--\s*snippet-exempt:.*-->$")

_CHECKED_LANGUAGES = {"d"}


def parse_region_tags(path: Path) -> dict[str, str]:
    regions: dict[str, str] = {}
    current: str | None = None
    lines: list[str] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        opened = _OPEN_RE.match(stripped)
        closed = _CLOSE_RE.match(stripped)
        if opened:
            current = opened.group(1)
            lines = []
        elif closed and current == closed.group(1):
            regions[current] = textwrap.dedent("\n".join(lines)).strip("\n")
            current = None
            lines = []
        elif current is not None:
            lines.append(line)
    return regions


def load_all_regions() -> tuple[dict[str, str], dict[str, str]]:
    all_regions: dict[str, str] = {}
    region_source: dict[str, str] = {}
    duplicates: list[str] = []
    for src in sorted(EXAMPLES_DIR.glob("*.d")):
        rel = src.relative_to(REPO_ROOT).as_posix()
        for name, content in parse_region_tags(src).items():
            if name in all_regions:
                duplicates.append(
                    f'region "{name}" defined in both {region_source[name]} and {rel}'
                )
            all_regions[name] = content
            region_source[name] = rel
    if duplicates:
        for msg in duplicates:
            print(f"ERROR: duplicate {msg}", file=sys.stderr)
        sys.exit(1)
    return all_regions, region_source


def _match_marker(line: str) -> re.Match[str] | None:
    return _NEW_MARKER.match(line) or _OLD_MARKER.match(line)


def _build_marker(region_name: str, region_source: dict[str, str]) -> str:
    parts = region_name.split("+") if "+" in region_name else [region_name]
    sources = {region_source[p] for p in parts if p in region_source}
    if len(sources) == 1:
        source_file = next(iter(sources))
    elif sources:
        source_file = ",".join(sorted(sources))
    else:
        source_file = "examples/?.d"
    return f"<!-- snippet-source: {source_file} | regions: {region_name} -->"


def resolve_region(name: str, regions: dict[str, str]) -> str | None:
    if "+" not in name:
        return regions.get(name)
    parts = name.split("+")
    resolved = [regions.get(p) for p in parts]
    if any(r is None for r in resolved):
        return None
    return "\n\n".join(r for r in resolved if r)


def sync_readme(
    regions: dict[str, str],
    region_source: dict[str, str],
    *,
    check: bool = False,
) -> bool:
    lines = README_PATH.read_text(encoding="utf-8").splitlines(keepends=True)
    out: list[str] = []
    i = 0
    changed = False
    missing: list[str] = []
    errors: list[str] = []
    snippet_count = 0

    while i < len(lines):
        line = lines[i].rstrip("\n")
        m = _match_marker(line.strip())
        if not m:
            out.append(lines[i])
            i += 1
            continue

        region_name = m.group(1)
        content = resolve_region(region_name, regions)
        if content is None:
            missing.append(region_name)
            out.append(lines[i])
            i += 1
            continue

        snippet_count += 1
        new_marker = _build_marker(region_name, region_source) + "\n"
        if lines[i] != new_marker:
            changed = True
        out.append(new_marker)
        i += 1

        while i < len(lines) and lines[i].strip() == "":
            out.append(lines[i])
            i += 1

        if i >= len(lines) or not lines[i].strip().startswith("```"):
            errors.append(f"snippet:{region_name} — expected ``` after marker")
            continue

        fence_lang = lines[i].strip()
        close_idx = i + 1
        while close_idx < len(lines) and lines[close_idx].strip() != "```":
            close_idx += 1
        if close_idx >= len(lines):
            errors.append(f"snippet:{region_name} — no closing ``` found")
            out.append(lines[i])
            i += 1
            continue

        new_block = fence_lang + "\n" + content + "\n```\n"
        old_block = "".join(lines[i : close_idx + 1])
        if old_block != new_block:
            changed = True
        out.append(new_block)
        i = close_idx + 1

    if errors:
        for err in errors:
            print(f"ERROR: {err}", file=sys.stderr)
    if missing:
        print(f"ERROR: missing regions: {', '.join(missing)}", file=sys.stderr)
    if errors or missing:
        sys.exit(1)

    new_text = "".join(out)
    if check:
        if changed:
            print("README.md is out of sync with example snippets. Run:")
            print("  python3 scripts/sync-readme-snippets.py")
        return changed

    if changed:
        README_PATH.write_text(new_text, encoding="utf-8", newline="")
        print(f"README.md updated ({snippet_count} snippets synced)")
    else:
        print("README.md is already up to date")
    return changed


def detect_uninjected_code_blocks(readme_path: Path) -> list[tuple[int, str]]:
    lines = readme_path.read_text(encoding="utf-8").splitlines()
    uninjected: list[tuple[int, str]] = []
    for idx, line in enumerate(lines):
        stripped = line.strip()
        if not stripped.startswith("```"):
            continue
        lang = stripped[3:].strip().lower()
        if lang not in _CHECKED_LANGUAGES:
            continue
        prev = idx - 1
        while prev >= 0 and lines[prev].strip() == "":
            prev -= 1
        if prev >= 0:
            prev_stripped = lines[prev].strip()
            if _match_marker(prev_stripped) or _EXEMPT_MARKER.match(prev_stripped):
                continue
        uninjected.append((idx + 1, stripped))
    return uninjected


def main() -> None:
    check = "--check" in sys.argv
    regions, region_source = load_all_regions()
    print(f"Loaded {len(regions)} regions from examples/*.d")
    changed = sync_readme(regions, region_source, check=check)
    uninjected = detect_uninjected_code_blocks(README_PATH)
    if uninjected:
        print(
            f"\nWARNING: {len(uninjected)} D code block(s) in README.md are NOT "
            "snippet-injected (not type-checked):",
            file=sys.stderr,
        )
        for lineno, fence in uninjected:
            print(f"  line {lineno}: {fence}", file=sys.stderr)
        if check:
            print(
                "\nAll D code blocks must be injected from compilable examples in "
                "examples/. Add a snippet marker above each block, move the code to "
                "examples/readme.d with region tags, or mark it "
                "<!-- snippet-exempt: reason -->.",
                file=sys.stderr,
            )
            sys.exit(1)
    if check and changed:
        sys.exit(1)


if __name__ == "__main__":
    main()
