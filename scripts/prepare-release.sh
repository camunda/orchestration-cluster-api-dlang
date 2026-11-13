#!/usr/bin/env bash
# Stamp the semantic-release-resolved version into dub.json and
# runtime/source/camunda/version_.d. Invoked by @semantic-release/exec prepareCmd.
set -euo pipefail

VERSION="${1:?usage: prepare-release.sh <version>}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

python3 - "$REPO_ROOT/dub.json" "$VERSION" <<'PY'
import json, sys
path, version = sys.argv[1], sys.argv[2]
data = json.loads(open(path, encoding="utf-8").read())
data["version"] = version
open(path, "w", encoding="utf-8").write(json.dumps(data, indent=2) + "\n")
PY

cat > "$REPO_ROOT/runtime/source/camunda/version_.d" <<D
/// Package version, stamped by \`scripts/prepare-release.sh\` during semantic-release.
module camunda.version_;

@safe:

/// SemVer of this SDK (\`dub.json\` \`version\`, git tag \`v\` + this string).
enum sdkVersion = "${VERSION}";

/// \`User-Agent\` product token.
enum sdkUserAgent = "camunda-orchestration-sdk-d/" ~ sdkVersion;
D

echo "[prepare-release] Wrote version ${VERSION} to dub.json and runtime/source/camunda/version_.d"
