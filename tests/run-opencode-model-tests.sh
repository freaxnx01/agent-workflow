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
      PR_NUMBER FIX_AGENT FIX_MODEL MODEL OPENROUTER_API_KEY

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

# The class also covers opencode's own 0-turn error after the preflight passed
# (design §4), where the id demonstrably IS listed — telling the operator to fix
# a correct `default-model` would send them the wrong way. `.session_id` tells
# the origins apart: only the preflight's event carries `opencode-preflight`.
own_err="$(mktemp --suffix=.json)"
EXECUTION_FILE="$FIXTURES/opencode-model-not-found.json" MODEL=z-ai/glm-5.2 bash "$ADAPT_OC" > "$own_err"
own_report="$(RENDER_ONLY=1 RESULT_FILE="$own_err" \
              ISSUE_NUMBER=42 WORKFLOW_RUN_URL=https://example/run/test \
              FAILURE_CLASS=model_not_found MODEL=z-ai/glm-5.2 AGENT=opencode \
              bash "$ROOT/scripts/post-run-report.sh")"
assert_not_contains "$own_report" 'is not on OpenRouter' \
  "a post-preflight model error does not claim the id is unlisted"
# shellcheck disable=SC2016  # markdown code span around the model id
assert_contains "$own_report" 'Model `z-ai/glm-5.2` could not be resolved' \
  "  → it names the model and the resolution failure"
assert_contains "$own_report" 'pipeline-ref' "  → and points at the pinned ref to fix"
rm -f "$own_err"

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

section "agent-implement.yml — model preflight, injection and alert are wired (#518)"

WF="$ROOT/.github/workflows/agent-implement.yml"
wf="$(cat "$WF")"
line_of() { grep -nF -- "$1" "$WF" | head -1 | cut -d: -f1; }

assert_contains "$wf" 'bash .claude-pipeline/scripts/check-opencode-model.sh' "Run OpenCode calls the model preflight"
assert_contains "$wf" "printf 'exit_code=65\\n'" "a failed model preflight publishes exit_code 65"
assert_contains "$wf" 'opencode models openrouter --refresh' "the catalog is warmed before the run"
# shellcheck disable=SC2016  # the `$(...)` is the workflow's own shell text
# being searched for, not an expansion this test wants.
assert_contains "$wf" 'OPENCODE_CONFIG_CONTENT="$(bash .claude-pipeline/scripts/opencode-model-config.sh)"' \
  "the model entry is injected"
assert_contains "$wf" 'export OPENCODE_CONFIG_CONTENT' "and exported to opencode"

# shellcheck disable=SC1003  # the trailing backslash is the workflow's line
# continuation after `opencode run`, which is what pins the ordering checks.
run_line="$(line_of 'opencode run \')"
for needle in 'scripts/check-opencode-auth.sh' 'scripts/check-opencode-model.sh' \
              'opencode models openrouter --refresh' 'export OPENCODE_CONFIG_CONTENT'; do
  if (( $(line_of "$needle") < run_line )); then
    pass "'$needle' comes before 'opencode run'"
  else
    fail "'$needle' comes before 'opencode run'" "line $(line_of "$needle") vs $run_line"
  fi
done
if (( $(line_of 'scripts/check-opencode-auth.sh') < $(line_of 'scripts/check-opencode-model.sh') )); then
  pass "the key preflight runs before the model preflight"
else
  fail "the key preflight runs before the model preflight"
fi

assert_contains "$wf" "steps.classify_failure.outputs.class == 'model_not_found'" \
  "an alert step is gated on the class"
# agent-implement.test.yml drives the classifier to exactly this class on every
# PR touching scripts/, and NTFY_URL/NTFY_TOPIC come from the callee's `vars` —
# without the carve-out each CI run pushes a real priority-high alert.
assert_contains "$wf" "always() && !inputs.stub-claude && steps.classify_failure.outputs.class == 'model_not_found'" \
  "and excluded on stub runs, like every other side-effecting step"
assert_not_contains "$wf" 'OpenRouter does not list model' \
  "the push does not claim the id is unlisted — the class covers both origins"
assert_contains "$wf" 'The run report on the issue names the cause and the fix.' \
  "  → it points at the report, which distinguishes them"
assert_contains "$wf" 'the model-not-found alert (#518)' \
  "the NTFY_TOKEN description names both pushes"
assert_contains "$wf" "contains(fromJSON('[\"out_of_credits\"]'), steps.classify_failure.outputs.class)" \
  "the pause list is still out_of_credits only"
assert_contains "$wf" 'opencode_model_not_found)' "the stub knows the model_not_found fixture"
assert_not_contains "$wf" "#518's second" "the stale 'second pause reason' note is gone"
assert_not_contains "$(cat "$ROOT/scripts/lib/pause-reasons.sh")" 'model_unavailable' \
  "pause-reasons.sh no longer promises a model pause reason"

test_wf="$(cat "$ROOT/.github/workflows/agent-implement.test.yml")"
assert_contains "$test_wf" 'stub-fixture: opencode_model_not_found' "act: a call job exercises the class"
assert_contains "$test_wf" 'want model_not_found' "act: a verify job asserts the class"

setup_doc="$(cat "$ROOT/docs/CONSUMER-SETUP.md")"
assert_contains "$setup_doc" '### Adding a new OpenRouter model' "CONSUMER-SETUP documents adding a model"
assert_contains "$setup_doc" 'model_not_found' "CONSUMER-SETUP names the class"
# shellcheck disable=SC2016  # markdown code span in the doc text, not expansion
assert_not_contains "$setup_doc" 'classifies that as `transient`' "CONSUMER-SETUP drops the #439 retry advice"

section "both #518 scripts are executable like every other script in scripts/"

for script in check-opencode-model.sh opencode-model-config.sh; do
  if [[ -x "$ROOT/scripts/$script" ]]; then
    pass "scripts/$script is executable"
  else
    fail "scripts/$script is executable" "committed mode is not 100755"
  fi
done

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
