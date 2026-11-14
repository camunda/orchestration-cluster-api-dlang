#!/usr/bin/env bash
# Mark a stable release as GitHub "Latest" when it is the newest GA version.
#
# Invoked by @semantic-release/exec successCmd. semantic-release never marks
# releases from a maintenance branch (stable/N) as Latest, so without this the
# repo's Latest stays on an older release while main only ships prereleases.
#
# Rules:
#   - prereleases (x.y.z-tag) are never marked;
#   - a release is marked only if it is >= the current Latest by version, so a
#     later stable/N release never takes Latest from a newer GA line.
# Like notify-dub.sh, this never fails the release: the tag is already out.
set -uo pipefail

VERSION="${1:?usage: mark-latest.sh <version>}"
REPO="camunda/orchestration-cluster-api-dlang"
TAG="v${VERSION}"

if [[ "${VERSION}" == *-* ]]; then
  echo "[mark-latest] ${TAG} is a prerelease; not marking Latest."
  exit 0
fi

current="$(gh api "repos/${REPO}/releases/latest" --jq .tag_name 2>/dev/null || true)"
if [[ -n "${current}" && "${current}" != "${TAG}" ]]; then
  newest="$(printf '%s\n%s\n' "${current#v}" "${VERSION}" | sort -V | tail -n1)"
  if [[ "${newest}" != "${VERSION}" ]]; then
    echo "[mark-latest] Latest is ${current}, newer than ${TAG}; leaving it."
    exit 0
  fi
fi

if gh release edit "${TAG}" --latest --repo "${REPO}"; then
  echo "[mark-latest] Marked ${TAG} as Latest (was ${current:-none})."
else
  echo "::warning::[mark-latest] could not mark ${TAG} as Latest; run: gh release edit ${TAG} --latest --repo ${REPO}" >&2
fi
exit 0
