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
FIXTURES="$ROOT/tests/fixtures"
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

section "check-opencode-model — OpenRouter model-list preflight (#518)"

OC_MODEL="$ROOT/scripts/check-opencode-model.sh"
OC_MODEL_OUT="$(mktemp)"

# model_check <model> [extra env assignments...] → exit code; OUTPUT_FILE is
# reset first, stdout+stderr land in $OC_MODEL_LOG.
OC_MODEL_LOG="$(mktemp)"
model_check() {
  local model="$1"; shift
  local ec=0
  : > "$OC_MODEL_OUT"
  env PATH="$MOCKS:$PATH" CURL_MOCK_FIXTURE="$FIXTURES/openrouter-models.json" \
    OUTPUT_FILE="$OC_MODEL_OUT" MODEL="$model" "$@" bash "$OC_MODEL" >"$OC_MODEL_LOG" 2>&1 || ec=$?
  printf '%s' "$ec"
}
out_bytes() { wc -c < "$OC_MODEL_OUT" | tr -d ' '; }

assert_equals "$(model_check z-ai/glm-5.3)" "0" "listed id → exit 0"
assert_equals "$(out_bytes)" "0" "listed id → OUTPUT_FILE untouched"
assert_equals "$(model_check openrouter/z-ai/glm-5.3)" "0" "openrouter/-prefixed listed id → exit 0"
assert_equals "$(model_check meta-llama/llama-4-maverick:free)" "0" "listed :free variant → exit 0"
assert_equals "$(model_check z-ai/glm-5.3:nitro)" "0" "unlisted routing suffix on a listed base id → exit 0"

assert_equals "$(model_check z-ai/glm-5.33)" "65" "unlisted id → exit 65"
event="$(cat "$OC_MODEL_OUT")"
assert_equals "$(printf '%s' "$event" | jq -r '.type')" "error" "unlisted id → an opencode error event"
assert_equals "$(printf '%s' "$event" | jq -r '.error.name')" "ModelNotFoundError" "unlisted id → error.name"
msg="$(printf '%s' "$event" | jq -r '.error.data.message')"
# shellcheck disable=SC2016  # the backticks are the message's markdown code
# span around the id, not command substitution — single quotes are the point.
assert_contains "$msg" 'Model not found: `z-ai/glm-5.33`' "unlisted id → message starts with the classifier's phrase and names the id"
assert_contains "$msg" 'default-model' "unlisted id → message names the input to fix"
assert_contains "$msg" 'model:' "unlisted id → message names the label to fix"
assert_contains "$msg" 'https://openrouter.ai/models' "unlisted id → message links the id list"
assert_contains "$(cat "$OC_MODEL_LOG")" '::error::' "unlisted id → an error annotation"

# Exact line match, never substring: glm-5 is a prefix of the listed glm-5.3.
assert_equals "$(model_check z-ai/glm-5)" "65" "prefix of a listed id → exit 65"
assert_equals "$(model_check z-ai/glm-9:free)" "65" "suffix on an unlisted base id → exit 65"

# Fail open: an unreadable list must not stop a run injection lets start.
curl_log="$(mktemp)"
assert_equals "$(model_check z-ai/glm-5.33 CURL_MOCK_FAIL=1 CURL_MOCK_LOG="$curl_log")" "0" \
  "model list unreachable → exit 0 (fail open)"
assert_equals "$(out_bytes)" "0" "model list unreachable → OUTPUT_FILE untouched"
assert_contains "$(cat "$OC_MODEL_LOG")" '::warning::' "model list unreachable → a warning annotation"
assert_equals "$(wc -l < "$curl_log" | tr -d ' ')" "2" "model list unreachable → fetched twice (one retry)"

assert_equals "$(model_check z-ai/glm-5.33 CURL_MOCK_FIXTURE="$FIXTURES/openrouter-models-malformed.json")" "0" \
  "body that is not a model list → exit 0 (fail open)"
assert_contains "$(cat "$OC_MODEL_LOG")" '::warning::' "body that is not a model list → a warning annotation"

# The list is public: no credential on the request, none in the output.
: > "$curl_log"
model_check z-ai/glm-5.33 OPENROUTER_API_KEY=sk-or-supersecret CURL_MOCK_LOG="$curl_log" >/dev/null
assert_not_contains "$(cat "$curl_log")" 'Authorization' "request carries no Authorization header"
assert_not_contains "$(cat "$curl_log" "$OC_MODEL_LOG" "$OC_MODEL_OUT")" 'sk-or-supersecret' "key value never appears"
assert_contains "$(cat "$curl_log")" 'https://openrouter.ai/api/v1/models' "default URL is OpenRouter's public model list"

ec="$(run_capture_ec env MODEL=z-ai/glm-5.3 bash "$OC_MODEL")"
assert_equals "$ec" "2" "missing OUTPUT_FILE → exit 2"
ec="$(run_capture_ec env OUTPUT_FILE="$OC_MODEL_OUT" bash "$OC_MODEL")"
assert_equals "$ec" "2" "missing MODEL → exit 2"

rm -f "$OC_MODEL_OUT" "$OC_MODEL_LOG" "$curl_log"

section "classify-failure — model_not_found (#518)"

CLASSIFY_FAIL="$ROOT/scripts/classify-failure.sh"
ADAPT_OC="$ROOT/scripts/adapt-opencode-result.sh"

# classify_result_text <num_turns> <result text> → the class line
classify_result_text() {
  local tmp out
  tmp="$(mktemp --suffix=.json)"
  jq -nc --argjson turns "$1" --arg text "$2" \
    '{type:"result",subtype:"error_during_execution",is_error:true,duration_ms:0,
      num_turns:$turns,total_cost_usd:0,session_id:"s",result:$text,
      usage:{input_tokens:0,output_tokens:0,cache_creation_input_tokens:0,cache_read_input_tokens:0}}' > "$tmp"
  out="$(RESULT_FILE="$tmp" bash "$CLASSIFY_FAIL")"
  rm -f "$tmp"
  printf '%s' "$out"
}

assert_equals "$(RESULT_FILE="$FIXTURES/result-opencode-model-not-found.json" bash "$CLASSIFY_FAIL")" \
  'class=model_not_found' "preflight result fixture → model_not_found"

assert_equals "$(classify_result_text 0 'Model not found: openrouter/z-ai/glm-5.3. Did you mean: z-ai/glm-4-32b, z-ai/glm-4.5, z-ai/glm-4.5-air?')" \
  'class=model_not_found' "opencode's own 0-turn error → model_not_found"
assert_equals "$(classify_result_text 0 'ProviderModelNotFoundError')" \
  'class=model_not_found' "bare error name at 0 turns → model_not_found"

# The message carries the model id, and the buckets below match bare digit
# runs. An id must never choose the class.
# shellcheck disable=SC2016  # the backticks are the message's markdown code
# spans around the id, not command substitution.
assert_equals "$(classify_result_text 0 'Model not found: `mistralai/mistral-small-2503` is not on the list')" \
  'class=model_not_found' "id containing 503 → model_not_found, not transient"
# shellcheck disable=SC2016
assert_equals "$(classify_result_text 0 'Model not found: `foo/bar-429` is not on the list')" \
  'class=model_not_found' "id containing 429 → model_not_found, not rate_limit"
# shellcheck disable=SC2016
assert_equals "$(classify_result_text 0 'Model not found: `foo/bar-401` is not on the list')" \
  'class=model_not_found' "id containing 401 → model_not_found, not api_auth"

assert_equals "$(classify_result_text 3 'Model not found: openrouter/z-ai/glm-5.3.')" \
  'class=bug' "same text after real turns → still bug"

# The whole chain: preflight event → adapter → classifier.
chain_out="$(mktemp)"; chain_result="$(mktemp --suffix=.json)"
env PATH="$MOCKS:$PATH" CURL_MOCK_FIXTURE="$FIXTURES/openrouter-models.json" \
  OUTPUT_FILE="$chain_out" MODEL=z-ai/glm-5.33 bash "$ROOT/scripts/check-opencode-model.sh" >/dev/null 2>&1 || true
EXECUTION_FILE="$chain_out" MODEL=z-ai/glm-5.33 bash "$ADAPT_OC" > "$chain_result"
assert_equals "$(jq -r '.num_turns' "$chain_result")" "0" "preflight event → adapter → 0 turns"
assert_equals "$(RESULT_FILE="$chain_result" bash "$CLASSIFY_FAIL")" 'class=model_not_found' \
  "preflight event → adapter → classifier → model_not_found"
rm -f "$chain_out" "$chain_result"

# The #164 missing-key preflight must keep its own class.
missing_key="$(mktemp --suffix=.json)"
EXECUTION_FILE="$FIXTURES/opencode-missing-key.json" MODEL=z-ai/glm-5.3 bash "$ADAPT_OC" > "$missing_key"
assert_equals "$(RESULT_FILE="$missing_key" bash "$CLASSIFY_FAIL")" 'class=api_auth' \
  "missing OPENROUTER_API_KEY → still api_auth"
rm -f "$missing_key"

section "model_not_found is alert-only: no retry, no pause, not an attempt (#518)"

retry_err="$(mktemp)"
out="$(CLASS=model_not_found ATTEMPT=1 ISSUE_NUMBER=42 REPO=o/r DRY_RUN=1 \
        bash "$ROOT/scripts/retry-dispatch.sh" 2>"$retry_err")"
assert_contains "$out" 'decision=stop' "retry-dispatch: model_not_found → stop"
assert_not_contains "$(cat "$retry_err")" 'unknown CLASS' "retry-dispatch knows the class"
rm -f "$retry_err"

# shellcheck source=scripts/lib/pause-reasons.sh
source "$ROOT/scripts/lib/pause-reasons.sh"
if is_pause_class model_not_found; then
  fail "model_not_found is not a pause class" "pause-reasons.sh lists it"
else
  pass "model_not_found is not a pause class"
fi

report="$(RENDER_ONLY=1 RESULT_FILE="$FIXTURES/result-opencode-model-not-found.json" \
          ISSUE_NUMBER=42 WORKFLOW_RUN_URL=https://example/run/test \
          FAILURE_CLASS=model_not_found MODEL=z-ai/glm-9 AGENT=opencode \
          bash "$ROOT/scripts/post-run-report.sh")"
assert_contains "$report" '## ai-implement run' "report keeps the run heading"
assert_contains "$report" ':x: failed: model_not_found' "report names the class as the outcome"
# shellcheck disable=SC2016  # markdown code span around the model id again
assert_contains "$report" 'Model `z-ai/glm-9` is not on OpenRouter' "report names the model"
assert_contains "$report" 'default-model' "report names the input to fix"
assert_contains "$report" 'https://openrouter.ai/models' "report links the id list"
assert_contains "$report" 'LABELS: ai:failed' "report stamps ai:failed"

# Every other class renders exactly as before: no fix block.
other="$(RENDER_ONLY=1 RESULT_FILE="$FIXTURES/result-opencode-model-not-found.json" \
         ISSUE_NUMBER=42 WORKFLOW_RUN_URL=https://example/run/test \
         FAILURE_CLASS=bug MODEL=z-ai/glm-9 bash "$ROOT/scripts/post-run-report.sh")"
assert_not_contains "$other" 'is not on OpenRouter' "another class → no model fix block"

# "Not an attempt" is check-attempt-cap's non-start rule: 0 turns AND $0.00.
comment="${report%%$'\n---\nLABELS:'*}"
cap="$(ISSUE_COMMENTS_JSON="$(jq -nc --arg b "$comment" '[{body:$b}]')" \
       ISSUE_NUMBER=42 REPO=o/r DRY_RUN=1 bash "$ROOT/scripts/check-attempt-cap.sh")"
assert_contains "$cap" 'attempt=1' "a model_not_found report does not consume an attempt"
assert_contains "$cap" 'non-starts=1' "it is counted as a non-start"
assert_contains "$cap" 'proceed=true' "and the next dispatch proceeds"

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
