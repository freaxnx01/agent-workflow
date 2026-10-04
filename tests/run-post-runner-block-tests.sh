#!/usr/bin/env bash
#
# run-post-runner-block-tests.sh — Layer-1 tests for scripts/post-runner-block.sh.
#
# Drives the script against the shared `gh` mock (tests/mocks/gh), which logs
# each invocation's argv to $GH_MOCK_LOG. Assertions are on that log: which
# object got the comment, and which label was applied.
#
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/post-runner-block.sh"
MOCKS="$HERE/mocks"

PASS=0; FAIL=0; FAIL_NAMES=()

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_GREEN=''; C_RED=''; C_DIM=''; C_OFF=''
fi

section() { printf '\n%s── %s ──%s\n' "$C_DIM" "$1" "$C_OFF"; }
pass() { PASS=$((PASS + 1)); printf '  %s✓%s %s\n' "$C_GREEN" "$C_OFF" "$1"; }
fail() {
  FAIL=$((FAIL + 1)); FAIL_NAMES+=("$1")
  printf '  %s✗%s %s\n' "$C_RED" "$C_OFF" "$1"
  [[ -n "${2:-}" ]] && printf '    %s%s%s\n' "$C_DIM" "$2" "$C_OFF"
}
assert_contains() {
  local hay="$1" needle="$2" name="$3"
  if [[ "$hay" == *"$needle"* ]]; then pass "$name"
  else fail "$name" "expected substring not found: $needle"; fi
}
assert_not_contains() {
  local hay="$1" needle="$2" name="$3"
  if [[ "$hay" != *"$needle"* ]]; then pass "$name"
  else fail "$name" "unexpected substring present: $needle"; fi
}
assert_equals() {
  if [[ "$1" == "$2" ]]; then pass "$3"
  else fail "$3" "expected '$2' got '$1'"; fi
}

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

run_block() {
  local log="$1"; shift
  : > "$log"
  env PATH="$MOCKS:$PATH" GH_MOCK_LOG="$log" "$@" bash "$SCRIPT" 2>&1
}

section "required env"

ec=0
out="$(run_block "$tmp/l0" ISSUE_NUMBER=42)" || ec=$?
assert_equals "$ec" "2"         "missing REPO → exit 2"
assert_contains "$out" "REPO"   "missing REPO → names REPO"

ec=0
out="$(run_block "$tmp/l1" REPO=o/r)" || ec=$?
assert_equals "$ec" "2"                "missing ISSUE_NUMBER → exit 2"
assert_contains "$out" "ISSUE_NUMBER"  "missing ISSUE_NUMBER → names ISSUE_NUMBER"

section "comment target"

log="$tmp/l2"
run_block "$log" REPO=o/r ISSUE_NUMBER=42 PR_NUMBER=7 EXIT_CODE=64 >/dev/null
logtext="$(cat "$log")"
assert_contains "$logtext" "pr comment 7"         "PR known → comments on the PR"
assert_not_contains "$logtext" "issue comment 42" "PR known → does not also comment on the issue"

log="$tmp/l3"
run_block "$log" REPO=o/r ISSUE_NUMBER=42 EXIT_CODE=64 >/dev/null
logtext="$(cat "$log")"
assert_contains "$logtext" "issue comment 42"     "no PR → comments on the issue"

section "comment content"

assert_contains "$logtext" "Review did not run"          "comment → says the review did not run"
assert_contains "$logtext" "docs/RUNNER-REQUIREMENTS.md" "comment → names the doc"
assert_not_contains "$logtext" "](../"                   "comment → no relative markdown link"

section "labels"

assert_contains "$logtext" "--add-label ai:runner-blocked"     "labels → applies ai:runner-blocked"
assert_not_contains "$logtext" "--add-label ai:review-blocked" "labels → never applies ai:review-blocked"
assert_contains "$logtext" "label create ai:runner-blocked"    "labels → idempotently creates the label first"

section "exit-code wording"

log="$tmp/l4"
run_block "$log" REPO=o/r ISSUE_NUMBER=42 EXIT_CODE=65 >/dev/null
assert_contains "$(cat "$log")" "checksum"  "exit 65 → comment names the checksum failure"

log="$tmp/l5"
run_block "$log" REPO=o/r ISSUE_NUMBER=42 EXIT_CODE=66 >/dev/null
assert_contains "$(cat "$log")" "no claude binary"  "exit 66 → comment names the missing binary"

log="$tmp/l6"
run_block "$log" REPO=o/r ISSUE_NUMBER=42 >/dev/null
assert_contains "$(cat "$log")" "could not be installed"  "no EXIT_CODE → generic reason"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'; printf '  - %s\n' "${FAIL_NAMES[@]}"
  exit 1
fi
