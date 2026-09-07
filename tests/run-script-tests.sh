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

out="$(render_only result-max-turns-unflagged.json)"
assert_contains "$out" 'failed: error_max_turns'        "max-turns w/ is_error:false → subtype still surfaced"
assert_contains "$out" 'LABELS: ai:failed'              "max-turns w/ is_error:false → ai:failed"

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

# #100: a successful run that opened no PR must NOT be ai:done.
out="$(PR_PRESENT=false render_only result-success-cheap.json)"
assert_contains "$out" 'LABELS: ai:failed'   "success but PR_PRESENT=false → ai:failed"
assert_contains "$out" 'no PR was opened'     "  → status text names the missing-PR cause"

# Regression: PR_PRESENT=true (or unset) preserves ai:done.
out="$(PR_PRESENT=true render_only result-success-cheap.json)"
assert_contains "$out" 'LABELS: ai:done'      "success + PR_PRESENT=true → ai:done"
out="$(render_only result-success-cheap.json)"
assert_contains "$out" 'LABELS: ai:done'      "success + PR_PRESENT unset → ai:done (legacy)"

# A genuine agent error stays ai:failed regardless of PR_PRESENT.
out="$(PR_PRESENT=true render_only result-rate-limit.json)"
assert_contains "$out" 'LABELS: ai:failed'    "agent error + PR_PRESENT=true → still ai:failed"

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

section "unparseable execution log degrades gracefully (regression: #58)"

# The OpenCode path passes the raw opencode-output.json as EXECUTION_FILE. When
# opencode errors, that file is plain text, not JSON. The report must still
# render (degrade the context row to n/a) instead of crashing on the
# max-context jq — that crash is what failed the run in #58.
ec="$(run_capture_ec render_only result-success-cheap.json exec-unparseable.txt)"
assert_equals "$ec" "0" "unparseable exec → exit 0, no crash"

out="$(render_only result-success-cheap.json exec-unparseable.txt)"
assert_contains "$out" 'n/a (no execution log provided)' \
  "unparseable exec → context row falls back to n/a"
assert_contains "$out" 'LABELS: ai:done' \
  "unparseable exec → result outcome still rendered"

# The actual #58 case: opencode failed (is_error result) AND raw exec is non-JSON.
out="$(render_only result-rate-limit.json exec-unparseable.txt)"
assert_contains "$out" 'LABELS: ai:failed' \
  "unparseable exec + error result → ai:failed, graceful"

section "OpenCode context metric (step_finish token shape)"

# OpenCode's --format json stream uses step_finish.part.tokens, not the Claude
# assistant/message.usage shape. The max-context selector must read it too, else
# the context row reads 0 for every opencode run.
out="$(render_only result-opencode-success.json opencode-success.json)"
assert_contains "$out" '600 / 200,000' \
  "opencode exec → max context from step_finish tokens (peak input 600)"

section "cumulative token totals from execution stream (#53)"

# result.json carries only the LAST turn's usage (claude-code-base-action quirk);
# with an execution stream present the comment must show cumulative totals.
# exec-multiturn.ndjson: turns of input 1000 + 1 → cumulative 1001 (last is 1).
out="$(render_only result-lastturn.json exec-multiturn.ndjson)"
assert_contains     "$out" '| Input tokens | 1,001 |'  "input = cumulative (1001), not last-turn (1)"
assert_contains     "$out" '| Output tokens | 150 |'   "output = cumulative (100+50)"
assert_contains     "$out" '| Total tokens | 6,351 |'  "total = input+output+cache (1001+150+5000+200)"
assert_not_contains "$out" '| Input tokens | 1 |'      "last-turn input (1) not shown"

# No execution stream → fall back to result.json usage (best available).
out="$(render_only result-lastturn.json)"
assert_contains "$out" '| Input tokens | 1 |' "no exec log → result.json usage used as-is"

section "resolved model + agent in the report (#59)"

out="$(MODEL=claude-opus-5 AGENT=claude RENDER_ONLY=1 \
       RESULT_FILE="$FIXTURES/result-success-cheap.json" \
       ISSUE_NUMBER=1 WORKFLOW_RUN_URL=u bash "$SCRIPT")"
assert_contains "$out" '**Model:** claude-opus-5 · **Agent:** claude' \
  "MODEL+AGENT env → Model·Agent line rendered"

out="$(render_only result-success-cheap.json)"
assert_not_contains "$out" '**Model:**' "no Model line when MODEL/AGENT unset"

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
assert_contains "$out" 'chosen: claude-opus-5 (label model:opus)'   "label model:opus → opus"

# Override: model:haiku
out="$(ISSUE_NUMBER=1 REPO=o/r ISSUE_LABELS='model:haiku' bash "$CLASSIFY")"
assert_contains "$out" 'chosen: claude-haiku-4-5 (label model:haiku)' "label model:haiku → haiku"

# Override: model:sonnet
out="$(ISSUE_NUMBER=1 REPO=o/r ISSUE_LABELS='model:sonnet' bash "$CLASSIFY")"
assert_contains "$out" 'chosen: claude-sonnet-5 (label model:sonnet)' "label model:sonnet → sonnet"

# Override: model:mistral-large with AGENT=opencode → opencode model ID
out="$(ISSUE_NUMBER=1 REPO=o/r AGENT=opencode \
       ISSUE_LABELS='ai-implement
model:mistral-large' bash "$CLASSIFY")"
assert_contains "$out" 'chosen: mistralai/mistral-large (label model:mistral-large)' \
  "label model:mistral-large + agent=opencode → mistral-large"

# Override: model:codestral with AGENT=opencode → codestral
out="$(ISSUE_NUMBER=1 REPO=o/r AGENT=opencode \
       ISSUE_LABELS='model:codestral' bash "$CLASSIFY")"
assert_contains "$out" 'chosen: mistralai/codestral-2508 (label model:codestral)' \
  "label model:codestral + agent=opencode → codestral"

# Override: additional OpenRouter coding models (#94) with AGENT=opencode
out="$(ISSUE_NUMBER=1 REPO=o/r AGENT=opencode \
       ISSUE_LABELS='model:deepseek-v3' bash "$CLASSIFY")"
assert_contains "$out" 'chosen: deepseek/deepseek-chat-v3-0324 (label model:deepseek-v3)' \
  "label model:deepseek-v3 + agent=opencode → deepseek-v3"

out="$(ISSUE_NUMBER=1 REPO=o/r AGENT=opencode \
       ISSUE_LABELS='model:qwen-coder' bash "$CLASSIFY")"
assert_contains "$out" 'chosen: qwen/qwen-2.5-coder-32b-instruct (label model:qwen-coder)' \
  "label model:qwen-coder + agent=opencode → qwen-coder"

out="$(ISSUE_NUMBER=1 REPO=o/r AGENT=opencode \
       ISSUE_LABELS='model:gemini-flash' bash "$CLASSIFY")"
assert_contains "$out" 'chosen: google/gemini-2.5-flash (label model:gemini-flash)' \
  "label model:gemini-flash + agent=opencode → gemini-flash"

out="$(ISSUE_NUMBER=1 REPO=o/r AGENT=opencode \
       ISSUE_LABELS='model:deepseek-r1' bash "$CLASSIFY")"
assert_contains "$out" 'chosen: deepseek/deepseek-r1-0528 (label model:deepseek-r1)' \
  "label model:deepseek-r1 + agent=opencode → deepseek-r1"

out="$(ISSUE_NUMBER=1 REPO=o/r AGENT=opencode \
       ISSUE_LABELS='model:llama-4-maverick' bash "$CLASSIFY")"
assert_contains "$out" 'chosen: meta-llama/llama-4-maverick (label model:llama-4-maverick)' \
  "label model:llama-4-maverick + agent=opencode → llama-4-maverick"

# Additional tool-use-capable coding models (#98)
out="$(ISSUE_NUMBER=1 REPO=o/r AGENT=opencode \
       ISSUE_LABELS='model:qwen3-coder' bash "$CLASSIFY")"
assert_contains "$out" 'chosen: qwen/qwen3-coder-30b-a3b-instruct (label model:qwen3-coder)' \
  "label model:qwen3-coder + agent=opencode → qwen3-coder"

out="$(ISSUE_NUMBER=1 REPO=o/r AGENT=opencode \
       ISSUE_LABELS='model:gpt-oss-120b' bash "$CLASSIFY")"
assert_contains "$out" 'chosen: openai/gpt-oss-120b (label model:gpt-oss-120b)' \
  "label model:gpt-oss-120b + agent=opencode → gpt-oss-120b"

out="$(ISSUE_NUMBER=1 REPO=o/r AGENT=opencode \
       ISSUE_LABELS='model:glm-flash' bash "$CLASSIFY")"
assert_contains "$out" 'chosen: z-ai/glm-4.7-flash (label model:glm-flash)' \
  "label model:glm-flash + agent=opencode → glm-flash"

out="$(ISSUE_NUMBER=1 REPO=o/r AGENT=opencode \
       ISSUE_LABELS='model:minimax-m2' bash "$CLASSIFY")"
assert_contains "$out" 'chosen: minimax/minimax-m2.5 (label model:minimax-m2)' \
  "label model:minimax-m2 + agent=opencode → minimax-m2"

out="$(ISSUE_NUMBER=1 REPO=o/r AGENT=opencode \
       ISSUE_LABELS='model:deepseek-v32' bash "$CLASSIFY")"
assert_contains "$out" 'chosen: deepseek/deepseek-v3.2 (label model:deepseek-v32)' \
  "label model:deepseek-v32 + agent=opencode → deepseek-v32"

out="$(ISSUE_NUMBER=1 REPO=o/r AGENT=opencode \
       ISSUE_LABELS='model:qwen3-27b' bash "$CLASSIFY")"
assert_contains "$out" 'chosen: qwen/qwen3.6-27b (label model:qwen3-27b)' \
  "label model:qwen3-27b + agent=opencode → qwen3.6-27b"

# Mismatch: a new OpenRouter label WITHOUT agent=opencode → warn + fall through
out="$(ISSUE_NUMBER=1 REPO=o/r AGENT=claude \
       ISSUE_LABELS='model:qwen-coder' \
       ISSUE_BODY='filler' bash "$CLASSIFY" 2>&1)"
assert_contains "$out" 'warn: label model:qwen-coder incompatible with AGENT=claude' \
  "model:qwen-coder + agent=claude → warn on stderr"

# Mismatch: model:mistral-large WITHOUT agent=opencode → warn + fall through.
# `2>&1` captures stderr too so the warn can be asserted; exit code must
# still be 0. ISSUE_BODY is set so the heuristic fallback doesn't hit
# the live `gh issue view` and fail under the test runner's `set -e`.
out="$(ISSUE_NUMBER=1 REPO=o/r AGENT=claude \
       ISSUE_LABELS='model:mistral-large' \
       ISSUE_BODY='filler' bash "$CLASSIFY" 2>&1)"
assert_contains "$out" 'warn: label model:mistral-large incompatible with AGENT=claude' \
  "model:mistral-large + agent=claude → warn on stderr"
assert_contains "$out" 'claude-sonnet-5' "mismatch → falls to DEFAULT_MODEL via heuristic default"
ec="$(run_capture_ec env ISSUE_NUMBER=1 REPO=o/r AGENT=claude \
       ISSUE_LABELS='model:mistral-large' \
       ISSUE_BODY='filler' \
       bash "$CLASSIFY")"
assert_equals "$ec" "0" "mismatch → exit 0 (warning, not error)"

# Mismatch the other way: model:opus + AGENT=opencode → warn + fall through
out="$(ISSUE_NUMBER=1 REPO=o/r AGENT=opencode \
       ISSUE_LABELS='model:opus' \
       ISSUE_BODY='filler' bash "$CLASSIFY" 2>&1)"
assert_contains "$out" 'warn: label model:opus incompatible with AGENT=opencode' \
  "model:opus + agent=opencode → warn on stderr"

# Heuristic: refactor keyword → opus
out="$(ISSUE_NUMBER=1 REPO=o/r ISSUE_LABELS='ai-implement' \
       ISSUE_BODY='Refactor the auth middleware' bash "$CLASSIFY")"
assert_contains "$out" 'claude-opus-5 (heuristic: refactor/architecture keywords)' "refactor keyword → opus"

# Heuristic: typo keyword → haiku
out="$(ISSUE_NUMBER=1 REPO=o/r ISSUE_LABELS='ai-implement' \
       ISSUE_BODY='Fix typo in the README' bash "$CLASSIFY")"
assert_contains "$out" 'claude-haiku-4-5 (heuristic: trivial-edit keywords)' "typo keyword → haiku"

# Heuristic escalation is Claude-only: refactor/architecture keywords must
# NOT hand a non-Claude agent a claude-* model id (opencode/OpenRouter has
# no such model and dies at zero tokens) — falls back to DEFAULT_MODEL.
out="$(ISSUE_NUMBER=1 REPO=o/r AGENT=opencode ISSUE_LABELS='ai-implement' \
       ISSUE_BODY='Refactor the auth middleware' DEFAULT_MODEL=z-ai/glm-5.2 bash "$CLASSIFY")"
assert_contains "$out" 'z-ai/glm-5.2 (heuristic: default (AGENT=opencode' \
  "refactor keyword + agent=opencode → DEFAULT_MODEL, not claude-opus-5"

# Same for the trivial-edit branch.
out="$(ISSUE_NUMBER=1 REPO=o/r AGENT=opencode ISSUE_LABELS='ai-implement' \
       ISSUE_BODY='Fix typo in the README' DEFAULT_MODEL=z-ai/glm-5.2 bash "$CLASSIFY")"
assert_contains "$out" 'z-ai/glm-5.2 (heuristic: default (AGENT=opencode' \
  "typo keyword + agent=opencode → DEFAULT_MODEL, not claude-haiku-4-5"

# An explicit OpenRouter override label still wins over the AGENT=opencode
# fallback above (override path is untouched by this fix).
out="$(ISSUE_NUMBER=1 REPO=o/r AGENT=opencode \
       ISSUE_LABELS=$'ai-implement\nmodel:qwen3-coder' \
       ISSUE_BODY='Refactor the auth middleware' bash "$CLASSIFY")"
assert_contains "$out" 'chosen: qwen/qwen3-coder-30b-a3b-instruct (label model:qwen3-coder)' \
  "override label still wins over agent=opencode heuristic fallback"

# Default: nothing matches
out="$(ISSUE_NUMBER=1 REPO=o/r ISSUE_LABELS='ai-implement' \
       ISSUE_BODY='Add a hello.md file' bash "$CLASSIFY")"
assert_contains "$out" 'claude-sonnet-5 (heuristic: default)' "no match → default sonnet"

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

section "classify-turns — explicit override labels + task-count heuristic"

CLASSIFY_TURNS="$ROOT/scripts/classify-turns.sh"

# Override: turns:80 label
out="$(ISSUE_NUMBER=1 REPO=o/r ISSUE_LABELS='ai-implement
turns:80' bash "$CLASSIFY_TURNS")"
assert_contains "$out" 'chosen: 80 (label turns:80)' "label turns:80 → 80"

# Override: turns:120 label
out="$(ISSUE_NUMBER=1 REPO=o/r ISSUE_LABELS='turns:120' bash "$CLASSIFY_TURNS")"
assert_contains "$out" 'chosen: 120 (label turns:120)' "label turns:120 → 120"

# Heuristic: 6+ "### Task N" headings under "## Implementation Plan" → 160
body6="## Implementation Plan
### Task 1: a
### Task 2: b
### Task 3: c
### Task 4: d
### Task 5: e
### Task 6: f"
out="$(ISSUE_NUMBER=1 REPO=o/r ISSUE_LABELS='ai-implement' ISSUE_BODY="$body6" bash "$CLASSIFY_TURNS")"
assert_contains "$out" 'chosen: 160 (heuristic: 6 plan tasks)' "6 tasks → 160"

# Heuristic: 4-5 tasks → 120
body4="## Implementation Plan
### Task 1: a
### Task 2: b
### Task 3: c
### Task 4: d"
out="$(ISSUE_NUMBER=1 REPO=o/r ISSUE_LABELS='ai-implement' ISSUE_BODY="$body4" bash "$CLASSIFY_TURNS")"
assert_contains "$out" 'chosen: 120 (heuristic: 4 plan tasks)' "4 tasks → 120"

# Heuristic: 2-3 tasks → 80
body2="## Implementation Plan
### Task 1: a
### Task 2: b"
out="$(ISSUE_NUMBER=1 REPO=o/r ISSUE_LABELS='ai-implement' ISSUE_BODY="$body2" bash "$CLASSIFY_TURNS")"
assert_contains "$out" 'chosen: 80 (heuristic: 2 plan tasks)' "2 tasks → 80"

# Regression: an "## Implementation Plan" section whose task headings are
# NOT "### Task N" (e.g. "## Task N", a different heading level, or plain
# prose) must fall through to DEFAULT_MAX_TURNS, not crash. grep -c exits 1
# on zero matches; under set -euo pipefail an unguarded `grep -c` inside a
# command substitution kills the whole script before it prints anything —
# this is exactly what happened on issue #193's Phase 1 dispatch
# (2026-08-04): the body used "## Task N" (H2) instead of "### Task N" (H3),
# classify-turns.sh silently exited 1, and the whole implement job aborted
# before ever running the implementer.
body_wrong_heading="## Implementation Plan
## Task 1: a
## Task 2: b"
ec="$(run_capture_ec env ISSUE_NUMBER=1 REPO=o/r ISSUE_LABELS='ai-implement' ISSUE_BODY="$body_wrong_heading" bash "$CLASSIFY_TURNS")"
assert_equals "$ec" "0" "Implementation Plan present but zero '### Task N' matches → exit 0, no crash"
out="$(ISSUE_NUMBER=1 REPO=o/r ISSUE_LABELS='ai-implement' ISSUE_BODY="$body_wrong_heading" bash "$CLASSIFY_TURNS")"
assert_contains "$out" 'chosen: 50 (heuristic: 0 plan task(s), default budget enough)' \
  "zero task-heading matches → falls through to DEFAULT_MAX_TURNS, not a crash"

# No "## Implementation Plan" section at all → default
out="$(ISSUE_NUMBER=1 REPO=o/r ISSUE_LABELS='ai-implement' ISSUE_BODY='Add a hello.md file' bash "$CLASSIFY_TURNS")"
assert_contains "$out" 'chosen: 50 (heuristic: no Implementation Plan section found)' "no plan section → default"

# DEFAULT_MAX_TURNS env override applied on the no-plan-section default branch
out="$(ISSUE_NUMBER=1 REPO=o/r ISSUE_LABELS='ai-implement' ISSUE_BODY='Add a hello.md file' \
       DEFAULT_MAX_TURNS=30 bash "$CLASSIFY_TURNS")"
assert_contains "$out" 'chosen: 30 (heuristic: no Implementation Plan section found)' "DEFAULT_MAX_TURNS env override applied"

# Regression (#280): a LARGE body must classify by its plan, EVERY time.
# `printf "$ISSUE_BODY" | grep -q` lets grep exit on the first match while
# printf is still writing; printf then dies of SIGPIPE (silently on some
# hosts, "write error: Broken pipe" on others) and pipefail turns a
# successful match into a false condition -- silently downgrading a
# 160-turn plan to the 50-turn default. Lost ~42% of the time on the real
# 57KB body from #280, which is what this fixture is. One run proves
# nothing; assert over repeated runs.
big_body="$(cat "$FIXTURES/issue-body-large-plan.md")"
turns_stable=true
turns_got=''
for _i in $(seq 1 25); do
  turns_got="$(ISSUE_NUMBER=1 REPO=o/r ISSUE_LABELS='ai-implement' ISSUE_BODY="$big_body" bash "$CLASSIFY_TURNS")"
  if [[ "$turns_got" != *'chosen: 160 (heuristic: 8 plan tasks)'* ]]; then
    turns_stable=false
    break
  fi
done
if [[ "$turns_stable" == true ]]; then
  pass "57KB enriched body → 160 on all 25 runs (no SIGPIPE race)"
else
  fail "57KB enriched body → 160 on all 25 runs (no SIGPIPE race)" "got: $turns_got"
fi

# Missing ISSUE_NUMBER → exit 2
ec="$(run_capture_ec env REPO=o/r bash "$CLASSIFY_TURNS")"
assert_equals "$ec" "2" "missing ISSUE_NUMBER → exit 2"

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

section "check-opencode-auth — OpenRouter key preflight (#164)"

OC_AUTH="$ROOT/scripts/check-opencode-auth.sh"
OC_AUTH_OUT="$(mktemp)"

# Key present → exit 0, nothing synthesized
: > "$OC_AUTH_OUT"
ec="$(run_capture_ec env OUTPUT_FILE="$OC_AUTH_OUT" OPENROUTER_API_KEY=sk-test \
      MODEL=openai/gpt-oss-120b bash "$OC_AUTH")"
assert_equals "$ec" "0" "key present → exit 0"
assert_equals "$(wc -c < "$OC_AUTH_OUT" | tr -d ' ')" "0" "key present → OUTPUT_FILE untouched"

# Key empty → exit 64
: > "$OC_AUTH_OUT"
ec="$(run_capture_ec env OUTPUT_FILE="$OC_AUTH_OUT" OPENROUTER_API_KEY= \
      MODEL=openai/gpt-oss-120b bash "$OC_AUTH")"
assert_equals "$ec" "64" "key empty → exit 64"

# ...and the synthesized event is a valid opencode `error` event
out="$(cat "$OC_AUTH_OUT")"
assert_equals "$(printf '%s' "$out" | jq -r '.type')"            "error"     "missing key → type=error"
assert_equals "$(printf '%s' "$out" | jq -r '.error.name')"      "AuthError" "missing key → error.name=AuthError"
assert_contains "$(printf '%s' "$out" | jq -r '.error.data.message')" \
  'OPENROUTER_API_KEY is not set' "missing key → message names the secret"
assert_contains "$(printf '%s' "$out" | jq -r '.error.data.message')" \
  'openai/gpt-oss-120b' "missing key → message carries the model for provenance"
assert_contains "$(printf '%s' "$out" | jq -r '.error.data.message')" \
  'docs/CONSUMER-SETUP.md' "missing key → message points at the setup doc"

# Key unset entirely (not just empty) → exit 64
: > "$OC_AUTH_OUT"
ec="$(run_capture_ec env OUTPUT_FILE="$OC_AUTH_OUT" MODEL=openai/gpt-oss-120b bash "$OC_AUTH")"
assert_equals "$ec" "64" "key unset → exit 64"

# The secret value is never echoed
out="$(OUTPUT_FILE="$OC_AUTH_OUT" OPENROUTER_API_KEY=sk-supersecret \
       MODEL=openai/gpt-oss-120b bash "$OC_AUTH" 2>&1)"
assert_not_contains "$out" 'sk-supersecret' "key value never printed"

# Missing OUTPUT_FILE → exit 2
ec="$(run_capture_ec env OPENROUTER_API_KEY= bash "$OC_AUTH")"
assert_equals "$ec" "2" "missing OUTPUT_FILE → exit 2"

rm -f "$OC_AUTH_OUT"

section "check-ai-merge-gate — input + label combinations"

AGATE="$ROOT/scripts/check-ai-merge-gate.sh"

# Both off → disabled
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_AI_REVIEW_AI_MERGE=false ISSUE_LABELS='ai-implement' bash "$AGATE")"
assert_contains "$out" 'enabled=false (workflow input ai-review-ai-merge=false)' "input=false, no label → disabled"

# Label only → still disabled (input gate not satisfied)
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_AI_REVIEW_AI_MERGE=false ISSUE_LABELS=$'ai-implement\nai-review-ai-merge' bash "$AGATE")"
assert_contains "$out" 'enabled=false (workflow input ai-review-ai-merge=false)' "input=false, label set → disabled (input wins)"

# Input only → disabled (label gate not satisfied)
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_AI_REVIEW_AI_MERGE=true ISSUE_LABELS='ai-implement' bash "$AGATE")"
assert_contains "$out" 'enabled=false (input=true but label ai-review-ai-merge missing)' "input=true, no label → disabled"

# Both new → enabled, no deprecation warning
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_AI_REVIEW_AI_MERGE=true ISSUE_LABELS=$'ai-implement\nai-review-ai-merge' bash "$AGATE")"
assert_contains "$out" 'enabled=true (input=true AND label ai-review-ai-merge present)' "new input + new label → enabled"
assert_not_contains "$out" '::warning::' "new input + new label → no deprecation warning"

# Deprecated input + deprecated label → enabled, two warnings
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_AUTO_REVIEW=true ISSUE_LABELS=$'ai-implement\nai-auto-review' bash "$AGATE")"
assert_contains "$out" 'enabled=true (input=true AND label ai-auto-review present)' "deprecated input + deprecated label → enabled"
assert_contains "$out" "::warning::workflow input 'auto-review' is deprecated; rename it to 'ai-review-ai-merge' (removed in v3)" "deprecated input → warning"
assert_contains "$out" "::warning::issue label 'ai-auto-review' is deprecated; relabel it to 'ai-review-ai-merge' (removed in v3)" "deprecated label → warning"

# New input + deprecated label → enabled, label warning only
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_AI_REVIEW_AI_MERGE=true ISSUE_LABELS=$'ai-implement\nai-auto-review' bash "$AGATE")"
assert_contains "$out" 'enabled=true (input=true AND label ai-auto-review present)' "new input + deprecated label → enabled"
assert_not_contains "$out" "workflow input 'auto-review' is deprecated" "new input + deprecated label → no input warning"
assert_contains "$out" "::warning::issue label 'ai-auto-review' is deprecated" "new input + deprecated label → label warning"

# Deprecated input + new label → enabled, input warning only
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_AUTO_REVIEW=true ISSUE_LABELS=$'ai-implement\nai-review-ai-merge' bash "$AGATE")"
assert_contains "$out" 'enabled=true (input=true AND label ai-review-ai-merge present)' "deprecated input + new label → enabled"
assert_contains "$out" "::warning::workflow input 'auto-review' is deprecated" "deprecated input + new label → input warning"
assert_not_contains "$out" "issue label 'ai-auto-review' is deprecated" "deprecated input + new label → no label warning"

# Both labels present → new label wins the reason text, no label warning
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_AI_REVIEW_AI_MERGE=true ISSUE_LABELS=$'ai-review-ai-merge\nai-auto-review' bash "$AGATE")"
assert_contains "$out" 'enabled=true (input=true AND label ai-review-ai-merge present)' "both labels → new label wins"
assert_not_contains "$out" "issue label 'ai-auto-review' is deprecated" "both labels → no label warning"

# Both inputs unset → disabled
out="$(ISSUE_NUMBER=1 REPO=o/r ISSUE_LABELS='ai-review-ai-merge' bash "$AGATE")"
assert_contains "$out" 'enabled=false (workflow input ai-review-ai-merge=false)' "unset inputs default to false"

# Invalid new input → exit 2
ec="$(run_capture_ec env ISSUE_NUMBER=1 REPO=o/r INPUT_AI_REVIEW_AI_MERGE=yes ISSUE_LABELS='' bash "$AGATE")"
assert_equals "$ec" "2" "invalid INPUT_AI_REVIEW_AI_MERGE → exit 2"

# Invalid deprecated input → exit 2
ec="$(run_capture_ec env ISSUE_NUMBER=1 REPO=o/r INPUT_AUTO_REVIEW=yes ISSUE_LABELS='' bash "$AGATE")"
assert_equals "$ec" "2" "invalid INPUT_AUTO_REVIEW → exit 2"

# Missing ISSUE_NUMBER → exit 2
ec="$(run_capture_ec env REPO=o/r INPUT_AI_REVIEW_AI_MERGE=true bash "$AGATE")"
assert_equals "$ec" "2" "missing ISSUE_NUMBER → exit 2"

# Missing REPO → exit 2
ec="$(run_capture_ec env ISSUE_NUMBER=1 INPUT_AI_REVIEW_AI_MERGE=true bash "$AGATE")"
assert_equals "$ec" "2" "missing REPO → exit 2"

section "check-human-merge-gate — input + label combinations"

HGATE="$ROOT/scripts/check-human-merge-gate.sh"

# Both off → disabled
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_AI_REVIEW_HUMAN_MERGE=false ISSUE_LABELS='ai-implement' bash "$HGATE")"
assert_contains "$out" 'enabled=false (workflow input ai-review-human-merge=false)' "input=false, no label → disabled"

# Label only → still disabled (input gate not satisfied)
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_AI_REVIEW_HUMAN_MERGE=false ISSUE_LABELS=$'ai-implement\nai-review-human-merge' bash "$HGATE")"
assert_contains "$out" 'enabled=false (workflow input ai-review-human-merge=false)' "input=false, label set → disabled (input wins)"

# Input only → disabled (label gate not satisfied)
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_AI_REVIEW_HUMAN_MERGE=true ISSUE_LABELS='ai-implement' bash "$HGATE")"
assert_contains "$out" 'enabled=false (input=true but label ai-review-human-merge missing)' "input=true, no label → disabled"

# Both new → enabled, no deprecation warning
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_AI_REVIEW_HUMAN_MERGE=true ISSUE_LABELS=$'ai-implement\nai-review-human-merge' bash "$HGATE")"
assert_contains "$out" 'enabled=true (input=true AND label ai-review-human-merge present)' "new input + new label → enabled"
assert_not_contains "$out" '::warning::' "new input + new label → no deprecation warning"

# Deprecated input + deprecated label → enabled, two warnings
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_PRE_PREVIEW=true ISSUE_LABELS=$'ai-implement\nai-pre-preview' bash "$HGATE")"
assert_contains "$out" 'enabled=true (input=true AND label ai-pre-preview present)' "deprecated input + deprecated label → enabled"
assert_contains "$out" "::warning::workflow input 'pre-preview' is deprecated; rename it to 'ai-review-human-merge' (removed in v3)" "deprecated input → warning"
assert_contains "$out" "::warning::issue label 'ai-pre-preview' is deprecated; relabel it to 'ai-review-human-merge' (removed in v3)" "deprecated label → warning"

# New input + deprecated label → enabled, label warning only
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_AI_REVIEW_HUMAN_MERGE=true ISSUE_LABELS=$'ai-implement\nai-pre-preview' bash "$HGATE")"
assert_contains "$out" 'enabled=true (input=true AND label ai-pre-preview present)' "new input + deprecated label → enabled"
assert_not_contains "$out" "workflow input 'pre-preview' is deprecated" "new input + deprecated label → no input warning"
assert_contains "$out" "::warning::issue label 'ai-pre-preview' is deprecated" "new input + deprecated label → label warning"

# Deprecated input + new label → enabled, input warning only
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_PRE_PREVIEW=true ISSUE_LABELS=$'ai-implement\nai-review-human-merge' bash "$HGATE")"
assert_contains "$out" 'enabled=true (input=true AND label ai-review-human-merge present)' "deprecated input + new label → enabled"
assert_contains "$out" "::warning::workflow input 'pre-preview' is deprecated" "deprecated input + new label → input warning"
assert_not_contains "$out" "issue label 'ai-pre-preview' is deprecated" "deprecated input + new label → no label warning"

# Both labels present → new label wins the reason text, no label warning
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_AI_REVIEW_HUMAN_MERGE=true ISSUE_LABELS=$'ai-review-human-merge\nai-pre-preview' bash "$HGATE")"
assert_contains "$out" 'enabled=true (input=true AND label ai-review-human-merge present)' "both labels → new label wins"
assert_not_contains "$out" "issue label 'ai-pre-preview' is deprecated" "both labels → no label warning"

# Both inputs unset → disabled
out="$(ISSUE_NUMBER=1 REPO=o/r ISSUE_LABELS='ai-review-human-merge' bash "$HGATE")"
assert_contains "$out" 'enabled=false (workflow input ai-review-human-merge=false)' "unset inputs default to false"

# Invalid new input → exit 2
ec="$(run_capture_ec env ISSUE_NUMBER=1 REPO=o/r INPUT_AI_REVIEW_HUMAN_MERGE=yes ISSUE_LABELS='' bash "$HGATE")"
assert_equals "$ec" "2" "invalid INPUT_AI_REVIEW_HUMAN_MERGE → exit 2"

# Invalid deprecated input → exit 2
ec="$(run_capture_ec env ISSUE_NUMBER=1 REPO=o/r INPUT_PRE_PREVIEW=yes ISSUE_LABELS='' bash "$HGATE")"
assert_equals "$ec" "2" "invalid INPUT_PRE_PREVIEW → exit 2"

# Missing ISSUE_NUMBER → exit 2
ec="$(run_capture_ec env REPO=o/r INPUT_AI_REVIEW_HUMAN_MERGE=true bash "$HGATE")"
assert_equals "$ec" "2" "missing ISSUE_NUMBER → exit 2"

# Missing REPO → exit 2
ec="$(run_capture_ec env ISSUE_NUMBER=1 INPUT_AI_REVIEW_HUMAN_MERGE=true bash "$HGATE")"
assert_equals "$ec" "2" "missing REPO → exit 2"

section "review-prompt — ADR-002 §2.4 auto-block rules present in template"

PROMPT="$ROOT/scripts/lib/review-prompt.md"

# Section header must exist — a future edit dropping it should fail CI.
assert_contains "$(cat "$PROMPT")" 'Automatic-block patterns (ADR-002 §2.4)' \
  "prompt template includes the ADR-002 §2.4 section header"

# Each of the three patterns must be present with a recognizable marker.
prompt_body="$(cat "$PROMPT")"
assert_contains "$prompt_body" 'Net deletion of test files'           "rule 1: net test-file deletion"
assert_contains "$prompt_body" 'renamed-to-skip or marked'            "rule 2: skipped-test detection"
assert_contains "$prompt_body" 'Fixture realignment to broken behavior' "rule 3: fixture-realignment heuristic"

# Concrete example matchers for the skipped-test rule (rule 2) — one
# per language family the ADR enumerates. Future contributors who add
# language coverage extend this list; future contributors who quietly
# drop language coverage trip the assertion.
for marker in 'xit(' '@pytest.mark.skip' '@Ignore' '[Fact(Skip =' 't.Skip(' '@Skip('; do
  assert_contains "$prompt_body" "$marker" "rule 2: matcher example '$marker' present"
done

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

# #72: agents wrap the JSON verdict in a code fence — salvage it, do not block.
out="$(review_run review-fenced-approve.json)"
assert_contains "$out" 'verdict=approve'         "fenced json output salvaged to approve"

# #72: agent adds prose around the JSON object — salvage the object.
out="$(review_run review-prose-approve.json)"
assert_contains "$out" 'verdict=approve'         "prose-wrapped json salvaged to approve"

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

section "parse-chain — extract Blocks: / Blocked by: markers (ADR-003)"

PARSE_CHAIN="$ROOT/scripts/parse-chain.sh"

out="$(printf 'Title\n\nBlocks: #42, #43\nBlocked by: #100\n' | bash "$PARSE_CHAIN")"
assert_contains "$out" 'blocks=#42 #43'    "single Blocks: line with commas → two refs"
assert_contains "$out" 'blocked-by=#100'   "single Blocked by: line → one ref"

# Multiple `Blocks:` lines union into a set
out="$(printf 'Blocks: #1\nsome text\nBlocks: #2\n' | bash "$PARSE_CHAIN")"
assert_contains "$out" 'blocks=#1 #2'      "multiple Blocks: lines → union"

# Cross-repo refs parsed-and-discarded per ADR-003 §6
out="$(printf 'Blocks: #5, org/other-repo#99, #6\n' | bash "$PARSE_CHAIN")"
assert_contains "$out" 'blocks=#5 #6'      "cross-repo refs ignored"

# `Also Blocks: #44` — not at line start, must not match
out="$(printf 'Also Blocks: #44\n' | bash "$PARSE_CHAIN")"
assert_contains "$out" 'blocks='           "inline 'Blocks:' (not at line start) → ignored"

# Body via env var instead of stdin
out="$(ISSUE_BODY=$'Blocked by: #7\n' bash "$PARSE_CHAIN" < /dev/null)"
assert_contains "$out" 'blocked-by=#7'     "ISSUE_BODY env seam"

# Missing body → exit 2
ec="$(run_capture_ec env bash "$PARSE_CHAIN" < /dev/null)"
assert_equals "$ec" "2" "no body provided → exit 2"

section "find-next-blocked-issue — eligibility per ADR-003"

FIND_NEXT="$ROOT/scripts/find-next-blocked-issue.sh"

find_next_run() {
  # Collect $GITHUB_OUTPUT and the script's stdout into one blob.
  local go
  go="$(mktemp)"
  GITHUB_OUTPUT="$go" "$@" bash "$FIND_NEXT"
  cat "$go"
  rm -f "$go"
}

# Single-blocker: PR closes #100; #101 blocked-by #100 → eligible
out="$(find_next_run env \
        CLOSED_ISSUE_NUMBER=100 REPO=o/r \
        CANDIDATES_JSON="$(cat "$FIXTURES/chain-single-blocker.json")")"
assert_contains "$out" 'successor-count=1' "chain-single-blocker.json → 1 successor"
assert_contains "$out" 'successors=101'    "successor list contains 101"

# Multi-blocker, partial (one still-open)
out="$(find_next_run env \
        CLOSED_ISSUE_NUMBER=100 REPO=o/r \
        ISSUE_STATE_200=open \
        CANDIDATES_JSON="$(cat "$FIXTURES/chain-multi-blocker-partial.json")")"
assert_contains "$out" 'successor-count=0' "chain-multi-blocker-partial.json → 0 successors"

# Multi-blocker, ALL closed
out="$(find_next_run env \
        CLOSED_ISSUE_NUMBER=100 REPO=o/r \
        ISSUE_STATE_200=closed \
        CANDIDATES_JSON="$(cat "$FIXTURES/chain-multi-blocker-all-closed.json")")"
assert_contains "$out" 'successor-count=1' "chain-multi-blocker-all-closed.json → 1 successor"
assert_contains "$out" 'successors=102'    "the right successor is named"

# Successor without ai-chain → never picked up
# (the gh query filters this in real runs, but the script defends
# against a CANDIDATES_JSON that bypasses the filter)
out="$(find_next_run env \
        CLOSED_ISSUE_NUMBER=100 REPO=o/r \
        CANDIDATES_JSON='[{"number":103,"body":"Blocked by: #100","labels":[{"name":"ai-implement"}]}]')"
assert_contains "$out" 'successor-count=0' "candidate without ai-chain → 0 successors"

# Candidate whose Blocked-by does NOT reference the closed issue → skip
# (#104 is blocked by #999, not #100; the close of #100 doesn't unblock it)
out="$(find_next_run env \
        CLOSED_ISSUE_NUMBER=100 REPO=o/r \
        CANDIDATES_JSON='[{"number":104,"body":"Blocked by: #999","labels":[{"name":"ai-chain"},{"name":"ai-implement"}]}]')"
assert_contains "$out" 'successor-count=0' "candidate not blocked-by the closed issue → 0 successors"

# Candidate with no Blocked-by entries at all → skip (degenerate)
out="$(find_next_run env \
        CLOSED_ISSUE_NUMBER=100 REPO=o/r \
        CANDIDATES_JSON='[{"number":105,"body":"no markers","labels":[{"name":"ai-chain"},{"name":"ai-implement"}]}]')"
assert_contains "$out" 'successor-count=0' "candidate with no Blocked-by → 0 successors"

# Multiple eligible successors at once → all dispatched
out="$(find_next_run env \
        CLOSED_ISSUE_NUMBER=100 REPO=o/r \
        CANDIDATES_JSON='[{"number":106,"body":"Blocked by: #100","labels":[{"name":"ai-chain"},{"name":"ai-implement"}]},{"number":107,"body":"Blocked by: #100","labels":[{"name":"ai-chain"},{"name":"ai-implement"}]}]')"
assert_contains "$out" 'successor-count=2' "two candidates both unblocked → 2 successors"
assert_contains "$out" 'successors=106 107' "both successor numbers listed"

# Depth cap engaged (chain-depth-cap.json)
out="$(find_next_run env \
        CLOSED_ISSUE_NUMBER=100 REPO=o/r \
        KILL_SWITCH_OPEN=false \
        CHAIN_DEPTH=5 MAX_CHAIN_DEPTH=5 \
        CANDIDATES_JSON="$(cat "$FIXTURES/chain-depth-cap.json")")"
assert_contains "$out" 'successor-count=0'              "chain-depth-cap.json @ cap → no dispatches"
assert_contains "$out" 'capped=108'                     "candidate listed under capped="
assert_contains "$out" 'candidate=108 decision=capped'  "per-candidate decision=capped emitted"
assert_contains "$out" 'depth=5'                        "audit line carries the depth"

# Depth one BELOW cap → dispatches
out="$(find_next_run env \
        CLOSED_ISSUE_NUMBER=100 REPO=o/r \
        KILL_SWITCH_OPEN=false \
        CHAIN_DEPTH=4 MAX_CHAIN_DEPTH=5 \
        CANDIDATES_JSON='[{"number":109,"body":"Blocked by: #100","labels":[{"name":"ai-chain"},{"name":"ai-implement"}]}]')"
assert_contains "$out" 'successor-count=1'                  "depth below cap → dispatched"
assert_contains "$out" 'candidate=109 decision=dispatched'  "per-candidate decision=dispatched emitted"

# Kill switch open (chain-paused.json) → paused regardless of depth
out="$(find_next_run env \
        CLOSED_ISSUE_NUMBER=100 REPO=o/r \
        KILL_SWITCH_OPEN=true \
        CHAIN_DEPTH=1 MAX_CHAIN_DEPTH=5 \
        CANDIDATES_JSON="$(cat "$FIXTURES/chain-paused.json")")"
assert_contains "$out" 'successor-count=0'              "chain-paused.json + kill switch → no dispatches"
assert_contains "$out" 'paused=110'                     "candidate listed under paused="
assert_contains "$out" 'candidate=110 decision=paused'  "per-candidate decision=paused emitted"

# Kill switch precedence over depth cap: both would fail, paused wins
out="$(find_next_run env \
        CLOSED_ISSUE_NUMBER=100 REPO=o/r \
        KILL_SWITCH_OPEN=true \
        CHAIN_DEPTH=999 MAX_CHAIN_DEPTH=5 \
        CANDIDATES_JSON='[{"number":111,"body":"Blocked by: #100","labels":[{"name":"ai-chain"},{"name":"ai-implement"}]}]')"
assert_contains     "$out" 'paused=111'   "kill switch precedence: paused not capped"
assert_not_contains "$out" 'capped=111'   "kill switch wins over depth cap"

# decision-summary aggregation across multiple candidates
out="$(find_next_run env \
        CLOSED_ISSUE_NUMBER=100 REPO=o/r \
        KILL_SWITCH_OPEN=false \
        CHAIN_DEPTH=4 MAX_CHAIN_DEPTH=5 \
        CANDIDATES_JSON='[{"number":120,"body":"Blocked by: #100","labels":[{"name":"ai-chain"},{"name":"ai-implement"}]},{"number":121,"body":"Blocked by: #100","labels":[{"name":"ai-chain"},{"name":"ai-implement"}]}]')"
assert_contains "$out" 'decision-summary=dispatched=2 capped=0 paused=0' "summary line counts decisions"

section "post-chain-audit — template rendering + comment posting"

POST_AUDIT="$ROOT/scripts/post-chain-audit.sh"

# Dispatched decision posts an audit comment via --body-file
LOG="$(mktemp)"
PATH="$MOCKS:$PATH" GH_MOCK_LOG="$LOG" \
REPO=o/r ISSUE_NUMBER=101 CLOSED_ISSUE=100 DECISION=dispatched DEPTH=2 MAX_DEPTH=5 \
  bash "$POST_AUDIT" >/dev/null
calls="$(cat "$LOG")"; rm -f "$LOG"
assert_contains "$calls" 'issue comment 101 --repo o/r --body-file' "dispatched → posts audit via --body-file"

# Capped decision posts a comment
LOG="$(mktemp)"
PATH="$MOCKS:$PATH" GH_MOCK_LOG="$LOG" \
REPO=o/r ISSUE_NUMBER=102 CLOSED_ISSUE=100 DECISION=capped DEPTH=5 MAX_DEPTH=5 \
  bash "$POST_AUDIT" >/dev/null
calls="$(cat "$LOG")"; rm -f "$LOG"
assert_contains "$calls" 'issue comment 102 --repo o/r --body-file' "capped → posts an audit comment"

# Paused decision posts a comment
LOG="$(mktemp)"
PATH="$MOCKS:$PATH" GH_MOCK_LOG="$LOG" \
REPO=o/r ISSUE_NUMBER=103 CLOSED_ISSUE=100 DECISION=paused DEPTH=1 MAX_DEPTH=5 \
  bash "$POST_AUDIT" >/dev/null
calls="$(cat "$LOG")"; rm -f "$LOG"
assert_contains "$calls" 'issue comment 103 --repo o/r --body-file' "paused → posts an audit comment"

# Invalid decision → exit 2
ec="$(run_capture_ec env REPO=o/r ISSUE_NUMBER=1 CLOSED_ISSUE=1 DECISION=maybe DEPTH=1 MAX_DEPTH=5 \
        bash "$POST_AUDIT")"
assert_equals "$ec" "2" "invalid DECISION → exit 2"

# Missing required env → exit 2
ec="$(run_capture_ec env REPO=o/r bash "$POST_AUDIT")"
assert_equals "$ec" "2" "missing ISSUE_NUMBER etc. → exit 2"

# Error paths
ec="$(run_capture_ec env REPO=o/r bash "$FIND_NEXT")"
assert_equals "$ec" "2" "missing CLOSED_ISSUE_NUMBER → exit 2"

ec="$(run_capture_ec env CLOSED_ISSUE_NUMBER=100 CANDIDATES_JSON='[]' bash "$FIND_NEXT")"
assert_equals "$ec" "2" "missing REPO → exit 2"

section "verify-gh-mock-merge — detect gh pr merge in the mock log"

VERIFY_MOCK="$ROOT/scripts/verify-gh-mock-merge.sh"

# Log containing a 'pr merge' line → attempted=true
LOG="$(mktemp)"
GO="$(mktemp)"
printf 'pr ready 9999 --repo o/r\npr merge 9999 --repo o/r --auto --squash\n' > "$LOG"
GITHUB_OUTPUT="$GO" GH_MOCK_LOG="$LOG" bash "$VERIFY_MOCK" >/dev/null
out="$(cat "$GO")"; rm -f "$LOG" "$GO"
assert_contains "$out" 'merge-attempted=true'  "log with 'pr merge' → attempted=true"

# Same log also reports ready-attempted=true (it contains a 'pr ready' line)
LOG="$(mktemp)"
GO="$(mktemp)"
printf 'pr ready 9999 --repo o/r\npr merge 9999 --repo o/r --auto --squash\n' > "$LOG"
GITHUB_OUTPUT="$GO" GH_MOCK_LOG="$LOG" bash "$VERIFY_MOCK" >/dev/null
out="$(cat "$GO")"; rm -f "$LOG" "$GO"
assert_contains "$out" 'ready-attempted=true' "log with 'pr ready' → ready-attempted=true"

# Log without 'pr ready' → ready-attempted=false
LOG="$(mktemp)"
GO="$(mktemp)"
printf 'pr comment 9999 --repo o/r --body held\nissue edit 42 --repo o/r --add-label ai:review-blocked\n' > "$LOG"
GITHUB_OUTPUT="$GO" GH_MOCK_LOG="$LOG" bash "$VERIFY_MOCK" >/dev/null
out="$(cat "$GO")"; rm -f "$LOG" "$GO"
assert_contains "$out" 'ready-attempted=false' "log without 'pr ready' → ready-attempted=false"

# Log without 'pr merge' → attempted=false
LOG="$(mktemp)"
GO="$(mktemp)"
printf 'pr ready 9999 --repo o/r\nissue edit 42 --repo o/r --add-label ai:review-blocked\n' > "$LOG"
GITHUB_OUTPUT="$GO" GH_MOCK_LOG="$LOG" bash "$VERIFY_MOCK" >/dev/null
out="$(cat "$GO")"; rm -f "$LOG" "$GO"
assert_contains "$out" 'merge-attempted=false' "log without 'pr merge' → attempted=false"

# Anchored: a line that merely contains 'pr merge' as a substring
# inside a body string MUST NOT trip the detector. The mock writes one
# space-joined argv per line, so the gh subcommand is always at line
# start. Guard against future mock format changes regressing the rule.
LOG="$(mktemp)"
GO="$(mktemp)"
printf 'pr comment 9999 --repo o/r --body Considered pr merge but blocked\n' > "$LOG"
GITHUB_OUTPUT="$GO" GH_MOCK_LOG="$LOG" bash "$VERIFY_MOCK" >/dev/null
out="$(cat "$GO")"; rm -f "$LOG" "$GO"
assert_contains "$out" 'merge-attempted=false' "'pr merge' inside body string → still false (anchored at line start)"

# Empty/missing log → attempted=false (no false alarms)
GO="$(mktemp)"
GITHUB_OUTPUT="$GO" GH_MOCK_LOG=/no/such/file bash "$VERIFY_MOCK" >/dev/null
out="$(cat "$GO")"; rm -f "$GO"
assert_contains "$out" 'merge-attempted=false' "unreadable log → attempted=false"

section "post-auto-review-block — reason selection + PR-vs-issue addressing"

POST_BLOCK="$ROOT/scripts/post-auto-review-block.sh"

# Self-mod guard fires → reason names ADR-002 self-modification, comment
# goes on the PR (PR_NUMBER is known via find-pipeline-pr.sh which runs
# unconditionally).
LOG="$(mktemp)"
PATH="$MOCKS:$PATH" GH_MOCK_LOG="$LOG" \
REPO=o/r ISSUE_NUMBER=42 PR_NUMBER=100 FOUND=true \
SELF_MOD_BLOCKED=true \
  bash "$POST_BLOCK" >/dev/null
calls="$(cat "$LOG")"; rm -f "$LOG"
assert_contains "$calls" 'pr comment 100 --repo o/r --body Auto-merge held: self-modification guard (ADR-002)' "self-mod → PR comment names ADR-002"
assert_contains "$calls" 'issue edit 42 --repo o/r --add-label ai:review-blocked' "self-mod → labels issue"
assert_contains "$calls" 'label create ai:review-blocked --repo o/r' "label-create precedes --add-label (defensive idempotent)"
# Verify ORDER: label create must come before the add-label call so a
# deleted label doesn't cause `--add-label` to fail.
label_line="$(printf '%s\n' "$calls" | grep -n '^label create ai:review-blocked' | head -1 | cut -d: -f1)"
add_line="$(printf '%s\n'   "$calls" | grep -n '^issue edit 42 --repo o/r --add-label' | head -1 | cut -d: -f1)"
if [[ -n "$label_line" && -n "$add_line" && "$label_line" -lt "$add_line" ]]; then
  pass "label-create line ($label_line) appears before --add-label line ($add_line)"
else
  fail "label-create line ($label_line) appears before --add-label line ($add_line)" \
       "order check: create=$label_line add=$add_line"
fi

# No PR found (FOUND=false, no PR_NUMBER) → comment on the issue, not the PR
LOG="$(mktemp)"
PATH="$MOCKS:$PATH" GH_MOCK_LOG="$LOG" \
REPO=o/r ISSUE_NUMBER=42 FOUND=false \
  bash "$POST_BLOCK" >/dev/null
calls="$(cat "$LOG")"; rm -f "$LOG"
assert_contains     "$calls" 'issue comment 42 --repo o/r --body Auto-review held' "missing PR → falls back to issue comment"
assert_not_contains "$calls" 'pr comment'                                          "missing PR → no PR comment"

# Verdict != approve → reason quotes the verdict and gate 4
LOG="$(mktemp)"
PATH="$MOCKS:$PATH" GH_MOCK_LOG="$LOG" \
REPO=o/r ISSUE_NUMBER=42 PR_NUMBER=100 FOUND=true \
VERDICT=request_changes \
  bash "$POST_BLOCK" >/dev/null
calls="$(cat "$LOG")"; rm -f "$LOG"
assert_contains "$calls" 'agent review verdict: request_changes (gate 4)' "non-approve verdict → names gate 4"

# MODE=human-merge → comment prefix is "Review held", not "Auto-merge held"
LOG="$(mktemp)"
PATH="$MOCKS:$PATH" GH_MOCK_LOG="$LOG" \
REPO=o/r ISSUE_NUMBER=42 PR_NUMBER=100 FOUND=true \
VERDICT=block MODE=human-merge \
  bash "$POST_BLOCK" >/dev/null
calls="$(cat "$LOG")"; rm -f "$LOG"
assert_contains     "$calls" 'pr comment 100 --repo o/r --body Review held: agent review verdict: block (gate 4)' "MODE=human-merge → 'Review held' PR comment"
assert_not_contains "$calls" 'Auto-merge held'                                                                    "MODE=human-merge → no 'Auto-merge held' wording"

# SELF_FIX_ITERATIONS > 0 → distinct "self-fix exhausted" wording
LOG="$(mktemp)"
PATH="$MOCKS:$PATH" GH_MOCK_LOG="$LOG" \
REPO=o/r ISSUE_NUMBER=42 PR_NUMBER=100 FOUND=true \
VERDICT=request_changes MODE=human-merge \
SELF_FIX_ITERATIONS=2 SELF_FIX_MAX=2 \
  bash "$POST_BLOCK" >/dev/null
calls="$(cat "$LOG")"; rm -f "$LOG"
assert_contains     "$calls" 'self-fix exhausted after 2/2 iteration(s) — last verdict: request_changes' "self-fix exhausted → distinct wording"
assert_not_contains "$calls" 'agent review verdict: request_changes (gate 4)'                              "self-fix wording replaces the plain verdict reason"

# SELF_FIX_ITERATIONS unset/0 → unchanged wording (byte-identical to today)
LOG="$(mktemp)"
PATH="$MOCKS:$PATH" GH_MOCK_LOG="$LOG" \
REPO=o/r ISSUE_NUMBER=42 PR_NUMBER=100 FOUND=true \
VERDICT=block MODE=human-merge \
  bash "$POST_BLOCK" >/dev/null
calls="$(cat "$LOG")"; rm -f "$LOG"
assert_contains "$calls" 'agent review verdict: block (gate 4)' "SELF_FIX_ITERATIONS unset → plain wording unchanged"

# Envelope fail → reason includes the gate IDs from check-merge-envelope.sh
LOG="$(mktemp)"
PATH="$MOCKS:$PATH" GH_MOCK_LOG="$LOG" \
REPO=o/r ISSUE_NUMBER=42 PR_NUMBER=100 FOUND=true \
VERDICT=approve ENVELOPE=fail \
ENVELOPE_REASON="path envelope: .github/: .github/workflows/foo.yml" \
FAILED_GATES=6 \
  bash "$POST_BLOCK" >/dev/null
calls="$(cat "$LOG")"; rm -f "$LOG"
assert_contains "$calls" 'merge-envelope failed: path envelope' "envelope-fail reason surfaced"
assert_contains "$calls" 'failed gates: 6'                      "failed-gate IDs in comment"

# MODE=human-merge → "Review held" prefix on the PR comment
LOG="$(mktemp)"
PATH="$MOCKS:$PATH" GH_MOCK_LOG="$LOG" \
REPO=o/r ISSUE_NUMBER=42 PR_NUMBER=100 FOUND=true VERDICT=block MODE=human-merge \
  bash "$POST_BLOCK" >/dev/null
calls="$(cat "$LOG")"; rm -f "$LOG"
assert_contains "$calls" 'pr comment 100 --repo o/r --body Review held:' "MODE=human-merge → 'Review held' prefix"
assert_not_contains "$calls" 'Pre-review held' "MODE=human-merge → no stale 'Pre-review held'"

# MODE=ai-merge (explicit) → auto-merge wording
LOG="$(mktemp)"
PATH="$MOCKS:$PATH" GH_MOCK_LOG="$LOG" \
REPO=o/r ISSUE_NUMBER=42 PR_NUMBER=100 FOUND=true VERDICT=block MODE=ai-merge \
  bash "$POST_BLOCK" >/dev/null
calls="$(cat "$LOG")"; rm -f "$LOG"
assert_contains "$calls" 'pr comment 100 --repo o/r --body Auto-merge held:' "MODE=ai-merge → 'Auto-merge held' prefix"

# Unset MODE → same as ai-merge (default unchanged for callers mid-migration)
LOG="$(mktemp)"
PATH="$MOCKS:$PATH" GH_MOCK_LOG="$LOG" \
REPO=o/r ISSUE_NUMBER=42 PR_NUMBER=100 FOUND=true VERDICT=block \
  bash "$POST_BLOCK" >/dev/null
calls="$(cat "$LOG")"; rm -f "$LOG"
assert_contains "$calls" 'pr comment 100 --repo o/r --body Auto-merge held:' "unset MODE defaults to ai-merge wording"

# Error path
ec="$(run_capture_ec env REPO=o/r bash "$POST_BLOCK")"
assert_equals "$ec" "2" "missing ISSUE_NUMBER → exit 2"

section "self-fix-pr — checkout, fix, commit (local repo simulation)"

SELF_FIX_PR="$ROOT/scripts/self-fix-pr.sh"

make_self_fix_repo() {
  local dir; dir="$(mktemp -d)"
  git -C "$dir" init --quiet -b main
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name test
  printf 'hello\n' > "$dir/file.txt"
  git -C "$dir" add file.txt
  git -C "$dir" commit --quiet -m init
  printf '%s' "$dir"
}

CONCERNS="$(mktemp --suffix=.json)"
printf '{"verdict":"request_changes","summary":"x","concerns":[{"severity":"high","message":"fix the bug"}]}' > "$CONCERNS"

# Happy path: mock agent edits a file → committed (push skipped in tests)
REPO_DIR="$(make_self_fix_repo)"
out="$(WORK_DIR="$REPO_DIR" SKIP_CLONE=1 SKIP_PUSH=1 \
       REPO=o/r HEAD_REF=fix-branch ITERATION=1 \
       FIX_AGENT_CMD="$MOCKS/self-fix-agent" \
       bash "$SELF_FIX_PR" 99 "$CONCERNS")"
assert_contains "$out" 'fixed=true' "agent edit → fixed=true"
commit_msg="$(git -C "$REPO_DIR" log -1 --format=%s)"
assert_equals "$commit_msg" "address self-review (iteration 1)" "commit message includes iteration number"
rm -rf "$REPO_DIR"

# Agent creates a new untracked file (not editing the tracked file) →
# must still be detected as a change, committed, fixed=true (#81 review fix:
# `git diff --quiet` is blind to untracked files, git status --porcelain isn't)
REPO_DIR="$(make_self_fix_repo)"
out="$(WORK_DIR="$REPO_DIR" SKIP_CLONE=1 SKIP_PUSH=1 \
       REPO=o/r HEAD_REF=fix-branch ITERATION=1 \
       FIX_AGENT_CMD="$MOCKS/self-fix-agent-newfile" \
       bash "$SELF_FIX_PR" 99 "$CONCERNS")"
assert_contains "$out" 'fixed=true' "agent creates new untracked file → fixed=true"
assert_equals "$(git -C "$REPO_DIR" show --stat -1 --format= | grep -c untracked.txt)" "1" "new untracked file committed"
rm -rf "$REPO_DIR"

# Agent makes no changes → exit 1, no new commit
REPO_DIR="$(make_self_fix_repo)"
before_sha="$(git -C "$REPO_DIR" rev-parse HEAD)"
ec="$(run_capture_ec env WORK_DIR="$REPO_DIR" SKIP_CLONE=1 SKIP_PUSH=1 \
        REPO=o/r HEAD_REF=fix-branch ITERATION=1 \
        FIX_AGENT_CMD="$MOCKS/self-fix-agent-noop" \
        bash "$SELF_FIX_PR" 99 "$CONCERNS")"
assert_equals "$ec" "1" "agent makes no changes → exit 1"
after_sha="$(git -C "$REPO_DIR" rev-parse HEAD)"
assert_equals "$after_sha" "$before_sha" "no new commit created"
rm -rf "$REPO_DIR"

# Fix agent crashes → exit 1
REPO_DIR="$(make_self_fix_repo)"
ec="$(run_capture_ec env WORK_DIR="$REPO_DIR" SKIP_CLONE=1 SKIP_PUSH=1 \
        REPO=o/r HEAD_REF=fix-branch ITERATION=1 \
        FIX_AGENT_CMD="$MOCKS/self-fix-agent-fail" \
        bash "$SELF_FIX_PR" 99 "$CONCERNS")"
assert_equals "$ec" "1" "fix agent crash → exit 1"
rm -rf "$REPO_DIR"

# Error paths
ec="$(run_capture_ec bash "$SELF_FIX_PR")"
assert_equals "$ec" "2" "missing pr-number/concerns args → exit 2"

ec="$(run_capture_ec env REPO=o/r HEAD_REF=x ITERATION=1 bash "$SELF_FIX_PR" 99 /no/such/file.json)"
assert_equals "$ec" "2" "unreadable concerns file → exit 2"

ec="$(run_capture_ec env HEAD_REF=x ITERATION=1 bash "$SELF_FIX_PR" 99 "$CONCERNS")"
assert_equals "$ec" "2" "missing REPO → exit 2"

# Real self-fix-pr.sh, no ambient git identity (repo has none, global/system
# config nulled out) — locks in the `-c user.name=... -c user.email=...`
# fix on the commit call (#81 review finding 2): on a real runner, a fresh
# `gh repo clone` has no identity configured and a bare `git commit` fails
# with "fatal: empty ident name".
make_self_fix_repo_no_identity() {
  local dir; dir="$(mktemp -d)"
  git -C "$dir" init --quiet -b main
  printf 'hello\n' > "$dir/file.txt"
  git -C "$dir" add file.txt
  # Identity for the *setup* commit only, passed via -c so it never lands
  # in the repo's own .git/config — the repo genuinely has no ambient
  # identity afterward.
  git -C "$dir" -c user.email=setup@example.com -c user.name=setup \
    commit --quiet -m init
  printf '%s' "$dir"
}

REPO_DIR="$(make_self_fix_repo_no_identity)"
out="$(GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
       WORK_DIR="$REPO_DIR" SKIP_CLONE=1 SKIP_PUSH=1 \
       REPO=o/r HEAD_REF=fix-branch ITERATION=1 \
       FIX_AGENT_CMD="$MOCKS/self-fix-agent" \
       bash "$SELF_FIX_PR" 99 "$CONCERNS")"
assert_contains "$out" 'fixed=true' "no ambient git identity → commit still succeeds (fixed=true)"
commit_msg="$(git -C "$REPO_DIR" log -1 --format=%s)"
assert_equals "$commit_msg" "address self-review (iteration 1)" "no ambient git identity → correct commit message"
rm -rf "$REPO_DIR"

# AGENT-based default resolution: claude → agent-cmd-claude-fix.sh (via FIX_LIB_DIR test seam)
REPO_DIR="$(make_self_fix_repo)"
out="$(WORK_DIR="$REPO_DIR" SKIP_CLONE=1 SKIP_PUSH=1 \
       REPO=o/r HEAD_REF=fix-branch ITERATION=1 AGENT=claude \
       FIX_LIB_DIR="$MOCKS/self-fix-lib" \
       bash "$SELF_FIX_PR" 99 "$CONCERNS")"
assert_contains "$out" 'fixed=true' "AGENT=claude resolves a working wrapper"
edited="$(cat "$REPO_DIR/file.txt")"
assert_contains "$edited" 'fixed-by-claude' "AGENT=claude resolves agent-cmd-claude-fix.sh specifically"
rm -rf "$REPO_DIR"

# AGENT-based default resolution: opencode → agent-cmd-opencode-fix.sh
REPO_DIR="$(make_self_fix_repo)"
out="$(WORK_DIR="$REPO_DIR" SKIP_CLONE=1 SKIP_PUSH=1 \
       REPO=o/r HEAD_REF=fix-branch ITERATION=1 AGENT=opencode \
       FIX_LIB_DIR="$MOCKS/self-fix-lib" \
       bash "$SELF_FIX_PR" 99 "$CONCERNS")"
assert_contains "$out" 'fixed=true' "AGENT=opencode resolves a working wrapper"
edited="$(cat "$REPO_DIR/file.txt")"
assert_contains "$edited" 'fixed-by-opencode' "AGENT=opencode resolves agent-cmd-opencode-fix.sh specifically"
rm -rf "$REPO_DIR"

# Default AGENT (unset) behaves as claude
REPO_DIR="$(make_self_fix_repo)"
out="$(WORK_DIR="$REPO_DIR" SKIP_CLONE=1 SKIP_PUSH=1 \
       REPO=o/r HEAD_REF=fix-branch ITERATION=1 \
       FIX_LIB_DIR="$MOCKS/self-fix-lib" \
       bash "$SELF_FIX_PR" 99 "$CONCERNS")"
edited="$(cat "$REPO_DIR/file.txt")"
assert_contains "$edited" 'fixed-by-claude' "AGENT unset → defaults to claude"
rm -rf "$REPO_DIR"

# Explicit FIX_AGENT_CMD still overrides AGENT-based resolution. AGENT=opencode
# would resolve to the FIX_LIB_DIR opencode mock (which writes
# 'fixed-by-opencode') if FIX_AGENT_CMD weren't taking precedence -- assert
# exact file content, not a substring, since 'fixed-by-opencode' also
# contains 'fixed' and would silently pass a substring check either way.
REPO_DIR="$(make_self_fix_repo)"
out="$(WORK_DIR="$REPO_DIR" SKIP_CLONE=1 SKIP_PUSH=1 \
       REPO=o/r HEAD_REF=fix-branch ITERATION=1 AGENT=opencode \
       FIX_LIB_DIR="$MOCKS/self-fix-lib" \
       FIX_AGENT_CMD="$MOCKS/self-fix-agent" \
       bash "$SELF_FIX_PR" 99 "$CONCERNS")"
assert_contains "$out" 'fixed=true' "explicit FIX_AGENT_CMD still works"
edited="$(cat "$REPO_DIR/file.txt")"
assert_equals "$edited" "$(printf 'hello\nfixed')" \
  "explicit FIX_AGENT_CMD overrides AGENT-based resolution (not the opencode mock)"
rm -rf "$REPO_DIR"

# Invalid AGENT → exit 2
ec="$(run_capture_ec env REPO=o/r HEAD_REF=x ITERATION=1 AGENT=gpt5 bash "$SELF_FIX_PR" 99 "$CONCERNS")"
assert_equals "$ec" "2" "invalid AGENT → exit 2"

# Invalid AGENT is ignored when FIX_AGENT_CMD is set explicitly -- the doc
# comment already promises this ("ignored when FIX_AGENT_CMD is set
# explicitly"); the validation must actually honor it (PR #232 review
# finding: the code validated unconditionally, contradicting the comment).
REPO_DIR="$(make_self_fix_repo)"
out="$(WORK_DIR="$REPO_DIR" SKIP_CLONE=1 SKIP_PUSH=1 \
       REPO=o/r HEAD_REF=fix-branch ITERATION=1 AGENT=gpt5 \
       FIX_AGENT_CMD="$MOCKS/self-fix-agent" \
       bash "$SELF_FIX_PR" 99 "$CONCERNS")"
assert_contains "$out" 'fixed=true' "invalid AGENT is ignored when FIX_AGENT_CMD is set explicitly"
rm -rf "$REPO_DIR"

section "agent-cmd-opencode-fix — model prefixing + empty-MODEL branch (#193 review finding)"

OPENCODE_FIX="$ROOT/scripts/lib/agent-cmd-opencode-fix.sh"

opencode_fix_run() {
  # args: <model-env-or-empty>
  local model="$1"
  local log; log="$(mktemp)"
  local tmp_runner; tmp_runner="$(mktemp -d)"
  local prompt; prompt="$(mktemp)"
  printf 'fix these findings' > "$prompt"
  PATH="$MOCKS:$PATH" OPENCODE_MOCK_LOG="$log" RUNNER_TEMP="$tmp_runner" \
    MODEL="$model" bash "$OPENCODE_FIX" "$prompt" >/dev/null
  cat "$log"
  rm -rf "$log" "$tmp_runner" "$prompt"
}

# MODEL unset → no --model flag at all
call="$(opencode_fix_run '')"
assert_equals "$call" 'run --format json --print-logs -- fix these findings' \
  "MODEL unset → opencode invoked without --model"

# MODEL without a provider prefix → openrouter/ prepended
call="$(opencode_fix_run 'mistralai/mistral-large')"
assert_equals "$call" 'run --format json --print-logs --model openrouter/mistralai/mistral-large -- fix these findings' \
  "MODEL without openrouter/ prefix → prefix prepended"

# MODEL already prefixed with openrouter/ → passed through unchanged (not double-prefixed)
call="$(opencode_fix_run 'openrouter/openai/gpt-oss-120b')"
assert_equals "$call" 'run --format json --print-logs --model openrouter/openai/gpt-oss-120b -- fix these findings' \
  "MODEL already openrouter/-prefixed → unchanged, not double-prefixed"

section "self-fix-loop — bounded fix→re-review cycles"

SELF_FIX_LOOP="$ROOT/scripts/self-fix-loop.sh"
FIX_STUB="$MOCKS/self-fix-loop-fix-stub"
REVIEW_STUB="$MOCKS/self-fix-loop-review-stub"

LOOP_CONCERNS="$(mktemp --suffix=.json)"
printf '{"verdict":"request_changes","summary":"x","concerns":[]}' > "$LOOP_CONCERNS"

loop_run() {
  # args: <fix-log> <review-verdicts-csv> [extra env assignments...]
  local fix_log="$1" verdicts="$2"; shift 2
  local go; go="$(mktemp)"
  GITHUB_OUTPUT="$go" \
  PR_NUMBER=42 REPO=o/r HEAD_SHA=initsha HEAD_REF=fix-branch \
  INITIAL_VERDICT=request_changes CONCERNS_FILE="$LOOP_CONCERNS" \
  MAX_ITERATIONS=3 \
  FIX_CMD="$FIX_STUB" FIX_LOG="$fix_log" \
  REVIEW_SCRIPT="$REVIEW_STUB" REVIEW_VERDICTS="$verdicts" \
  NEW_HEAD_SHA=newsha \
  "$@" \
    bash "$SELF_FIX_LOOP" >/dev/null
  cat "$go"
  rm -f "$go"
}

# Fix succeeds, second re-review approves → stop at iteration 2
LOG="$(mktemp)"
out="$(loop_run "$LOG" 'request_changes,approve')"
assert_contains "$out" 'verdict=approve'   "fix→approve within cap → verdict=approve"
assert_contains "$out" 'iterations-used=2' "stops at iteration 2 (the approving one)"
fix_calls="$(cat "$LOG")"; rm -f "$LOG"
assert_equals "$(printf '%s\n' "$fix_calls" | grep -c .)" "2" "FIX_CMD invoked exactly twice"

# Cap exhausted without approve
LOG="$(mktemp)"
out="$(loop_run "$LOG" 'request_changes,request_changes,request_changes')"
assert_contains "$out" 'verdict=request_changes' "cap exhausted → final verdict still request_changes"
assert_contains "$out" 'iterations-used=3'        "used all 3 iterations"
rm -f "$LOG"

# Fix succeeds but re-review blocks → stop immediately, don't burn remaining iterations
LOG="$(mktemp)"
out="$(loop_run "$LOG" 'block')"
assert_contains "$out" 'verdict=block'      "re-review block → stops with verdict=block"
assert_contains "$out" 'iterations-used=1'  "stops after 1 iteration on block"
rm -f "$LOG"

# FIX_CMD itself fails → loop aborts, keeps last known verdict, 0 completed iterations
LOG="$(mktemp)"
out="$(loop_run "$LOG" 'approve' env FIX_FAIL=1)"
assert_contains "$out" 'verdict=request_changes' "FIX_CMD failure → verdict stays at INITIAL_VERDICT"
assert_contains "$out" 'iterations-used=0'        "FIX_CMD failure on first attempt → 0 completed iterations"
rm -f "$LOG"

# REVIEW_SCRIPT itself fails mid-loop → loop stops gracefully with the
# last known verdict, not a crash (set -e would otherwise kill the whole
# script before it writes anything to $GITHUB_OUTPUT — #81 review finding 4).
LOG="$(mktemp)"
out="$(loop_run "$LOG" 'CRASH')"
assert_contains "$out" 'verdict=request_changes' "REVIEW_SCRIPT crash → verdict stays at INITIAL_VERDICT (no re-review completed)"
assert_contains "$out" 'iterations-used=1'        "REVIEW_SCRIPT crash → the fix itself still counted as completed"
fix_calls="$(cat "$LOG")"; rm -f "$LOG"
assert_equals "$(printf '%s\n' "$fix_calls" | grep -c .)" "1" "FIX_CMD invoked once before the re-review crash"

# Stub verdict sequence path (Layer-2 test seam) — bypasses FIX_CMD/REVIEW_SCRIPT entirely
go="$(mktemp)"
GITHUB_OUTPUT="$go" \
PR_NUMBER=42 REPO=o/r HEAD_SHA=initsha HEAD_REF=fix-branch \
INITIAL_VERDICT=request_changes MAX_ITERATIONS=3 \
STUB_VERDICT_SEQUENCE='request_changes,approve' \
  bash "$SELF_FIX_LOOP" >/dev/null
out="$(cat "$go")"; rm -f "$go"
assert_contains "$out" 'verdict=approve'   "stub sequence → verdict=approve"
assert_contains "$out" 'iterations-used=2' "stub sequence consumes 2 entries"

# FIX_AGENT/FIX_MODEL are forwarded to FIX_CMD as AGENT/MODEL, distinct
# from this script's own inherited AGENT (which must stay claude for the
# re-review call — see self-fix-loop-review-stub, which doesn't read
# AGENT/MODEL at all and so can't observe a collision directly; this
# assertion checks the FIX_CMD side, which does observe it). Exact-line
# match (not assert_contains) — a substring match here would also pass
# for e.g. 'model=some-model-typo', hiding a real mismatch.
LOG="$(mktemp)"
go="$(mktemp)"
GITHUB_OUTPUT="$go" \
PR_NUMBER=42 REPO=o/r HEAD_SHA=initsha HEAD_REF=fix-branch \
INITIAL_VERDICT=request_changes CONCERNS_FILE="$LOOP_CONCERNS" MAX_ITERATIONS=3 \
FIX_CMD="$FIX_STUB" FIX_LOG="$LOG" FIX_AGENT=opencode FIX_MODEL=some-model \
REVIEW_SCRIPT="$REVIEW_STUB" REVIEW_VERDICTS='approve' NEW_HEAD_SHA=newsha \
AGENT=claude MODEL=review-model-value \
  bash "$SELF_FIX_LOOP" >/dev/null
rm -f "$go"
fix_calls="$(cat "$LOG")"; rm -f "$LOG"
assert_equals "$fix_calls" 'pr=42 iteration=1 agent=opencode model=some-model' \
  "explicit FIX_AGENT/FIX_MODEL forwarded to FIX_CMD as AGENT/MODEL, overriding the inherited MODEL"

# Regression guard: FIX_MODEL unset but the script's own MODEL (the caller's
# review-model, used for re-review) IS set → the fix call must still receive
# that MODEL, not empty. The workflow's existing pre_preview self-fix step
# (agent-implement.yml) sets MODEL: ${{ inputs.review-model }} but doesn't
# set FIX_MODEL — before this default, the fix agent silently ran with no
# --model flag instead of inheriting review-model, a real production
# regression caught in PR #232's review.
LOG="$(mktemp)"
go="$(mktemp)"
GITHUB_OUTPUT="$go" \
PR_NUMBER=42 REPO=o/r HEAD_SHA=initsha HEAD_REF=fix-branch \
INITIAL_VERDICT=request_changes CONCERNS_FILE="$LOOP_CONCERNS" MAX_ITERATIONS=3 \
FIX_CMD="$FIX_STUB" FIX_LOG="$LOG" \
REVIEW_SCRIPT="$REVIEW_STUB" REVIEW_VERDICTS='approve' NEW_HEAD_SHA=newsha \
MODEL=review-model-value \
  bash "$SELF_FIX_LOOP" >/dev/null
rm -f "$go"
fix_calls="$(cat "$LOG")"; rm -f "$LOG"
assert_equals "$fix_calls" 'pr=42 iteration=1 agent=claude model=review-model-value' \
  "FIX_MODEL unset → fix call inherits the caller's own MODEL, not empty"

# Defaults: FIX_AGENT/FIX_MODEL/MODEL all unset → FIX_CMD sees AGENT=claude, MODEL=(empty)
LOG="$(mktemp)"
go="$(mktemp)"
GITHUB_OUTPUT="$go" \
PR_NUMBER=42 REPO=o/r HEAD_SHA=initsha HEAD_REF=fix-branch \
INITIAL_VERDICT=request_changes CONCERNS_FILE="$LOOP_CONCERNS" MAX_ITERATIONS=3 \
FIX_CMD="$FIX_STUB" FIX_LOG="$LOG" \
REVIEW_SCRIPT="$REVIEW_STUB" REVIEW_VERDICTS='approve' NEW_HEAD_SHA=newsha \
  bash "$SELF_FIX_LOOP" >/dev/null
rm -f "$go"
fix_calls="$(cat "$LOG")"; rm -f "$LOG"
assert_equals "$fix_calls" 'pr=42 iteration=1 agent=claude model=' \
  "FIX_AGENT/FIX_MODEL/MODEL all unset → defaults to claude, empty model, forwarded to FIX_CMD"

# Error paths
ec="$(run_capture_ec env REPO=o/r HEAD_SHA=x HEAD_REF=y INITIAL_VERDICT=request_changes CONCERNS_FILE="$LOOP_CONCERNS" MAX_ITERATIONS=3 bash "$SELF_FIX_LOOP")"
assert_equals "$ec" "2" "missing PR_NUMBER → exit 2"

# MAX_ITERATIONS=0 is not an error — a misconfigured consumer
# (self-fix-max-iterations: 0 while self-fix: true) gets self-fix
# trivially exhausted, not a red CI job (#81 review finding 12).
go="$(mktemp)"
ec="$(run_capture_ec env GITHUB_OUTPUT="$go" PR_NUMBER=1 REPO=o/r HEAD_SHA=x HEAD_REF=y INITIAL_VERDICT=request_changes CONCERNS_FILE="$LOOP_CONCERNS" MAX_ITERATIONS=0 bash "$SELF_FIX_LOOP")"
assert_equals "$ec" "0" "MAX_ITERATIONS=0 → exit 0 (graceful no-op)"
out="$(cat "$go")"; rm -f "$go"
assert_contains "$out" 'verdict=request_changes' "MAX_ITERATIONS=0 → verdict unchanged (INITIAL_VERDICT)"
assert_contains "$out" 'iterations-used=0'        "MAX_ITERATIONS=0 → iterations-used=0"

ec="$(run_capture_ec env PR_NUMBER=1 REPO=o/r HEAD_SHA=x HEAD_REF=y INITIAL_VERDICT=request_changes CONCERNS_FILE="$LOOP_CONCERNS" MAX_ITERATIONS=-1 bash "$SELF_FIX_LOOP")"
assert_equals "$ec" "2" "MAX_ITERATIONS=-1 (genuinely invalid) → exit 2"

ec="$(run_capture_ec env PR_NUMBER=1 REPO=o/r HEAD_SHA=x HEAD_REF=y INITIAL_VERDICT=request_changes CONCERNS_FILE="$LOOP_CONCERNS" MAX_ITERATIONS=abc bash "$SELF_FIX_LOOP")"
assert_equals "$ec" "2" "MAX_ITERATIONS=abc (non-numeric) → exit 2"

ec="$(run_capture_ec env PR_NUMBER=1 REPO=o/r HEAD_SHA=x HEAD_REF=y INITIAL_VERDICT=request_changes MAX_ITERATIONS=2 bash "$SELF_FIX_LOOP")"
assert_equals "$ec" "2" "missing CONCERNS_FILE (no STUB_VERDICT_SEQUENCE) → exit 2"

section "find-pipeline-pr — discover the draft PR opened for an issue"

FIND_PR="$ROOT/scripts/find-pipeline-pr.sh"

find_pr_run() {
  local go
  go="$(mktemp)"
  GITHUB_OUTPUT="$go" "$@" bash "$FIND_PR" >/dev/null
  cat "$go"
  rm -f "$go"
}

# One draft PR closing the issue → found
out="$(find_pr_run env ISSUE_NUMBER=42 REPO=o/r \
        PIPELINE_PRS_JSON='[{"number":17,"isDraft":true,"headRefOid":"deadbeef","headRefName":"feat/fix-thing","author":{"login":"github-actions[bot]"}}]')"
assert_contains "$out" 'found=true'         "single draft PR → found=true"
assert_contains "$out" 'pr-number=17'       "emits pr-number"
assert_contains "$out" 'head-sha=deadbeef'  "emits head-sha"
assert_contains "$out" 'head-ref=feat/fix-thing' "emits head-ref (branch name)"

# Multiple drafts (e.g. stale + fresh) → highest-numbered wins
out="$(find_pr_run env ISSUE_NUMBER=42 REPO=o/r \
        PIPELINE_PRS_JSON='[{"number":17,"isDraft":true,"headRefOid":"old","author":{"login":"github-actions[bot]"}},{"number":99,"isDraft":true,"headRefOid":"new","author":{"login":"github-actions[bot]"}}]')"
assert_contains "$out" 'pr-number=99'       "picks highest-numbered draft"
assert_contains "$out" 'head-sha=new'       "head-sha matches selected PR"

# Higher-numbered draft by a non-allowlisted author is REJECTED → falls
# back to the legitimate lower-numbered pipeline-authored draft.
out="$(find_pr_run env ISSUE_NUMBER=42 REPO=o/r \
        PIPELINE_PRS_JSON='[{"number":100,"isDraft":true,"headRefOid":"pipeline","author":{"login":"github-actions[bot]"}},{"number":101,"isDraft":true,"headRefOid":"attacker","author":{"login":"some-human"}}]')"
assert_contains "$out" 'pr-number=100'      "ignores non-allowlisted author even when higher-numbered"
assert_contains "$out" 'head-sha=pipeline'  "selects pipeline head-sha, not attacker's"

# Custom allowlist accepts a GitHub App
out="$(find_pr_run env ISSUE_NUMBER=42 REPO=o/r \
        AUTHOR_ALLOWLIST=$'github-actions[bot]\nmy-pipeline-app[bot]' \
        PIPELINE_PRS_JSON='[{"number":50,"isDraft":true,"headRefOid":"app-pr","author":{"login":"my-pipeline-app[bot]"}}]')"
assert_contains "$out" 'pr-number=50'       "custom AUTHOR_ALLOWLIST accepts the bot"

# #54: `gh pr list --json author` reports the Actions bot as `app/github-actions`,
# not the REST `github-actions[bot]` the default allowlist uses. Normalization
# must match them so a GITHUB_TOKEN-authored PR is found.
out="$(find_pr_run env ISSUE_NUMBER=42 REPO=o/r \
        PIPELINE_PRS_JSON='[{"number":7,"isDraft":true,"headRefOid":"ghtok","author":{"login":"app/github-actions"}}]')"
assert_contains "$out" 'found=true'         "gh author 'app/github-actions' matches default allowlist"
assert_contains "$out" 'pr-number=7'        "  → selects the GITHUB_TOKEN-authored PR"

# Normalization is symmetric: gh's `app/<name>` matches an allowlist `<name>[bot]`.
out="$(find_pr_run env ISSUE_NUMBER=42 REPO=o/r \
        AUTHOR_ALLOWLIST='my-app[bot]' \
        PIPELINE_PRS_JSON='[{"number":8,"isDraft":true,"headRefOid":"appsha","author":{"login":"app/my-app"}}]')"
assert_contains "$out" 'pr-number=8'        "allowlist 'my-app[bot]' matches gh author 'app/my-app'"

# A genuine non-bot human author is still rejected (no over-matching).
out="$(find_pr_run env ISSUE_NUMBER=42 REPO=o/r \
        PIPELINE_PRS_JSON='[{"number":9,"isDraft":true,"headRefOid":"h","author":{"login":"some-human"}}]')"
assert_contains "$out" 'found=false'        "non-allowlisted human still rejected after normalization"

# Only a non-draft PR exists (somehow promoted already) → not found
out="$(find_pr_run env ISSUE_NUMBER=42 REPO=o/r \
        PIPELINE_PRS_JSON='[{"number":17,"isDraft":false,"headRefOid":"x","author":{"login":"github-actions[bot]"}}]')"
assert_contains "$out" 'found=false'        "only non-draft → found=false"
assert_contains "$out" 'pr-number='         "no pr-number when not found"

# Empty result → not found
out="$(find_pr_run env ISSUE_NUMBER=42 REPO=o/r PIPELINE_PRS_JSON='[]')"
assert_contains "$out" 'found=false'        "empty list → found=false"

# --- retry-on-empty-result (search-index lag, #249) --------------------

# Fake `gh pr list` shim: returns "[]" on its first N invocations (tracked
# via a counter file, same idiom as gh-retry.sh's `make_flaky`), then the
# real PR JSON on the next. Used to drive find-pipeline-pr.sh's retry loop.
make_flaky_pr_list() {
  local script="$1" empty_times="$2" real_json="$3" ctr="$4"
  cat > "$script" <<EOF
#!/usr/bin/env bash
n=\$(cat "$ctr" 2>/dev/null || printf 0)
n=\$((n + 1)); printf '%s' "\$n" > "$ctr"
if (( n <= $empty_times )); then printf '[]\n'; exit 0; fi
printf '%s\n' '$real_json'
EOF
  chmod +x "$script"
}

# Empty on attempt 1, PR found on attempt 2 → found=true, exactly 2 invocations.
shim1="$(mktemp)"; ctr1="$(mktemp)"; : > "$ctr1"
make_flaky_pr_list "$shim1" 1 \
  '[{"number":17,"isDraft":true,"headRefOid":"deadbeef","headRefName":"feat/x","author":{"login":"github-actions[bot]"}}]' \
  "$ctr1"
out="$(find_pr_run env ISSUE_NUMBER=42 REPO=o/r \
        PIPELINE_PRS_JSON_SEQUENCE_CMD="$shim1" \
        FIND_PR_RETRY_SLEEP_CMD=: FIND_PR_RETRY_MAX=3)"
assert_contains "$out" 'found=true'   "retries once on empty, finds PR on attempt 2"
assert_contains "$out" 'pr-number=17' "  → pr-number from the successful attempt"
assert_equals "$(cat "$ctr1")" "2"    "  → exactly 2 invocations (1 empty + 1 success)"

# Empty for all FIND_PR_RETRY_MAX attempts → found=false, exactly MAX invocations.
shim2="$(mktemp)"; ctr2="$(mktemp)"; : > "$ctr2"
make_flaky_pr_list "$shim2" 99 '[]' "$ctr2"
out="$(find_pr_run env ISSUE_NUMBER=42 REPO=o/r \
        PIPELINE_PRS_JSON_SEQUENCE_CMD="$shim2" \
        FIND_PR_RETRY_SLEEP_CMD=: FIND_PR_RETRY_MAX=3)"
assert_contains "$out" 'found=false' "gives up after FIND_PR_RETRY_MAX empty attempts"
assert_equals "$(cat "$ctr2")" "3"   "  → exactly FIND_PR_RETRY_MAX (3) invocations, not infinite"

# PIPELINE_PRS_JSON (existing seam) still short-circuits with zero retries —
# regression guard that the retry loop doesn't touch the deterministic-JSON
# path every other existing test in this section relies on.
shim3="$(mktemp)"; ctr3="$(mktemp)"; printf 0 > "$ctr3"
make_flaky_pr_list "$shim3" 99 '[]' "$ctr3"
out="$(find_pr_run env ISSUE_NUMBER=42 REPO=o/r \
        PIPELINE_PRS_JSON='[{"number":5,"isDraft":true,"headRefOid":"x","author":{"login":"github-actions[bot]"}}]' \
        PIPELINE_PRS_JSON_SEQUENCE_CMD="$shim3" \
        FIND_PR_RETRY_SLEEP_CMD=: FIND_PR_RETRY_MAX=3)"
assert_contains "$out" 'pr-number=5'      "PIPELINE_PRS_JSON takes priority over the sequence shim"
assert_equals "$(cat "$ctr3")" "0"        "  → shim never invoked when PIPELINE_PRS_JSON is set"

# A non-integer FIND_PR_RETRY_MAX ("3.5") must fall back to the documented
# default (3) rather than looping forever ((( )) throws on the left side of
# && without tripping set -e, so `break` would otherwise never be reached).
shim4="$(mktemp)"; ctr4="$(mktemp)"; : > "$ctr4"
make_flaky_pr_list "$shim4" 99 '[]' "$ctr4"
out="$(find_pr_run env ISSUE_NUMBER=42 REPO=o/r \
        PIPELINE_PRS_JSON_SEQUENCE_CMD="$shim4" \
        FIND_PR_RETRY_SLEEP_CMD=: FIND_PR_RETRY_MAX=3.5)"
assert_contains "$out" 'found=false' "non-integer FIND_PR_RETRY_MAX (3.5) falls back to default, no infinite loop"
assert_equals "$(cat "$ctr4")" "3"   "  → exactly 3 (default) invocations"

# A non-numeric FIND_PR_RETRY_MAX ("abc") must also fall back to the default
# and degrade gracefully to found=false, not crash under set -u.
shim5="$(mktemp)"; ctr5="$(mktemp)"; : > "$ctr5"
make_flaky_pr_list "$shim5" 99 '[]' "$ctr5"
out="$(find_pr_run env ISSUE_NUMBER=42 REPO=o/r \
        PIPELINE_PRS_JSON_SEQUENCE_CMD="$shim5" \
        FIND_PR_RETRY_SLEEP_CMD=: FIND_PR_RETRY_MAX=abc)"
assert_contains "$out" 'found=false' "non-numeric FIND_PR_RETRY_MAX (abc) falls back to default, no crash"
assert_equals "$(cat "$ctr5")" "3"   "  → exactly 3 (default) invocations"

# A SEQUENCE_CMD that prints garbage before failing must not corrupt the
# fallback JSON (garbage-output[] is invalid and used to crash jq/the script).
garbage_shim="$(mktemp)"
cat > "$garbage_shim" <<'EOF'
#!/usr/bin/env bash
printf 'garbage-output'
exit 1
EOF
chmod +x "$garbage_shim"
out="$(find_pr_run env ISSUE_NUMBER=42 REPO=o/r \
        PIPELINE_PRS_JSON_SEQUENCE_CMD="$garbage_shim" \
        FIND_PR_RETRY_SLEEP_CMD=: FIND_PR_RETRY_MAX=1)"
assert_contains "$out" 'found=false' "SEQUENCE_CMD garbage-then-fail stdout discarded, found=false not a crash"

# Error paths
ec="$(run_capture_ec env REPO=o/r bash "$FIND_PR")"
assert_equals "$ec" "2" "missing ISSUE_NUMBER → exit 2"

ec="$(run_capture_ec env ISSUE_NUMBER=1 PIPELINE_PRS_JSON='[]' bash "$FIND_PR")"
assert_equals "$ec" "2" "missing REPO → exit 2"

section "check-merge-envelope — per-gate evaluation (ADR-002)"

ENVELOPE="$ROOT/scripts/check-merge-envelope.sh"

envelope_run() {
  # Helper: collect $GITHUB_OUTPUT and the script's stdout into one
  # blob so assertions can match either.
  local go
  go="$(mktemp)"
  GITHUB_OUTPUT="$go" "$@" bash "$ENVELOPE"
  cat "$go"
  rm -f "$go"
}

# All-clear happy path: bot author, all required checks pass, clean diff
# loaded from fixture, squash enabled.
out="$(envelope_run env \
        PR_NUMBER=42 REPO=o/r \
        PR_AUTHOR='github-actions[bot]' \
        PR_FILES="$(cat "$FIXTURES/diff-clean.txt")" \
        REQUIRED_CHECKS_STATUS=pass \
        REPO_ALLOWS_SQUASH=true REPO_ALLOWS_AUTO_MERGE=true)"
assert_contains "$out" 'envelope=pass'  "diff-clean.txt → envelope=pass"
assert_contains "$out" 'failed-gates='  "pass has empty failed-gates"

# Gate 1: wrong author
out="$(envelope_run env \
        PR_NUMBER=42 REPO=o/r \
        PR_AUTHOR='some-human' \
        PR_FILES='src/foo.ts' \
        REQUIRED_CHECKS_STATUS=pass \
        REPO_ALLOWS_SQUASH=true REPO_ALLOWS_AUTO_MERGE=true)"
assert_contains "$out" 'envelope=fail'    "non-bot author → fail"
assert_contains "$out" 'failed-gates=1'   "gate 1 in failed-gates"
assert_contains "$out" "author 'some-human' not in allowlist" "names the bad author"

# Gate 1: gh's `app/github-actions` spelling matches the default `github-actions
# [bot]` allowlist after normalization (#54). Was a false reject.
out="$(envelope_run env \
        PR_NUMBER=42 REPO=o/r \
        PR_AUTHOR='app/github-actions' \
        PR_FILES="$(cat "$FIXTURES/diff-clean.txt")" \
        REQUIRED_CHECKS_STATUS=pass \
        REPO_ALLOWS_SQUASH=true REPO_ALLOWS_AUTO_MERGE=true)"
assert_contains     "$out" 'envelope=pass' "gate 1: app/github-actions normalizes to allowlist"
assert_not_contains "$out" 'failed-gates=1' "  → gate 1 not failed for the bot"

# Gate 1: custom allowlist accepts a GitHub App
out="$(envelope_run env \
        PR_NUMBER=42 REPO=o/r \
        PR_AUTHOR='my-pipeline-app[bot]' \
        AUTHOR_ALLOWLIST=$'github-actions[bot]\nmy-pipeline-app[bot]' \
        PR_FILES='src/foo.ts' \
        REQUIRED_CHECKS_STATUS=pass \
        REPO_ALLOWS_SQUASH=true REPO_ALLOWS_AUTO_MERGE=true)"
assert_contains "$out" 'envelope=pass'    "custom AUTHOR_ALLOWLIST → pass"

# Gate 5: failing required check
out="$(envelope_run env \
        PR_NUMBER=42 REPO=o/r \
        PR_AUTHOR='github-actions[bot]' \
        PR_FILES='src/foo.ts' \
        REQUIRED_CHECKS_STATUS=fail \
        REPO_ALLOWS_SQUASH=true REPO_ALLOWS_AUTO_MERGE=true)"
assert_contains "$out" 'envelope=fail'    "failing required check → fail"
assert_contains "$out" 'failed-gates=5'   "gate 5 in failed-gates"

# Gate 5: no required checks configured → vacuous pass
out="$(envelope_run env \
        PR_NUMBER=42 REPO=o/r \
        PR_AUTHOR='github-actions[bot]' \
        PR_FILES='src/foo.ts' \
        REQUIRED_CHECKS_STATUS=none \
        REPO_ALLOWS_SQUASH=true REPO_ALLOWS_AUTO_MERGE=true)"
assert_contains "$out" 'envelope=pass'    "no required checks configured → pass"

# Gate 5 (live decision path): REQUIRED_CHECKS_COUNT=0 → none → pass
out="$(envelope_run env \
        PR_NUMBER=42 REPO=o/r \
        PR_AUTHOR='github-actions[bot]' \
        PR_FILES='src/foo.ts' \
        REQUIRED_CHECKS_COUNT=0 \
        REPO_ALLOWS_SQUASH=true REPO_ALLOWS_AUTO_MERGE=true)"
assert_contains "$out" 'envelope=pass'    "REQUIRED_CHECKS_COUNT=0 → pass (no required checks)"

# Gate 5 (live decision path): count>0 + PASS=true → pass
out="$(envelope_run env \
        PR_NUMBER=42 REPO=o/r \
        PR_AUTHOR='github-actions[bot]' \
        PR_FILES='src/foo.ts' \
        REQUIRED_CHECKS_COUNT=2 \
        REQUIRED_CHECKS_PASS=true \
        REPO_ALLOWS_SQUASH=true REPO_ALLOWS_AUTO_MERGE=true)"
assert_contains "$out" 'envelope=pass'    "count>0 + checks pass → envelope=pass"

# Gate 5 (live decision path): count>0 + PASS=false → fail
# Covers both failing AND pending checks — `gh pr checks --required`
# exits non-zero for either, and ADR-002 §2.5 says refuse on both.
out="$(envelope_run env \
        PR_NUMBER=42 REPO=o/r \
        PR_AUTHOR='github-actions[bot]' \
        PR_FILES='src/foo.ts' \
        REQUIRED_CHECKS_COUNT=2 \
        REQUIRED_CHECKS_PASS=false \
        REPO_ALLOWS_SQUASH=true REPO_ALLOWS_AUTO_MERGE=true)"
assert_contains "$out" 'envelope=fail'    "count>0 + checks not-green (failing or pending) → fail"
assert_contains "$out" 'failed-gates=5'   "gate 5 fires on pending/failing required check"

# Gate 5 (#75): UNKNOWN count (protection rule unreadable — a non-integer like a
# 403 error body) must NOT vacuously pass; the PR's required-checks result
# decides. UNKNOWN + checks green → pass.
out="$(envelope_run env \
        PR_NUMBER=42 REPO=o/r \
        PR_AUTHOR='github-actions[bot]' \
        PR_FILES='src/foo.ts' \
        REQUIRED_CHECKS_COUNT='{"status":"403"}' \
        REQUIRED_CHECKS_PASS=true \
        REPO_ALLOWS_SQUASH=true REPO_ALLOWS_AUTO_MERGE=true)"
assert_contains "$out" 'envelope=pass'    "unreadable count + checks green → pass (no shell error)"

# UNKNOWN count + checks not-green → BLOCK (must not vacuous-pass on a 403).
out="$(envelope_run env \
        PR_NUMBER=42 REPO=o/r \
        PR_AUTHOR='github-actions[bot]' \
        PR_FILES='src/foo.ts' \
        REQUIRED_CHECKS_COUNT='{"status":"403"}' \
        REQUIRED_CHECKS_PASS=false \
        REPO_ALLOWS_SQUASH=true REPO_ALLOWS_AUTO_MERGE=true)"
assert_contains "$out" 'envelope=fail'    "unreadable count + checks not-green → fail (no vacuous pass)"
assert_contains "$out" 'failed-gates=5'   "  → gate 5 blocks on unreadable+not-green"

# Gate 5 (live decision path): invalid REQUIRED_CHECKS_PASS → exit 2
ec="$(run_capture_ec env \
        PR_NUMBER=42 REPO=o/r \
        PR_AUTHOR='github-actions[bot]' PR_FILES='src/foo.ts' \
        REQUIRED_CHECKS_COUNT=1 REQUIRED_CHECKS_PASS=maybe \
        REPO_ALLOWS_SQUASH=true REPO_ALLOWS_AUTO_MERGE=true \
        bash "$ENVELOPE")"
assert_equals "$ec" "2" "invalid REQUIRED_CHECKS_PASS → exit 2"

# Gate 6: .github/ touch (loaded from fixture)
out="$(envelope_run env \
        PR_NUMBER=42 REPO=o/r \
        PR_AUTHOR='github-actions[bot]' \
        PR_FILES="$(cat "$FIXTURES/diff-github-touch.txt")" \
        REQUIRED_CHECKS_STATUS=pass \
        REPO_ALLOWS_SQUASH=true REPO_ALLOWS_AUTO_MERGE=true)"
assert_contains "$out" 'envelope=fail'                "diff-github-touch.txt → fail"
assert_contains "$out" 'failed-gates=6'               "gate 6 in failed-gates"
assert_contains "$out" '.github/: .github/workflows'  "names the .github/ violation"

# Gate 6: secret-glob hit (loaded from fixture)
out="$(envelope_run env \
        PR_NUMBER=42 REPO=o/r \
        PR_AUTHOR='github-actions[bot]' \
        PR_FILES="$(cat "$FIXTURES/diff-secret-glob.txt")" \
        REQUIRED_CHECKS_STATUS=pass \
        REPO_ALLOWS_SQUASH=true REPO_ALLOWS_AUTO_MERGE=true)"
assert_contains "$out" 'envelope=fail'             "diff-secret-glob.txt → fail"
assert_contains "$out" 'failed-gates=6'            "gate 6 fires for secret-glob"
assert_contains "$out" 'secret-glob: config/prod.sops.yaml' "names the secret-glob hit"

# Gate 6: blocklist-file glob match (loaded from fixture)
BLOCKLIST_TMP="$(mktemp)"
printf '# user-defined exclusions\nmigrations/**\n*.tf\n' > "$BLOCKLIST_TMP"
out="$(envelope_run env \
        PR_NUMBER=42 REPO=o/r \
        PR_AUTHOR='github-actions[bot]' \
        PR_FILES="$(cat "$FIXTURES/diff-blocklist-hit.txt")" \
        REQUIRED_CHECKS_STATUS=pass \
        REPO_ALLOWS_SQUASH=true REPO_ALLOWS_AUTO_MERGE=true \
        BLOCKLIST_FILE="$BLOCKLIST_TMP")"
rm -f "$BLOCKLIST_TMP"
assert_contains "$out" 'envelope=fail'      "diff-blocklist-hit.txt → fail"
assert_contains "$out" 'blocklist: main.tf' "names the blocklist hit"

# Gate 7: squash disabled
out="$(envelope_run env \
        PR_NUMBER=42 REPO=o/r \
        PR_AUTHOR='github-actions[bot]' \
        PR_FILES='src/foo.ts' \
        REQUIRED_CHECKS_STATUS=pass \
        REPO_ALLOWS_SQUASH=false REPO_ALLOWS_AUTO_MERGE=true)"
assert_contains "$out" 'envelope=fail'      "squash disabled → fail"
assert_contains "$out" 'failed-gates=7'     "gate 7 in failed-gates"
assert_contains "$out" 'allow_squash_merge=false' "names squash-merge as the missing setting"

# Gate 7: squash enabled but auto-merge disabled — common consumer
# misconfiguration (auto-merge is OFF by default on new GitHub repos).
out="$(envelope_run env \
        PR_NUMBER=42 REPO=o/r \
        PR_AUTHOR='github-actions[bot]' \
        PR_FILES='src/foo.ts' \
        REQUIRED_CHECKS_STATUS=pass \
        REPO_ALLOWS_SQUASH=true REPO_ALLOWS_AUTO_MERGE=false)"
assert_contains "$out" 'envelope=fail'           "auto-merge disabled → fail"
assert_contains "$out" 'failed-gates=7'          "gate 7 fires for auto-merge off"
assert_contains "$out" 'allow_auto_merge=false'  "names auto-merge as the missing setting"

# Gate 7: BOTH squash and auto-merge disabled → still one gate-7 entry
out="$(envelope_run env \
        PR_NUMBER=42 REPO=o/r \
        PR_AUTHOR='github-actions[bot]' \
        PR_FILES='src/foo.ts' \
        REQUIRED_CHECKS_STATUS=pass \
        REPO_ALLOWS_SQUASH=false REPO_ALLOWS_AUTO_MERGE=false)"
assert_contains "$out" 'envelope=fail'      "both repo settings off → fail"
assert_contains "$out" 'failed-gates=7'     "gate 7 consolidated (one ID even when both sub-checks fail)"
assert_contains "$out" 'allow_squash_merge=false' "names squash-merge in reasons"
assert_contains "$out" 'allow_auto_merge=false'   "names auto-merge in reasons"

# Gate 7 (CODEOWNERS): no CODEOWNERS file → vacuous pass
CO_TMP="$(mktemp)"  # used only to force-resolve to an absent path
out="$(envelope_run env \
        PR_NUMBER=42 REPO=o/r \
        PR_AUTHOR='github-actions[bot]' \
        PR_FILES='src/foo.ts' \
        REQUIRED_CHECKS_STATUS=pass \
        REPO_ALLOWS_SQUASH=true REPO_ALLOWS_AUTO_MERGE=true \
        CODEOWNERS_FILE=/no/such/codeowners)"
rm -f "$CO_TMP"
assert_contains "$out" 'envelope=pass'  "no CODEOWNERS file → pass"

# Gate 7 (CODEOWNERS): satisfied by PR author
CO_FIX="$FIXTURES/codeowners-mixed.txt"
out="$(envelope_run env \
        PR_NUMBER=42 REPO=o/r \
        PR_AUTHOR='default-owner' \
        AUTHOR_ALLOWLIST='default-owner' \
        PR_FILES='src/random.ts' \
        REQUIRED_CHECKS_STATUS=pass \
        REPO_ALLOWS_SQUASH=true REPO_ALLOWS_AUTO_MERGE=true \
        CODEOWNERS_FILE="$CO_FIX" \
        PR_REVIEWS_JSON='[]')"
assert_contains "$out" 'envelope=pass'  "PR author is the required owner → pass"

# Gate 7 (CODEOWNERS): satisfied by an approving reviewer
out="$(envelope_run env \
        PR_NUMBER=42 REPO=o/r \
        PR_AUTHOR='github-actions[bot]' \
        PR_FILES='src/random.ts' \
        REQUIRED_CHECKS_STATUS=pass \
        REPO_ALLOWS_SQUASH=true REPO_ALLOWS_AUTO_MERGE=true \
        CODEOWNERS_FILE="$CO_FIX" \
        PR_REVIEWS_JSON='[{"state":"APPROVED","user":{"login":"default-owner"}}]')"
assert_contains "$out" 'envelope=pass'  "approving reviewer is the required owner → pass"

# Gate 7 (CODEOWNERS): unsatisfied — no approvals, author is not the owner
out="$(envelope_run env \
        PR_NUMBER=42 REPO=o/r \
        PR_AUTHOR='github-actions[bot]' \
        PR_FILES='src/random.ts' \
        REQUIRED_CHECKS_STATUS=pass \
        REPO_ALLOWS_SQUASH=true REPO_ALLOWS_AUTO_MERGE=true \
        CODEOWNERS_FILE="$CO_FIX" \
        PR_REVIEWS_JSON='[]')"
assert_contains "$out" 'envelope=fail'                "CODEOWNERS unsatisfied → fail"
assert_contains "$out" 'failed-gates=7'               "gate 7 in failed-gates"
assert_contains "$out" 'CODEOWNERS not satisfied: @default-owner' "names the missing owner"

# Gate 7 (CODEOWNERS): team owners are deferred to GitHub (informational log,
# not a gate failure)
out="$(envelope_run env \
        PR_NUMBER=42 REPO=o/r \
        PR_AUTHOR='alice' \
        AUTHOR_ALLOWLIST='alice' \
        PR_FILES='src/auth/handler.ts' \
        REQUIRED_CHECKS_STATUS=pass \
        REPO_ALLOWS_SQUASH=true REPO_ALLOWS_AUTO_MERGE=true \
        CODEOWNERS_FILE="$CO_FIX" \
        PR_REVIEWS_JSON='[]')"
assert_contains "$out" 'envelope=pass'                "individual owner satisfied + team deferred → pass"
assert_contains "$out" 'codeowners-deferred-teams: @example-org/security-team' "team owner logged as deferred"

# Gate 7 (CODEOWNERS): wrong CODEOWNERS file in a path (file exists but
# no matching pattern) → no required owners → pass
CO_EMPTY="$(mktemp)"
printf '# comment only\n\n' > "$CO_EMPTY"
out="$(envelope_run env \
        PR_NUMBER=42 REPO=o/r \
        PR_AUTHOR='github-actions[bot]' \
        PR_FILES='src/random.ts' \
        REQUIRED_CHECKS_STATUS=pass \
        REPO_ALLOWS_SQUASH=true REPO_ALLOWS_AUTO_MERGE=true \
        CODEOWNERS_FILE="$CO_EMPTY" \
        PR_REVIEWS_JSON='[]')"
rm -f "$CO_EMPTY"
assert_contains "$out" 'envelope=pass'  "CODEOWNERS file empty/no matches → pass"

# Invalid REPO_ALLOWS_AUTO_MERGE → exit 2
ec="$(run_capture_ec env \
        PR_NUMBER=42 REPO=o/r \
        PR_AUTHOR='github-actions[bot]' PR_FILES='src/foo.ts' \
        REQUIRED_CHECKS_STATUS=pass \
        REPO_ALLOWS_SQUASH=true REPO_ALLOWS_AUTO_MERGE=maybe \
        bash "$ENVELOPE")"
assert_equals "$ec" "2" "invalid REPO_ALLOWS_AUTO_MERGE → exit 2"

# Multiple gates fail simultaneously → both reported
out="$(envelope_run env \
        PR_NUMBER=42 REPO=o/r \
        PR_AUTHOR='nope-human' \
        PR_FILES='.github/workflows/auto.yml' \
        REQUIRED_CHECKS_STATUS=fail \
        REPO_ALLOWS_SQUASH=false REPO_ALLOWS_AUTO_MERGE=false)"
assert_contains "$out" 'envelope=fail'      "multi-gate-fail → fail"
assert_contains "$out" 'failed-gates=1,5,6,7' "all four gates listed in order"

# Error paths
ec="$(run_capture_ec env REPO=o/r bash "$ENVELOPE")"
assert_equals "$ec" "2" "missing PR_NUMBER → exit 2"

ec="$(run_capture_ec env PR_NUMBER=1 \
        PR_AUTHOR='github-actions[bot]' PR_FILES='x' \
        REQUIRED_CHECKS_STATUS=pass REPO_ALLOWS_SQUASH=true REPO_ALLOWS_AUTO_MERGE=true \
        bash "$ENVELOPE")"
assert_equals "$ec" "2" "missing REPO → exit 2"

ec="$(run_capture_ec env PR_NUMBER=1 REPO=o/r \
        PR_AUTHOR=bot PR_FILES=x \
        REQUIRED_CHECKS_STATUS=maybe \
        REPO_ALLOWS_SQUASH=true REPO_ALLOWS_AUTO_MERGE=true \
        bash "$ENVELOPE")"
assert_equals "$ec" "2" "invalid REQUIRED_CHECKS_STATUS → exit 2"

section "adapt-opencode-result — normalize OpenCode output to canonical shape"

ADAPT_OC="$ROOT/scripts/adapt-opencode-result.sh"

# Happy path
out="$(MODEL=mistralai/codestral-2508 EXECUTION_FILE="$FIXTURES/opencode-success.json" bash "$ADAPT_OC")"
assert_contains "$out" '"is_error":false'                 "success → is_error=false"
assert_contains "$out" '"subtype":"success"'              "success → subtype=success"
assert_contains "$out" '"duration_ms":28000'              "duration = max-min event timestamp"
assert_contains "$out" '"num_turns":2'                    "num_turns = step_finish count"
assert_contains "$out" '"input_tokens":1200'              "input_tokens = sum step input"
assert_contains "$out" '"output_tokens":580'              "output_tokens = sum step output"
assert_contains "$out" '"cache_creation_input_tokens":0'  "cache_creation = sum step cache.write"
assert_contains "$out" 'opened PR #999'                   "result = final text event"

# Rate-limit fixture
out="$(MODEL=mistralai/mistral-large EXECUTION_FILE="$FIXTURES/opencode-rate-limit.json" bash "$ADAPT_OC")"
assert_contains "$out" '"is_error":true'                  "rate-limit → is_error=true"
assert_contains "$out" 'rate limit'                       "rate-limit result text has 'rate limit'"

# Auth-fail fixture
out="$(EXECUTION_FILE="$FIXTURES/opencode-auth-fail.json" bash "$ADAPT_OC")"
assert_contains "$out" '"is_error":true'                  "auth-fail → is_error=true"
assert_contains "$out" '403'                              "auth-fail result text mentions 403"

# Preflight missing-key event → canonical error result (#164)
out="$(EXECUTION_FILE="$FIXTURES/opencode-missing-key.json" MODEL=openai/gpt-oss-120b bash "$ADAPT_OC")"
assert_equals "$(printf '%s' "$out" | jq -r '.is_error')" "true" \
  "missing-key preflight → is_error true"
assert_contains "$(printf '%s' "$out" | jq -r '.result')" 'OPENROUTER_API_KEY is not set' \
  "missing-key preflight → result carries the actionable message"

# Unparseable input → bug-bucket result
TMP_BAD="$(mktemp)"
printf 'this is not json {{ bad' > "$TMP_BAD"
out="$(EXECUTION_FILE="$TMP_BAD" bash "$ADAPT_OC")"
rm -f "$TMP_BAD"
assert_contains "$out" '"is_error":true'                       "unparseable → is_error=true"
assert_contains "$out" '"subtype":"error_during_execution"'    "unparseable → error_during_execution subtype"
assert_contains "$out" 'not parseable'                         "unparseable → result names the failure"

# End-to-end: adapter output piped into classify-failure.sh produces the
# expected bucket. Verifies the new classify-failure regex (`403`,
# `provider.error`, etc.) catches what the adapter passes through.
adapter_to_classifier() {
  local fixture="$1"
  local tmp
  tmp="$(mktemp --suffix=.json)"
  MODEL=mistralai/codestral-2508 EXECUTION_FILE="$FIXTURES/$fixture" \
    bash "$ADAPT_OC" > "$tmp"
  RESULT_FILE="$tmp" bash "$ROOT/scripts/classify-failure.sh"
  rm -f "$tmp"
}
out="$(adapter_to_classifier opencode-success.json)"
assert_contains "$out" 'class=success'    "opencode success → class=success"
out="$(adapter_to_classifier opencode-rate-limit.json)"
assert_contains "$out" 'class=rate_limit' "opencode rate-limit → class=rate_limit"
out="$(adapter_to_classifier opencode-auth-fail.json)"
assert_contains "$out" 'class=api_auth'   "opencode 403 / forbidden → class=api_auth"

# Missing OPENROUTER_API_KEY is an operator problem, not a retryable one (#164)
out="$(adapter_to_classifier opencode-missing-key.json)"
assert_contains "$out" 'class=api_auth' "missing OPENROUTER_API_KEY → api_auth (no retry)"

# Error paths
ec="$(run_capture_ec env bash "$ADAPT_OC")"
assert_equals "$ec" "2" "adapter: missing EXECUTION_FILE → exit 2"
ec="$(run_capture_ec env EXECUTION_FILE=/no/such/file bash "$ADAPT_OC")"
assert_equals "$ec" "64" "adapter: unreadable EXECUTION_FILE → exit 64"

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

# OpenCode-flavored result fixtures (canonical shape, post-adapter)
out="$(RESULT_FILE="$FIXTURES/result-opencode-success.json"      bash "$CLASSIFY_FAIL")"
assert_contains "$out" 'class=success'      "result-opencode-success.json → success"

out="$(RESULT_FILE="$FIXTURES/result-opencode-rate-limit.json"   bash "$CLASSIFY_FAIL")"
assert_contains "$out" 'class=rate_limit'   "result-opencode-rate-limit.json → rate_limit"

out="$(RESULT_FILE="$FIXTURES/result-opencode-task-failure.json" bash "$CLASSIFY_FAIL")"
assert_contains "$out" 'class=task_failure' "result-opencode-task-failure.json → task_failure"

# post-run-report.sh renders the OpenCode-flavored success fixture without
# error. RENDER_ONLY skips the gh comment/label side effects.
out="$(RENDER_ONLY=1 \
        RESULT_FILE="$FIXTURES/result-opencode-success.json" \
        ISSUE_NUMBER=42 \
        WORKFLOW_RUN_URL='https://example/run/777' \
        bash "$ROOT/scripts/post-run-report.sh")"
assert_contains "$out" '0.0035'      "post-run-report includes opencode cost (\$0.0035)"
assert_contains "$out" '1,200'       "post-run-report formats input_tokens with thousands separator"
assert_contains "$out" 'success'     "post-run-report shows success outcome"

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

# Trigger label (user-applied; consumer agent.yml keys its `if:` on it)
assert_contains "$log" 'label create ai-implement --repo owner/repo' "creates ai-implement"

# Lifecycle labels (written by post-run-report.sh)
assert_contains "$log" 'label create ai:running --repo owner/repo' "creates ai:running"
assert_contains "$log" 'label create ai:done --repo owner/repo'    "creates ai:done"
assert_contains "$log" 'label create ai:failed --repo owner/repo'  "creates ai:failed"
assert_contains "$log" 'label create ctx:medium --repo owner/repo' "creates ctx:medium"
assert_contains "$log" 'label create ctx:high --repo owner/repo'   "creates ctx:high"

# Selector labels (read by classify-agent.sh — ADR-001)
assert_contains "$log" 'label create agent:claude --repo owner/repo'   "creates agent:claude"
assert_contains "$log" 'label create agent:opencode --repo owner/repo' "creates agent:opencode"

# Gate labels (review flows ADR-002/ADR-004, named by ADR-009; chaining epic #4)
assert_contains "$log" 'label create ai-review-ai-merge --repo owner/repo'    "creates ai-review-ai-merge"
assert_contains "$log" 'label create ai-review-human-merge --repo owner/repo' "creates ai-review-human-merge"
assert_contains "$log" 'label create ai-chain --repo owner/repo'        "creates ai-chain"
assert_contains "$log" 'label create ai:chain-paused --repo owner/repo' "creates ai:chain-paused"
assert_not_contains "$log" 'label create ai-auto-review'  "does not create deprecated ai-auto-review"
assert_not_contains "$log" 'label create ai-pre-preview'  "does not create deprecated ai-pre-preview"

# Outcome label (auto-review epic #3 — ADR-002 §2)
assert_contains "$log" 'label create ai:review-blocked --repo owner/repo' "creates ai:review-blocked"

# Coordination label (read/written by /enrich's concurrency lock)
assert_contains "$log" 'label create enrichment-ongoing --repo owner/repo' "creates enrichment-ongoing"

# Turn-budget override labels (read by classify-turns.sh stage 1). Without
# these the documented override is unusable in a fresh repo: `gh issue edit
# --add-label turns:160` fails outright on a label that does not exist, so
# the only way to reach a bigger budget is the heuristic. Found on #280.
assert_contains "$log" 'label create turns:50 --repo owner/repo'  "creates turns:50"
assert_contains "$log" 'label create turns:80 --repo owner/repo'  "creates turns:80"
assert_contains "$log" 'label create turns:120 --repo owner/repo' "creates turns:120"
assert_contains "$log" 'label create turns:160 --repo owner/repo' "creates turns:160"

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

# AGENT unset → OpenCode install NEVER attempted (Claude path stays zero-cost)
out="$(TOOLS="bash sh" bash "$ENSURE")"
assert_not_contains "$out" 'opencode' "AGENT unset → no opencode message at all"

# AGENT=claude → same: no opencode work
out="$(AGENT=claude TOOLS="bash sh" bash "$ENSURE")"
assert_not_contains "$out" 'opencode' "AGENT=claude → no opencode message"

# AGENT=opencode + OPENCODE_DRY_RUN → reports install plan, skips
out="$(AGENT=opencode TOOLS="bash sh" OPENCODE_DRY_RUN=1 bash "$ENSURE")"
assert_contains "$out" 'opencode'                  "AGENT=opencode → opencode probe runs"
assert_contains "$out" 'opencode install skipped (DRY_RUN)' "OPENCODE_DRY_RUN → install skipped"

# AGENT=opencode + DRY_RUN (the umbrella flag) also skips opencode install
out="$(AGENT=opencode TOOLS="bash sh" DRY_RUN=1 bash "$ENSURE")"
assert_contains "$out" 'opencode install skipped (DRY_RUN)' "umbrella DRY_RUN also skips opencode"

# AGENT=opencode + custom pinned version flows through to the message
out="$(AGENT=opencode TOOLS="bash sh" OPENCODE_DRY_RUN=1 OPENCODE_VERSION=9.9.9 bash "$ENSURE")"
assert_contains "$out" 'pinned version 9.9.9'      "OPENCODE_VERSION env overrides the pinned default"

# RUNNER-REQUIREMENTS.md mentions the same pinned version as the script default
# (catches drift between docs and code).
SCRIPT_VERSION="$(grep -oE 'OPENCODE_VERSION:-[0-9.]+' "$ENSURE" | head -1 | sed 's/.*-//')"
assert_contains "$(cat "$ROOT/docs/RUNNER-REQUIREMENTS.md")" "$SCRIPT_VERSION" \
  "RUNNER-REQUIREMENTS.md mentions the script's OPENCODE_VERSION default ($SCRIPT_VERSION)"

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

section "gh-retry — backoff classifies and retries transient failures"

GH_RETRY="$ROOT/scripts/lib/gh-retry.sh"

# Fake command: fails the first N invocations (tracked in a counter file),
# emitting a chosen stderr, then succeeds. Used to drive with_backoff.
make_flaky() {
  local script="$1" fail_times="$2" stderr_msg="$3"
  cat > "$script" <<EOF
#!/usr/bin/env bash
ctr="\${FLAKY_CTR:?}"
n=\$(cat "\$ctr" 2>/dev/null || printf 0)
n=\$((n + 1)); printf '%s' "\$n" > "\$ctr"
if (( n <= $fail_times )); then printf '%s\n' "$stderr_msg" >&2; exit 1; fi
printf 'ok\n'; exit 0
EOF
  chmod +x "$script"
}

# Retryable: secondary rate limit, succeeds on the 2nd attempt.
flaky="$(mktemp)"; ctr="$(mktemp)"; : > "$ctr"
make_flaky "$flaky" 1 "You have exceeded a secondary rate limit"
ec=0
# shellcheck disable=SC1090  # source path is intentionally dynamic (test seam)
( source "$GH_RETRY"
  FLAKY_CTR="$ctr" GH_RETRY_SLEEP_CMD=: GH_RETRY_NO_JITTER=1 with_backoff "$flaky" ) >/dev/null 2>&1 || ec=$?
assert_equals "$ec" "0" "with_backoff retries secondary-rate-limit then succeeds"
assert_equals "$(cat "$ctr")" "2" "  → exactly 2 attempts (1 fail + 1 success)"

# Non-retryable: permission error fails fast on the first attempt.
flaky2="$(mktemp)"; ctr2="$(mktemp)"; : > "$ctr2"
make_flaky "$flaky2" 5 "GitHub Actions is not permitted to create or approve pull requests"
ec=0
# shellcheck disable=SC1090
( source "$GH_RETRY"
  FLAKY_CTR="$ctr2" GH_RETRY_SLEEP_CMD=: GH_RETRY_NO_JITTER=1 with_backoff "$flaky2" ) >/dev/null 2>&1 || ec=$?
assert_equals "$ec" "1" "with_backoff fails fast on non-retryable permission error"
assert_equals "$(cat "$ctr2")" "1" "  → exactly 1 attempt (no retry)"

# Exhausts retries on a persistently retryable failure.
flaky3="$(mktemp)"; ctr3="$(mktemp)"; : > "$ctr3"
make_flaky "$flaky3" 9 "503 Server Error"
ec=0
# shellcheck disable=SC1090
( source "$GH_RETRY"
  FLAKY_CTR="$ctr3" GH_RETRY_MAX=3 GH_RETRY_SLEEP_CMD=: GH_RETRY_NO_JITTER=1 with_backoff "$flaky3" ) >/dev/null 2>&1 || ec=$?
assert_equals "$ec" "1" "with_backoff gives up after GH_RETRY_MAX attempts"
assert_equals "$(cat "$ctr3")" "3" "  → exactly GH_RETRY_MAX (3) attempts"

# gh_retryable classification.
# shellcheck disable=SC1090,SC2015  # dynamic source; A&&B||C pattern is intentional (pass/fail callbacks)
( source "$GH_RETRY"; gh_retryable "secondary rate limit" ) \
  && pass "gh_retryable: secondary rate limit → retryable" \
  || fail "gh_retryable: secondary rate limit → retryable"
# shellcheck disable=SC1090,SC2015
( source "$GH_RETRY"; gh_retryable "not permitted to create or approve pull requests" ) \
  && fail "gh_retryable: permission error → must NOT be retryable" \
  || pass "gh_retryable: permission error → not retryable"

# shellcheck disable=SC1090,SC2015  # dynamic source; intentional pass/fail via &&/||
( source "$GH_RETRY"
  gh_retryable "not permitted to create or approve pull requests and hit secondary rate limit" ) \
  && fail "gh_retryable: fatal+transient co-occurrence must be fatal" \
  || pass "gh_retryable: fatal wins over transient co-occurrence"

section "verify-or-recover-pr — make run status PR-aware"

VERIFY="$ROOT/scripts/verify-or-recover-pr.sh"

verify_run() {
  local go log; go="$(mktemp)"; log="$(mktemp)"
  GITHUB_OUTPUT="$go" GH_MOCK_LOG="$log" PATH="$MOCKS:$PATH" "$@" bash "$VERIFY" >/dev/null 2>&1 || true
  printf 'LOG<<%s>>\n' "$(tr '\n' ';' < "$log")"
  cat "$go"; rm -f "$go" "$log"
}

# Genuine agent error → no-op, pr-present=false, no gh pr create.
out="$(verify_run env ISSUE_NUMBER=42 REPO=o/r IS_ERROR=true)"
assert_contains "$out" 'pr-present=false'  "IS_ERROR=true → pr-present=false"
assert_contains "$out" 'recovered=false'   "IS_ERROR=true → recovered=false"
assert_not_contains "$out" 'pr create'     "IS_ERROR=true → never calls gh pr create"

# PR already exists → pr-present=true, no recovery.
out="$(verify_run env ISSUE_NUMBER=42 REPO=o/r IS_ERROR=false \
        PIPELINE_PRS_JSON='[{"number":17,"isDraft":true,"headRefOid":"x","author":{"login":"github-actions[bot]"}}]')"
assert_contains "$out" 'pr-present=true'    "existing PR → pr-present=true"
assert_contains "$out" 'recovered=false'    "existing PR → no recovery"
assert_not_contains "$out" 'pr create'      "existing PR → never calls gh pr create"

# No PR + recoverable branch → recovery opens the PR.
out="$(verify_run env ISSUE_NUMBER=42 REPO=o/r IS_ERROR=false DEFAULT_BRANCH=main \
        PIPELINE_PRS_JSON='[]' BRANCH=ai/issue-42 BRANCH_REMOTE_EXISTS=true BRANCH_AHEAD=true)"
assert_contains "$out" 'recovered=true'     "no PR + branch → recovery runs"
assert_contains "$out" 'pr-present=true'    "no PR + branch → pr-present after recovery"
assert_contains "$out" 'pr create'          "recovery calls gh pr create"
assert_contains "$out" 'Closes #42'         "recovery PR body closes the issue"

# No PR + no usable branch → pr-present=false, no recovery attempt.
out="$(verify_run env ISSUE_NUMBER=42 REPO=o/r IS_ERROR=false DEFAULT_BRANCH=main \
        PIPELINE_PRS_JSON='[]' BRANCH=main BRANCH_REMOTE_EXISTS=true BRANCH_AHEAD=true)"
assert_contains "$out" 'pr-present=false'   "branch == default → not recoverable"
assert_not_contains "$out" 'pr create'      "default branch → never calls gh pr create"

out="$(verify_run env ISSUE_NUMBER=42 REPO=o/r IS_ERROR=false DEFAULT_BRANCH=main \
        PIPELINE_PRS_JSON='[]' BRANCH=ai/issue-42 BRANCH_REMOTE_EXISTS=false BRANCH_AHEAD=true)"
assert_contains "$out" 'pr-present=false'   "branch not pushed → pr-present=false"

# No PR + branch, but gh pr create fails transiently then succeeds → recovered.
ctr="$(mktemp)"; : > "$ctr"
out="$(verify_run env ISSUE_NUMBER=42 REPO=o/r IS_ERROR=false DEFAULT_BRANCH=main \
        PIPELINE_PRS_JSON='[]' BRANCH=ai/issue-42 BRANCH_REMOTE_EXISTS=true BRANCH_AHEAD=true \
        GH_RETRY_SLEEP_CMD=: GH_RETRY_NO_JITTER=1 \
        GH_MOCK_PR_CREATE_FAIL_TIMES=1 GH_MOCK_PR_CREATE_CTR="$ctr" \
        GH_MOCK_PR_CREATE_STDERR='secondary rate limit')"
assert_contains "$out" 'recovered=true'     "transient pr-create failure → retried → recovered"

# No PR + branch, but gh pr create fails permanently (permission) → not recovered.
ctr2="$(mktemp)"; : > "$ctr2"
out="$(verify_run env ISSUE_NUMBER=42 REPO=o/r IS_ERROR=false DEFAULT_BRANCH=main \
        PIPELINE_PRS_JSON='[]' BRANCH=ai/issue-42 BRANCH_REMOTE_EXISTS=true BRANCH_AHEAD=true \
        GH_RETRY_SLEEP_CMD=: GH_RETRY_NO_JITTER=1 \
        GH_MOCK_PR_CREATE_FAIL_TIMES=9 GH_MOCK_PR_CREATE_CTR="$ctr2" \
        GH_MOCK_PR_CREATE_STDERR='not permitted to create or approve pull requests')"
assert_contains "$out" 'pr-present=false'   "permanent pr-create failure → pr-present=false"
assert_contains "$out" 'recovered=false'    "permanent pr-create failure → recovered=false"

# No PR + branch, but gh pr create fails with "already exists" (search-index lag)
# → pr-present=true (the PR already existed), recovered=false.
ctr3_ae="$(mktemp)"; : > "$ctr3_ae"
out="$(verify_run env ISSUE_NUMBER=42 REPO=o/r IS_ERROR=false DEFAULT_BRANCH=main \
        PIPELINE_PRS_JSON='[]' BRANCH=ai/issue-42 BRANCH_REMOTE_EXISTS=true BRANCH_AHEAD=true \
        GH_RETRY_SLEEP_CMD=: GH_RETRY_NO_JITTER=1 \
        GH_MOCK_PR_CREATE_FAIL_TIMES=9 GH_MOCK_PR_CREATE_CTR="$ctr3_ae" \
        GH_MOCK_PR_CREATE_STDERR='a pull request for branch "ai/issue-42" into branch "main" already exists')"
assert_contains "$out" 'pr-present=true'   "gh pr create 'already exists' (search lag) → pr-present=true"
assert_contains "$out" 'recovered=false'   "  → not counted as recovered (it pre-existed)"

# Missing required env → exit 2.
ec="$(run_capture_ec env REPO=o/r IS_ERROR=false bash "$VERIFY")"
assert_equals "$ec" "2" "missing ISSUE_NUMBER → exit 2"

# --- setup/link-partials.sh -------------------------------------------------

section "setup/link-partials.sh"

LINK_PARTIALS="$ROOT/setup/link-partials.sh"

# Fresh machine: empty HOME -> block created, all three partials imported.
lp_home1="$(mktemp -d)"
env HOME="$lp_home1" bash "$LINK_PARTIALS" --no-sync >/dev/null 2>&1
lp_md1="$(cat "$lp_home1/.claude/CLAUDE.md")"
assert_contains "$lp_md1" \
  "<!-- BEGIN provisioned:claude-partials (managed by setup/link-partials.sh) -->" \
  "fresh HOME -> managed block created"
assert_contains "$lp_md1" \
  "@~/repos/github/freaxnx01/public/agent-workflow/partials/task-checklist.md" \
  "fresh HOME -> task-checklist imported"
assert_contains "$lp_md1" \
  "@~/repos/github/freaxnx01/public/agent-workflow/partials/skill-authoring.md" \
  "fresh HOME -> skill-authoring imported"
assert_contains "$lp_md1" \
  "@~/repos/github/freaxnx01/public/agent-workflow/partials/subagent-driven-default.md" \
  "fresh HOME -> subagent-driven-default imported"
assert_not_contains "$lp_md1" "partials/README.md" \
  "fresh HOME -> README.md is not imported"

# Idempotency: two consecutive runs leave CLAUDE.md byte-identical.
cp "$lp_home1/.claude/CLAUDE.md" "$lp_home1/snapshot"
env HOME="$lp_home1" bash "$LINK_PARTIALS" --no-sync >/dev/null 2>&1
if diff -q "$lp_home1/snapshot" "$lp_home1/.claude/CLAUDE.md" >/dev/null 2>&1; then
  pass "re-run is byte-idempotent"
else
  fail "re-run is byte-idempotent" \
    "$(diff "$lp_home1/snapshot" "$lp_home1/.claude/CLAUDE.md" | head -5)"
fi

# Migration: seeded legacy block + a stray config/claude line, plus unrelated
# user content that must survive verbatim and in order.
lp_home2="$(mktemp -d)"
mkdir -p "$lp_home2/.claude"
cat > "$lp_home2/.claude/CLAUDE.md" <<'LP_EOF'
# My personal instructions

Always be concise.

<!-- BEGIN provisioned:claude-partials (managed by setup/00-claude-partials.sh) -->
@~/repos/github/freaxnx01/public/config/claude/task-checklist.md
@~/repos/github/freaxnx01/public/config/claude/skill-authoring.md
<!-- END provisioned:claude-partials -->

## A later section

@~/repos/github/freaxnx01/public/config/claude/subagent-driven-default.md

Trailing user note.
LP_EOF
env HOME="$lp_home2" bash "$LINK_PARTIALS" --no-sync >/dev/null 2>&1
lp_md2="$(cat "$lp_home2/.claude/CLAUDE.md")"

assert_not_contains "$lp_md2" "config/claude" \
  "migration -> zero config/claude references remain"
assert_not_contains "$lp_md2" "00-claude-partials.sh" \
  "migration -> legacy marker swept"
assert_equals "$(grep -c 'BEGIN provisioned:claude-partials' "$lp_home2/.claude/CLAUDE.md")" "1" \
  "migration -> exactly one managed block"
assert_contains "$lp_md2" \
  "@~/repos/github/freaxnx01/public/agent-workflow/partials/task-checklist.md" \
  "migration -> new paths present"

# Non-destructive: unrelated user content survives, order preserved.
assert_contains "$lp_md2" "# My personal instructions" "migration -> user heading survives"
assert_contains "$lp_md2" "Always be concise."         "migration -> user prose survives"
assert_contains "$lp_md2" "## A later section"         "migration -> later section survives"
assert_contains "$lp_md2" "Trailing user note."        "migration -> trailing note survives"
lp_seq="$(grep -o 'My personal instructions\|A later section\|Trailing user note' \
  "$lp_home2/.claude/CLAUDE.md" | tr '\n' '|')"
assert_equals "$lp_seq" "My personal instructions|A later section|Trailing user note|" \
  "migration -> user content order preserved"

# Guard: an empty partials/ must hard-fail, never report success having copied nothing.
lp_scratch="$(mktemp -d)"
mkdir -p "$lp_scratch/setup" "$lp_scratch/partials"
cp "$LINK_PARTIALS" "$lp_scratch/setup/link-partials.sh"
lp_home3="$(mktemp -d)"
lp_ec="$(run_capture_ec env HOME="$lp_home3" bash "$lp_scratch/setup/link-partials.sh" --no-sync)"
assert_equals "$lp_ec" "1" "empty partials/ -> hard fail, not silent success"

# --- setup/link-commands.sh --------------------------------------------------

section "setup/link-commands.sh"

LINK_COMMANDS="$ROOT/setup/link-commands.sh"

# link-commands.sh resolves its source from $HOME (not BASH_SOURCE), so a scratch
# HOME needs the canonical path to point back at the real checkout.
lc_home="$(mktemp -d)"
mkdir -p "$lc_home/repos/github/freaxnx01/public"
ln -s "$ROOT" "$lc_home/repos/github/freaxnx01/public/agent-workflow"

# Baseline install.
env HOME="$lc_home" bash "$LINK_COMMANDS" --no-sync >/dev/null

# Seed a stale command file that no longer exists in the repo's commands/ tree —
# simulating a machine that installed an older revision before some commands
# were removed (e.g. the gh:/fj: -> forge-agnostic merge, #198/#199). Recording
# it in the manifest too is what marks it as "this installer's own prior work"
# rather than a foreign file — pruning is scoped to the manifest, never to
# "any *.md under DEST_DIR" (see the scope-guard test below).
mkdir -p "$lc_home/.claude/commands/gh"
echo "stale content" > "$lc_home/.claude/commands/gh/stale-removed-command.md"
echo "gh/stale-removed-command.md" >> "$lc_home/.claude/.agent-workflow-commands-manifest"

# Re-running the installer must prune it, not just leave it alongside the
# current set — a stale command left installed silently shadows nothing (it's
# just extra), but for a removed/renamed command it means the old, superseded
# behavior keeps working forever instead of actually going away.
env HOME="$lc_home" bash "$LINK_COMMANDS" --no-sync >/dev/null
assert_equals "$([ -e "$lc_home/.claude/commands/gh/stale-removed-command.md" ] && echo yes || echo no)" \
  "no" "re-install prunes a command file no longer in source"

# Non-destructive: real, current commands from the repo survive re-install.
assert_equals "$([ -e "$lc_home/.claude/commands/issues.md" ] && echo yes || echo no)" \
  "yes" "re-install -> current command file still present"

# The same pruning must catch a stale command left over from a --link install
# (a symlink, and a dangling one at that once its source file is gone) — a
# plain `find -type f` silently skips broken symlinks, so this needs its own
# scratch HOME rather than reusing lc_home's copy-mode state.
lc_link_home="$(mktemp -d)"
mkdir -p "$lc_link_home/repos/github/freaxnx01/public"
ln -s "$ROOT" "$lc_link_home/repos/github/freaxnx01/public/agent-workflow"
env HOME="$lc_link_home" bash "$LINK_COMMANDS" --no-sync --link >/dev/null
mkdir -p "$lc_link_home/.claude/commands/fj"
ln -sfn /nonexistent "$lc_link_home/.claude/commands/fj/stale-removed-command.md"
echo "fj/stale-removed-command.md" >> "$lc_link_home/.claude/.agent-workflow-commands-manifest"
env HOME="$lc_link_home" bash "$LINK_COMMANDS" --no-sync --link >/dev/null
assert_equals "$([ -L "$lc_link_home/.claude/commands/fj/stale-removed-command.md" ] && echo yes || echo no)" \
  "no" "re-install (--link) prunes a dangling stale symlink"

# Scope guard: pruning must never touch a file this installer never placed.
# ~/.claude/commands/ is Claude Code's general user-commands directory, not
# exclusively agent-workflow's — a file a user authored by hand (or another
# tool installed) must survive, even though it's not part of the current
# agent-workflow commands/ tree.
lc_foreign_home="$(mktemp -d)"
mkdir -p "$lc_foreign_home/repos/github/freaxnx01/public"
ln -s "$ROOT" "$lc_foreign_home/repos/github/freaxnx01/public/agent-workflow"
env HOME="$lc_foreign_home" bash "$LINK_COMMANDS" --no-sync >/dev/null
mkdir -p "$lc_foreign_home/.claude/commands/my-own-namespace"
echo "not agent-workflow's" > "$lc_foreign_home/.claude/commands/my-own-namespace/personal.md"
env HOME="$lc_foreign_home" bash "$LINK_COMMANDS" --no-sync >/dev/null
assert_equals "$([ -e "$lc_foreign_home/.claude/commands/my-own-namespace/personal.md" ] && echo yes || echo no)" \
  "yes" "re-install never prunes a file this installer didn't place"

# --- setup/bootstrap.sh -----------------------------------------------------

section "setup/bootstrap.sh"

BOOTSTRAP="$ROOT/setup/bootstrap.sh"

# link-commands.sh resolves its source from $HOME (not BASH_SOURCE), so a scratch
# HOME needs the canonical path to point back at the real checkout.
bs_home="$(mktemp -d)"
mkdir -p "$bs_home/repos/github/freaxnx01/public"
ln -s "$ROOT" "$bs_home/repos/github/freaxnx01/public/agent-workflow"

# Default (no flags): commands are COPIED (link-commands.sh's default since ADR-005).
bs_out="$(env HOME="$bs_home" bash "$BOOTSTRAP" --no-sync 2>&1)"
assert_contains "$bs_out" "copied" "bootstrap default -> commands copied"
assert_contains "$bs_out" "normalizing" "bootstrap -> link-partials step ran"
assert_contains "$bs_out" "installing hooks" "bootstrap -> link-hooks step ran"
assert_contains "$bs_out" "installing agent-workflow skills" "bootstrap -> link-skills step ran"
assert_contains "$(cat "$bs_home/.claude/CLAUDE.md")" \
  "@~/repos/github/freaxnx01/public/agent-workflow/partials/task-checklist.md" \
  "bootstrap -> partials landed in CLAUDE.md"

# Argument passthrough: --link must survive bootstrap -> link-commands.sh and
# flip the observable install mode. This is the channel --copy also travels.
bs_home2="$(mktemp -d)"
mkdir -p "$bs_home2/repos/github/freaxnx01/public"
ln -s "$ROOT" "$bs_home2/repos/github/freaxnx01/public/agent-workflow"
bs_out2="$(env HOME="$bs_home2" bash "$BOOTSTRAP" --no-sync --link 2>&1)"
assert_contains "$bs_out2" "linked" "--link passes through bootstrap to link-commands"
# NOTE: link-hooks.sh always copies (hooks are never symlinked -- see its own
# header comment), so it unconditionally prints "  copied  handoff-resume.sh"
# regardless of --link. A raw "  copied  " substring check over the FULL
# bootstrap output would therefore always fail, hook step included. Assert on
# link-commands.sh's own mode banner ("(copy)" vs "(link)") instead, which is
# the precise signal for "commands were not copied".
assert_not_contains "$bs_out2" "(copy)" "--link -> nothing copied"

# --copy is accepted end-to-end (it is already the default, so it is a no-op --
# but the flag must not error, since old notes and the deprecation stub pass it).
bs_home3="$(mktemp -d)"
mkdir -p "$bs_home3/repos/github/freaxnx01/public"
ln -s "$ROOT" "$bs_home3/repos/github/freaxnx01/public/agent-workflow"
bs_ec="$(run_capture_ec env HOME="$bs_home3" bash "$BOOTSTRAP" --no-sync --copy)"
assert_equals "$bs_ec" "0" "--copy accepted end-to-end"

section "link-commands — installs every scripts/lib helper, not just detect-forge"

# Regression: the installer hardcoded a single LIB_SRC/LIB_DEST pair, so
# parse-enrich-args.sh shipped in the repo but never reached ~/.claude and
# /enrich's argument parsing failed with "No such file or directory".
LINKER="$ROOT/setup/link-commands.sh"
fake_home="$(mktemp -d)"

HOME="$fake_home" REPO_DIR="$ROOT" bash "$LINKER" --no-sync >/dev/null 2>&1 || true

installed_dir="$fake_home/.claude/scripts/lib"
for lib in "$ROOT"/scripts/lib/*.sh; do
  name="$(basename "$lib")"
  if [[ -f "$installed_dir/$name" ]]; then
    pass "installed scripts/lib/$name"
  else
    fail "installed scripts/lib/$name" "file missing under \$HOME/.claude/scripts/lib"
  fi
done

# The two helpers user-level commands actually source must be byte-identical.
for name in detect-forge.sh parse-enrich-args.sh; do
  if cmp -s "$ROOT/scripts/lib/$name" "$installed_dir/$name"; then
    pass "  → $name matches the repo copy byte-for-byte"
  else
    fail "  → $name matches the repo copy byte-for-byte" "content differs or file absent"
  fi
done

rm -rf "$fake_home"

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
