#!/usr/bin/env bash
# Release gate: compare the public D API about to be tagged on stable/<N> with
# the last published N.x.y release. Runs in .github/workflows/publish.yml after
# regeneration, so generated code from upstream spec drift (which no PR
# reviewed) is checked too.
#
# Approved breaks: the entries of api-compat-suppressions.txt (committed; a PR
# changing it needs the breaking-change-approved label), which the checker
# skips. Emergency override: DISPATCH_APPROVED=true (the api_break_approved
# input of a manual run).
#
# Env: API_COMPAT (checker binary), GITHUB_REF_NAME, DISPATCH_APPROVED,
#      GITHUB_STEP_SUMMARY, RUNNER_TEMP.
# Exit: 0 pass, 1 unapproved break, 2 setup error.
set -uo pipefail

: "${API_COMPAT:?}" "${GITHUB_REF_NAME:?}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
tmp="${RUNNER_TEMP:-$(mktemp -d)}"

case "$GITHUB_REF_NAME" in
  stable/*) ;;
  *) echo "::notice::${GITHUB_REF_NAME} publishes prereleases with no compatibility promise; skipping."; exit 0 ;;
esac
major="${GITHUB_REF_NAME#stable/}"

version=$("$API_COMPAT" --print-baseline-major "$major") || exit 2
if [ -z "$version" ]; then
  echo "::notice::No ${major}.x release published yet; nothing to compare against."
  exit 0
fi
tag="v${version}"
echo "Baseline: ${tag}"

cleanup() {
  git worktree remove --force "$tmp/api-compat-baseline" >/dev/null 2>&1 || true
}
trap cleanup EXIT
git worktree add -q --detach "$tmp/api-compat-baseline" "$tag" || exit 2

pipeline_status=(0 0)
"$API_COMPAT" --baseline-dir "$tmp/api-compat-baseline" --baseline-tag "$tag" | tee "$tmp/api-compat.txt" || pipeline_status=("${PIPESTATUS[@]}")
[ "${pipeline_status[1]}" -eq 0 ] || exit 2
rc="${pipeline_status[0]}"
{
  echo "## API compatibility (vs ${tag})"
  echo '```'
  cat "$tmp/api-compat.txt" || exit 2
  echo '```'
} >> "$summary" || exit 2
[ "$rc" -eq 1 ] || exit "$rc"

if [ "${DISPATCH_APPROVED:-false}" = "true" ]; then
  echo "::warning::Breaking API changes approved by the api_break_approved input of this run."
  exit 0
fi
echo "::error::Release blocked: the public API breaks compatibility with ${tag}. If intended, record the \"${tag} BREAK ...\" lines (baseline tag first) in api-compat-suppressions.txt through a PR labelled breaking-change-approved (or re-run this workflow manually with api_break_approved), then re-run."
exit 1
