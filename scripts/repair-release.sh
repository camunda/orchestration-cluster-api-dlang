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
# The script is idempotent. It repairs the *newest* tag reachable from HEAD
# (auto mode), or an explicitly requested tag (manual mode, $1 / $TAG). It:
#   1. picks the tag: $1 / $TAG when given, else the newest v* tag reachable
#      from HEAD; tracks whether a GitHub Release already exists for it;
#   2. validates the tag. In auto mode HEAD must be the release commit for
#      that tag (`chore(release): X [skip ci]`) — if not, the failure happened
#      before tagging, so it logs, changes nothing and exits 0 (the job's own
#      failure stands; a re-run is the right fix). In manual mode the tag must
#      exist and its commit must be reachable from the current branch (the
#      workflow runs at the branch tip, which may have moved past the tag);
#   3. recreates refs/notes/semantic-release-<tag> when missing, deriving the
#      channel from the release.config.cjs branch model in pure bash (no Node.js
#      / npm dependency), and pushes
#      it with up to 3 attempts and backoff — retried whenever the note is
#      absent from origin, even if a local note already exists;
#   4. creates the GitHub Release from the tag's CHANGELOG.md section with
#      --verify-tag (--prerelease --latest=false for prereleases; --latest=false
#      for stable releases) — skipped when the release already exists. For a
#      stable (GA) version it then runs scripts/mark-latest.sh *unconditionally*
#      — even when the release already existed — so a retry whose earlier
#      attempt created the release but died before marking it Latest still
#      reconciles Latest; the never-demote rule there decides;
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

EXPLICIT=0
TAG="${1:-${TAG:-}}"
if [[ -n "${TAG}" ]]; then
  EXPLICIT=1
else
  # Auto mode: prefer a v* tag pointing *at* HEAD. Git's descending version
  # order ranks a prerelease (v11.0.0-alpha.4) above the GA it precedes
  # (v11.0.0), so the newest *reachable* tag can be an ancestor's prerelease
  # even when HEAD is the new stable release commit — and the HEAD-equality
  # guard below would then skip repairing that stable release. Only when no tag
  # points at HEAD do we fall back to the newest reachable tag, which exists
  # solely to drive the no-op diagnostic ("the failure happened before
  # tagging").
  head_commit_for_pick="$(git rev-parse HEAD 2>/dev/null || true)"
  # Among the tags at HEAD, prefer a GA release (no prerelease `-`) over a
  # prerelease: every version sort ranks a prerelease above the GA it precedes,
  # so a plain "newest" pick could still select the prerelease here.
  TAG="$(git tag -l 'v*' --points-at "${head_commit_for_pick}" 2>/dev/null \
    | grep -v -- '-' | sort -V | tail -n1 || true)"
  if [[ -z "${TAG}" ]]; then
    TAG="$(git tag -l 'v*' --points-at "${head_commit_for_pick}" 2>/dev/null \
      | sort -V | tail -n1 || true)"
  fi
  if [[ -z "${TAG}" ]]; then
    TAG="$(git tag -l 'v*' --sort=-version:refname --merged HEAD 2>/dev/null | head -n1 || true)"
  fi
fi
if [[ -z "${TAG}" ]]; then
  log "no v* tag reachable from HEAD; nothing to repair."
  exit 0
fi
log "tag to repair: ${TAG} (mode: $( ((EXPLICIT)) && echo explicit || echo auto ))"

# Track release existence separately from the note: a GitHub Release existing
# does not establish that the semantic-release note exists, so this never
# short-circuits the note repair below.
RELEASE_EXISTS=0
if gh release view "${TAG}" --repo "${REPO}" >/dev/null 2>&1; then
  RELEASE_EXISTS=1
  log "GitHub Release for ${TAG} already exists; will skip its re-creation."
fi

# --- 2. Validate the tag -------------------------------------------------------

VERSION="${TAG#v}"
# An explicit repair target must be an exact tag ref, not just any resolvable
# revision: `rev-list` and the reachability check below both accept `HEAD` or a
# branch name, which would otherwise push a bogus refs/notes/semantic-release-HEAD
# before failing CHANGELOG extraction. Resolve only refs/tags/<name> so an
# invalid repair request dies before anything is pushed to origin. (Auto mode
# always yields a real tag, but the check is cheap and keeps the invariant in
# one place.)
tag_commit="$(git rev-list -n1 "refs/tags/${TAG}" 2>/dev/null || true)"
if [[ -z "${tag_commit}" ]]; then
  if ((EXPLICIT)); then
    die "no tag named ${TAG} (refs/tags/${TAG} does not resolve); refusing to repair a non-tag revision."
  fi
  die "tag ${TAG} does not exist locally; cannot repair."
fi

if ((EXPLICIT)); then
  # Manual mode: the workflow runs at the selected branch tip, which may have
  # moved past the tag (or gained a regeneration commit). HEAD need not be the
  # release commit — instead require the tagged commit to be reachable from
  # HEAD so we never repair a tag that is not on this branch's history.
  if ! git merge-base --is-ancestor "${tag_commit}" HEAD 2>/dev/null; then
    die "tag ${TAG} (${tag_commit:0:7}) is not reachable from HEAD; refusing to repair a tag outside this branch."
  fi
  log "explicit tag ${TAG} is reachable from HEAD; proceeding."
else
  # Auto mode: only repair when HEAD is the release commit for the newest tag.
  head_commit="$(git rev-parse HEAD)"
  head_subject="$(git log -1 --format=%s HEAD)"
  if [[ "${head_commit}" != "${tag_commit}" || "${head_subject}" != "chore(release): ${VERSION} [skip ci]" ]]; then
    log "HEAD (${head_commit:0:7}: ${head_subject}) is not the release commit for ${TAG};"
    log "the failure happened before tagging — nothing repaired, re-run the release."
    exit 0
  fi
fi

# --- 3. Channel for the semantic-release note --------------------------------
# Derive the channel the release.config.cjs branch model implies for this
# branch. This mirrors the branch rules in
# @camunda8/sdk-infra/configs/release.config.base.cjs (read via
# release.config.cjs), but is computed in pure bash so the repair tooling — and
# its test harness — runs on the documented D-only development setup, with no
# Node.js or npm-installed release dependencies (README reserves those for
# `make generate` / spec fetching). The branch model, for reference:
#   main                    → "alpha"  (prerelease id)
#   stable/<current major>  → "latest"
#   stable/<older major>    → "<major>-stable"
# CAMUNDA_SDK_CURRENT_STABLE_MAJOR names the currently promoted stable major.
channel_for_branch() {
  local branch="$1"
  local current="${CAMUNDA_SDK_CURRENT_STABLE_MAJOR:-}"
  if [[ "${branch}" == "main" ]]; then
    printf 'alpha'
    return 0
  fi
  if [[ "${branch}" =~ ^stable/([0-9]+)$ ]]; then
    local major="${BASH_REMATCH[1]}"
    if [[ -n "${current}" && "${major}" == "${current}" ]]; then
      printf 'latest'
    else
      printf '%s-stable' "${major}"
    fi
    return 0
  fi
  return 1
}

BRANCH="${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')}"
CHANNEL="$(channel_for_branch "${BRANCH}")"
if [[ -z "${CHANNEL}" ]]; then
  die "could not derive the release channel for branch '${BRANCH}' (expected 'main' or 'stable/<major>')"
fi
log "branch '${BRANCH}' releases on channel '${CHANNEL}'"

# --- 4. Recreate the git note when missing ------------------------------------

# Test mode: when the harness sets REPAIR_RELEASE_TEST_FIXTURE, refuse to
# mutate anything unless the clone and its origin both live under the fixture.
# Defence in depth so a broken fixture can never write to a real clone/origin.
# Succeeds only when $1 is an existing absolute directory whose physical path
# (symlinks and '..' resolved) lies strictly under the physical directory $2.
path_in_fixture() {
  local p="$1" root="$2" phys
  # Only plain local paths: reject URLs (scheme://) and scp-style host:path.
  [[ "${p}" != *://* ]] || return 1
  [[ "${p}" != [!/]*:* ]] || return 1
  [[ "${p}" == /* ]] || return 1
  # -P: resolve symlinks before "..", as git does; a logical cd collapses
  # "link/.." lexically and would hide an escape through a symlink.
  phys="$(cd -P -- "${p}" 2>/dev/null && pwd -P)" || return 1
  [[ -n "${phys}" && "${phys}" == "${root}"/* ]]
}

assert_test_fixture() {
  # Only an unset variable selects production mode; set-but-empty fails closed.
  [[ -z "${REPAIR_RELEASE_TEST_FIXTURE+set}" ]] && return 0
  local fixture="${REPAIR_RELEASE_TEST_FIXTURE}"
  [[ -n "${fixture}" ]] || die "test mode: REPAIR_RELEASE_TEST_FIXTURE is set but empty"
  local top origin
  fixture="$(cd -P -- "${fixture}" 2>/dev/null && pwd -P)" || die "test mode: fixture ${REPAIR_RELEASE_TEST_FIXTURE} does not resolve"
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || die "test mode: not in a git work tree"
  origin="$(git remote get-url origin 2>/dev/null)" || die "test mode: no origin remote"
  path_in_fixture "${top}" "${fixture}" || die "test mode: work tree ${top} is outside fixture ${fixture}"
  path_in_fixture "${origin}" "${fixture}" || die "test mode: origin ${origin} is outside fixture ${fixture}"
  # Pushes may go elsewhere (pushurl, pushInsteadOf): check every push URL.
  local push_urls url
  push_urls="$(git remote get-url --push --all origin 2>/dev/null)" || push_urls=""
  [[ -n "${push_urls}" ]] || die "test mode: origin has no push URL"
  while IFS= read -r url; do
    path_in_fixture "${url}" "${fixture}" || die "test mode: origin push URL ${url} is outside fixture ${fixture}"
  done <<< "${push_urls}"
}
assert_test_fixture

NOTE_REF="refs/notes/semantic-release-${TAG}"
repaired=()

# Check remote presence first: a note can exist locally while being absent from
# origin (e.g. its push was rejected). Only skip when origin already has it.
git fetch origin "${NOTE_REF}:${NOTE_REF}" >/dev/null 2>&1 || true
if git ls-remote origin "${NOTE_REF}" 2>/dev/null | grep -q .; then
  log "note ${NOTE_REF} already present on the remote."
else
  if git notes --ref="semantic-release-${TAG}" show "${TAG}" >/dev/null 2>&1; then
    log "note ${NOTE_REF} exists locally but is missing on the remote; re-pushing."
  else
    log "writing missing note ${NOTE_REF}: {\"channels\":[\"${CHANNEL}\"]}"
    git notes --ref="semantic-release-${TAG}" add -f -m "{\"channels\":[\"${CHANNEL}\"]}" "${TAG}" \
      || die "failed to write note for ${TAG}"
  fi
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

if [[ "${RELEASE_EXISTS}" == "1" ]]; then
  log "GitHub Release ${TAG} already exists; skipping creation."
else
  notes_file="$(mktemp "${TMPDIR:-/tmp}/repair-release-notes.XXXXXX")" || die "mktemp failed (TMPDIR=${TMPDIR:-unset})"
  [[ -n "${notes_file}" ]] || die "mktemp returned an empty path"
  trap 'rm -f "${notes_file}"' EXIT
  # The section for this version: from its heading to the next release heading,
  # taken from the CHANGELOG.md of the release commit itself (the tag's blob),
  # so the notes match what semantic-release wrote at release time.
  # CHANGELOG headings carry the bare version, no `v`. Major/minor releases use
  # `# [version]`; stable patch releases use `## [version]` — accept both at
  # both the opening and the terminating boundary. The version is matched
  # literally (index on the bracketed prefix), never as a regex, so its dots
  # and prerelease dashes cannot over-match a neighbouring version.
  git show "${TAG}:CHANGELOG.md" 2>/dev/null | awk -v ver="${VERSION}" '
    {
      is_open  = ($0 ~ /^#{1,2} \[/) && (index($0, "[" ver "]") == 3 || index($0, "[" ver "]") == 4)
      is_bound = ($0 ~ /^#{1,2} \[/)
    }
    is_open { in_section = 1; next }
    in_section && is_bound { exit }
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
fi

# Reconcile Latest for a stable release *outside* the creation guard: when
# creation succeeded on an earlier attempt but the runner stopped before the
# release was marked Latest (or that edit failed transiently), the retry finds
# RELEASE_EXISTS=1 and skips the block above — so the reconciliation must run
# for an already-existing release too, or the stable release can stay absent
# from Latest forever. The never-demote rule in mark-latest.sh makes this safe
# to run unconditionally for GA versions.
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
