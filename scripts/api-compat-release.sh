#!/usr/bin/env bash
# Release gate: compare the public D API about to be tagged on stable/<N> with
# the last published N.x.y release. Runs in .github/workflows/publish.yml after
# regeneration, so generated code from upstream spec drift (which no PR
# reviewed) is checked too.
#
# Override: the api-break-approved label on a PR merged to this branch since
# that release, or DISPATCH_APPROVED=true (the api_break_approved input of a
# manual run). An approval covers the API as of that PR's merge: breaks added
# after the newest approved merge need their own approval.
#
# Env: API_COMPAT (checker binary), GITHUB_REF_NAME, GITHUB_REPOSITORY, GH_TOKEN,
#      DISPATCH_APPROVED, GITHUB_STEP_SUMMARY, RUNNER_TEMP.
# Exit: 0 pass, 1 unapproved break, 2 setup error.
set -uo pipefail

: "${API_COMPAT:?}" "${GITHUB_REF_NAME:?}" "${GITHUB_REPOSITORY:?}"
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
  git worktree remove --force "$tmp/api-compat-approved" >/dev/null 2>&1 || true
}
trap cleanup EXIT
git worktree add -q --detach "$tmp/api-compat-baseline" "$tag" || exit 2

pipeline_status=(0 0)
"$API_COMPAT" --baseline-dir "$tmp/api-compat-baseline" | tee "$tmp/api-compat.txt" || pipeline_status=("${PIPESTATUS[@]}")
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

approved=""
merges=""
# A reset or merged-back branch can reach the tag only through a second parent.
tag_sha=$(git rev-parse --verify "${tag}^{commit}") || exit 2
line=$(git rev-list --first-parent HEAD) || exit 2
commits=""
if grep -Fxq "$tag_sha" <<< "$line"; then
  commits=$(git log --first-parent --format=%H "${tag}..HEAD") || exit 2
else
  echo "::notice::${tag} is not on the first-parent history of HEAD; no label can approve this release."
fi
while read -r sha; do
  [ -n "$sha" ] || continue
  prs=$(gh api "repos/${GITHUB_REPOSITORY}/commits/${sha}/pulls" \
    --jq '.[] | select(.merged_at != null) | select(any(.labels[]; .name == "api-break-approved")) | [.number, .base.ref, .merge_commit_sha] | @tsv') || exit 2
  while IFS=$'\t' read -r number base merge; do
    if [ "$base" = "$GITHUB_REF_NAME" ] && [ -n "$merge" ] && grep -Fxq "$merge" <<< "$commits"; then
      approved="${approved} #${number}"
      merges="${merges}${merge} #${number}"$'\n'
    fi
  done <<< "$prs"
done <<< "$commits"
approved=$(echo "$approved" | xargs -n1 2>/dev/null | sort -u | xargs)
if [ -z "$approved" ]; then
  echo "::error::Release blocked: the public API breaks compatibility with ${tag}. If intended, label the PR that made the change api-break-approved (or re-run this workflow manually with api_break_approved), then re-run."
  exit 1
fi

# `git log` lists the newest first.
latest=""
latest_pr=""
while read -r sha; do
  hit=$(grep -m1 "^${sha} " <<< "$merges" || true)
  if [ -n "$hit" ]; then
    latest="$sha"
    latest_pr="${hit#* }"
    break
  fi
done <<< "$commits"
if [ "$latest" != "$(git rev-parse HEAD)" ]; then
  git worktree add -q --detach "$tmp/api-compat-approved" "$latest" || exit 2
  since=0
  "$API_COMPAT" --baseline-dir "$tmp/api-compat-approved" || since=$?
  if [ "$since" -eq 1 ]; then
    echo "::error::Release blocked: breaking API changes were added after ${latest_pr} (${latest}), the newest approved PR. Label the PR that made them api-break-approved (or re-run this workflow manually with api_break_approved), then re-run."
    exit 1
  fi
  [ "$since" -eq 0 ] || exit "$since"
fi
echo "::warning::Breaking API changes approved with the api-break-approved label on: ${approved}"
exit 0
