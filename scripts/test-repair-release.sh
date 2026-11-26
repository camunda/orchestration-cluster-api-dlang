#!/usr/bin/env bash
# Test harness for scripts/repair-release.sh.
#
# Each case builds a scratch fixture: a local bare "origin" plus a working
# clone whose HEAD is a synthetic release commit, and a stubbed `gh` on PATH
# that records its calls and simulates the GitHub Releases state. The channel
# is derived in pure bash by repair-release.sh (mirroring the
# release.config.cjs branch model), so this harness — and `make check` — runs
# on the documented D-only development setup with no Node.js / npm release
# dependencies.
#
# Run: bash scripts/test-repair-release.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/repair-release.sh"

# --- safety ------------------------------------------------------------------
#
# The harness creates commits and pushes. It must never do so outside its
# scratch fixture (a failed mktemp once made it push empty commits to the real
# origin). Everything below fails closed.

# Scratch root: respect TMPDIR; fall back to ${REPO_ROOT}/.tmp (gitignored)
# when the system temp dir is not writable (sandboxes). The fallback can be
# overridden for the regression test.
FALLBACK_TMP="${REPAIR_TEST_FALLBACK_TMP:-${REPO_ROOT}/.tmp}"

make_scratch_dir() {
  local dir=""
  dir="$(mktemp -d "${TMPDIR:-/tmp}/repair-release-test.XXXXXX" 2>/dev/null)" || dir=""
  if [[ -z "${dir}" || ! -d "${dir}" ]]; then
    mkdir -p "${FALLBACK_TMP}" 2>/dev/null || true
    dir="$(mktemp -d "${FALLBACK_TMP}/repair-release-test.XXXXXX" 2>/dev/null)" || dir=""
  fi
  [[ -n "${dir}" && -d "${dir}" ]] || return 1
  # Canonical path so prefix checks against git's resolved paths are reliable.
  (cd "${dir}" && pwd -P)
}

# Abort the whole run unless the current work tree and its origin both live
# under ${FIXTURE}.
assert_in_fixture() {
  local top origin url
  if [[ -z "${FIXTURE:-}" || ! -d "${FIXTURE}" ]]; then
    echo "FATAL: no fixture directory; refusing to mutate git state" >&2
    exit 2
  fi
  top="$(command git rev-parse --show-toplevel 2>/dev/null)" || top=""
  origin="$(command git remote get-url origin 2>/dev/null)" || origin=""
  if [[ "${top}" != "${FIXTURE}"/* || "${origin}" != "${FIXTURE}"/* ]]; then
    echo "FATAL: git work tree '${top}' / origin '${origin}' outside fixture '${FIXTURE}'; aborting" >&2
    exit 2
  fi
  # Push destinations can differ from the fetch URL (pushurl, pushInsteadOf):
  # every effective push URL must be inside the fixture too.
  local push_urls
  push_urls="$(command git remote get-url --push --all origin 2>/dev/null)" || push_urls=""
  if [[ -z "${push_urls}" ]]; then
    echo "FATAL: origin has no push URL; aborting" >&2
    exit 2
  fi
  while IFS= read -r url; do
    if [[ "${url}" != "${FIXTURE}"/* ]]; then
      echo "FATAL: origin push URL '${url}' outside fixture '${FIXTURE}'; aborting" >&2
      exit 2
    fi
  done <<< "${push_urls}"
}

# Every mutating git call in this harness goes through this guard.
git() {
  case "${1:-}" in
    commit | push | tag | notes) assert_in_fixture ;;
  esac
  command git "$@"
}

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
  FIXTURE="$(make_scratch_dir)" || FIXTURE=""
  if [[ -z "${FIXTURE}" || ! -d "${FIXTURE}" ]]; then
    echo "FATAL: could not create a scratch fixture directory (TMPDIR=${TMPDIR:-unset}, fallback=${FALLBACK_TMP})" >&2
    exit 2
  fi
  export REPAIR_RELEASE_TEST_FIXTURE="${FIXTURE}"
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

  # Local bare remote + working clone. Pin the initial branch to `main` so the
  # fixture does not depend on the host's init.defaultBranch (master vs main):
  # the harness pushes HEAD:main and later checks out `main` by name, so an
  # ambient default of `master` would otherwise make `make check` fail for the
  # wrong reason.
  git init -q --bare "${FIXTURE}/remote.git"
  git init -q -b main "${FIXTURE}/work"
  cd "${FIXTURE}/work" || exit 2
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
  cd "${REPO_ROOT}" || exit 2
  [[ -n "${FIXTURE:-}" && -d "${FIXTURE}" ]] && rm -rf "${FIXTURE}"
  FIXTURE=""
}

run_repair() {
  # $1: branch name to simulate; remaining args passed to the script.
  local branch="$1"
  shift
  (
    cd "${FIXTURE}/work" || exit 2
    mkdir -p "${FIXTURE}/tmp" || exit 2
    TMPDIR="${FIXTURE}/tmp" GITHUB_REF_NAME="${branch}" GITHUB_REPOSITORY="camunda/orchestration-cluster-api-dlang" \
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
  real_git="$(type -P git)"
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
  git checkout -q main
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

test_head_release_preferred_over_ancestor_prerelease() {
  local name="HEAD stable release preferred over an ancestor's higher-sorting prerelease tag"
  # HEAD is the stable release v11.0.0, but an ancestor carries the prerelease
  # v11.0.0-alpha.4, which sorts *above* v11.0.0 in git's descending version
  # order. Auto mode must pick the tag pointing at HEAD, not the prerelease.
  setup_fixture "11.0.0-alpha.4"
  # Record the prerelease tag, then add the stable release commit on top.
  local pre_tag="${TAG}"
  cat > CHANGELOG.md <<'EOF'
# [11.0.0](https://example.test/compare/v11.0.0-alpha.4...v11.0.0) (2026-11-16)


### Features

* ga ([def5678](https://example.test/commit/def5678))

# [11.0.0-alpha.4](https://example.test/compare/v0.0.0...v11.0.0-alpha.4) (2026-11-15)


### Bug Fixes

* a fix ([abc1234](https://example.test/commit/abc1234))
EOF
  git add CHANGELOG.md
  git commit -q -m "chore(release): 11.0.0 [skip ci]"
  git tag -a "v11.0.0" -m "11.0.0"
  git push -q origin HEAD:main
  git push -q origin v11.0.0
  # Auto mode on the stable branch: must repair v11.0.0, not the prerelease.
  # (note_body/remote_has_note use $TAG; point it at the stable tag.)
  TAG="v11.0.0"
  if CAMUNDA_SDK_CURRENT_STABLE_MAJOR=11 run_repair stable/11 \
    && remote_has_note \
    && gh_calls_contain "release create v11.0.0" \
    && ! gh_calls_contain "release create ${pre_tag}"; then
    ok "${name}"
  else
    not_ok "${name}"
  fi
  teardown_fixture
}

test_ga_preferred_over_prerelease_at_same_commit() {
  local name="GA tag preferred over a prerelease tag pointing at the same commit"
  # Both tags point at HEAD; a plain "newest" version sort ranks the prerelease
  # above the GA, so auto mode must explicitly prefer the GA.
  setup_fixture "11.0.0"
  git tag -a "v11.0.0-alpha.1" -m "11.0.0-alpha.1"
  git push -q origin v11.0.0-alpha.1
  if CAMUNDA_SDK_CURRENT_STABLE_MAJOR=11 run_repair stable/11 \
    && remote_has_note \
    && gh_calls_contain "release create v11.0.0" \
    && ! gh_calls_contain "release create v11.0.0-alpha.1"; then
    ok "${name}"
  else
    not_ok "${name}"
  fi
  teardown_fixture
}

test_channel_derivation_without_node() {
  local name="channel derived in pure bash for main / current stable / older stable"
  # Source the script's function by extracting it; simplest is to invoke the
  # script far enough to log the channel, but that needs a full fixture. Here we
  # assert the branch→channel mapping directly via the script's own logic by
  # running a no-op repair for each branch and reading the logged channel.
  local out
  setup_fixture "11.0.0-alpha.5"
  git notes --ref="semantic-release-${TAG}" add -f -m '{"channels":["alpha"]}' "${TAG}"
  git push -q origin "refs/notes/semantic-release-${TAG}"
  echo "${TAG}" > "${FIXTURE}/gh-state" # everything present -> no-op, but channel is logged first

  out="$(run_repair main 2>&1)"
  local main_ok=0; [[ "${out}" == *"releases on channel 'alpha'"* ]] && main_ok=1
  out="$(CAMUNDA_SDK_CURRENT_STABLE_MAJOR=10 run_repair stable/10 2>&1)"
  local cur_ok=0; [[ "${out}" == *"releases on channel 'latest'"* ]] && cur_ok=1
  out="$(CAMUNDA_SDK_CURRENT_STABLE_MAJOR=10 run_repair stable/9 2>&1)"
  local old_ok=0; [[ "${out}" == *"releases on channel '9-stable'"* ]] && old_ok=1

  if [[ "${main_ok}" == "1" && "${cur_ok}" == "1" && "${old_ok}" == "1" ]]; then
    ok "${name}"
  else
    not_ok "${name} (main=${main_ok} current=${cur_ok} older=${old_ok})"
  fi
  teardown_fixture
}

test_explicit_nontag_revision_fails_without_mutating_origin() {
  local name="explicit non-tag revision (HEAD) -> dies before pushing any note"
  # `HEAD` resolves via rev-list and is reachable from HEAD, so without an exact
  # refs/tags/ check the script would push refs/notes/semantic-release-HEAD
  # before failing CHANGELOG extraction. It must die before any push.
  setup_fixture "11.0.0-alpha.5"
  local out rc
  out="$(run_repair main HEAD 2>&1)"; rc=$?
  if [[ "${rc}" != "0" ]] \
    && [[ "${out}" == *"no tag named HEAD"* ]] \
    && ! git ls-remote "${FIXTURE}/remote.git" 'refs/notes/*' 2>/dev/null | grep -q . \
    && ! gh_calls_contain "release create"; then
    ok "${name}"
  else
    not_ok "${name}"
  fi
  teardown_fixture
}

test_latest_reconciled_when_stable_release_already_exists() {
  local name="stable release exists but not Latest -> mark-latest runs on retry"
  # Creation succeeded on an earlier attempt but the runner died before marking
  # Latest, so the release already exists (RELEASE_EXISTS=1) and creation is
  # skipped. The Latest reconciliation must still run for the GA release.
  # repair-release.sh invokes scripts/mark-latest.sh by absolute path, so we
  # observe it through the stubbed gh: the real mark-latest.sh calls
  # `gh release edit <tag> --latest` when the release should become Latest
  # (here there is no newer Latest, so it does).
  setup_fixture "10.2.1" "##"
  git notes --ref="semantic-release-${TAG}" add -f -m '{"channels":["latest"]}' "${TAG}"
  git push -q origin "refs/notes/semantic-release-${TAG}"
  echo "${TAG}" > "${FIXTURE}/gh-state" # release already exists
  if CAMUNDA_SDK_CURRENT_STABLE_MAJOR=10 run_repair stable/10 \
    && gh_calls_contain "release edit ${TAG} --latest" \
    && ! gh_calls_contain "release create"; then
    ok "${name}"
  else
    not_ok "${name}"
  fi
  teardown_fixture
}

test_fails_closed_when_no_temp_dir() {
  local name="no writable temp dir -> harness exits non-zero, enclosing repo untouched"
  local before after rc
  before="$(cd "${REPO_ROOT}" && command git rev-parse HEAD)"
  REPAIR_TEST_NESTED=1 TMPDIR=/dev/null \
    REPAIR_TEST_FALLBACK_TMP=/dev/null \
    bash "${BASH_SOURCE[0]}" >/dev/null 2>&1
  rc=$?
  after="$(cd "${REPO_ROOT}" && command git rev-parse HEAD)"
  if [[ "${rc}" != "0" && "${before}" == "${after}" ]]; then
    ok "${name}"
  else
    not_ok "${name} (rc=${rc} before=${before} after=${after})"
  fi
}

test_pushurl_outside_fixture_refused() {
  local name="origin pushurl / pushInsteadOf outside fixture -> refused, outside repo untouched"
  local outside rc_script rc_guard rc_insteadof
  outside="$(make_scratch_dir)" || outside=""
  if [[ -z "${outside}" ]]; then
    not_ok "${name} (no scratch dir)"
    return
  fi
  command git init -q --bare "${outside}/remote.git"
  setup_fixture "11.0.0-alpha.5"
  command git -C "${FIXTURE}/work" config remote.origin.pushurl "${outside}/remote.git"
  run_repair main >/dev/null 2>&1
  rc_script=$?
  (cd "${FIXTURE}/work" && git push -q origin HEAD:main) >/dev/null 2>&1
  rc_guard=$?
  command git -C "${FIXTURE}/work" config --unset remote.origin.pushurl
  command git -C "${FIXTURE}/work" config "url.${outside}/remote.git.pushInsteadOf" "${FIXTURE}/remote.git"
  run_repair main >/dev/null 2>&1
  rc_insteadof=$?
  if [[ "${rc_script}" != "0" && "${rc_guard}" == "2" && "${rc_insteadof}" != "0" ]] \
    && [[ -z "$(command git -C "${outside}/remote.git" for-each-ref)" ]]; then
    ok "${name}"
  else
    not_ok "${name} (script=${rc_script} guard=${rc_guard} insteadOf=${rc_insteadof})"
  fi
  teardown_fixture
  rm -rf "${outside}"
}

main() {
  if [[ -z "${REPAIR_TEST_NESTED:-}" ]]; then
    test_fails_closed_when_no_temp_dir
  fi
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
  test_head_release_preferred_over_ancestor_prerelease
  test_ga_preferred_over_prerelease_at_same_commit
  test_channel_derivation_without_node
  test_explicit_nontag_revision_fails_without_mutating_origin
  test_latest_reconciled_when_stable_release_already_exists
  test_pushurl_outside_fixture_refused

  echo
  echo "${pass} passed, ${fail} failed"
  if ((fail > 0)); then
    printf 'failed: %s\n' "${failures[@]}" >&2
    exit 1
  fi
}

main "$@"
