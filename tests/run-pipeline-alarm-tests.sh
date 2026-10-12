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

# --- Task 2: a paused run is not an attempt --------------------------------

# render_report [FAILURE_CLASS] — the run report post-run-report.sh renders for
# a failed run, optionally with a failure class attached.
render_report() {
  RENDER_ONLY=1 \
  FAILURE_CLASS="${1:-}" \
  RESULT_FILE="$FIXTURES/result-rate-limit.json" \
  ISSUE_NUMBER=42 \
  WORKFLOW_RUN_URL=https://example/run/test \
    bash "$ROOT/scripts/post-run-report.sh"
}

section "post-run-report — a paused run reports as paused"

out="$(render_report out_of_credits)"
assert_contains "$out" '## ai-implement paused' "pause class -> paused heading"
assert_not_contains "$out" '## ai-implement run' "pause class -> not a run report"
assert_not_contains "$out" 'ai:failed'           "pause class -> no ai:failed label"
assert_contains "$out" 'LABELS: '                "pause class -> label list still emitted"
assert_contains "$out" 'paused:'                 "pause class -> outcome says paused"
assert_contains "$out" 'credits'                 "pause class -> outcome names the reason"
assert_contains "$out" '**Turns:**'              "pause class -> metrics kept for the cap regexes"

out="$(render_report)"
assert_contains "$out" '## ai-implement run'  "no failure class -> heading unchanged"
assert_contains "$out" 'LABELS: ai:failed'    "no failure class -> ai:failed unchanged"

out="$(render_report bug)"
assert_contains "$out" '## ai-implement run'  "non-pause class -> heading unchanged"
assert_contains "$out" 'LABELS: ai:failed'    "non-pause class -> ai:failed unchanged"

section "check-attempt-cap — a paused report is neither attempt nor non-start"

# shellcheck disable=SC2016  # `$0.03` is the report's literal Cost field, which
# is what count_reports parses — expanding it would break the fixture.
paused_report='[{"body":"## ai-implement paused\n\n**Outcome:** :warning: paused: OpenRouter key limit / credits exhausted\n**Duration:** 0s · **Turns:** 7 · **Cost:** $0.03"}]'
out="$(ISSUE_COMMENTS_JSON="$paused_report" ISSUE_NUMBER=42 REPO=o/r DRY_RUN=1 \
  bash "$ROOT/scripts/check-attempt-cap.sh")"
assert_contains "$out" 'attempt=1'    "paused report is not a prior attempt"
assert_contains "$out" 'non-starts=0' "paused report is not a non-start"
assert_contains "$out" 'proceed=true' "the issue still proceeds"

section "classify-agent — after a pause the issue resumes as attempt 1"

out="$(ISSUE_LABELS='' ISSUE_NUMBER=42 REPO=o/r DEFAULT_AGENT=opencode ATTEMPT=1 \
  HAS_OPENROUTER_KEY=true bash "$ROOT/scripts/classify-agent.sh")"
assert_contains "$out" 'chosen: opencode' "attempt 1 stays on the default agent"

# --- Task 3: notify-ntfy.sh -------------------------------------------------

section "notify-ntfy — the push never fails the run"

NTFY="$ROOT/scripts/notify-ntfy.sh"

# ntfy_run <log dir> [extra env assignments...] — runs notify-ntfy.sh with the
# curl mock on PATH, capturing stdout+stderr. argv goes to $dir/argv, the
# request body to $dir/body.
ntfy_run() {
  local dir="$1"; shift
  env PATH="$MOCKS:$PATH" \
    CURL_MOCK_FIXTURE="$FIXTURES/ntfy-published.json" \
    CURL_MOCK_LOG="$dir/argv" \
    CURL_MOCK_BODY_LOG="$dir/body" \
    "$@" bash "$NTFY" 2>&1
}

d="$(mktemp -d)"
ec=0
out="$(ntfy_run "$d" NTFY_TOPIC=pipeline-alerts NTFY_TITLE=t NTFY_MESSAGE=m)" || ec=$?
assert_equals "$ec" 0 "unconfigured -> exit 0"
assert_contains "$out" 'not configured' "unconfigured -> says so"
assert_equals "$(cat "$d/argv" 2>/dev/null || printf '')" '' "unconfigured -> no curl call"
rm -rf "$d"

d="$(mktemp -d)"
out="$(ntfy_run "$d" \
  NTFY_URL=https://ntfy.home.freaxnx01.ch \
  NTFY_TOPIC=pipeline-alerts \
  NTFY_TITLE='Pipeline paused' \
  NTFY_MESSAGE='out of credits' \
  NTFY_PRIORITY=urgent \
  NTFY_CLICK=https://github.com/o/r/issues/7 \
  NTFY_TAGS=rotating_light,warning)"
body="$(cat "$d/body")"
assert_contains "$(cat "$d/argv")" 'ntfy.home.freaxnx01.ch' "configured -> posts to the server"
assert_equals "$(jq -r .topic <<<"$body")"    pipeline-alerts  "body carries the topic"
assert_equals "$(jq -r .priority <<<"$body")" 5                "urgent -> priority 5"
assert_equals "$(jq -r .title <<<"$body")"    'Pipeline paused' "body carries the title"
assert_equals "$(jq -r .click <<<"$body")"    'https://github.com/o/r/issues/7' "body carries the click URL"
assert_equals "$(jq -r '.tags | join("+")' <<<"$body")" 'rotating_light+warning' "tags are split on comma"
assert_contains "$out" 'sent' "configured -> reports the send"
rm -rf "$d"

d="$(mktemp -d)"
out="$(ntfy_run "$d" NTFY_URL=https://ntfy.example NTFY_TOPIC=t NTFY_MESSAGE=m NTFY_PRIORITY=high)"
assert_equals "$(jq -r .priority <<<"$(cat "$d/body")")" 4 "high -> priority 4"
rm -rf "$d"

d="$(mktemp -d)"
out="$(ntfy_run "$d" NTFY_URL=https://ntfy.example NTFY_TOPIC=t NTFY_MESSAGE=m)"
assert_equals "$(jq -r .priority <<<"$(cat "$d/body")")" 3 "no priority -> default 3"
rm -rf "$d"

d="$(mktemp -d)"
out="$(ntfy_run "$d" NTFY_URL=https://ntfy.example NTFY_TOPIC=t NTFY_MESSAGE=m \
  NTFY_TOKEN=s3cret-publisher-token)"
assert_not_contains "$(cat "$d/argv")" 's3cret' "token never reaches curl's argv"
assert_not_contains "$out" 's3cret' "token never reaches stdout or stderr"
assert_not_contains "$(cat "$d/body")" 's3cret' "token never reaches the request body"
rm -rf "$d"

d="$(mktemp -d)"
ec=0
out="$(ntfy_run "$d" CURL_MOCK_FAIL=1 NTFY_URL=https://ntfy.example NTFY_TOPIC=t \
  NTFY_MESSAGE=m NTFY_TOKEN=s3cret-publisher-token)" || ec=$?
assert_equals "$ec" 0 "curl failure -> still exit 0"
assert_contains "$out" 'warning:' "curl failure -> warns"
assert_not_contains "$out" 's3cret' "curl failure -> no token in the warning"
rm -rf "$d"

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
