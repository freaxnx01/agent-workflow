#!/usr/bin/env bash
#
# run-implement-azdo-tests.sh — Layer-1 tests for how scripts/implement-azdo.sh
# obtains its Azure DevOps token (explicit PAT vs. the CI-host adapter).
# `az` is mocked via tests/mocks/az; DRY_RUN=1 stops the driver before the agent.
#
# Usage: tests/run-implement-azdo-tests.sh
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

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

REPO_AZ="$TMP/repo"
mkdir "$REPO_AZ"
git -C "$REPO_AZ" init -q -b main
git -C "$REPO_AZ" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
git -C "$REPO_AZ" remote add origin 'https://dev.azure.com/contoso/MyProject/_git/my-repo'

AZ_MAP="$TMP/map"
printf 'work-item show\t%s/forge-workitem-azdo.json\n' "$FIXTURES" > "$AZ_MAP"
printf 'resource comments\t%s/forge-comments-azdo.json\n' "$FIXTURES" >> "$AZ_MAP"

# run_driver [VAR=value ...] — runs the driver dry against the fake ADO repo
# under a scrubbed environment; sets RC, OUT (stdout) and ERR (stderr).
RC=0; OUT=''; ERR=''
run_driver() {
  RC=0
  # shellcheck disable=SC2016  # $1/$2 are for the inner bash, not this one
  env -i HOME="$TMP" PATH="$MOCKS:$PATH" \
    ISSUE_NUMBER=7 DRY_RUN=1 AZ_MOCK_FIXTURE="$FIXTURES/forge-workitem-azdo.json" AZ_MOCK_MAP="$AZ_MAP" \
    "$@" bash -c 'cd "$1" && bash "$2"' _ "$REPO_AZ" "$ROOT/scripts/implement-azdo.sh" \
    >"$TMP/out" 2>"$TMP/err" || RC=$?
  OUT="$(cat "$TMP/out")"; ERR="$(cat "$TMP/err")"
}

# run_agent_driver [VAR=value ...] — runs the driver for real (no DRY_RUN) with the
# mock claude. GIT_ALLOW_PROTOCOL=file makes ls-remote/push to the fake https
# origin fail at once, so nothing touches the network. Resets the repo first;
# DROP_ORIGIN_MAIN=1 (set in the caller's env) deletes origin/main after the
# reset. Sets RC, OUT and ERR.
run_agent_driver() {
  RC=0
  git -C "$REPO_AZ" checkout -q main
  git -C "$REPO_AZ" branch -q -D agent/test 2>/dev/null || true
  git -C "$REPO_AZ" update-ref refs/remotes/origin/main main
  [[ -z "${DROP_ORIGIN_MAIN:-}" ]] || git -C "$REPO_AZ" update-ref -d refs/remotes/origin/main
  : > "$TMP/az.log"
  # shellcheck disable=SC2016  # $1/$2 are for the inner bash, not this one
  env -i HOME="$TMP" PATH="$MOCKS:$PATH" \
    ISSUE_NUMBER=7 AZ_MOCK_FIXTURE="$FIXTURES/forge-workitem-azdo.json" AZ_MOCK_MAP="$AZ_MAP" \
    AZURE_DEVOPS_EXT_PAT=pat CLAUDE_MOCK_RESULT="$FIXTURES/result-success-cheap.json" \
    AZ_MOCK_LOG="$TMP/az.log" GIT_ALLOW_PROTOCOL=file \
    GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
    GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid \
    "$@" bash -c 'cd "$1" && bash "$2"' _ "$REPO_AZ" "$ROOT/scripts/implement-azdo.sh" \
    >"$TMP/out" 2>"$TMP/err" || RC=$?
  OUT="$(cat "$TMP/out")"; ERR="$(cat "$TMP/err")"
}

# run_loop <steps-csv> [VAR=value ...] — runs the driver for real against a fresh
# bare origin (clone in $WORK, so origin/HEAD exists) with the scripted claude
# mock (tests/mocks/claude, step mode) and the origin shim, which makes detect_forge
# see an Azure DevOps remote while pushes go to the bare repo. Sets RC, OUT, ERR,
# AZLOG (az argv log), CLAUDELOG (agent call log), WORK and BARE.
LOOP_N=0
RC=0; OUT=''; ERR=''; AZLOG=''; CLAUDELOG=''; WORK=''; BARE=''
run_loop() {
  local steps="$1" dir seed
  shift
  LOOP_N=$((LOOP_N + 1))
  dir="$TMP/loop-$LOOP_N"; BARE="$dir/bare.git"; WORK="$dir/work"; seed="$dir/seed"
  mkdir -p "$dir"
  git init -q --bare -b main "$BARE"
  git init -q -b main "$seed"
  git -C "$seed" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
  git -C "$seed" push -q "$BARE" main
  # LOOP_SEED_BRANCH=<name> puts a foreign commit on that branch of the origin
  # before the run, as a human's salvage of an earlier run would.
  if [[ -n "${LOOP_SEED_BRANCH:-}" ]]; then
    git -C "$seed" checkout -q -b "$LOOP_SEED_BRANCH"
    printf 'foreign\n' > "$seed/foreign.txt"
    git -C "$seed" add foreign.txt
    git -C "$seed" -c user.name=t -c user.email=t@example.invalid commit -q -m foreign
    git -C "$seed" push -q "$BARE" "$LOOP_SEED_BRANCH"
  fi
  git clone -q "$BARE" "$WORK" 2>/dev/null
  # Azure Pipelines checks out a detached HEAD; LOOP_DETACH=1 reproduces that.
  [[ -z "${LOOP_DETACH:-}" ]] || git -C "$WORK" checkout -q --detach
  tr ',' '\n' <<<"$steps" > "$dir/steps"
  : > "$dir/az.log"; : > "$dir/claude.log"
  {
    printf 'work-item show\t%s/forge-workitem-azdo.json\n' "$FIXTURES"
    printf 'work-item update\t%s/forge-workitem-azdo.json\n' "$FIXTURES"
    printf 'repos pr create\t%s/azdo-pr-create.tsv\n' "$FIXTURES"
    printf 'resource comments\t%s/%s\n' "$FIXTURES" "${AZ_COMMENTS:-forge-comments-azdo.json}"
  } > "$dir/map"
  RC=0
  # shellcheck disable=SC2016  # $1/$2 are for the inner bash, not this one
  env -i HOME="$TMP" PATH="$MOCKS/git-origin:$MOCKS:$PATH" \
    GIT_MOCK_REAL="$(command -v git)" \
    GIT_MOCK_ORIGIN_URL=https://dev.azure.com/contoso/MyProject/_git/my-repo \
    AZURE_DEVOPS_EXT_PAT=pat ISSUE_NUMBER=7 DELAY_OVERRIDE_SEC=0 \
    GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=t@example.invalid \
    GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=t@example.invalid \
    AZ_MOCK_FIXTURE="$FIXTURES/forge-workitem-azdo.json" AZ_MOCK_MAP="$dir/map" AZ_MOCK_LOG="$dir/az.log" \
    CLAUDE_MOCK_STEPS="$dir/steps" CLAUDE_MOCK_STATE="$dir/claude.state" CLAUDE_MOCK_LOG="$dir/claude.log" \
    "$@" bash -c 'cd "$1" && bash "$2"' _ "$WORK" "$ROOT/scripts/implement-azdo.sh" \
    >"$dir/out" 2>"$dir/err" || RC=$?
  OUT="$(cat "$dir/out")"; ERR="$(cat "$dir/err")"
  AZLOG="$(cat "$dir/az.log")"
  # shellcheck disable=SC2034  # CLAUDELOG is read by the retry-loop tests
  CLAUDELOG="$(cat "$dir/claude.log")"
}

count_reports() { grep -c 'ai-implement run (local, Azure DevOps) — attempt' <<<"$1" || true; }

section "token source"

SENTINEL="tok-SECRET-9f3a"

run_driver TF_BUILD=True SYSTEM_ACCESSTOKEN="$SENTINEL"
assert_eq "pipelines_token_used_when_pat_unset: rc" "0" "$RC"
assert_contains "pipelines_token_used_when_pat_unset: dry run reached" "DRY_RUN=1" "$OUT"
assert_not_contains "token_never_printed" "$SENTINEL" "$OUT$ERR"

run_driver AZURE_DEVOPS_EXT_PAT=pat TF_BUILD=True SYSTEM_ACCESSTOKEN="$SENTINEL"
assert_eq "explicit_pat_wins: rc" "0" "$RC"

run_driver AZURE_DEVOPS_EXT_PAT=pat TF_BUILD=True
assert_eq "explicit_pat_wins_without_system_accesstoken: rc" "0" "$RC"

run_driver TF_BUILD=True SYSTEM_ACCESSTOKEN=
assert_eq "pipelines_empty_token_exits_2: rc" "2" "$RC"

run_driver GITHUB_ACTIONS=true GITHUB_TOKEN="$SENTINEL"
assert_eq "actions_github_token_not_used_as_pat: rc" "2" "$RC"
assert_contains "actions_github_token_not_used_as_pat: message" "AZURE_DEVOPS_EXT_PAT must be set" "$ERR"
assert_not_contains "actions_github_token_never_printed" "$SENTINEL" "$OUT$ERR"

run_driver
assert_eq "local_without_pat_exits_2: rc" "2" "$RC"
assert_contains "local_without_pat_exits_2: message" "AZURE_DEVOPS_EXT_PAT must be set" "$ERR"

section "run context label"

run_driver TF_BUILD=True SYSTEM_ACCESSTOKEN="$SENTINEL"
assert_contains "pipeline_run_labelled_pipeline" "implement (pipeline, Azure DevOps)" "$OUT"

run_driver AZURE_DEVOPS_EXT_PAT=pat
assert_contains "local_run_labelled_local" "implement (local, Azure DevOps)" "$OUT"

section "pipeline-file guard"

run_agent_driver CLAUDE_MOCK_TOUCH=azure-pipelines-pr.yml
assert_eq "pipeline_file_blocks_run: rc" "1" "$RC"
assert_contains "pipeline_file_blocks_run: message" "refusing to push or open a PR" "$ERR"
assert_contains "pipeline_file_blocks_run: names file" "azure-pipelines-pr.yml" "$ERR"
heading_line="$(printf '%s\n' "$ERR" | grep -n 'refusing to push or open a PR' | head -1 | cut -d: -f1)"
path_line="$(printf '%s\n' "$ERR" | grep -n '^ *azure-pipelines-pr.yml$' | head -1 | cut -d: -f1)"
assert_eq "pipeline_file_blocks_run: heading precedes path" "1" \
  "$([[ -n "$heading_line" && -n "$path_line" && "$heading_line" -lt "$path_line" ]] && echo 1 || echo 0)"
assert_not_contains "pipeline_file_blocks_run: no PR" "repos pr create" "$(cat "$TMP/az.log")"
assert_not_contains "pipeline_file_blocks_run: no push attempt" "could not push" "$ERR"

run_agent_driver CLAUDE_MOCK_TOUCH=src/app.cs
assert_not_contains "src_only_proceeds_past_guard: not blocked" "pipeline files" "$ERR"
assert_contains "src_only_proceeds_past_guard: reached push" "could not push" "$ERR"
assert_eq "src_only_proceeds_past_guard: rc" "1" "$RC"

run_agent_driver CLAUDE_MOCK_TOUCH=deploy/build.yml PIPELINE_FILE_GLOBS='deploy/**'
assert_eq "extra_glob_blocks_run: rc" "1" "$RC"
assert_contains "extra_glob_blocks_run: names file" "deploy/build.yml" "$ERR"
assert_not_contains "extra_glob_blocks_run: no PR" "repos pr create" "$(cat "$TMP/az.log")"

DROP_ORIGIN_MAIN=1 run_agent_driver CLAUDE_MOCK_TOUCH=src/app.cs
assert_eq "missing_base_ref_blocks_run: rc" "1" "$RC"
assert_contains "missing_base_ref_blocks_run: message" "cannot diff" "$ERR"
assert_not_contains "missing_base_ref_blocks_run: no push attempt" "could not push" "$ERR"

section "one attempt"

run_loop success
assert_eq "attempt_success: rc" "0" "$RC"
assert_contains "attempt_success: PR created" "repos pr create" "$AZLOG"
assert_contains "attempt_success: work item linked" "--work-items 7" "$AZLOG"
assert_eq "attempt_success: one report" "1" "$(count_reports "$AZLOG")"
assert_contains "attempt_success: report heading" "— attempt 1" "$AZLOG"
assert_contains "attempt_success: outcome" "**Outcome:** success" "$AZLOG"
assert_contains "attempt_success: turns" "**Turns:** 4 / cap" "$AZLOG"
# shellcheck disable=SC2016  # literal dollar sign
assert_contains "attempt_success: cost" '**Cost:** $0.0042' "$AZLOG"
assert_contains "attempt_success: PR in report" "draft PR: !42" "$AZLOG"
assert_contains "attempt_success: branch pushed" "ai/7-ok-1" "$(git -C "$BARE" branch --list 'ai/7-ok-1')"
assert_contains "attempt_success: draft PR line" "draft PR  : #42" "$OUT"

run_loop api_auth
assert_eq "attempt_api_auth: rc" "1" "$RC"
assert_eq "attempt_api_auth: one report" "1" "$(count_reports "$AZLOG")"
assert_contains "attempt_api_auth: outcome" "**Outcome:** failed: api_auth" "$AZLOG"
assert_not_contains "attempt_api_auth: no PR" "repos pr create" "$AZLOG"
assert_not_contains "attempt_api_auth: no branch-left line" "branch left on the server" "$AZLOG"
assert_contains "attempt_api_auth: stop message" "Stopping: api_auth does not retry (or the retry budget is spent)." "$ERR"

run_loop pipeline-file
assert_eq "attempt_pipeline_file: rc" "1" "$RC"
assert_not_contains "attempt_pipeline_file: no PR" "repos pr create" "$AZLOG"
assert_eq "attempt_pipeline_file: branch not pushed" "" "$(git -C "$BARE" branch --list 'ai/7-pf-1')"
assert_eq "attempt_pipeline_file: one report" "1" "$(count_reports "$AZLOG")"
assert_contains "attempt_pipeline_file: report names file" "azure-pipelines.yml" "$AZLOG"

run_loop success
assert_not_contains "g5_banner_no_longer_unavailable" "retry            : unavailable" "$OUT"
assert_contains "g5_banner_names_policy" "lib/retry-policy.sh" "$OUT"
assert_not_contains "g5_report_no_unavailable_text" "Retry and auto-merge are unavailable" "$AZLOG"

# The report must round-trip through check-attempt-cap.sh: it counts a failed
# attempt, and an unknown or zero-turn report is still counted correctly.
cap_roundtrip() {
  local result="$1" body comments
  # shellcheck disable=SC2016  # $1/$2 are for the inner bash, not this one
  body="$(env -i HOME="$TMP" PATH="$PATH" bash -c '
    source "$1"
    ATTEMPT_SECONDS=5 TURNS_BUDGET=80 RUN_CONTEXT=pipeline RUN_ATTEMPT=1 RESULT_FILE="$2"
    render_report "failed: task_failure" "next: stopping"' _ "$ROOT/scripts/implement-azdo.sh" "$result")"
  comments="$(jq -Rs '[{body: .}]' <<<"$body")"
  env -i HOME="$TMP" PATH="$PATH" ISSUE_NUMBER=7 REPO=contoso/my-repo DRY_RUN=1 \
    ISSUE_COMMENTS_JSON="$comments" bash "$ROOT/scripts/check-attempt-cap.sh"
}
cap_out="$(cap_roundtrip "$FIXTURES/result-max-turns.json")"
assert_contains "cap_roundtrip_max_turns: attempt" "attempt=2" "$cap_out"
assert_contains "cap_roundtrip_max_turns: non-starts" "non-starts=0" "$cap_out"
cap_out="$(cap_roundtrip "$FIXTURES/result-api-auth.json")"
assert_contains "cap_roundtrip_api_auth: attempt" "attempt=2" "$cap_out"

# report_metrics_line writes the word unknown, never 0, when the result has no data.
printf 'not json' > "$TMP/notjson.txt"
printf '{"type":"result"}' > "$TMP/nofields.json"
for case_file in "$TMP/missing.json" "$TMP/notjson.txt" "$TMP/nofields.json"; do
  # shellcheck disable=SC2016  # $1/$2 are for the inner bash, not this one
  line="$(env -i HOME="$TMP" PATH="$PATH" bash -c 'source "$1"; ATTEMPT_SECONDS=5 TURNS_BUDGET=80; report_metrics_line "$2"' \
    _ "$ROOT/scripts/implement-azdo.sh" "$case_file")"
  assert_contains "metrics_unknown_$(basename "$case_file"): turns" "**Turns:** unknown / cap 80" "$line"
  assert_contains "metrics_unknown_$(basename "$case_file"): cost" "**Cost:** unknown" "$line"
done

# post_report fails closed: the report is counted even when the forge refuses it.
# shellcheck disable=SC2016  # $1 is for the inner bash, not this one
post_out="$(env -i HOME="$TMP" PATH="$PATH" bash -c '
  source "$1"
  forge_issue_comment() { return 1; }
  WORK_DIR="$(mktemp -d)"; ISSUE_NUMBER=7 RUN_CONTEXT=local RUN_ATTEMPT=1 ATTEMPT_SECONDS=1 TURNS_BUDGET=80
  RESULT_FILE=/nonexistent ISSUE_COMMENTS_JSON="[]"
  post_report "failed: bug" "next: stopping" 2>/dev/null; rc=$?
  printf "rc=%s count=%s\n" "$rc" "$(jq length <<<"$ISSUE_COMMENTS_JSON")"
  rm -rf "$WORK_DIR"' _ "$ROOT/scripts/implement-azdo.sh")"
assert_eq "post_report_failed_post_still_counted" "rc=0 count=1" "$post_out"

section "retry loop"

run_loop transient,success
assert_eq "retry_transient_then_success: rc" "0" "$RC"
assert_eq "retry_transient_then_success: two reports" "2" "$(count_reports "$AZLOG")"
assert_contains "retry_transient_then_success: attempt 1" "— attempt 1" "$AZLOG"
assert_contains "retry_transient_then_success: attempt 2" "— attempt 2" "$AZLOG"
assert_contains "retry_transient_then_success: first failed" "failed: transient" "$AZLOG"
assert_contains "retry_transient_then_success: retry line" "next: retrying in 0s" "$AZLOG"
assert_contains "retry_transient_then_success: cap line" "- cap: attempt 2 of 2" "$AZLOG"
assert_eq "retry_transient_then_success: one PR" "1" "$(grep -c 'repos pr create' <<<"$AZLOG" || true)"
assert_eq "retry_transient_then_success: second call starts clean" "call 2 branch=main dirty=0" "$(sed -n 2p <<<"$CLAUDELOG")"
assert_eq "retry_transient_then_success: failed branch deleted" "" "$(git -C "$WORK" branch --list 'ai/7-try-1')"

run_loop task_failure,task_failure
assert_eq "retry_task_failure_twice: rc" "1" "$RC"
assert_eq "retry_task_failure_twice: two reports" "2" "$(count_reports "$AZLOG")"
assert_contains "retry_task_failure_twice: second stops" "next: stopping" "$AZLOG"
assert_not_contains "retry_task_failure_twice: no PR" "repos pr create" "$AZLOG"

run_loop api_auth,success
assert_eq "retry_api_auth_not_retried: rc" "1" "$RC"
assert_eq "retry_api_auth_not_retried: one report" "1" "$(count_reports "$AZLOG")"
assert_eq "retry_api_auth_not_retried: one agent call" "1" "$(grep -c . <<<"$CLAUDELOG" || true)"

AZ_COMMENTS=azdo-comments-two-reports.json run_loop success
assert_eq "cap_reached_at_start: rc" "0" "$RC"
assert_eq "cap_reached_at_start: no agent call" "" "$CLAUDELOG"
assert_contains "cap_reached_at_start: parked comment" "## ai-implement parked" "$AZLOG"
assert_eq "cap_reached_at_start: no attempt report" "0" "$(count_reports "$AZLOG")"
assert_contains "cap_reached_at_start: output" "parked" "$OUT"

run_loop transient,transient,success MAX_ATTEMPTS=2
assert_eq "cap_reached_mid_run: rc" "0" "$RC"
assert_eq "cap_reached_mid_run: two agent calls" "2" "$(wc -l <<<"$CLAUDELOG")"
assert_eq "cap_reached_mid_run: two reports" "2" "$(count_reports "$AZLOG")"
assert_contains "cap_reached_mid_run: parked" "## ai-implement parked" "$AZLOG"
second_report="$(awk '/— attempt 2/ {f = 1} f && /## ai-implement parked/ {exit} f' <<<"$AZLOG")"
assert_contains "cap_reached_mid_run: second report found" "— attempt 2" "$second_report"
assert_not_contains "cap_reached_mid_run: no retry promise" "retrying" "$second_report"
assert_contains "cap_reached_mid_run: second report stops" "next: stopping (attempt cap reached)" "$AZLOG"
assert_eq "cap_reached_mid_run: parked comes last" "1" \
  "$([[ "${AZLOG##*— attempt 2}" == *"## ai-implement parked"* ]] && echo 1 || echo 0)"

run_loop transient-pushed,success
assert_contains "retry_names_remote_branch" "branch left on the server: ai/7-try-1" "$AZLOG"

run_loop transient-pushed-fixed,success-fixed
assert_eq "reused_branch: rc" "0" "$RC"
assert_eq "reused_branch: one PR" "1" "$(grep -c 'repos pr create' <<<"$AZLOG" || true)"
assert_contains "reused_branch: remote tip is attempt 2" "HELLO.md" "$(git -C "$BARE" ls-tree -r --name-only ai/7-same)"
assert_not_contains "reused_branch: stale commit gone" "a.txt" "$(git -C "$BARE" ls-tree -r --name-only ai/7-same)"

# A branch that existed on the server before the run is a collision: reported,
# never overwritten.
LOOP_SEED_BRANCH=ai/7-same run_loop success-fixed
assert_eq "preexisting_branch: rc" "1" "$RC"
assert_not_contains "preexisting_branch: no PR" "repos pr create" "$AZLOG"
assert_contains "preexisting_branch: foreign commit kept" "foreign.txt" "$(git -C "$BARE" ls-tree -r --name-only ai/7-same)"
assert_not_contains "preexisting_branch: not overwritten" "HELLO.md" "$(git -C "$BARE" ls-tree -r --name-only ai/7-same)"
assert_contains "preexisting_branch: report says why" "already exists on the server" "$AZLOG"

# reset_workspace keeps ignored files locally and wipes them on a pipeline agent.

# Found live (run 42): on a detached checkout the attempt "ended on" HEAD, and
# the reset tried `git branch -D HEAD`.
LOOP_DETACH=1 run_loop transient-nobranch,success
assert_eq "retry_detached_checkout: rc" "0" "$RC"
assert_eq "retry_detached_checkout: two reports" "2" "$(count_reports "$AZLOG")"
assert_not_contains "retry_detached_checkout: no reset error" "could not reset" "$ERR"
LOOP_DETACH=1 run_loop api_auth
assert_not_contains "detached_no_branch: no branch-left line" "branch left on the server" "$AZLOG"
LOOP_DETACH=1 run_loop success-nobranch
assert_eq "detached_no_branch_success: rc" "1" "$RC"
assert_not_contains "detached_no_branch_success: no PR" "repos pr create" "$AZLOG"
assert_contains "detached_no_branch_success: says why" "did not branch" "$AZLOG"
section "agent timeout"

run_loop hang,success IMPLEMENT_TIMEOUT_MIN=0.02
assert_eq "timeout_hang_then_success: rc" "0" "$RC"
assert_eq "timeout_hang_then_success: two reports" "2" "$(count_reports "$AZLOG")"
assert_contains "timeout_hang_then_success: first failed transient" "failed: transient" "$AZLOG"
assert_contains "timeout_hang_then_success: turns unknown" "**Turns:** unknown" "$AZLOG"
assert_contains "timeout_hang_then_success: cost unknown" "**Cost:** unknown" "$AZLOG"

# A report written after a timeout (empty result file) still counts as an attempt.
# shellcheck disable=SC2016  # $1/$2 are for the inner bash, not this one
timeout_body="$(env -i HOME="$TMP" PATH="$PATH" bash -c '
  source "$1"
  : > "$2"
  ATTEMPT_SECONDS=1 TURNS_BUDGET=80 RUN_CONTEXT=pipeline RUN_ATTEMPT=1 RESULT_FILE="$2"
  render_report "failed: transient" "next: stopping"' _ "$ROOT/scripts/implement-azdo.sh" "$TMP/empty-result.json")"
timeout_comments="$(jq -Rs '[{body: .}]' <<<"$timeout_body")"
cap_out="$(env -i HOME="$TMP" PATH="$PATH" ISSUE_NUMBER=7 REPO=contoso/my-repo DRY_RUN=1 \
  ISSUE_COMMENTS_JSON="$timeout_comments" bash "$ROOT/scripts/check-attempt-cap.sh")"
assert_contains "timeout_cap_roundtrip: attempt" "attempt=2" "$cap_out"
assert_contains "timeout_cap_roundtrip: non-starts" "non-starts=0" "$cap_out"

run_driver IMPLEMENT_TIMEOUT_MIN=abc AZURE_DEVOPS_EXT_PAT=pat
assert_eq "timeout_invalid: rc" "2" "$RC"
assert_contains "timeout_invalid: message" "IMPLEMENT_TIMEOUT_MIN must be a number of minutes" "$ERR"

# Clones $BARE, the bare repo of the most recent run_loop (run one first).
reset_ignored_file_survives() {
  local tf="$1" dir="$TMP/reset-$2"
  git clone -q "$BARE" "$dir" 2>/dev/null
  if [[ ! -e "$dir/.gitignore" ]]; then
    printf '.envrc\n' > "$dir/.gitignore"
    git -C "$dir" add .gitignore
    git -C "$dir" -c user.name=t -c user.email=t@example.invalid commit -q -m ignore
    git -C "$dir" update-ref refs/remotes/origin/main main
  fi
  git -C "$dir" checkout -q -b ai/x
  printf 'secret\n' > "$dir/.envrc"; printf 'junk\n' > "$dir/junk.txt"
  # shellcheck disable=SC2016  # $1..$3 are for the inner bash
  env -i HOME="$TMP" PATH="$PATH" ${tf:+TF_BUILD="$tf"} bash -c '
    source "$1"; cd "$2"; DEFAULT_BRANCH=main HEAD_BRANCH=ai/x
    reset_workspace' _ "$ROOT/scripts/implement-azdo.sh" "$dir" >/dev/null 2>&1 || return 2
  [[ -e "$dir/.envrc" ]] && printf 'kept' || printf 'removed'
}
run_loop success
assert_eq "reset_local_keeps_ignored_file" "kept" "$(reset_ignored_file_survives '' local)"
assert_eq "reset_pipeline_removes_ignored_file" "removed" "$(reset_ignored_file_survives True pipe)"
assert_eq "reset_untracked_file_removed" "" "$([[ -e "$TMP/reset-local/junk.txt" ]] && echo present)"
assert_eq "reset_branch_deleted" "" "$(git -C "$TMP/reset-local" branch --list ai/x)"

printf '\n%s─────%s\n' "$C_DIM" "$C_OFF"
printf '  %s%d passed%s' "$C_GREEN" "$PASS" "$C_OFF"
if [ "$FAIL" -gt 0 ]; then
  printf ', %s%d failed%s\n' "$C_RED" "$FAIL" "$C_OFF"
  printf '\nFailed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf '  - %s\n' "$n"; done
  exit 1
fi
printf '\n'
exit 0
