#!/usr/bin/env bash
# Stamp the semantic-release-resolved version into runtime/source/camunda/version_.d
# (the User-Agent). Invoked by @semantic-release/exec prepareCmd.
# dub.json has no "version": the DUB registry takes versions from git tags and
# rejects packages whose dub.json declares one.
set -euo pipefail

VERSION="${1:?usage: prepare-release.sh <version>}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

cat > "$REPO_ROOT/runtime/source/camunda/version_.d" <<D
/// Package version, stamped by \`scripts/prepare-release.sh\` during semantic-release.
module camunda.version_;

@safe:

/// SemVer of this SDK (git tag \`v\` + this string).
enum sdkVersion = "${VERSION}";

/// \`User-Agent\` product token.
enum sdkUserAgent = "camunda-orchestration-sdk-d/" ~ sdkVersion;
D

echo "[prepare-release] Wrote version ${VERSION} to runtime/source/camunda/version_.d"
