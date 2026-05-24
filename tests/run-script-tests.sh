#!/usr/bin/env bash
#
# run-script-tests.sh — Layer-1 fixture tests for scripts/ (no network, no gh).
#
# Drives each fixture under tests/fixtures/ through the appropriate script and
# asserts the observable output. The real `gh` CLI is replaced by the mock at
# tests/mocks/gh. Should run in <5 seconds.
#
# Usage: tests/run-script-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/post-run-report.sh"
FIXTURES="$ROOT/tests/fixtures"
MOCKS="$ROOT/tests/mocks"

PASS=0
FAIL=0
FAIL_NAMES=()
START_TS="$(date +%s%N 2>/dev/null || date +%s)"

# --- output helpers ---------------------------------------------------------

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_GREEN=''; C_RED=''; C_DIM=''; C_OFF=''
fi

section() { printf '\n%s── %s ──%s\n' "$C_DIM" "$1" "$C_OFF"; }

pass() {
  PASS=$((PASS + 1))
  printf '  %s✓%s %s\n' "$C_GREEN" "$C_OFF" "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  FAIL_NAMES+=("$1")
  printf '  %s✗%s %s\n' "$C_RED" "$C_OFF" "$1"
  [[ -n "${2:-}" ]] && printf '    %s%s%s\n' "$C_DIM" "$2" "$C_OFF"
}

# --- assertion helpers ------------------------------------------------------

assert_contains() {
  local hay="$1" needle="$2" name="$3"
  if [[ "$hay" == *"$needle"* ]]; then
    pass "$name"
  else
    fail "$name" "expected substring not found: $needle"
  fi
}

assert_not_contains() {
  local hay="$1" needle="$2" name="$3"
  if [[ "$hay" != *"$needle"* ]]; then
    pass "$name"
  else
    fail "$name" "unexpected substring present: $needle"
  fi
}

assert_equals() {
  if [[ "$1" == "$2" ]]; then
    pass "$3"
  else
    fail "$3" "expected '$2' got '$1'"
  fi
}

# --- driver helpers ---------------------------------------------------------

render_only() {
  local result="$FIXTURES/$1"
  local exec=""
  [[ $# -ge 2 && -n "$2" ]] && exec="$FIXTURES/$2"
  RENDER_ONLY=1 \
  RESULT_FILE="$result" \
  EXECUTION_FILE="$exec" \
  ISSUE_NUMBER=42 \
  WORKFLOW_RUN_URL=https://example/run/test \
    bash "$SCRIPT"
}

# Run command (with env-var prefixes via `env`); capture exit code without
# tripping set -e in the caller.
run_capture_ec() {
  local ec=0
  "$@" >/dev/null 2>&1 || ec=$?
  printf '%s' "$ec"
}

# --- tests ------------------------------------------------------------------

section "render_only — branch coverage per fixture"

out="$(render_only result-success-cheap.json)"
assert_contains "$out" 'LABELS: ai:done'                "success-cheap → ai:done"
assert_contains "$out" "\$0.0042"                       "success-cheap → cost shows 4 sig digits"
assert_contains "$out" ':white_check_mark: success'     "success-cheap → success outcome"
assert_contains "$out" 'no execution log provided'      "success-cheap → context row reads n/a"

out="$(render_only result-success-expensive.json)"
assert_contains "$out" 'LABELS: ai:done'                "success-expensive → ai:done"
assert_contains "$out" "\$1.87"                         "success-expensive → cost %.2f"
assert_contains "$out" '8m 2s'                          "success-expensive → duration humanised"

out="$(render_only result-rate-limit.json)"
assert_contains "$out" 'LABELS: ai:failed'              "rate-limit → ai:failed"
assert_contains "$out" 'failed: error_during_execution' "rate-limit → subtype surfaced"
assert_contains "$out" ':x:'                            "rate-limit → x emoji"

out="$(render_only result-max-turns.json)"
assert_contains "$out" 'LABELS: ai:failed'              "max-turns → ai:failed"
assert_contains "$out" 'failed: error_max_turns'        "max-turns → distinct subtype"
assert_contains "$out" '10m 12s'                        "max-turns → minutes+seconds duration"

out="$(render_only result-low-cache-hit.json)"
assert_contains "$out" '(27% hit rate)'                 "low-cache-hit → 27% computed"
assert_contains "$out" 'LABELS: ai:done'                "low-cache-hit → still ai:done (low hit ≠ failure)"

out="$(render_only result-high-context.json exec-high-context.ndjson)"
assert_contains "$out" 'ai:done,ctx:high'               "high-context → ai:done + ctx:high"
assert_contains "$out" '165,000 / 200,000 (82%)'        "high-context → 82% of 200k"

# Same data, presented as a JSON array (claude-code-base-action's shape).
exec_array="$(mktemp)"
jq -s '.' "$FIXTURES/exec-high-context.ndjson" > "$exec_array"
out="$(RENDER_ONLY=1 RESULT_FILE="$FIXTURES/result-high-context.json" \
       EXECUTION_FILE="$exec_array" \
       ISSUE_NUMBER=42 WORKFLOW_RUN_URL=u \
       bash "$SCRIPT")"
rm -f "$exec_array"
assert_contains "$out" 'ai:done,ctx:high'               "execution as JSON array → still ctx:high"
assert_contains "$out" '165,000 / 200,000 (82%)'        "execution as JSON array → same 82% peak"

section "context threshold knobs (vary CONTEXT_WINDOW_SIZE on same exec fixture)"

threshold_run() {
  RENDER_ONLY=1 \
  RESULT_FILE="$FIXTURES/result-high-context.json" \
  EXECUTION_FILE="$FIXTURES/exec-high-context.ndjson" \
  ISSUE_NUMBER=42 WORKFLOW_RUN_URL=u \
  CONTEXT_WINDOW_SIZE="$1" \
    bash "$SCRIPT"
}

out="$(threshold_run 200000)"
assert_contains     "$out" 'ctx:high'    "window=200k (82%) → ctx:high"

out="$(threshold_run 300000)"
assert_contains     "$out" 'ctx:medium'  "window=300k (55%) → ctx:medium"
assert_not_contains "$out" 'ctx:high'    "window=300k → not ctx:high"

out="$(threshold_run 1000000)"
assert_not_contains "$out" 'ctx:medium'  "window=1M (16%) → no ctx:medium"
assert_not_contains "$out" 'ctx:high'    "window=1M (16%) → no ctx:high"

section "error paths (exit codes are part of the script API)"

ec="$(run_capture_ec env RENDER_ONLY=1 RESULT_FILE=/does/not/exist.json \
       ISSUE_NUMBER=1 WORKFLOW_RUN_URL=u bash "$SCRIPT")"
assert_equals "$ec" "64" "missing RESULT_FILE → exit 64"

tmp_bad="$(mktemp)"
printf 'not valid json\n' > "$tmp_bad"
ec="$(run_capture_ec env RENDER_ONLY=1 RESULT_FILE="$tmp_bad" \
       ISSUE_NUMBER=1 WORKFLOW_RUN_URL=u bash "$SCRIPT")"
rm -f "$tmp_bad"
assert_equals "$ec" "65" "invalid JSON → exit 65"

ec="$(run_capture_ec env RENDER_ONLY=1 \
       RESULT_FILE="$FIXTURES/result-success-cheap.json" \
       WORKFLOW_RUN_URL=u bash "$SCRIPT")"
assert_equals "$ec" "2" "missing ISSUE_NUMBER → exit 2"

section "classify-task — explicit override labels and heuristics"

CLASSIFY="$ROOT/scripts/classify-task.sh"

# Override: model:opus label
out="$(ISSUE_NUMBER=1 REPO=o/r ISSUE_LABELS='ai-implement
model:opus' bash "$CLASSIFY")"
assert_contains "$out" 'chosen: claude-opus-4-7 (label model:opus)'   "label model:opus → opus"

# Override: model:haiku
out="$(ISSUE_NUMBER=1 REPO=o/r ISSUE_LABELS='model:haiku' bash "$CLASSIFY")"
assert_contains "$out" 'chosen: claude-haiku-4-5 (label model:haiku)' "label model:haiku → haiku"

# Override: model:sonnet
out="$(ISSUE_NUMBER=1 REPO=o/r ISSUE_LABELS='model:sonnet' bash "$CLASSIFY")"
assert_contains "$out" 'chosen: claude-sonnet-4-6 (label model:sonnet)' "label model:sonnet → sonnet"

# Heuristic: refactor keyword → opus
out="$(ISSUE_NUMBER=1 REPO=o/r ISSUE_LABELS='ai-implement' \
       ISSUE_BODY='Refactor the auth middleware' bash "$CLASSIFY")"
assert_contains "$out" 'claude-opus-4-7 (heuristic: refactor/architecture keywords)' "refactor keyword → opus"

# Heuristic: typo keyword → haiku
out="$(ISSUE_NUMBER=1 REPO=o/r ISSUE_LABELS='ai-implement' \
       ISSUE_BODY='Fix typo in the README' bash "$CLASSIFY")"
assert_contains "$out" 'claude-haiku-4-5 (heuristic: trivial-edit keywords)' "typo keyword → haiku"

# Default: nothing matches
out="$(ISSUE_NUMBER=1 REPO=o/r ISSUE_LABELS='ai-implement' \
       ISSUE_BODY='Add a hello.md file' bash "$CLASSIFY")"
assert_contains "$out" 'claude-sonnet-4-6 (heuristic: default)' "no match → default sonnet"

# Default override via DEFAULT_MODEL env
out="$(ISSUE_NUMBER=1 REPO=o/r ISSUE_LABELS='ai-implement' \
       ISSUE_BODY='Add a hello.md file' DEFAULT_MODEL=claude-haiku-4-5 bash "$CLASSIFY")"
assert_contains "$out" 'claude-haiku-4-5 (heuristic: default)' "DEFAULT_MODEL env override applied on default branch"

# Missing ISSUE_NUMBER → exit 2
ec="$(run_capture_ec env REPO=o/r bash "$CLASSIFY")"
assert_equals "$ec" "2" "missing ISSUE_NUMBER → exit 2"

# Override label wins over heuristic keywords
out="$(ISSUE_NUMBER=1 REPO=o/r \
       ISSUE_LABELS=$'ai-implement\nmodel:haiku' \
       ISSUE_BODY='Refactor the auth middleware' bash "$CLASSIFY")"
assert_contains "$out" 'claude-haiku-4-5 (label model:haiku)' "override label beats heuristic"

section "classify-agent — label override + input fallback (ADR-001)"

CLASSIFY_AGENT="$ROOT/scripts/classify-agent.sh"

# Override: agent:claude label
out="$(ISSUE_NUMBER=1 REPO=o/r ISSUE_LABELS='agent:claude' bash "$CLASSIFY_AGENT")"
assert_contains "$out" 'chosen: claude (label agent:claude)'     "label agent:claude → claude"

# Override: agent:opencode label
out="$(ISSUE_NUMBER=1 REPO=o/r ISSUE_LABELS='agent:opencode' bash "$CLASSIFY_AGENT")"
assert_contains "$out" 'chosen: opencode (label agent:opencode)' "label agent:opencode → opencode"

# Default input (no label, no DEFAULT_AGENT) → claude
out="$(ISSUE_NUMBER=1 REPO=o/r ISSUE_LABELS='ai-implement' bash "$CLASSIFY_AGENT")"
assert_contains "$out" 'chosen: claude (workflow input default (claude))' "no label, no DEFAULT_AGENT → claude"

# Input fallback: DEFAULT_AGENT=opencode
out="$(ISSUE_NUMBER=1 REPO=o/r ISSUE_LABELS='ai-implement' DEFAULT_AGENT=opencode bash "$CLASSIFY_AGENT")"
assert_contains "$out" 'chosen: opencode (workflow input default (opencode))' "no label, DEFAULT_AGENT=opencode → opencode"

# Label beats input
out="$(ISSUE_NUMBER=1 REPO=o/r ISSUE_LABELS='agent:claude' DEFAULT_AGENT=opencode bash "$CLASSIFY_AGENT")"
assert_contains "$out" 'chosen: claude (label agent:claude)'     "label agent:claude beats DEFAULT_AGENT=opencode"

# Invalid DEFAULT_AGENT → exit 2
ec="$(run_capture_ec env ISSUE_NUMBER=1 REPO=o/r ISSUE_LABELS='ai-implement' DEFAULT_AGENT=mistral bash "$CLASSIFY_AGENT")"
assert_equals "$ec" "2" "invalid DEFAULT_AGENT → exit 2"

# Missing ISSUE_NUMBER → exit 2
ec="$(run_capture_ec env REPO=o/r bash "$CLASSIFY_AGENT")"
assert_equals "$ec" "2" "missing ISSUE_NUMBER → exit 2"

# Missing REPO → exit 2
ec="$(run_capture_ec env ISSUE_NUMBER=1 bash "$CLASSIFY_AGENT")"
assert_equals "$ec" "2" "missing REPO → exit 2"

section "check-auto-review-gate — input + label combinations"

GATE="$ROOT/scripts/check-auto-review-gate.sh"

# Both off → disabled
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_AUTO_REVIEW=false ISSUE_LABELS='ai-implement' bash "$GATE")"
assert_contains "$out" 'enabled=false (workflow input auto-review=false)' "input=false, no label → disabled"

# Label only → still disabled (input gate not satisfied)
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_AUTO_REVIEW=false ISSUE_LABELS=$'ai-implement\nai-auto-review' bash "$GATE")"
assert_contains "$out" 'enabled=false (workflow input auto-review=false)' "input=false, label set → disabled (input wins)"

# Input only → disabled (label gate not satisfied)
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_AUTO_REVIEW=true ISSUE_LABELS='ai-implement' bash "$GATE")"
assert_contains "$out" 'enabled=false (input=true but label ai-auto-review missing)' "input=true, no label → disabled"

# Both on → enabled
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_AUTO_REVIEW=true ISSUE_LABELS=$'ai-implement\nai-auto-review' bash "$GATE")"
assert_contains "$out" 'enabled=true (input=true AND label ai-auto-review present)' "input=true, label set → enabled"

# Default INPUT_AUTO_REVIEW (unset) → disabled
out="$(ISSUE_NUMBER=1 REPO=o/r ISSUE_LABELS='ai-auto-review' bash "$GATE")"
assert_contains "$out" 'enabled=false (workflow input auto-review=false)' "unset INPUT_AUTO_REVIEW defaults to false"

# Invalid INPUT_AUTO_REVIEW → exit 2
ec="$(run_capture_ec env ISSUE_NUMBER=1 REPO=o/r INPUT_AUTO_REVIEW=yes ISSUE_LABELS='' bash "$GATE")"
assert_equals "$ec" "2" "invalid INPUT_AUTO_REVIEW → exit 2"

# Missing ISSUE_NUMBER → exit 2
ec="$(run_capture_ec env REPO=o/r INPUT_AUTO_REVIEW=true bash "$GATE")"
assert_equals "$ec" "2" "missing ISSUE_NUMBER → exit 2"

# Missing REPO → exit 2
ec="$(run_capture_ec env ISSUE_NUMBER=1 INPUT_AUTO_REVIEW=true bash "$GATE")"
assert_equals "$ec" "2" "missing REPO → exit 2"

section "review-pr — verdict paths + idempotency + oversized diff"

REVIEW="$ROOT/scripts/review-pr.sh"
AGENT_MOCK="$MOCKS/agent-review"

# Common env helper: minimal diff (well below the size cap)
TINY_DIFF="$(mktemp)"
trap 'rm -f "$TINY_DIFF"' EXIT
printf 'diff --git a/foo b/foo\n--- a/foo\n+++ b/foo\n@@ -1 +1 @@\n-old\n+new\n' > "$TINY_DIFF"

review_run() {
  # args: <fixture> [extra env assignments...]
  local fixture="$1"; shift
  local go
  go="$(mktemp)"
  GITHUB_OUTPUT="$go" \
  PR_NUMBER=42 REPO=o/r AGENT=claude HEAD_SHA=abc123 \
  DIFF_FILE="$TINY_DIFF" \
  EXISTING_COMMENTS='' \
  DRY_RUN=1 \
  AGENT_CMD="$AGENT_MOCK" \
  AGENT_FIXTURE="$FIXTURES/$fixture" \
  "$@" \
    bash "$REVIEW" >/dev/null
  cat "$go"
  rm -f "$go"
}

out="$(review_run review-approve.json)"
assert_contains "$out" 'verdict=approve'         "approve fixture → verdict=approve"
assert_contains "$out" 'posted=false'            "approve + DRY_RUN → not posted"

out="$(review_run review-request-changes.json)"
assert_contains "$out" 'verdict=request_changes' "request_changes fixture → verdict=request_changes"

out="$(review_run review-block.json)"
assert_contains "$out" 'verdict=block'           "block fixture → verdict=block"

# Oversized diff → block regardless of agent output (agent is not invoked)
BIG_DIFF="$(mktemp)"
head -c 1024 /dev/urandom | base64 > "$BIG_DIFF"
out="$(MAX_DIFF_BYTES=10 \
       review_run review-approve.json \
       env DIFF_FILE="$BIG_DIFF")"
assert_contains "$out" 'verdict=block'           "diff exceeds MAX_DIFF_BYTES → verdict=block"
assert_contains "$out" 'unreviewable'            "oversized reason mentions 'unreviewable'"
rm -f "$BIG_DIFF"

# Malformed agent JSON → coerced to block
out="$(review_run review-malformed.json)"
assert_contains "$out" 'verdict=block'           "malformed agent output → verdict=block"

# Agent invocation failure → coerced to block
out="$(review_run review-approve.json env AGENT_FAIL=1)"
assert_contains "$out" 'verdict=block'           "agent failure → verdict=block"

# Invalid verdict string in agent JSON → coerced to block
BAD_VERDICT="$(mktemp --suffix=.json)"
printf '{"verdict":"lgtm","summary":"x","concerns":[]}\n' > "$BAD_VERDICT"
out="$(AGENT_FIXTURE_OVERRIDE="$BAD_VERDICT" review_run review-approve.json env AGENT_FIXTURE="$BAD_VERDICT")"
rm -f "$BAD_VERDICT"
assert_contains "$out" 'verdict=block'           "unknown verdict string → verdict=block"

# Idempotency: existing comment with the head-SHA marker → skip post
GO="$(mktemp)"
GITHUB_OUTPUT="$GO" \
PR_NUMBER=42 REPO=o/r AGENT=claude HEAD_SHA=abc123 \
DIFF_FILE="$TINY_DIFF" \
EXISTING_COMMENTS='## Automated review — verdict: `approve`
<!-- review-pr:abc123 -->
prior body' \
AGENT_CMD="$AGENT_MOCK" AGENT_FIXTURE="$FIXTURES/review-approve.json" \
  bash "$REVIEW" >/dev/null
out="$(cat "$GO")"
rm -f "$GO"
assert_contains "$out" 'posted=false'            "existing marker for HEAD_SHA → posted=false"
assert_contains "$out" 'verdict=approve'         "idempotent run still emits verdict"

# Full path with mocked gh (no DRY_RUN, no EXISTING_COMMENTS): posts a comment
REVIEW_LOG="$(mktemp)"
GO="$(mktemp)"
PATH="$MOCKS:$PATH" \
GH_MOCK_LOG="$REVIEW_LOG" \
GITHUB_OUTPUT="$GO" \
PR_NUMBER=42 REPO=owner/repo AGENT=claude HEAD_SHA=abc123 \
DIFF_FILE="$TINY_DIFF" \
AGENT_CMD="$AGENT_MOCK" AGENT_FIXTURE="$FIXTURES/review-approve.json" \
  bash "$REVIEW" >/dev/null
gh_calls="$(cat "$REVIEW_LOG")"
go_out="$(cat "$GO")"
rm -f "$REVIEW_LOG" "$GO"
assert_contains "$gh_calls" 'pr view 42 --repo owner/repo'         "fetches existing comments via gh pr view"
assert_contains "$gh_calls" 'pr comment 42 --repo owner/repo --body-file' "posts via gh pr comment --body-file"
assert_contains "$go_out"   'posted=true'                          "no marker → posted=true"

# Error paths
ec="$(run_capture_ec env REPO=o/r AGENT=claude HEAD_SHA=abc bash "$REVIEW")"
assert_equals "$ec" "2" "missing PR_NUMBER → exit 2"

ec="$(run_capture_ec env PR_NUMBER=1 REPO=o/r AGENT=mistral HEAD_SHA=abc \
        DIFF_FILE="$TINY_DIFF" AGENT_CMD="$AGENT_MOCK" \
        AGENT_FIXTURE="$FIXTURES/review-approve.json" bash "$REVIEW")"
assert_equals "$ec" "2" "invalid AGENT → exit 2"

ec="$(run_capture_ec env PR_NUMBER=1 REPO=o/r AGENT=claude HEAD_SHA=abc \
        PROMPT_TEMPLATE=/no/such/template.md DIFF_FILE="$TINY_DIFF" \
        AGENT_CMD="$AGENT_MOCK" AGENT_FIXTURE="$FIXTURES/review-approve.json" \
        bash "$REVIEW")"
assert_equals "$ec" "64" "missing PROMPT_TEMPLATE → exit 64"

section "classify-failure — buckets per fixture"

CLASSIFY_FAIL="$ROOT/scripts/classify-failure.sh"

out="$(RESULT_FILE="$FIXTURES/result-success-cheap.json"      bash "$CLASSIFY_FAIL")"
assert_contains "$out" 'class=success'      "success fixture → success"

out="$(RESULT_FILE="$FIXTURES/result-rate-limit.json"         bash "$CLASSIFY_FAIL")"
assert_contains "$out" 'class=rate_limit'   "rate-limit fixture → rate_limit"

out="$(RESULT_FILE="$FIXTURES/result-max-turns.json"          bash "$CLASSIFY_FAIL")"
assert_contains "$out" 'class=task_failure' "max-turns fixture → task_failure"

out="$(RESULT_FILE="$FIXTURES/result-api-auth.json"           bash "$CLASSIFY_FAIL")"
assert_contains "$out" 'class=api_auth'     "api-auth fixture → api_auth"

ec="$(run_capture_ec env bash "$CLASSIFY_FAIL")"
assert_equals "$ec" "2" "missing RESULT_FILE → exit 2"

ec="$(run_capture_ec env RESULT_FILE=/no/such/file bash "$CLASSIFY_FAIL")"
assert_equals "$ec" "64" "unreadable RESULT_FILE → exit 64"

section "retry-dispatch — policy decisions (DRY_RUN, no real dispatch)"

RETRY="$ROOT/scripts/retry-dispatch.sh"

# success → no retry regardless of attempt
out="$(CLASS=success ATTEMPT=1 ISSUE_NUMBER=42 REPO=o/r DRY_RUN=1 bash "$RETRY")"
assert_contains "$out" 'decision=stop'  "class=success → stop"

# rate_limit, attempt 1 → retry
out="$(CLASS=rate_limit ATTEMPT=1 ISSUE_NUMBER=42 REPO=o/r DRY_RUN=1 bash "$RETRY")"
assert_contains "$out" 'decision=retry'  "rate_limit attempt=1 → retry"
assert_contains "$out" 'delay-seconds=300' "rate_limit delay defaults to 300s"

# rate_limit, attempt at cap → stop
out="$(CLASS=rate_limit ATTEMPT=3 ISSUE_NUMBER=42 REPO=o/r DRY_RUN=1 bash "$RETRY")"
assert_contains "$out" 'decision=stop'  "rate_limit attempt=cap → stop"

# transient, exponential backoff
out="$(CLASS=transient ATTEMPT=1 ISSUE_NUMBER=42 REPO=o/r DRY_RUN=1 bash "$RETRY")"
assert_contains "$out" 'delay-seconds=10' "transient attempt=1 → 10s backoff"
out="$(CLASS=transient ATTEMPT=2 ISSUE_NUMBER=42 REPO=o/r DRY_RUN=1 bash "$RETRY")"
assert_contains "$out" 'delay-seconds=20' "transient attempt=2 → 20s backoff"
out="$(CLASS=transient ATTEMPT=3 ISSUE_NUMBER=42 REPO=o/r DRY_RUN=1 bash "$RETRY")"
assert_contains "$out" 'decision=stop'  "transient attempt=cap → stop"

# task_failure: only retry once (default MAX_RETRIES_TASK=1)
out="$(CLASS=task_failure ATTEMPT=1 ISSUE_NUMBER=42 REPO=o/r DRY_RUN=1 bash "$RETRY")"
assert_contains "$out" 'decision=retry' "task_failure attempt=1 → retry once"
out="$(CLASS=task_failure ATTEMPT=2 ISSUE_NUMBER=42 REPO=o/r DRY_RUN=1 bash "$RETRY")"
assert_contains "$out" 'decision=stop'  "task_failure attempt=2 → stop"

# operator-intervention classes never auto-retry
out="$(CLASS=api_auth ATTEMPT=1 ISSUE_NUMBER=42 REPO=o/r DRY_RUN=1 bash "$RETRY")"
assert_contains "$out" 'decision=stop'  "api_auth → stop (operator intervention)"
out="$(CLASS=bug ATTEMPT=1 ISSUE_NUMBER=42 REPO=o/r DRY_RUN=1 bash "$RETRY")"
assert_contains "$out" 'decision=stop'  "bug → stop (operator intervention)"

# DRY_RUN actually skips dispatch (the retry path would otherwise sleep 300s)
out="$(CLASS=rate_limit ATTEMPT=1 ISSUE_NUMBER=42 REPO=o/r DELAY_OVERRIDE_SEC=0 DRY_RUN=1 bash "$RETRY")"
assert_contains "$out" 'DRY_RUN: would sleep'  "DRY_RUN prints would-dispatch message"

# Missing required env
ec="$(run_capture_ec env CLASS=success ATTEMPT=1 ISSUE_NUMBER=42 bash "$RETRY")"
assert_equals "$ec" "2" "missing REPO → exit 2"

section "ensure-issue-labels — issues label-create calls under gh mock"

LABELS_LOG="$(mktemp)"
PATH="$MOCKS:$PATH" \
GH_MOCK_LOG="$LABELS_LOG" \
REPO=owner/repo \
  bash "$ROOT/scripts/ensure-issue-labels.sh" >/dev/null

log="$(cat "$LABELS_LOG")"
rm -f "$LABELS_LOG"

# Lifecycle labels (written by post-run-report.sh)
assert_contains "$log" 'label create ai:running --repo owner/repo' "creates ai:running"
assert_contains "$log" 'label create ai:done --repo owner/repo'    "creates ai:done"
assert_contains "$log" 'label create ai:failed --repo owner/repo'  "creates ai:failed"
assert_contains "$log" 'label create ctx:medium --repo owner/repo' "creates ctx:medium"
assert_contains "$log" 'label create ctx:high --repo owner/repo'   "creates ctx:high"

# Selector labels (read by classify-agent.sh — ADR-001)
assert_contains "$log" 'label create agent:claude --repo owner/repo'   "creates agent:claude"
assert_contains "$log" 'label create agent:opencode --repo owner/repo' "creates agent:opencode"

# Gate labels (auto-review epic #3, chaining epic #4)
assert_contains "$log" 'label create ai-auto-review --repo owner/repo'  "creates ai-auto-review"
assert_contains "$log" 'label create ai-chain --repo owner/repo'        "creates ai-chain"
assert_contains "$log" 'label create ai:chain-paused --repo owner/repo' "creates ai:chain-paused"

ec="$(run_capture_ec env bash "$ROOT/scripts/ensure-issue-labels.sh")"
assert_equals "$ec" "2" "missing REPO → exit 2"

section "ensure-toolchain — happy path + dry-run"

ENSURE="$ROOT/scripts/ensure-toolchain.sh"

out="$(TOOLS="bash sh" bash "$ENSURE")"
assert_contains "$out" 'all required tools present'             "all-present → success message"

out="$(TOOLS="bash surely_no_such_tool_xyz" DRY_RUN=1 bash "$ENSURE")"
assert_contains "$out" 'missing (DRY_RUN, not installing)'      "missing+DRY_RUN → reports + exits 0"
assert_contains "$out" 'surely_no_such_tool_xyz'                "DRY_RUN report names the missing tool"

ec="$(run_capture_ec env DRY_RUN=1 TOOLS="surely_no_such_tool_xyz" bash "$ENSURE")"
assert_equals "$ec" "0" "DRY_RUN with missing tool → exit 0 (no install attempted)"

section "full path with mocked gh (verifies side effects)"

MOCK_LOG="$(mktemp)"
trap 'rm -f "$MOCK_LOG"' EXIT

PATH="$MOCKS:$PATH" \
GH_MOCK_LOG="$MOCK_LOG" \
RESULT_FILE="$FIXTURES/result-high-context.json" \
EXECUTION_FILE="$FIXTURES/exec-high-context.ndjson" \
ISSUE_NUMBER=42 \
REPO=owner/repo \
WORKFLOW_RUN_URL=https://example/run/777 \
  bash "$SCRIPT" >/dev/null

log="$(cat "$MOCK_LOG")"
assert_contains "$log" 'issue comment 42 --repo owner/repo --body-file' "calls 'gh issue comment' with --body-file"
assert_contains "$log" 'issue edit 42 --repo owner/repo --add-label ai:done,ctx:high' "applies ai:done,ctx:high"
assert_contains "$log" 'issue edit 42 --repo owner/repo --remove-label ai:running'   "removes ai:running"
assert_contains "$log" 'issue edit 42 --repo owner/repo --remove-label ai:failed'    "removes opposite label (ai:failed) on success"

# --- summary ----------------------------------------------------------------

END_TS="$(date +%s%N 2>/dev/null || date +%s)"
if [[ "${#START_TS}" -gt 10 ]]; then
  elapsed_ms=$(( (END_TS - START_TS) / 1000000 ))
else
  elapsed_ms=$(( (END_TS - START_TS) * 1000 ))
fi

total=$((PASS + FAIL))
printf '\n'
if (( FAIL == 0 )); then
  printf '%s✓%s %d/%d tests passed (%dms)\n' "$C_GREEN" "$C_OFF" "$PASS" "$total" "$elapsed_ms"
  exit 0
else
  printf '%s✗%s %d/%d tests passed (%dms) — %d failed:\n' "$C_RED" "$C_OFF" "$PASS" "$total" "$elapsed_ms" "$FAIL"
  for n in "${FAIL_NAMES[@]}"; do printf '    - %s\n' "$n"; done
  exit 1
fi
