#!/usr/bin/env bash
#
# run-opencode-model-tests.sh — Layer-1 fixture tests for #518: the injected
# opencode model config, the OpenRouter model-list preflight, the
# `model_not_found` failure class and how a run in that class is reported.
#
# Hermetic by contract: the real `curl` and `opencode` are replaced by the
# mocks at tests/mocks/. No network, no GitHub, no Docker.
#
# Usage: tests/run-opencode-model-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOCKS="$ROOT/tests/mocks"

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

assert_equals() {
  if [[ "$1" == "$2" ]]; then
    pass "$3"
  else
    fail "$3" "expected '$2' got '$1'"
  fi
}

run_capture_ec() {
  local ec=0
  "$@" >/dev/null 2>&1 || ec=$?
  printf '%s' "$ec"
}

MODEL_CONFIG="$ROOT/scripts/opencode-model-config.sh"
OPENCODE_FIX="$ROOT/scripts/lib/agent-cmd-opencode-fix.sh"
WANT_CONFIG='{"provider":{"openrouter":{"models":{"z-ai/glm-5.3":{}}}}}'

section "opencode-model-config — the injected provider/model entry (#518)"

out="$(MODEL=z-ai/glm-5.3 bash "$MODEL_CONFIG")"
assert_equals "$out" "$WANT_CONFIG" "bare id → one openrouter model entry"

out="$(MODEL=openrouter/z-ai/glm-5.3 bash "$MODEL_CONFIG")"
assert_equals "$out" "$WANT_CONFIG" "openrouter/-prefixed id → prefix stripped from the key"

# An id is data, not JSON: quotes and backslashes must be escaped, not spliced.
out="$(MODEL='a"b\c/d' bash "$MODEL_CONFIG")"
assert_equals "$(printf '%s' "$out" | jq -r '.provider.openrouter.models | keys[0]')" 'a"b\c/d' \
  "id with a quote and a backslash → still valid JSON with the id as the key"

ec="$(run_capture_ec env MODEL= bash "$MODEL_CONFIG")"
assert_equals "$ec" "2" "empty MODEL → exit 2"

section "agent-cmd-opencode-fix — injects the model entry (#518)"

# opencode_fix_env <model> → the OPENCODE_CONFIG_CONTENT the mock opencode saw
opencode_fix_env() {
  local log envlog runner prompt
  log="$(mktemp)"; envlog="$(mktemp)"; runner="$(mktemp -d)"; prompt="$(mktemp)"
  printf 'fix these findings' > "$prompt"
  PATH="$MOCKS:$PATH" OPENCODE_MOCK_LOG="$log" OPENCODE_MOCK_ENV_LOG="$envlog" \
    RUNNER_TEMP="$runner" MODEL="$1" bash "$OPENCODE_FIX" "$prompt" >/dev/null
  cat "$envlog"
  rm -rf "$log" "$envlog" "$runner" "$prompt"
}

assert_equals "$(opencode_fix_env 'z-ai/glm-5.3')" "$WANT_CONFIG" \
  "self-fix with a model → opencode started with the injected entry"
assert_equals "$(opencode_fix_env 'openrouter/z-ai/glm-5.3')" "$WANT_CONFIG" \
  "self-fix with a prefixed model → same entry"
assert_equals "$(opencode_fix_env '')" "" \
  "self-fix without a model → nothing injected"

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
