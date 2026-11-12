#!/usr/bin/env python3
"""Verify every spec operation has a compilable example region.

Usage:
    python3 scripts/check-example-coverage.py
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
META = ROOT / "external-spec" / "bundled" / "spec-metadata.json"
MAP = ROOT / "examples" / "operation-map.json"
EXAMPLES = ROOT / "examples"

_OPEN_RE = re.compile(r"^//\s*#?region\s+([\w.-]+)\s*$")
_CLOSE_RE = re.compile(r"^//\s*#?endregion\s+([\w.-]+)\s*$")


def regions_in(path: Path) -> set[str]:
    found: set[str] = set()
    current = None
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        opened = _OPEN_RE.match(stripped)
        closed = _CLOSE_RE.match(stripped)
        if opened:
            current = opened.group(1)
        elif closed and current == closed.group(1):
            found.add(current)
            current = None
    return found


def main() -> int:
    meta = json.loads(META.read_text(encoding="utf-8"))
    operations = [op["operationId"] for op in meta["operations"]]
    op_set = set(operations)
    mapping = json.loads(MAP.read_text(encoding="utf-8"))

    file_regions: dict[str, set[str]] = {}
    for src in EXAMPLES.glob("*.d"):
        file_regions[src.name] = regions_in(src)

    errors: list[str] = []
    for op_id, entries in mapping.items():
        if op_id not in op_set:
            errors.append(f"'{op_id}' is not a known exact OpenAPI operationId.")
            continue
        if not isinstance(entries, list) or not entries:
            errors.append(f"'{op_id}' must map to a non-empty list of examples.")
            continue
        for entry in entries:
            fname = entry.get("file")
            region = entry.get("region")
            if not fname or not region:
                errors.append(f"'{op_id}' has an entry without file/region.")
                continue
            if fname not in file_regions:
                errors.append(f"'{op_id}' references missing file '{fname}'.")
                continue
            if region not in file_regions[fname]:
                errors.append(f"'{op_id}' references missing region '{region}' in {fname}.")

    if errors:
        print("Example map integrity errors:", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        return 1

    missing = [op for op in operations if op not in mapping]
    covered = len(operations) - len(missing)
    pct = 0 if not operations else round(100 * covered / len(operations))
    print(f"Spec operations: {len(operations)}")
    print(f"Covered:         {covered}")
    print(f"Missing:         {len(missing)}")
    print(f"Coverage:        {pct}%")
    if missing:
        print("\nMissing examples for:", file=sys.stderr)
        for op in missing:
            print(f"  - {op}", file=sys.stderr)
        return 1
    print("\nExample coverage is complete.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
