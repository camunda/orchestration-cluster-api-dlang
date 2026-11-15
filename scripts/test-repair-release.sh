#!/usr/bin/env bash
# Test harness for scripts/repair-release.sh.
#
# Each case builds a scratch fixture: a local bare "origin" plus a working
# clone whose HEAD is a synthetic release commit, and a stubbed `gh` on PATH
# that records its calls and simulates the GitHub Releases state. The real
# release.config.cjs is used to derive channels, so the main/alpha and
# stable/N cases exercise the same node lookup the workflow relies on.
#
# Run: bash scripts/test-repair-release.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/repair-release.sh"

pass=0
fail=0
declare -a failures=()

ok() {
  local name="$1"
  pass=$((pass + 1))
  echo "ok ${pass} - ${name}"
}

not_ok() {
  local name="$1"
  fail=$((fail + 1))
  failures+=("${name}")
  echo "not ok - ${name}" >&2
}

# --- fixture -----------------------------------------------------------------

setup_fixture() {
  # $1: version (e.g. 11.0.0-alpha.5 or 10.2.1)
  # $2: optional heading level for the version's CHANGELOG section (default "#";
  #     pass "##" for a stable patch release, whose notes sit one level deeper).
  FIXTURE="$(mktemp -d)"
  local version="$1"
  local heading="${2:-#}"
  TAG="v${version}"

  export GH_CALLS="${FIXTURE}/gh-calls"
  : > "${GH_CALLS}"

  # Stubbed gh: records calls; release state lives in ${FIXTURE}/gh-state.
  mkdir -p "${FIXTURE}/bin"
  cat > "${FIXTURE}/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${GH_CALLS}"
state="${GH_CALLS%/gh-calls}/gh-state"
if [[ "$1 $2" == "release view" ]]; then
  grep -qx "$3" "${state}" 2>/dev/null
  exit $?
fi
if [[ "$1 $2" == "release create" ]]; then
  echo "$3" >> "${state}"
  exit 0
fi
exit 0
STUB
  chmod +x "${FIXTURE}/bin/gh"
  : > "${FIXTURE}/gh-state"
  export PATH="${FIXTURE}/bin:${PATH}"

  # Local bare remote + working clone.
  git init -q --bare "${FIXTURE}/remote.git"
  git init -q "${FIXTURE}/work"
  cd "${FIXTURE}/work" || return 1
  git config user.name test
  git config user.email test@example.com
  git remote add origin "${FIXTURE}/remote.git"

  # A feature commit, then the release commit the tag points to.
  git commit -q --allow-empty -m "feat: something"
  cat > CHANGELOG.md <<EOF
${heading} [${version}](https://example.test/compare/v0.0.0...${TAG}) (2026-11-15)


### Bug Fixes

* a fix ([abc1234](https://example.test/commit/abc1234))

# [0.0.0](https://example.test/releases/tag/v0.0.0) (2026-01-01)
EOF
  git add CHANGELOG.md
  git commit -q -m "chore(release): ${version} [skip ci]"
  git tag -a "${TAG}" -m "${version}"
  git push -q origin HEAD:main
  git push -q origin "${TAG}"
}

teardown_fixture() {
  cd "${REPO_ROOT}" || return
  [[ -n "${FIXTURE:-}" && -d "${FIXTURE}" ]] && rm -rf "${FIXTURE}"
  FIXTURE=""
}

run_repair() {
  # $1: branch name to simulate; remaining args passed to the script.
  local branch="$1"
  shift
  (
    cd "${FIXTURE}/work" || return 1
    GITHUB_REF_NAME="${branch}" GITHUB_REPOSITORY="camunda/orchestration-cluster-api-dlang" \
      bash "${SCRIPT}" "$@"
  )
}

gh_calls_contain() {
  grep -qF -- "$1" "${GH_CALLS}"
}

note_body() {
  (cd "${FIXTURE}/work" && git notes --ref="semantic-release-${TAG}" show "${TAG}" 2>/dev/null)
}

remote_has_note() {
  git ls-remote "${FIXTURE}/remote.git" "refs/notes/semantic-release-${TAG}" 2>/dev/null | grep -q .
}

# --- cases -------------------------------------------------------------------

test_release_created_when_only_tag_and_note_present() {
  local name="tag and note present, release missing -> only the release is created"
  setup_fixture "11.0.0-alpha.5"
  git notes --ref="semantic-release-${TAG}" add -f -m '{"channels":["alpha"]}' "${TAG}"
  git push -q origin "refs/notes/semantic-release-${TAG}"
  if run_repair main \
    && [[ "$(grep -c 'release create' "${GH_CALLS}")" == "1" ]] \
    && gh_calls_contain "release create ${TAG}" \
    && gh_calls_contain "--prerelease" \
    && gh_calls_contain "--verify-tag"; then
    ok "${name}"
  else
    not_ok "${name}"
  fi
  teardown_fixture
}

test_note_and_release_created_main_alpha() {
  local name="tag present, note and release missing -> both created (main/alpha channel)"
  setup_fixture "11.0.0-alpha.5"
  if run_repair main \
    && remote_has_note \
    && [[ "$(note_body)" == '{"channels":["alpha"]}' ]] \
    && gh_calls_contain "release create ${TAG}" \
    && gh_calls_contain "--prerelease"; then
    ok "${name}"
  else
    not_ok "${name}"
  fi
  teardown_fixture
}

test_note_and_release_created_stable_latest() {
  local name="tag present, note and release missing -> both created (stable/N latest channel, patch heading)"
  # A stable patch release's CHANGELOG section sits one heading level deeper.
  setup_fixture "10.2.1" "##"
  if CAMUNDA_SDK_CURRENT_STABLE_MAJOR=10 run_repair stable/10 \
    && remote_has_note \
    && [[ "$(note_body)" == '{"channels":["latest"]}' ]] \
    && gh_calls_contain "release create ${TAG}" \
    && ! gh_calls_contain "--prerelease"; then
    ok "${name}"
  else
    not_ok "${name}"
  fi
  teardown_fixture
}

test_noop_when_everything_present() {
  local name="everything present -> no-op"
  setup_fixture "11.0.0-alpha.5"
  git notes --ref="semantic-release-${TAG}" add -f -m '{"channels":["alpha"]}' "${TAG}"
  git push -q origin "refs/notes/semantic-release-${TAG}"
  echo "${TAG}" > "${FIXTURE}/gh-state" # release exists
  if run_repair main \
    && [[ ! -s "${GH_CALLS}" || "$(grep -c 'release create' "${GH_CALLS}")" == "0" ]]; then
    ok "${name}"
  else
    not_ok "${name}"
  fi
  teardown_fixture
}

test_noop_when_head_is_not_release_commit() {
  local name="HEAD isn't a release commit -> no-op with a log line"
  setup_fixture "11.0.0-alpha.5"
  git commit -q --allow-empty -m "feat: something after the tag"
  local out
  out="$(run_repair main 2>&1)"
  if [[ "${out}" == *"not the release commit"* ]] \
    && ! gh_calls_contain "release create" \
    && ! remote_has_note; then
    ok "${name}"
  else
    not_ok "${name}"
  fi
  teardown_fixture
}

test_note_push_retried_until_success() {
  local name="note push fails once, then succeeds -> note pushed, release created"
  setup_fixture "11.0.0-alpha.5"
  # Wrap git so the first push of the note ref fails.
  mkdir -p "${FIXTURE}/gitbin"
  local real_git
  real_git="$(command -v git)"
  cat > "${FIXTURE}/gitbin/git" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "push" && "\$*" == *"refs/notes/"* ]]; then
  counter="${FIXTURE}/push-attempts"
  n=\$(( \$(cat "\$counter" 2>/dev/null || echo 0) + 1 ))
  echo "\$n" > "\$counter"
  if [[ "\$n" == "1" ]]; then
    echo "rejected (simulated transient failure)" >&2
    exit 1
  fi
fi
exec "${real_git}" "\$@"
STUB
  chmod +x "${FIXTURE}/gitbin/git"
  export PATH="${FIXTURE}/gitbin:${PATH}"
  if run_repair main \
    && [[ "$(cat "${FIXTURE}/push-attempts")" == "2" ]] \
    && remote_has_note \
    && gh_calls_contain "release create ${TAG}"; then
    ok "${name}"
  else
    not_ok "${name}"
  fi
  teardown_fixture
}

test_note_repaired_when_release_exists() {
  local name="release exists but note missing -> note still repaired, release not recreated"
  setup_fixture "11.0.0-alpha.5"
  echo "${TAG}" > "${FIXTURE}/gh-state" # release exists, note does not
  if run_repair main \
    && remote_has_note \
    && [[ "$(note_body)" == '{"channels":["alpha"]}' ]] \
    && ! gh_calls_contain "release create"; then
    ok "${name}"
  else
    not_ok "${name}"
  fi
  teardown_fixture
}

test_explicit_older_tag_repaired() {
  local name="explicit older tag, HEAD moved past it -> repaired (no HEAD-equality skip)"
  setup_fixture "11.0.0-alpha.5"
  # Move the branch tip past the release commit, as a manual dispatch would be.
  git commit -q --allow-empty -m "feat: work after the tag"
  git push -q origin HEAD:main
  if run_repair main "${TAG}" \
    && remote_has_note \
    && gh_calls_contain "release create ${TAG}"; then
    ok "${name}"
  else
    not_ok "${name}"
  fi
  teardown_fixture
}

test_explicit_tag_not_reachable_fails() {
  local name="explicit tag not reachable from HEAD -> refuses to repair"
  setup_fixture "11.0.0-alpha.5"
  # Build an unrelated tag on a detached, unpushed commit.
  git checkout -q -b other
  git commit -q --allow-empty -m "unrelated work"
  git tag -a "v9.9.9" -m "9.9.9"
  git checkout -q main 2>/dev/null || git checkout -q master
  local out rc
  out="$(run_repair main v9.9.9 2>&1)"; rc=$?
  if [[ "${rc}" != "0" ]] \
    && [[ "${out}" == *"not reachable from HEAD"* ]] \
    && ! gh_calls_contain "release create"; then
    ok "${name}"
  else
    not_ok "${name}"
  fi
  teardown_fixture
}

test_local_note_pushed_when_missing_remotely() {
  local name="note exists locally but not on origin -> re-pushed, release created"
  setup_fixture "11.0.0-alpha.5"
  # Create the note locally but never push it (the transient-rejection case).
  git notes --ref="semantic-release-${TAG}" add -f -m '{"channels":["alpha"]}' "${TAG}"
  if run_repair main \
    && remote_has_note \
    && gh_calls_contain "release create ${TAG}"; then
    ok "${name}"
  else
    not_ok "${name}"
  fi
  teardown_fixture
}

main() {
  test_release_created_when_only_tag_and_note_present
  test_note_and_release_created_main_alpha
  test_note_and_release_created_stable_latest
  test_noop_when_everything_present
  test_noop_when_head_is_not_release_commit
  test_note_push_retried_until_success
  test_note_repaired_when_release_exists
  test_explicit_older_tag_repaired
  test_explicit_tag_not_reachable_fails
  test_local_note_pushed_when_missing_remotely

  echo
  echo "${pass} passed, ${fail} failed"
  if ((fail > 0)); then
    printf 'failed: %s\n' "${failures[@]}" >&2
    exit 1
  fi
}

main "$@"
