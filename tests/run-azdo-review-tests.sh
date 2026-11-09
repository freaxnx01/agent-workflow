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

section "azdo self-fix command"

PAT='tok-SECRET-5e1c'
PAT_B64="$(printf ':%s' "$PAT" | base64 -w0)"

# fresh_world — bare repo B (main) plus clone W on agent/x with one pushed commit.
B=''; W=''
fresh_world() {
  rm -rf "$T/world"; mkdir "$T/world"
  B="$T/world/B.git"; W="$T/world/W"
  git init -q --bare -b main "$B"
  git clone -q "$B" "$W" 2>/dev/null
  git -C "$W" config user.name t
  git -C "$W" config user.email t@example.invalid
  git -C "$W" checkout -q -b main
  printf 'base\n' > "$W/file.txt"
  git -C "$W" add file.txt
  git -C "$W" commit -q -m base
  git -C "$W" push -q origin main
  git -C "$W" checkout -q -b agent/x
  printf 'work\n' >> "$W/file.txt"
  git -C "$W" commit -q -am work
  git -C "$W" push -q origin agent/x
}

# selffix_azdo <fix-agent-mock> [VAR=value ...] — sets RC, SF_LOG (git argv log),
# SF_OUT (stdout+stderr) and SF_STOP (stop-file content).
RC=0; SF_LOG=''; SF_OUT=''; SF_STOP=''
selffix_azdo() {
  local agent="$1"; shift
  RC=0
  rm -f "$T/git.log" "$T/stop"
  ( cd "$W" && env \
      PATH="$MOCKS/git-origin:$MOCKS:$PATH" GIT_MOCK_REAL="$(command -v git)" \
      GIT_MOCK_ORIGIN_URL='https://dev.azure.com/contoso/MyProject/_git/my-repo' \
      GIT_MOCK_LOG="$T/git.log" AZURE_DEVOPS_EXT_PAT="$PAT" \
      HEAD_REF=agent/x ITERATION=1 REPO=MyProject/my-repo DEFAULT_BRANCH=main \
      SELF_FIX_STOP_FILE="$T/stop" FIX_AGENT_CMD="$MOCKS/$agent" \
      "$@" \
      bash "$ROOT/scripts/azdo-self-fix.sh" 42 "$T/concerns.json" ) >"$T/sf.out" 2>&1 || RC=$?
  SF_LOG="$(cat "$T/git.log" 2>/dev/null || true)"
  SF_OUT="$(cat "$T/sf.out")"
  SF_STOP="$(cat "$T/stop" 2>/dev/null || true)"
}

fresh_world
selffix_azdo self-fix-agent
assert_eq "self_fix_pushes_with_extraheader: exit 0" "0" "$RC"
assert_eq "self_fix_pushes_with_extraheader: remote has the fix commit" \
  "$(git -C "$W" rev-parse HEAD)" "$(git -C "$B" rev-parse agent/x)"
assert_eq "self_fix_pushes_with_extraheader: author is ai-implement" \
  "ai-implement <ai-implement@noreply.invalid>" "$(git -C "$W" log -1 --format='%an <%ae>')"
assert_contains "self_fix_pushes_with_extraheader: push used the redacted extraheader" \
  "http.extraheader=Authorization: Basic <redacted>" "$(printf '%s\n' "$SF_LOG" | grep ' push ' || true)"
assert_eq "self_fix_pushes_with_extraheader: stop file empty" "" "$SF_STOP"

assert_not_contains "self_fix_secret_never_persisted: git log" "$PAT" "$SF_LOG"
assert_not_contains "self_fix_secret_never_persisted: git log (base64)" "$PAT_B64" "$SF_LOG"
assert_not_contains "self_fix_secret_never_persisted: output" "$PAT" "$SF_OUT"
assert_not_contains "self_fix_secret_never_persisted: output (base64)" "$PAT_B64" "$SF_OUT"
SF_CFG="$(git -C "$W" config --list; git -C "$W" remote -v)"
assert_not_contains "self_fix_secret_never_persisted: config and remotes" "$PAT" "$SF_CFG"
assert_not_contains "self_fix_secret_never_persisted: config and remotes (base64)" "$PAT_B64" "$SF_CFG"
assert_eq "self_fix_secret_never_persisted: no extraheader in config" "" \
  "$(git -C "$W" config --get-all http.extraheader || true)"

fresh_world
BEFORE="$(git -C "$B" rev-parse agent/x)"
selffix_azdo self-fix-agent-pipeline
assert_eq "self_fix_guard_blocks_pipeline_file: exit 3" "3" "$RC"
assert_eq "self_fix_guard_blocks_pipeline_file: remote unchanged" "$BEFORE" "$(git -C "$B" rev-parse agent/x)"
assert_not_contains "self_fix_guard_blocks_pipeline_file: no push" " push " "$SF_LOG"
assert_contains "self_fix_guard_blocks_pipeline_file: stop file names the path" \
  "the fix changed pipeline files: azure-pipelines.yml" "$SF_STOP"
assert_contains "self_fix_guard_blocks_pipeline_file: stderr carries the line" \
  "self-fix stopped: the fix changed pipeline files: azure-pipelines.yml" "$SF_OUT"

fresh_world
git -C "$W" update-ref -d refs/remotes/origin/main
BEFORE="$(git -C "$B" rev-parse agent/x)"
selffix_azdo self-fix-agent
assert_eq "self_fix_guard_fails_closed: exit 3" "3" "$RC"
assert_eq "self_fix_guard_fails_closed: remote unchanged" "$BEFORE" "$(git -C "$B" rev-parse agent/x)"
assert_not_contains "self_fix_guard_fails_closed: no push" " push " "$SF_LOG"

fresh_world
selffix_azdo self-fix-agent-fail
assert_eq "self_fix_agent_failure: exit 1" "1" "$RC"
assert_not_contains "self_fix_agent_failure: no push" " push " "$SF_LOG"
assert_eq "self_fix_agent_failure: stop file empty" "" "$SF_STOP"

fresh_world
RC=0
( cd "$W" && env REPO=MyProject/my-repo HEAD_REF=agent/x ITERATION=1 SKIP_CLONE=1 SKIP_PUSH=1 \
    WORK_DIR="$W" FIX_AGENT_CMD="$MOCKS/self-fix-agent" \
    bash "$ROOT/scripts/self-fix-pr.sh" 42 "$T/concerns.json" ) >/dev/null 2>&1 || RC=$?
assert_eq "self_fix_pr_default_identity_unchanged: exit 0" "0" "$RC"
assert_eq "self_fix_pr_default_identity_unchanged: author" \
  "github-actions[bot] <github-actions[bot]@users.noreply.github.com>" \
  "$(git -C "$W" log -1 --format='%an <%ae>')"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then printf 'failed: %s\n' "${FAIL_NAMES[*]}"; exit 1; fi
