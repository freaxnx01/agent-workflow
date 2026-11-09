#!/usr/bin/env bash
#
# run-azdo-review-tests.sh — Layer-1 tests for review-pr.sh and self-fix-loop.sh
# on Azure DevOps (FORGE=azdo). The PR diff, head SHA and comments go through
# the forge verbs; `az` is mocked via tests/mocks/az, and no `gh` is ever
# called (the gh mock exits non-zero without GH_MOCK_LOG).
#
# Usage: tests/run-azdo-review-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOCKS="$ROOT/tests/mocks"
FIXTURES="$ROOT/tests/fixtures"

PASS=0
FAIL=0
FAIL_NAMES=()

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
  [ $# -gt 1 ] && printf '      %s\n' "$2"
  return 0
}
assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then pass "$name"; else fail "$name" "expected: $expected | actual: $actual"; fi
}
assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$name"; else fail "$name" "missing: $needle"; fi
}
assert_not_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then pass "$name"; else fail "$name" "unexpected: $needle"; fi
}

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

R="$T/repo"
mkdir "$R"
git -C "$R" init -q -b main
git -C "$R" config user.name t
git -C "$R" config user.email t@example.invalid
git -C "$R" remote add origin 'https://dev.azure.com/contoso/MyProject/_git/my-repo'
git -C "$R" commit -q --allow-empty -m base
git -C "$R" update-ref refs/remotes/origin/main HEAD
git -C "$R" checkout -q -b agent/x
mkdir "$R/src"
printf 'hello\n' > "$R/src/a.txt"
git -C "$R" add src/a.txt
git -C "$R" commit -q -m 'add a'

# az_map <file> <fixture-for-POST> <fixture-for-GET> — first match wins.
az_map() {
  printf -- '--http-method POST\t%s\n' "$2" > "$1"
  printf 'pullRequestThreads\t%s\n' "$3" >> "$1"
}

# review_azdo [VAR=value ...] — runs review-pr.sh in the fake ADO repo; sets
# RC, GO (the GITHUB_OUTPUT file content) and AZLOG (the az argv log).
RC=0; GO=''; AZLOG=''
review_azdo() {
  RC=0
  rm -rf "$T/go" "$T/az.log" "$T/rt"
  mkdir "$T/rt"
  ( cd "$R" && env \
      PATH="$MOCKS:$PATH" FORGE=azdo DEFAULT_BRANCH=main \
      PR_NUMBER=42 REPO=MyProject/my-repo HEAD_SHA=abc123 AGENT=claude \
      AGENT_CMD="$MOCKS/agent-review" AGENT_FIXTURE="$FIXTURES/review-approve.json" \
      AGENT_PROMPT_COPY="$T/prompt" \
      AZ_MOCK_MAP="$T/map" AZ_MOCK_LOG="$T/az.log" AZ_MOCK_STDIN_LOG="$T/stdin.log" \
      GITHUB_OUTPUT="$T/go" RUNNER_TEMP="$T/rt" \
      "$@" \
      bash "$ROOT/scripts/review-pr.sh" ) >"$T/out" 2>"$T/err" || RC=$?
  GO="$(cat "$T/go" 2>/dev/null || true)"
  AZLOG="$(cat "$T/az.log" 2>/dev/null || true)"
}

post_count() { printf '%s\n' "$AZLOG" | grep -c -e '--http-method POST' || true; }

section "review-pr.sh on azdo"

rm -f "$T/stdin.log"
az_map "$T/map" "$FIXTURES/azdo-pr-thread-created.json" "$FIXTURES/azdo-pr-threads-empty.json"
review_azdo
assert_eq "azdo_review_posts_one_thread: exit 0" "0" "$RC"
assert_contains "azdo_review_posts_one_thread: posted=true" "posted=true" "$GO"
assert_contains "azdo_review_posts_one_thread: verdict=approve" "verdict=approve" "$GO"
assert_eq "azdo_review_posts_one_thread: one POST" "1" "$(post_count)"
assert_eq "azdo_review_posts_one_thread: marker leads the thread content" "yes" \
  "$(jq -r 'if (.comments[0].content | startswith("<!-- review-pr:abc123 -->")) then "yes" else "no" end' "$T/stdin.log")"
assert_contains "azdo_review_posts_one_thread: prompt holds the forge_pr_diff diff" "src/a.txt" "$(cat "$T/prompt")"

# Round-trip: the POST body, read back as the GET response, marks the head.
jq -s '{value: ., count: length}' "$T/stdin.log" > "$T/threads-posted.json"
cp "$T/stdin.log" "$T/stdin-first.log"

rm -f "$T/stdin.log"
az_map "$T/map" "$FIXTURES/azdo-pr-thread-created.json" "$T/threads-posted.json"
review_azdo
assert_contains "azdo_review_same_sha_posts_nothing: posted=false" "posted=false" "$GO"
assert_eq "azdo_review_same_sha_posts_nothing: no POST" "0" "$(post_count)"

rm -f "$T/stdin.log"
review_azdo HEAD_SHA=def456
assert_contains "azdo_review_new_sha_posts_again: posted=true" "posted=true" "$GO"
assert_eq "azdo_review_new_sha_posts_again: one POST" "1" "$(post_count)"

rm -f "$T/stdin.log"
az_map "$T/map" "$FIXTURES/azdo-pr-thread-created.json" "$FIXTURES/azdo-pr-threads-empty.json"
review_azdo -u DEFAULT_BRANCH
if (( RC != 0 )); then pass "azdo_review_diff_failure_is_loud: non-zero exit"; else fail "azdo_review_diff_failure_is_loud: non-zero exit" "exit 0"; fi
assert_eq "azdo_review_diff_failure_is_loud: no POST" "0" "$(post_count)"

section "self-fix-loop.sh on azdo"

printf '{"verdict":"request_changes","summary":"x","concerns":[]}' > "$T/concerns.json"
rm -f "$T/go" "$T/fix.log"
( cd "$R" && env \
    FORGE=azdo PR_NUMBER=42 REPO=MyProject/my-repo HEAD_SHA=initsha HEAD_REF=agent/x \
    INITIAL_VERDICT=request_changes CONCERNS_FILE="$T/concerns.json" MAX_ITERATIONS=2 \
    FIX_CMD="$MOCKS/self-fix-loop-fix-stub" FIX_LOG="$T/fix.log" \
    REVIEW_SCRIPT="$MOCKS/self-fix-loop-review-stub" REVIEW_VERDICTS=request_changes,approve \
    GITHUB_OUTPUT="$T/go" \
    bash "$ROOT/scripts/self-fix-loop.sh" ) >/dev/null 2>&1 || true
LOOP_GO="$(cat "$T/go" 2>/dev/null || true)"
assert_contains "azdo_loop_head_sha_from_git: head-sha is the checkout HEAD" \
  "head-sha=$(git -C "$R" rev-parse HEAD)" "$LOOP_GO"
assert_contains "azdo_loop_head_sha_from_git: verdict=approve" "verdict=approve" "$LOOP_GO"
assert_contains "azdo_loop_head_sha_from_git: iterations-used=2" "iterations-used=2" "$LOOP_GO"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then printf 'failed: %s\n' "${FAIL_NAMES[*]}"; exit 1; fi
