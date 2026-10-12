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

assert_not_equals() {
  if [[ "$1" != "$2" ]]; then
    pass "$3"
  else
    fail "$3" "did not expect '$2'"
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
assert_equals "$(classify_text 'This request requires more credits, or fewer max_tokens. You requested up to 64000 tokens')" \
  out_of_credits "requires more credits, or fewer max_tokens"
# Negative (F1): ordinary prose must never pause a consumer repo.
assert_not_equals "$(classify_text 'The task: add credits screen to the game; build timeout')" \
  out_of_credits "prose 'add credits screen' is not out_of_credits"
assert_not_equals "$(classify_text 'Plan: payment required for the shop; the game requires more credits UI')" \
  out_of_credits "prose about payment/credits in a plan is not out_of_credits"
assert_not_equals "$(classify_text 'addXcredits helper failed')" \
  out_of_credits "add.credits no longer matches any char"
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

# --- Task 4: pipeline-pause.sh ----------------------------------------------

section "pipeline-pause — one alarm issue per pause"

PAUSE="$ROOT/scripts/pipeline-pause.sh"

# pause_run <dir> <first-list-fixture> <relist-fixture> [extra env...] — runs
# pipeline-pause.sh with gh and curl mocked. Writes to $dir:
#   gh    gh argv, one call per line
#   body  the contents of every --body-file gh was handed
#   ntfy  the JSON body notify-ntfy.sh pushed (absent when no push happened)
pause_run() {
  local dir="$1" list="$2" relist="$3"; shift 3
  {
    printf '%s\t%s\n' '--json number,body' "$FIXTURES/$list"
    printf '%s\t%s\n' '--json number --limit' "$FIXTURES/$relist"
    printf '%s\t%s\n' 'issue create' "$FIXTURES/alarm-create-url.txt"
  } > "$dir/stdout-map"
  env PATH="$MOCKS:$PATH" \
    GH_MOCK_LOG="$dir/gh" \
    GH_MOCK_BODY_LOG="$dir/body" \
    GH_MOCK_STDOUT_MAP="$dir/stdout-map" \
    CURL_MOCK_FIXTURE="$FIXTURES/ntfy-published.json" \
    CURL_MOCK_BODY_LOG="$dir/ntfy" \
    REPO=freaxnx01/game-rhyflitzer \
    REASON=out_of_credits \
    NTFY_URL=https://ntfy.home.freaxnx01.ch \
    NTFY_TOPIC=pipeline-alerts \
    "$@" bash "$PAUSE" 2>&1
}

# (a) no open alarm -> create one, push once
d="$(mktemp -d)"
# shellcheck disable=SC2016  # OpenRouter's literal error text again.
out="$(pause_run "$d" alarm-list-empty.json alarm-list-own.json \
  ISSUE_NUMBER=99 \
  ERROR_TEXT='Key limit exceeded (monthly limit). $10.09 of $10.00 used; resets 2026-11-01')"
gh_log="$(cat "$d/gh")"
body="$(cat "$d/body")"
assert_contains "$gh_log" 'issue create'      "no alarm -> creates one"
assert_contains "$gh_log" 'Pipeline paused'   "created title names the pause"
assert_contains "$gh_log" 'pipeline-paused'   "created with the alarm label"
assert_contains "$body"   'Key limit exceeded' "alarm body carries the error text"
assert_contains "$body"   'https://openrouter.ai/settings/keys' "alarm body links key management"
assert_contains "$body"   '#99'                "alarm body lists the paused issue"
assert_contains "$body"   'How to resume'      "alarm body says how to resume"
assert_contains "$out"    'alarm-issue=9'      "emits the alarm issue number"
assert_contains "$out"    'created=true'       "emits created=true"
ntfy="$(cat "$d/ntfy")"
# One push == one JSON body in the log. Counted by its `topic` key, not by
# lines: jq renders the body pretty-printed across ten of them.
assert_equals "$(grep -c '"topic"' "$d/ntfy")" 1 "exactly one ntfy push"
assert_equals "$(jq -r .priority <<<"$ntfy")" 5 "push is urgent"
assert_equals "$(jq -r .click <<<"$ntfy")" \
  'https://github.com/freaxnx01/game-rhyflitzer/issues/9' "push links the alarm issue"
rm -rf "$d"

# (b) an open alarm exists -> update it, no second create, no second push
d="$(mktemp -d)"
out="$(pause_run "$d" alarm-list-existing.json alarm-list-own.json ISSUE_NUMBER=34)"
gh_log="$(cat "$d/gh")"
assert_not_contains "$gh_log" 'issue create'   "existing alarm -> no second issue"
assert_contains "$gh_log" 'issue edit 7'       "existing alarm -> edited"
assert_contains "$(cat "$d/body")" '#12 #34'   "new issue appended to the marker block"
assert_contains "$out" 'alarm-issue=7'         "emits the existing alarm number"
assert_contains "$out" 'created=false'         "emits created=false"
assert_equals "$([[ -s "$d/ntfy" ]] && printf nonempty || printf empty)" empty \
  "existing alarm -> no second push"
rm -rf "$d"

# (F5) backticks in the error text must not break the alarm body's code fence
d="$(mktemp -d)"
out="$(pause_run "$d" alarm-list-empty.json alarm-list-own.json \
  ISSUE_NUMBER=99 \
  ERROR_TEXT='Key limit exceeded ```evil``` `x`')"
# shellcheck disable=SC2016  # literal backticks are the thing under test
assert_not_contains "$(cat "$d/body")" '`evil`' "backticks stripped from the error text"
assert_contains "$(cat "$d/body")" 'Key limit exceeded' "error text is still shown"
rm -rf "$d"

# (c) an already-listed issue is not duplicated
d="$(mktemp -d)"
out="$(pause_run "$d" alarm-list-existing.json alarm-list-own.json ISSUE_NUMBER=12)"
assert_contains "$(cat "$d/body")" '<!-- paused-issues -->#12<!-- /paused-issues -->' \
  "an already-listed issue is not appended twice"
rm -rf "$d"

# (d) race: a lower-numbered alarm appeared while we were creating ours
d="$(mktemp -d)"
out="$(pause_run "$d" alarm-list-empty.json alarm-list-race.json ISSUE_NUMBER=99)"
gh_log="$(cat "$d/gh")"
assert_contains "$gh_log" 'issue close 9'  "race -> our duplicate alarm is closed"
assert_contains "$gh_log" 'duplicate of #5' "race -> closed as a duplicate of the winner"
assert_contains "$out" 'alarm-issue=5'     "race -> the winner is reported"
assert_contains "$out" 'created=false'     "race -> we did not create the alarm"
assert_equals "$([[ -s "$d/ntfy" ]] && printf nonempty || printf empty)" empty \
  "race -> the loser does not push"
rm -rf "$d"

# (e) ntfy unconfigured -> the alarm is still raised
d="$(mktemp -d)"
ec=0
out="$(pause_run "$d" alarm-list-empty.json alarm-list-own.json ISSUE_NUMBER=99 \
  NTFY_URL= NTFY_TOPIC=)" || ec=$?
assert_equals "$ec" 0 "no ntfy config -> exit 0"
assert_contains "$(cat "$d/gh")" 'issue create' "no ntfy config -> alarm still created"
assert_contains "$out" 'not configured' "no ntfy config -> says the push was skipped"
rm -rf "$d"

# (f) a leaked key in the error text is redacted before it is posted
d="$(mktemp -d)"
out="$(pause_run "$d" alarm-list-empty.json alarm-list-own.json ISSUE_NUMBER=99 \
  ERROR_TEXT='401 for key sk-or-v1-0a1b2c3d4e5f6071829304a5b6c7d8e9 — no credits')"
assert_not_contains "$(cat "$d/body")" 'sk-or-v1-0a1b2c' "a leaked key is redacted"
assert_contains "$(cat "$d/body")" 'sk-or-***' "the redaction is visible"
assert_not_contains "$(cat "$d/ntfy")" 'sk-or-v1-0a1b2c' "no leaked key in the push"
rm -rf "$d"

section "ensure-issue-labels — the alarm label exists"

assert_contains "$(cat "$ROOT/scripts/ensure-issue-labels.sh")" "create pipeline-paused" \
  "pipeline-paused is created in consumer repos"

# --- Task 5: check-pipeline-pause.sh ----------------------------------------

section "check-pipeline-pause — a paused repo starts no agent"

GATE="$ROOT/scripts/check-pipeline-pause.sh"

# gate_run <dir> <alarm-list-fixture> [extra env...] — runs the dispatch gate
# with gh mocked. $dir/gh holds the argv log, $dir/body the posted comment.
gate_run() {
  local dir="$1" list="$2"; shift 2
  printf '%s\t%s\n' 'issue list' "$FIXTURES/$list" > "$dir/stdout-map"
  env PATH="$MOCKS:$PATH" \
    GH_MOCK_LOG="$dir/gh" \
    GH_MOCK_BODY_LOG="$dir/body" \
    GH_MOCK_STDOUT_MAP="$dir/stdout-map" \
    REPO=freaxnx01/game-rhyflitzer \
    ISSUE_NUMBER=99 \
    "$@" bash "$GATE" 2>&1
}

d="$(mktemp -d)"
out="$(gate_run "$d" paused-gate-alarm.json)"
assert_contains "$out" 'paused=true'    "open alarm -> paused"
assert_contains "$out" 'alarm-issue=9'  "open alarm -> names the alarm"
assert_equals "$(grep -c 'issue comment' "$d/gh")" 1 "open alarm -> comments once"
assert_contains "$(cat "$d/body")" 'pipeline paused' "the comment says the pipeline is paused"
assert_contains "$(cat "$d/body")" 'see #9'          "the comment links the alarm"
assert_contains "$(cat "$d/body")" 'out_of_credits'  "the comment names the reason"
assert_not_contains "$(cat "$d/gh")" '--remove-label' "the issue keeps its ai-implement label"
rm -rf "$d"

# The same issue dispatched again while the pause holds: still blocked, but the
# comment is not repeated — a paused repo would otherwise spam every issue.
d="$(mktemp -d)"
gate_run "$d" paused-gate-alarm.json >/dev/null
notice="$(cat "$d/body")"
rm -rf "$d"
d="$(mktemp -d)"
out="$(gate_run "$d" paused-gate-alarm.json \
  ISSUE_COMMENTS_JSON="$(jq -n --arg b "$notice" '[{body: $b}]')")"
assert_contains "$out" 'paused=true' "second dispatch -> still paused"
assert_equals "$(grep -c 'issue comment' "$d/gh" || true)" 0 "second dispatch -> no duplicate comment"
rm -rf "$d"

d="$(mktemp -d)"
out="$(gate_run "$d" alarm-list-empty.json)"
assert_contains "$out" 'paused=false' "no alarm and no variable -> not paused"
assert_equals "$(grep -c 'issue comment' "$d/gh" || true)" 0 "not paused -> no comment"
rm -rf "$d"

d="$(mktemp -d)"
out="$(gate_run "$d" alarm-list-empty.json \
  AGENT_PAUSED_VAR='out_of_credits 2026-10-12T01:43Z')"
assert_contains "$out" 'paused=true' "the manual AGENT_PAUSED variable also pauses"
assert_contains "$(cat "$d/body")" 'AGENT_PAUSED' "the comment names the variable"
rm -rf "$d"

section "agent-implement.yml — the gate is wired in front of every agent step"

wf="$(cat "$ROOT/.github/workflows/agent-implement.yml")"
assert_contains "$wf" 'id: pause_gate' "the gate step exists"
assert_contains "$wf" "steps.pause_gate.outputs.paused != 'true'" "agent steps are gated on it"
assert_equals "$(grep -c "steps.pause_gate.outputs.paused != 'true'" \
  "$ROOT/.github/workflows/agent-implement.yml")" 3 \
  "attempt cap, Claude and OpenCode are all gated"
assert_contains "$wf" 'pipeline-pause.sh' "the alarm is raised from the implement job"
assert_contains "$wf" 'NTFY_TOKEN' "the ntfy token is wired through"
assert_contains "$(cat "$ROOT/.github/workflows/agent.yml")" 'NTFY_TOKEN' \
  "the dogfood consumer forwards the ntfy token"

# --- Task 6: pipeline-resume.sh ---------------------------------------------

section "pipeline-resume — clearing the alarm re-dispatches the queued issues"

RESUME="$ROOT/scripts/pipeline-resume.sh"

# resume_run <dir> <alarm-list-fixture> [extra env...]
resume_run() {
  local dir="$1" list="$2"; shift 2
  {
    printf '%s\t%s\n' 'issue list' "$FIXTURES/$list"
    printf '%s\t%s\n' 'issue view 12' "$FIXTURES/resume-issue-open.json"
    printf '%s\t%s\n' 'issue view 34' "$FIXTURES/resume-issue-closed.json"
  } > "$dir/stdout-map"
  env PATH="$MOCKS:$PATH" \
    GH_MOCK_LOG="$dir/gh" \
    GH_MOCK_BODY_LOG="$dir/body" \
    GH_MOCK_STDOUT_MAP="$dir/stdout-map" \
    REPO=freaxnx01/game-rhyflitzer \
    "$@" bash "$RESUME" 2>&1
}

d="$(mktemp -d)"
out="$(resume_run "$d" resume-alarm.json)"
gh_log="$(cat "$d/gh")"
assert_equals "$(grep -c 'workflow run' "$d/gh" || true)" 1 "only the still-queued issue is re-dispatched"
assert_contains "$gh_log" 'issue-number=12'   "the open, still-labelled issue is re-dispatched"
assert_not_contains "$gh_log" 'issue-number=34' "a closed issue is not re-dispatched"
assert_not_contains "$gh_log" 'attempt='      "no attempt input -> the re-run is attempt 1"
assert_contains "$gh_log" 'issue close 7'     "the alarm is closed"
assert_contains "$out" 'resumed'              "reports the resume"
rm -rf "$d"

# The alarm has to be closed BEFORE the re-dispatch: a dispatch that races a
# still-open alarm is stopped by the gate and the resume achieves nothing.
d="$(mktemp -d)"
resume_run "$d" resume-alarm.json >/dev/null
close_line="$(grep -n 'issue close 7' "$d/gh" | head -1 | cut -d: -f1)"
run_line="$(grep -n 'workflow run' "$d/gh" | head -1 | cut -d: -f1)"
if [[ -n "$close_line" && -n "$run_line" ]] && (( close_line < run_line )); then
  pass "the alarm is closed before the issues are re-dispatched"
else
  fail "the alarm is closed before the issues are re-dispatched" \
    "close at ${close_line:-none}, dispatch at ${run_line:-none}"
fi
rm -rf "$d"

d="$(mktemp -d)"
ec=0
out="$(resume_run "$d" alarm-list-empty.json)" || ec=$?
assert_equals "$ec" 0 "no alarm -> exit 0"
assert_contains "$out" 'nothing to resume' "no alarm -> says so"
assert_equals "$(grep -c 'workflow run' "$d/gh" || true)" 0 "no alarm -> dispatches nothing"
rm -rf "$d"

d="$(mktemp -d)"
out="$(resume_run "$d" resume-alarm.json AGENT_PAUSED_VAR='out_of_credits 2026-10-12T01:43Z')"
assert_contains "$out" 'AGENT_PAUSED' "warns that the manual variable still pauses the repo"
rm -rf "$d"

d="$(mktemp -d)"
out="$(resume_run "$d" resume-alarm.json DRY_RUN=1)"
assert_equals "$(grep -c 'workflow run' "$d/gh" || true)" 0 "dry run -> no dispatch"
assert_equals "$(grep -c 'issue close' "$d/gh" || true)" 0 "dry run -> the alarm stays open"
assert_contains "$out" '#12' "dry run -> names what it would re-dispatch"
rm -rf "$d"

# --- Task 7: check-openrouter-budget.sh -------------------------------------

section "check-openrouter-budget — warn before the limit is reached"

BUDGET="$ROOT/scripts/check-openrouter-budget.sh"

# budget_run <dir> <key-fixture> <credits-fixture> [extra env...] — runs the
# budget check with curl mocked per endpoint. $dir/argv holds the curl argv.
budget_run() {
  local dir="$1" key="$2" credits="$3"; shift 3
  {
    printf '%s\t%s\n' '/key' "$FIXTURES/$key"
    printf '%s\t%s\n' '/credits' "$FIXTURES/$credits"
  } > "$dir/fixture-map"
  env PATH="$MOCKS:$PATH" \
    CURL_MOCK_FIXTURE_MAP="$dir/fixture-map" \
    CURL_MOCK_LOG="$dir/argv" \
    OPENROUTER_API_KEY=sk-or-v1-0a1b2c3d4e5f6071829304a5b6c7d8e9 \
    "$@" bash "$BUDGET" 2>&1
}

verdict_of() { sed -n 's/^verdict=//p' <<<"$1"; }

d="$(mktemp -d)"
out="$(budget_run "$d" openrouter-key-ok.json openrouter-credits-ok.json)"
assert_equals "$(verdict_of "$out")" ok "8 of 10 USD left -> ok"
assert_contains "$out" 'message=' "a one-line message is emitted"
assert_not_contains "$out" '0a1b2c3d4e5f' "the key never reaches stdout"
assert_not_contains "$(cat "$d/argv")" '0a1b2c3d4e5f' "the key never reaches curl's argv"
rm -rf "$d"

d="$(mktemp -d)"
out="$(budget_run "$d" openrouter-key-low.json openrouter-credits-ok.json)"
assert_equals "$(verdict_of "$out")" warn "1.50 of 10 left (15%) -> warn"
rm -rf "$d"

d="$(mktemp -d)"
out="$(budget_run "$d" openrouter-key-floor.json openrouter-credits-ok.json)"
assert_equals "$(verdict_of "$out")" warn "2.80 left of 50 -> warn on the absolute floor"
rm -rf "$d"

d="$(mktemp -d)"
out="$(budget_run "$d" openrouter-key-nolimit.json openrouter-credits-ok.json)"
assert_equals "$(verdict_of "$out")" ok "no limit set -> no key warning"
rm -rf "$d"

d="$(mktemp -d)"
out="$(budget_run "$d" openrouter-key-exhausted.json openrouter-credits-ok.json)"
assert_equals "$(verdict_of "$out")" exhausted "nothing left -> exhausted"
rm -rf "$d"

d="$(mktemp -d)"
out="$(budget_run "$d" openrouter-key-ok.json openrouter-credits-low.json)"
assert_equals "$(verdict_of "$out")" warn "healthy key, \$5 left on the account -> warn"
assert_contains "$out" 'account' "the message says which budget is low"
rm -rf "$d"

# A key without management rights cannot read /credits. That is the normal
# case for a pipeline key, so it must not degrade the key verdict.
d="$(mktemp -d)"
ec=0
out="$(budget_run "$d" openrouter-key-low.json openrouter-credits-ok.json \
  CURL_MOCK_FAIL_PATTERN=/credits)" || ec=$?
assert_equals "$ec" 0 "a 403 on /credits is tolerated"
assert_equals "$(verdict_of "$out")" warn "the verdict still comes from the key alone"
rm -rf "$d"

d="$(mktemp -d)"
ec=0
out="$(env -u OPENROUTER_API_KEY PATH="$MOCKS:$PATH" \
  CURL_MOCK_FIXTURE="$FIXTURES/openrouter-key-ok.json" bash "$BUDGET" 2>&1)" || ec=$?
assert_equals "$ec" 2 "no key -> exit 2"
rm -rf "$d"

# --- Task 8: the health and probe workflows ---------------------------------

section "pipeline-health.yml — the daily check is wired to the scripts"

health="$(cat "$ROOT/.github/workflows/pipeline-health.yml")"
assert_contains "$health" 'workflow_call:' "callable by a consumer's own cron"
assert_contains "$health" 'check-openrouter-budget.sh' "runs the budget check"
assert_contains "$health" "verdict == 'warn'" "warn -> a push"
assert_contains "$health" 'NTFY_PRIORITY: high' "the warning is high, not urgent"
assert_contains "$health" "verdict == 'exhausted'" "exhausted -> the alarm"
assert_contains "$health" 'pipeline-pause.sh' "raises the same alarm as a failed run"
assert_contains "$health" 'Key healthy again' "a recovered key is reported on the open alarm"
# The secrets context is not available in `if:`; testing it there evaluates
# empty and the step is skipped on every repo.
assert_contains "$health" "env.OPENROUTER_API_KEY != ''" "the no-key skip tests env, not secrets"
assert_not_contains "$health" "secrets.OPENROUTER_API_KEY != ''" "no secrets context in an if:"
assert_contains "$health" 'issues: write' "least privilege: issues write, nothing more"
assert_not_contains "$health" 'contents: write' "the health check never writes code"

section "pipeline-ntfy-probe.yml — reachability is measurable"

probe="$(cat "$ROOT/.github/workflows/pipeline-ntfy-probe.yml")"
assert_contains "$probe" 'workflow_dispatch:' "manual only"
assert_not_contains "$probe" 'schedule:' "nothing pages on a schedule to prove the pager works"
assert_contains "$probe" '/v1/health' "probes the server's health endpoint"
assert_contains "$probe" 'notify-ntfy.sh' "and sends a real notification"
assert_contains "$probe" 'ntfy.sh' "documents the fallback in its own summary"

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
