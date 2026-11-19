#!/usr/bin/env bash
# Run the test suite on a real Windows runner for the current working tree,
# including uncommitted and untracked (not ignored) files.
#
# Snapshots the tree into a commit through a temporary index (your index,
# branch and stash are untouched), pushes it to ci-windows/<user>-<sha>,
# which .github/workflows/check-windows.yml runs, waits for the result,
# prints the failed log, and deletes the branch. Needs `gh` auth and push
# access. Exit status is the run's.
set -euo pipefail

repo="${CHECK_WINDOWS_REPO:-camunda/orchestration-cluster-api-dlang}"
remote="${CHECK_WINDOWS_REMOTE:-origin}"
root="$(git rev-parse --show-toplevel)"
cd "$root"

make typecheck-windows >/dev/null || { echo "check-windows: fix the Windows type-check first (make typecheck-windows)" >&2; exit 1; }

tmp_index="$(mktemp)"
trap 'rm -f "$tmp_index"' EXIT
cp "$(git rev-parse --git-path index)" "$tmp_index"
GIT_INDEX_FILE="$tmp_index" git add -A
tree="$(GIT_INDEX_FILE="$tmp_index" git write-tree)"
sha="$(git commit-tree "$tree" -p HEAD -m "check-windows snapshot of $(git rev-parse --short HEAD)")"

user="$(gh api user -q .login 2>/dev/null || whoami)"
branch="ci-windows/${user}-${sha:0:12}"
cleanup() {
  git push -q "$remote" --delete "$branch" >/dev/null 2>&1 || true
  rm -f "$tmp_index"
}
trap cleanup EXIT

git push -q "$remote" "$sha:refs/heads/$branch" 2>/dev/null
echo "check-windows: pushed $branch; waiting for the run..."

run=""
for _ in $(seq 1 60); do
  # Not --workflow: that only resolves workflows on the default branch.
  run="$(gh run list -R "$repo" --branch "$branch" --json databaseId,headSha,workflowName \
    -q ".[] | select(.headSha == \"$sha\" and .workflowName == \"check-windows\") | .databaseId" | head -1)"
  [ -n "$run" ] && break
  sleep 5
done
[ -n "$run" ] || { echo "check-windows: no run appeared for $branch" >&2; exit 1; }

echo "check-windows: https://github.com/$repo/actions/runs/$run"
if gh run watch "$run" -R "$repo" --exit-status --interval 15 >/dev/null; then
  echo "check-windows: passed"
else
  gh run view "$run" -R "$repo" --log-failed \
    | cut -f3- | sed -E 's/^[0-9TZ:.-]+ //' \
    | grep -E 'Error|AssertError|Exception|FAILED|LNK[0-9]+|\.d\([0-9]+' | head -40 || true
  echo "check-windows: FAILED" >&2
  exit 1
fi
