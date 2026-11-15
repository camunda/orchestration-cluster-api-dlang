#!/usr/bin/env bash
# Repair a half-finished semantic-release run: the release commit and tag were
# pushed, but the run died before the git note and/or the GitHub Release were
# created (e.g. a transient rejection pushing refs/notes/semantic-release-*).
# On the next run semantic-release finds the tag, treats the version as
# released, and stops — so the missing pieces never appear on their own.
#
# Invoked by .github/workflows/publish.yml with `if: failure()` after the
# semantic-release step, and by hand via `make repair-release TAG=vX.Y.Z`
# (or the publish workflow's `repair-tag` dispatch input).
#
# The script is idempotent and only ever touches the *newest* tag reachable
# from HEAD. It:
#   1. finds the newest v* tag reachable from HEAD (or uses $1 / $TAG);
#      exits 0 when a GitHub Release already exists for it;
#   2. verifies HEAD is the release commit for that tag
#      (`chore(release): X [skip ci]`, the commit the tag points to) — if not,
#      the failure happened before tagging, so it logs, changes nothing and
#      exits 0 (the job's own failure stands; a re-run is the right fix);
#   3. recreates refs/notes/semantic-release-<tag> when missing, deriving the
#      channel from release.config.cjs's branch config (via node), and pushes
#      it with up to 3 attempts and backoff;
#   4. creates the GitHub Release from the tag's CHANGELOG.md section with
#      --verify-tag (--prerelease --latest=false for prereleases; --latest=false
#      plus scripts/mark-latest.sh for stable releases, so the existing
#      never-demote rule decides whether it becomes Latest);
#   5. prints a ::warning:: summary of what was repaired.
#
# Exit codes: 0 = nothing to repair or fully repaired; 1 = a repair was
# attempted but failed. The workflow step appends `&& exit 1 || exit 1` so the
# job still fails after a successful repair — the incident stays visible.
set -uo pipefail

REPO="${GITHUB_REPOSITORY:-camunda/orchestration-cluster-api-dlang}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

log()  { echo "[repair-release] $*"; }
warn() { echo "::warning::[repair-release] $*"; }
die()  { echo "::error::[repair-release] $*" >&2; exit 1; }

# --- 1. Pick the tag ---------------------------------------------------------

TAG="${1:-${TAG:-}}"
if [[ -z "${TAG}" ]]; then
  TAG="$(git tag -l 'v*' --sort=-version:refname --merged HEAD 2>/dev/null | head -n1 || true)"
fi
if [[ -z "${TAG}" ]]; then
  log "no v* tag reachable from HEAD; nothing to repair."
  exit 0
fi
log "newest tag reachable from HEAD: ${TAG}"

if gh release view "${TAG}" --repo "${REPO}" >/dev/null 2>&1; then
  log "GitHub Release for ${TAG} already exists; nothing to repair."
  exit 0
fi

# --- 2. HEAD must be the release commit for the tag --------------------------

VERSION="${TAG#v}"
tag_commit="$(git rev-list -n1 "${TAG}")"
head_commit="$(git rev-parse HEAD)"
head_subject="$(git log -1 --format=%s HEAD)"
if [[ "${head_commit}" != "${tag_commit}" || "${head_subject}" != "chore(release): ${VERSION} [skip ci]" ]]; then
  log "HEAD (${head_commit:0:7}: ${head_subject}) is not the release commit for ${TAG};"
  log "the failure happened before tagging — nothing repaired, re-run the release."
  exit 0
fi

# --- 3. Channel for the semantic-release note --------------------------------
# Derive what release.config.cjs's branch config implies for this branch
# rather than hard-coding: main → "alpha" (prerelease id), the current stable
# line → "latest", an older stable/N → "N-stable".

BRANCH="${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')}"
CHANNEL="$(BRANCH="${BRANCH}" node - "${REPO_ROOT}" <<'NODE'
const path = require('node:path');
const repoRoot = process.argv[2];
process.env.GITHUB_REF_NAME = process.env.BRANCH || process.env.GITHUB_REF_NAME || '';
const cfg = require(path.join(repoRoot, 'release.config.cjs'));
const entry = (cfg.branches || []).find(
  (b) => (typeof b === 'string' ? b : b && b.name) === process.env.GITHUB_REF_NAME,
);
let channel = entry && typeof entry === 'object' ? entry.channel : undefined;
if (!channel && entry && typeof entry === 'object' && entry.prerelease) {
  channel = entry.prerelease; // semantic-release defaults channel to the prerelease id
}
if (!channel) channel = 'latest';
process.stdout.write(channel);
NODE
)"
if [[ -z "${CHANNEL}" ]]; then
  die "could not derive the release channel for branch '${BRANCH}' from release.config.cjs"
fi
log "branch '${BRANCH}' releases on channel '${CHANNEL}'"

# --- 4. Recreate the git note when missing ------------------------------------

NOTE_REF="refs/notes/semantic-release-${TAG}"
repaired=()

git fetch origin "${NOTE_REF}:${NOTE_REF}" >/dev/null 2>&1 || true
if git notes --ref="semantic-release-${TAG}" show "${TAG}" >/dev/null 2>&1; then
  log "note ${NOTE_REF} already present."
elif git ls-remote origin "${NOTE_REF}" | grep -q .; then
  log "note ${NOTE_REF} exists on the remote."
else
  log "writing missing note ${NOTE_REF}: {\"channels\":[\"${CHANNEL}\"]}"
  git notes --ref="semantic-release-${TAG}" add -f -m "{\"channels\":[\"${CHANNEL}\"]}" "${TAG}" \
    || die "failed to write note for ${TAG}"
  pushed=0
  for attempt in 1 2 3; do
    if git push origin "${NOTE_REF}" >/dev/null 2>&1; then
      pushed=1
      break
    fi
    log "note push attempt ${attempt}/3 failed; retrying after backoff."
    sleep $((attempt * 5))
  done
  if [[ "${pushed}" != "1" ]]; then
    die "could not push ${NOTE_REF} after 3 attempts"
  fi
  repaired+=("git note ${NOTE_REF} (channels: ${CHANNEL})")
fi

# --- 5. Create the GitHub Release from the CHANGELOG section ------------------

notes_file="$(mktemp)"
trap 'rm -f "${notes_file}"' EXIT
# The section for this version: from its heading to the next release heading,
# taken from the CHANGELOG.md of the release commit itself (the tag's blob),
# so the notes match what semantic-release wrote at release time.
# CHANGELOG headings carry the bare version (`# [11.0.0-alpha.4](...)`), no `v`.
git show "${TAG}:CHANGELOG.md" 2>/dev/null | awk -v ver="${VERSION}" '
  $0 ~ "^# \\[" ver "\\]" { in_section = 1; next }
  in_section && /^# \[/ { exit }
  in_section { print }
' > "${notes_file}"
if [[ ! -s "${notes_file}" ]]; then
  die "no CHANGELOG.md section found for ${TAG} at ${TAG}:CHANGELOG.md"
fi

release_args=(create "${TAG}" --repo "${REPO}" --verify-tag --latest=false --notes-file "${notes_file}")
if [[ "${VERSION}" == *-* ]]; then
  release_args+=(--prerelease)
fi
if ! gh release "${release_args[@]}"; then
  die "failed to create GitHub Release for ${TAG}"
fi
repaired+=("GitHub Release ${TAG}")

# A stable release may deserve Latest; the existing never-demote rule decides.
if [[ "${VERSION}" != *-* ]]; then
  bash "${SCRIPT_DIR}/mark-latest.sh" "${VERSION}" || true
fi

# --- 6. Summary ----------------------------------------------------------------

if ((${#repaired[@]})); then
  warn "repaired half-finished release ${TAG}: ${repaired[*]}"
else
  log "nothing was missing for ${TAG}."
fi
exit 0
