#!/usr/bin/env bash
#
# run-pipeline-alarm-tests.sh — Layer-1 fixture tests for the pipeline
# credit/key-limit alarm (#517): the `out_of_credits` failure class, the paused
# run report, the alarm issue, the ntfy push, the dispatch gate, the resume
# script and the OpenRouter budget early warning.
#
# Hermetic by contract: the real `gh` and `curl` are replaced by the mocks at
# tests/mocks/. No network, no GitHub, no Docker.
#
# Usage: tests/run-pipeline-alarm-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Layer-1 tests are hermetic by contract, which has to include the *ambient*
# environment: on a GitHub Actions runner GITHUB_REPOSITORY is always set and
# scripts under test fall back to it, so a "missing REPO -> exit 2" assertion
# passes locally and fails in CI (#354). Same list as run-script-tests.sh.
unset GITHUB_REPOSITORY GITHUB_OUTPUT GITHUB_ACTIONS GITHUB_TOKEN \
      REPO ISSUE_BODY ISSUE_LABELS ISSUE_JSON ISSUE_COMMENTS_JSON \
      PR_NUMBER FIX_AGENT FIX_MODEL MODEL

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
  return 0
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

# classify_text <result text> -> the class classify-failure.sh assigns to a
# failed run whose `.result` is that text.
classify_text() {
  local f out
  f="$(mktemp)"
  jq -n --arg t "$1" \
    '{is_error:true,subtype:"error_during_execution",num_turns:3,result:$t}' > "$f"
  out="$(RESULT_FILE="$f" bash "$ROOT/scripts/classify-failure.sh" | sed -n 's/^class=//p')"
  rm -f "$f"
  printf '%s' "$out"
}

# --- Task 1: classify out_of_credits ---------------------------------------

section "classify-failure — out_of_credits"

# shellcheck disable=SC2016  # the `$10.09` is OpenRouter's literal error text,
# not a variable — single quotes are exactly the point.
assert_equals "$(classify_text 'HTTP 403: Key limit exceeded (monthly limit). $10.09 of $10.00 used; resets 2026-11-01')" \
  out_of_credits "403 key limit exceeded"
assert_equals "$(classify_text 'API Error 402: This request would exceed your available credits')" \
  out_of_credits "402 would exceed available credits"
assert_equals "$(classify_text 'Insufficient credits. Add more using https://openrouter.ai/settings/credits')" \
  out_of_credits "insufficient credits"
assert_equals "$(classify_text '429 rate_limit_error: exceed your account rate limit')" \
  rate_limit "plain 429 stays rate_limit"
assert_equals "$(classify_text '401 invalid api key')" \
  api_auth "401 stays api_auth"
assert_equals "$(classify_text '503 service unavailable')" \
  transient "5xx stays transient"

section "pause-reasons — the pause-class table"

pr_lib="$ROOT/scripts/lib/pause-reasons.sh"
if [[ -r "$pr_lib" ]]; then
  # shellcheck source=scripts/lib/pause-reasons.sh
  source "$pr_lib"
  if is_pause_class out_of_credits; then
    pass "out_of_credits is a pause class"
  else
    fail "out_of_credits is a pause class"
  fi
  if is_pause_class bug; then
    fail "bug is not a pause class"
  else
    pass "bug is not a pause class"
  fi
  assert_equals "$(pause_reason_for_class out_of_credits)" out_of_credits "reason id for the class"
  assert_contains "$(pause_title out_of_credits)" 'credits' "alarm title names credits"
  assert_contains "$(pause_hint out_of_credits)" 'https://openrouter.ai/settings/keys' "hint links key settings"
else
  fail "scripts/lib/pause-reasons.sh exists" "not found"
fi

section "retry-dispatch — a pause class never retries"

out="$(CLASS=out_of_credits ATTEMPT=1 ISSUE_NUMBER=1 REPO=o/r DRY_RUN=1 \
  bash "$ROOT/scripts/retry-dispatch.sh" 2>&1)"
assert_contains "$out" 'decision=stop'   "out_of_credits -> stop"
assert_contains "$out" 'delay-seconds=0' "out_of_credits -> no delay"
assert_not_contains "$out" 'unknown CLASS' "out_of_credits is a known class"

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
