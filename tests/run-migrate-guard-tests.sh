#!/usr/bin/env bash
#
# run-migrate-guard-tests.sh — Layer-1 tests for the backlog guard rollout
# (#653): scripts/lib/milestone-stub.sh, the milestone queries in
# scripts/lib/backlog-milestone.sh and
# `scripts/migrate-consumers.sh --add-milestone-guard`. gh is mocked; no
# network.
#
# Usage: tests/run-migrate-guard-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/tests/fixtures/migrate-guard"
MOCKS="$ROOT/tests/mocks"

unset GITHUB_REPOSITORY GITHUB_OUTPUT GITHUB_STEP_SUMMARY REPO

PASS=0
FAIL=0
FAIL_NAMES=()

pass() { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
fail() {
  FAIL=$((FAIL + 1)); FAIL_NAMES+=("$1")
  printf '  ✗ %s\n' "$1"
  [[ $# -gt 1 ]] && printf '      %s\n' "$2"
  return 0
}
section() { printf '\n── %s ──\n' "$1"; }
assert_eq() {
  if [[ "$3" == "$2" ]]; then pass "$1"; else fail "$1" "expected: $2 | actual: $3"; fi
}
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1" "missing: $3 | in: $2"; fi
}
assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1" "unexpected: $3 | in: $2"; fi
}

section "milestone stub — one source for onboarding and the rollout"

# shellcheck disable=SC1091
stub="$(source "$ROOT/scripts/lib/milestone-stub.sh"; build_milestone_yml freaxnx01/agent-workflow v2)"

assert_contains "calls the reusable workflow at the given ref" "$stub" \
  'uses: freaxnx01/agent-workflow/.github/workflows/backlog-milestone.yml@v2'
assert_contains "checks out the scripts at the same ref" "$stub" '      pipeline-ref: v2'
# shellcheck disable=SC2016  # `${{ }}` is Actions expression syntax, not shell
assert_contains "passes only the issue number, unexpanded" "$stub" \
  'issue-number: ${{ github.event.issue.number }}'
assert_contains "runs on opened and reopened" "$stub" 'types: [opened, reopened]'
assert_contains "the calling job may set the milestone" "$stub" '      issues: write'
assert_not_contains "never writes code" "$stub" 'contents: write'

# The ref is a parameter, not the sourcing script's environment: the rollout
# writes the stub at whatever ref the consumer already pins.
# shellcheck disable=SC1091
other="$(source "$ROOT/scripts/lib/milestone-stub.sh"; build_milestone_yml o/p v2.4.1)"
assert_contains "the pipeline repo is a parameter" "$other" 'uses: o/p/.github/workflows/backlog-milestone.yml@v2.4.1'
assert_contains "the ref is a parameter" "$other" '      pipeline-ref: v2.4.1'

if command -v actionlint >/dev/null 2>&1; then
  d="$(mktemp -d)"
  printf '%s\n' "$stub" > "$d/issue-milestone.yml"
  if actionlint "$d/issue-milestone.yml" >/dev/null 2>&1; then
    pass "actionlint accepts the generated stub"
  else
    fail "actionlint accepts the generated stub" "$(actionlint "$d/issue-milestone.yml" 2>&1 | head -5)"
  fi
  rm -rf "$d"
else
  printf '  - skipped actionlint (not installed)\n'
fi

if command -v yamllint >/dev/null 2>&1; then
  if printf '%s\n' "$stub" | yamllint -d '{extends: relaxed, rules: {line-length: disable, truthy: disable}}' - >/dev/null 2>&1; then
    pass "the generated stub is valid YAML"
  else
    fail "the generated stub is valid YAML" "yamllint rejected it"
  fi
fi

section "milestone queries — state, creation, un-milestoned issues"

# in_lib <map-line...> — runs the lib call in $LIB_CALL with gh mocked. Each
# map line is "<argv substring>\t<fixture>"; $LIB_FAIL, when set, is the mock's
# fail map. The gh argv log is left in $LIB_DIR/gh for the caller to read — the
# calls a query makes are part of what is asserted.
#
# SC2030/SC2031: the exports are deliberately confined to the subshell — that
# isolation is the point, so every case starts from the same environment.
# shellcheck disable=SC2030,SC2031
in_lib() {
  : > "$LIB_DIR/gh"
  printf '%b' "$@" > "$LIB_DIR/map"
  # shellcheck disable=SC1091
  (export PATH="$MOCKS:$PATH" GH_MOCK_LOG="$LIB_DIR/gh" GH_MOCK_STDOUT_MAP="$LIB_DIR/map" \
          ${LIB_FAIL:+GH_MOCK_FAIL_MAP="$LIB_FAIL"}
   source "$ROOT/scripts/lib/backlog-milestone.sh"; "${LIB_CALL[@]}")
}

LIB_DIR="$(mktemp -d)"
LIB_FAIL=''
MILESTONES='milestones?state=all\t'

LIB_CALL=(list_unmilestoned_issues o/r)
assert_eq "un-milestoned issues span every page, pull requests dropped" \
  "$(printf '1\n2\n4')" "$(in_lib 'milestone=none\t'"$FIX/unmilestoned-two-pages.json"'\n')"
assert_contains "un-milestoned issues are read page by page" "$(cat "$LIB_DIR/gh")" '--paginate'

LIB_CALL=(backlog_milestone_state o/r)
assert_eq "an open backlog is found among other milestones" "open 7" \
  "$(in_lib "$MILESTONES$FIX/milestones-open.json"'\n')"
assert_eq "a closed backlog is reported as closed, never as missing" "closed 5" \
  "$(in_lib "$MILESTONES$FIX/milestones-closed.json"'\n')"
assert_eq "no backlog at all is missing" "missing" \
  "$(in_lib "$MILESTONES$FIX/milestones-missing.json"'\n')"
assert_eq "an open backlog wins over a closed namesake" "open 7" \
  "$(in_lib "$MILESTONES$FIX/milestones-open-and-closed.json"'\n')"

printf '%s\n' 'milestones?state=all' > "$LIB_DIR/fail"
LIB_FAIL="$LIB_DIR/fail"
rc=0; in_lib "$MILESTONES$FIX/milestones-open.json"'\n' >/dev/null || rc=$?
assert_eq "an unreadable milestone list fails, never reads as missing" "1" "$rc"
LIB_FAIL=''

LIB_CALL=(create_backlog_milestone o/r)
assert_eq "creating backlog prints the new number" "9" \
  "$(in_lib '-X POST repos/o/r/milestones\t'"$FIX/milestone-created.json"'\n')"
assert_contains "creating backlog POSTs the title exactly" "$(cat "$LIB_DIR/gh")" \
  'api -X POST repos/o/r/milestones -f title=backlog'
assert_contains "creating backlog says where the convention comes from" "$(cat "$LIB_DIR/gh")" \
  'freaxnx01/ai-instructions#61'

LIB_CALL=(create_backlog_milestone o/r)
printf '%s\n' '-X POST' > "$LIB_DIR/fail"
LIB_FAIL="$LIB_DIR/fail"
rc=0; in_lib '-X POST repos/o/r/milestones\t'"$FIX/milestone-created.json"'\n' >/dev/null || rc=$?
assert_eq "a failed creation returns 1, never a number" "1" "$rc"
LIB_FAIL=''
rm -rf "$LIB_DIR"

printf '\npassed: %d   failed: %d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf -- '  - %s\n' "$n"; done
  exit 1
fi
exit 0
