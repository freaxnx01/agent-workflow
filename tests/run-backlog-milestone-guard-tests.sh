#!/usr/bin/env bash
#
# run-backlog-milestone-guard-tests.sh — Layer-1 tests for the backlog milestone
# guard (#646): scripts/assign-backlog-milestone.sh,
# scripts/backfill-backlog-milestone.sh and their workflows. gh is mocked; no
# network.
#
# Usage: tests/run-backlog-milestone-guard-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/tests/fixtures/backlog-milestone"
MOCKS="$ROOT/tests/mocks"
GUARD="$ROOT/scripts/assign-backlog-milestone.sh"

unset GITHUB_REPOSITORY GITHUB_OUTPUT GITHUB_STEP_SUMMARY REPO ISSUE_NUMBER DRY_RUN

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

decide() {
  # shellcheck disable=SC1090
  (source "$GUARD"; milestone_decision < "$FIX/$1")
}

section "milestone_decision — which issues the guard touches"

assert_eq "an open issue with no milestone is assigned" "assign" "$(decide issue-open.json)"
assert_eq "an issue with a milestone is left alone" "skip has milestone v2.3 · intake" "$(decide issue-has-milestone.json)"
assert_eq "a closed issue is left alone" "skip issue is closed" "$(decide issue-closed.json)"
assert_eq "a pull request is left alone" "skip is a pull request" "$(decide issue-pull-request.json)"

section "backlog_milestone_number — exact title, every page"

# lookup <milestones-fixture> — the lib's lookup with gh mocked.
#
# SC2030/SC2031: the exports are deliberately local to the subshell -- that
# isolation is the point, so each case starts from the same environment.
# shellcheck disable=SC2030,SC2031
lookup() {
  local d; d="$(mktemp -d)"
  printf '%s\t%s\n' 'milestones?state=open' "$FIX/$1" > "$d/map"
  # shellcheck disable=SC1090
  (export PATH="$MOCKS:$PATH" GH_MOCK_LOG="$d/gh" GH_MOCK_STDOUT_MAP="$d/map"
   source "$ROOT/scripts/lib/backlog-milestone.sh"; backlog_milestone_number freaxnx01/sample)
  rm -rf "$d"
}
assert_eq "finds backlog among other milestones" "7" "$(lookup milestones-with-backlog.json)"
assert_eq "a near-miss title does not count" "" "$(lookup milestones-without-backlog.json)"
assert_eq "finds backlog on the second page" "7" "$(lookup milestones-two-pages.json)"

# run_guard <dir> <issue-fixture> <milestones-fixture> [extra env...]
# shellcheck disable=SC2031  # PATH is rebuilt per call from the pristine $MOCKS
run_guard() {
  local dir="$1" issue="$2" milestones="$3"; shift 3
  printf '%s\t%s\n' 'milestones?state=open' "$FIX/$milestones" 'api repos/' "$FIX/$issue" > "$dir/map"
  env PATH="$MOCKS:$PATH" GH_MOCK_LOG="$dir/gh" GH_MOCK_STDOUT_MAP="$dir/map" \
    REPO=freaxnx01/sample ISSUE_NUMBER=42 "$@" bash "$GUARD" 2>&1
}

section "the guard — write path"

d="$(mktemp -d)"; : > "$d/gh"
rc=0; out="$(run_guard "$d" issue-open.json milestones-with-backlog.json GITHUB_OUTPUT="$d/out")" || rc=$?
assert_eq "assigned -> exit 0" "0" "$rc"
assert_contains "assigned -> says so" "$out" 'milestone: #42 assigned backlog'
assert_contains "assigned -> PATCHes only the milestone, by number" "$(cat "$d/gh")" \
  'api -X PATCH repos/freaxnx01/sample/issues/42 -F milestone=7'
assert_contains "the issue is re-read over REST" "$(cat "$d/gh")" 'api repos/freaxnx01/sample/issues/42'
assert_contains "GITHUB_OUTPUT gets decision=assigned" "$(cat "$d/out")" 'decision=assigned'
rm -rf "$d"

d="$(mktemp -d)"; : > "$d/gh"
rc=0; out="$(run_guard "$d" issue-has-milestone.json milestones-with-backlog.json GITHUB_OUTPUT="$d/out")" || rc=$?
assert_eq "has a milestone -> exit 0" "0" "$rc"
assert_contains "has a milestone -> says why" "$out" 'milestone: #42 skipped (has milestone v2.3 · intake)'
assert_not_contains "has a milestone -> no PATCH" "$(cat "$d/gh")" 'PATCH'
assert_not_contains "has a milestone -> no milestone lookup" "$(cat "$d/gh")" 'milestones?'
assert_contains "GITHUB_OUTPUT names the reason" "$(cat "$d/out")" 'reason=has milestone v2.3 · intake'
rm -rf "$d"

section "the guard — no backlog milestone warns, never creates"

d="$(mktemp -d)"; : > "$d/gh"
rc=0; out="$(run_guard "$d" issue-open.json milestones-without-backlog.json GITHUB_OUTPUT="$d/out")" || rc=$?
assert_eq "missing backlog -> exit 0" "0" "$rc"
assert_contains "missing backlog -> a warning annotation" "$out" '::warning::'
assert_contains "missing backlog -> skipped with reason" "$out" 'milestone: #42 skipped (no backlog milestone)'
assert_not_contains "missing backlog -> no PATCH" "$(cat "$d/gh")" 'PATCH'
assert_not_contains "missing backlog -> no milestone is created" "$(cat "$d/gh")" 'POST'
assert_contains "GITHUB_OUTPUT says skipped" "$(cat "$d/out")" 'decision=skipped'
rm -rf "$d"

section "the guard — dry run, failures, usage"

d="$(mktemp -d)"; : > "$d/gh"
rc=0; out="$(run_guard "$d" issue-open.json milestones-with-backlog.json DRY_RUN=1)" || rc=$?
assert_eq "dry run -> exit 0" "0" "$rc"
assert_contains "dry run -> says what it would do" "$out" 'DRY_RUN: would assign #42 to backlog (#7)'
assert_not_contains "dry run -> no PATCH" "$(cat "$d/gh")" 'PATCH'
rm -rf "$d"

d="$(mktemp -d)"; : > "$d/gh"
printf '%s\n' 'api repos/freaxnx01/sample/issues/42' > "$d/fail"
rc=0; out="$(run_guard "$d" issue-open.json milestones-with-backlog.json GH_MOCK_FAIL_MAP="$d/fail")" || rc=$?
assert_eq "unreadable issue -> exit 1" "1" "$rc"
assert_not_contains "unreadable issue -> no PATCH" "$(cat "$d/gh")" 'PATCH'
rm -rf "$d"

d="$(mktemp -d)"; : > "$d/gh"
printf '%s\n' 'milestones?state=open' > "$d/fail"
rc=0; out="$(run_guard "$d" issue-open.json milestones-with-backlog.json GH_MOCK_FAIL_MAP="$d/fail")" || rc=$?
assert_eq "unreadable milestone list -> exit 1" "1" "$rc"
rm -rf "$d"

d="$(mktemp -d)"; : > "$d/gh"
printf '%s\n' 'PATCH' > "$d/fail"
rc=0; out="$(run_guard "$d" issue-open.json milestones-with-backlog.json GH_MOCK_FAIL_MAP="$d/fail")" || rc=$?
assert_eq "failed write -> exit 1" "1" "$rc"
rm -rf "$d"

rc=0; env -u REPO ISSUE_NUMBER=42 bash "$GUARD" >/dev/null 2>&1 || rc=$?
assert_eq "missing REPO -> exit 2" "2" "$rc"
rc=0; env REPO='a/b/../c' ISSUE_NUMBER=42 bash "$GUARD" >/dev/null 2>&1 || rc=$?
assert_eq "malformed REPO -> exit 2" "2" "$rc"
rc=0; env REPO=a/b ISSUE_NUMBER=0 bash "$GUARD" >/dev/null 2>&1 || rc=$?
assert_eq "non-positive ISSUE_NUMBER -> exit 2" "2" "$rc"

BACKFILL="$ROOT/scripts/backfill-backlog-milestone.sh"

# run_backfill <dir> <unmilestoned-fixture> <milestones-fixture> [args...]
# shellcheck disable=SC2031  # PATH is rebuilt per call from the pristine $MOCKS
run_backfill() {
  local dir="$1" issues="$2" milestones="$3"; shift 3
  printf '%s\t%s\n' 'milestones?state=open' "$FIX/$milestones" 'milestone=none' "$FIX/$issues" > "$dir/map"
  env PATH="$MOCKS:$PATH" GH_MOCK_LOG="$dir/gh" GH_MOCK_STDOUT_MAP="$dir/map" \
    ${GH_MOCK_FAIL_MAP:+GH_MOCK_FAIL_MAP="$GH_MOCK_FAIL_MAP"} \
    bash "$BACKFILL" -R freaxnx01/sample "$@" 2>&1
}

section "backfill — dry run counts every page, writes nothing"

d="$(mktemp -d)"; : > "$d/gh"
rc=0; out="$(run_backfill "$d" unmilestoned-two-pages.json milestones-with-backlog.json)" || rc=$?
assert_eq "dry run -> exit 0" "0" "$rc"
# 11, 12 on page one, 14 on page two; 13 is a pull request.
assert_contains "dry run -> counts across pages, PRs excluded" "$out" \
  'backfill: 3 open issues without a milestone in freaxnx01/sample'
assert_contains "dry run -> lists a page-two issue" "$out" '#14'
assert_not_contains "dry run -> does not list the pull request" "$out" '#13'
assert_contains "dry run -> says how to apply" "$out" 'DRY_RUN: would assign backlog (#7) to 3 issues'
assert_not_contains "dry run -> no PATCH" "$(cat "$d/gh")" 'PATCH'
assert_contains "dry run -> reads every page" "$(cat "$d/gh")" '--paginate'
rm -rf "$d"

section "backfill — --apply assigns each issue"

d="$(mktemp -d)"; : > "$d/gh"
rc=0; out="$(run_backfill "$d" unmilestoned-two-pages.json milestones-with-backlog.json --apply)" || rc=$?
assert_eq "apply -> exit 0" "0" "$rc"
for n in 11 12 14; do
  assert_contains "apply -> #$n assigned" "$(cat "$d/gh")" "api -X PATCH repos/freaxnx01/sample/issues/$n -F milestone=7"
done
assert_not_contains "apply -> the pull request is not touched" "$(cat "$d/gh")" 'issues/13 '
assert_contains "apply -> reports the tally" "$out" 'backfill: assigned 3 of 3'
rm -rf "$d"

d="$(mktemp -d)"; : > "$d/gh"
printf '%s\n' 'issues/12 -F' > "$d/fail"
rc=0; out="$(GH_MOCK_FAIL_MAP="$d/fail" run_backfill "$d" unmilestoned-two-pages.json milestones-with-backlog.json --apply)" || rc=$?
assert_eq "one failed write -> exit 1" "1" "$rc"
assert_contains "one failed write -> keeps going" "$(cat "$d/gh")" 'issues/14 -F milestone=7'
assert_contains "one failed write -> the tally shows it" "$out" 'backfill: assigned 2 of 3'
rm -rf "$d"

d="$(mktemp -d)"; : > "$d/gh"
rc=0; out="$(run_backfill "$d" unmilestoned-empty.json milestones-with-backlog.json --apply)" || rc=$?
assert_eq "nothing to do -> exit 0" "0" "$rc"
assert_contains "nothing to do -> reports zero" "$out" 'backfill: 0 open issues without a milestone'
assert_not_contains "nothing to do -> no PATCH" "$(cat "$d/gh")" 'PATCH'
rm -rf "$d"

section "backfill — never creates backlog"

d="$(mktemp -d)"; : > "$d/gh"
rc=0; out="$(run_backfill "$d" unmilestoned-two-pages.json milestones-without-backlog.json --apply)" || rc=$?
assert_eq "missing backlog -> exit 64" "64" "$rc"
assert_contains "missing backlog -> says so" "$out" 'has no open "backlog" milestone'
assert_not_contains "missing backlog -> no PATCH" "$(cat "$d/gh")" 'PATCH'
assert_not_contains "missing backlog -> no POST" "$(cat "$d/gh")" 'POST'
rm -rf "$d"

section "backfill — usage"

rc=0; bash "$BACKFILL" >/dev/null 2>&1 || rc=$?
assert_eq "no -R -> exit 2" "2" "$rc"
rc=0; bash "$BACKFILL" -R freaxnx01/sample --bogus >/dev/null 2>&1 || rc=$?
assert_eq "unknown flag -> exit 2" "2" "$rc"
rc=0; bash "$BACKFILL" -R 'not a repo' >/dev/null 2>&1 || rc=$?
assert_eq "malformed repo -> exit 2" "2" "$rc"

printf '\npassed: %d   failed: %d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf -- '  - %s\n' "$n"; done
  exit 1
fi
exit 0
