#!/usr/bin/env bash
#
# run-issue-intake-tests.sh — Layer-1 tests for scripts/issue-intake.sh and the
# issue-intake reusable workflow (#549). gh is mocked; no network.
#
# Usage: tests/run-issue-intake-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/tests/fixtures/intake"
MOCKS="$ROOT/tests/mocks"
SCRIPT="$ROOT/scripts/issue-intake.sh"

# Hermetic: a runner always sets these, and the script falls back to none of them.
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
  (source "$SCRIPT"; intake_decision < "$FIX/$1")
}

section "intake_decision — who gets the label"

assert_eq "an unlabelled hand-filed issue is labelled" "label" "$(decide issue-plain.json)"
assert_eq "an issue that already has it is skipped" "skip already labelled" "$(decide issue-labelled.json)"
assert_eq "a category label does not block intake" "label" "$(decide issue-category.json)"
assert_eq "ai-implement blocks intake" "skip pipeline label ai-implement" "$(decide issue-ai-implement.json)"
assert_eq "an ai:-prefixed label blocks intake" "skip pipeline label ai:paused" "$(decide issue-ai-prefixed.json)"
assert_eq "the emoji parked label blocks intake" "skip pipeline label 🧊 parked" "$(decide issue-parked-emoji.json)"
assert_eq "a body with a plan heading is skipped" "skip already has an implementation plan" "$(decide issue-planned.json)"
assert_eq "a prose mention of the plan heading does not count" "label" "$(decide issue-plan-in-prose.json)"
assert_eq "a bot-opened issue is skipped" "skip opened by a bot" "$(decide issue-bot.json)"

for l in enrichment-ongoing needs-human parked roadmap pipeline-paused; do
  # shellcheck disable=SC1090
  got="$(jq -n --arg l "$l" '{number:1,labels:[{name:$l}],body:"x",author:{login:"u",is_bot:false}}' \
    | (source "$SCRIPT"; intake_decision))"
  assert_eq "$l blocks intake" "skip pipeline label $l" "$got"
done

# run_intake <dir> <fixture> [extra env...] — runs the script with gh mocked.
run_intake() {
  local dir="$1" fixture="$2"; shift 2
  printf '%s\t%s\n' 'issue view' "$FIX/$fixture" > "$dir/stdout-map"
  env PATH="$MOCKS:$PATH" GH_MOCK_LOG="$dir/gh" GH_MOCK_STDOUT_MAP="$dir/stdout-map" \
    REPO=freaxnx01/game-rhyflitzer ISSUE_NUMBER=357 "$@" bash "$SCRIPT" 2>&1
}

section "the write path"

d="$(mktemp -d)"; : > "$d/gh"
out="$(run_intake "$d" issue-plain.json GITHUB_OUTPUT="$d/out")"
assert_contains "labelled -> says so" "$out" 'intake: #357 labelled needs-enrichment'
assert_contains "labelled -> the issue is edited" "$(cat "$d/gh")" \
  'issue edit 357 --repo freaxnx01/game-rhyflitzer --add-label needs-enrichment'
create_line="$(grep -n 'label create needs-enrichment' "$d/gh" | head -1 | cut -d: -f1)"
edit_line="$(grep -n -- '--add-label needs-enrichment' "$d/gh" | head -1 | cut -d: -f1)"
if [[ -n "$create_line" && -n "$edit_line" ]] && (( create_line < edit_line )); then
  pass "the label is created before it is applied"
else
  fail "the label is created before it is applied" "create ${create_line:-none}, edit ${edit_line:-none}"
fi
assert_contains "the create carries the colour" "$(grep 'label create' "$d/gh")" 'd4c5f9'
assert_contains "GITHUB_OUTPUT gets the decision" "$(cat "$d/out")" 'decision=labelled'
assert_contains "the issue is re-read, not taken from the payload" "$(cat "$d/gh")" \
  'issue view 357 --repo freaxnx01/game-rhyflitzer --json number,labels,body,author'
rm -rf "$d"

d="$(mktemp -d)"; : > "$d/gh"
out="$(run_intake "$d" issue-ai-implement.json GITHUB_OUTPUT="$d/out")"
assert_contains "skipped -> says why" "$out" 'intake: #357 skipped (pipeline label ai-implement)'
assert_not_contains "skipped -> no edit" "$(cat "$d/gh")" 'issue edit'
assert_not_contains "skipped -> no label create" "$(cat "$d/gh")" 'label create'
assert_contains "skipped -> GITHUB_OUTPUT says skipped" "$(cat "$d/out")" 'decision=skipped'
assert_contains "skipped -> GITHUB_OUTPUT names the reason" "$(cat "$d/out")" 'reason=pipeline label ai-implement'
rm -rf "$d"

d="$(mktemp -d)"; : > "$d/gh"
out="$(run_intake "$d" issue-plain.json DRY_RUN=1)"
assert_contains "dry run -> says what it would do" "$out" 'DRY_RUN: would label #357 needs-enrichment'
assert_not_contains "dry run -> no edit" "$(cat "$d/gh")" 'issue edit'
assert_not_contains "dry run -> no label create" "$(cat "$d/gh")" 'label create'
rm -rf "$d"

section "failures are loud"

d="$(mktemp -d)"; : > "$d/gh"
printf 'issue view\n' > "$d/fail"
ec=0; out="$(run_intake "$d" issue-plain.json GH_MOCK_FAIL_MAP="$d/fail")" || ec=$?
assert_eq "unreadable issue -> exit 1" "1" "$ec"
assert_contains "unreadable issue -> says so" "$out" 'could not read issue #357'
assert_not_contains "unreadable issue -> no edit" "$(cat "$d/gh")" 'issue edit'
rm -rf "$d"

d="$(mktemp -d)"; : > "$d/gh"
printf -- '--add-label needs-enrichment\n' > "$d/fail"
ec=0; out="$(run_intake "$d" issue-plain.json GH_MOCK_FAIL_MAP="$d/fail")" || ec=$?
assert_eq "failed label write -> exit 1" "1" "$ec"
assert_contains "failed label write -> says so" "$out" 'could not label issue #357'
rm -rf "$d"

d="$(mktemp -d)"; : > "$d/gh"
ec=0; env PATH="$MOCKS:$PATH" GH_MOCK_LOG="$d/gh" ISSUE_NUMBER=357 bash "$SCRIPT" >/dev/null 2>&1 || ec=$?
assert_eq "missing REPO -> exit 2" "2" "$ec"
ec=0; env PATH="$MOCKS:$PATH" GH_MOCK_LOG="$d/gh" REPO=o/r ISSUE_NUMBER='12;x' bash "$SCRIPT" >/dev/null 2>&1 || ec=$?
assert_eq "non-numeric ISSUE_NUMBER -> exit 2" "2" "$ec"
assert_eq "invalid env -> no gh call" "" "$(cat "$d/gh")"
rm -rf "$d"

printf '\npassed: %d   failed: %d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf -- '  - %s\n' "$n"; done
  exit 1
fi
exit 0
