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

section "ensure-issue-labels — issues 5 label-create calls under gh mock"

LABELS_LOG="$(mktemp)"
PATH="$MOCKS:$PATH" \
GH_MOCK_LOG="$LABELS_LOG" \
REPO=owner/repo \
  bash "$ROOT/scripts/ensure-issue-labels.sh" >/dev/null

log="$(cat "$LABELS_LOG")"
rm -f "$LABELS_LOG"

assert_contains "$log" 'label create ai:running --repo owner/repo' "creates ai:running"
assert_contains "$log" 'label create ai:done --repo owner/repo'    "creates ai:done"
assert_contains "$log" 'label create ai:failed --repo owner/repo'  "creates ai:failed"
assert_contains "$log" 'label create ctx:medium --repo owner/repo' "creates ctx:medium"
assert_contains "$log" 'label create ctx:high --repo owner/repo'   "creates ctx:high"

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
