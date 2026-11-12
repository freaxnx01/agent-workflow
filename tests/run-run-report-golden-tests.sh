#!/usr/bin/env bash
#
# run-run-report-golden-tests.sh — Layer-1 tests that pin the *exact bytes* of
# the run report scripts/post-run-report.sh renders (#585).
#
# The rest of the suite asserts with `assert_contains`, which cannot prove that
# a change left the visible report alone. #585 appends a hidden run marker to
# the comment and promises the visible part stays byte-identical, so that
# promise needs a test that compares bytes: every case below renders with
# `RENDER_ONLY=1`, has its marker line deleted, and is diffed against a golden
# file captured from the script *before* the marker existed.
#
# Regenerate the golden files deliberately, never to make a red test green:
#
#   UPDATE_GOLDEN=1 tests/run-run-report-golden-tests.sh
#
# Usage: tests/run-run-report-golden-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/post-run-report.sh"
FIXTURES="$ROOT/tests/fixtures"
GOLDEN="$ROOT/tests/fixtures/run-report-golden"

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

# --- the cases --------------------------------------------------------------

# One entry per rendering path that touches the tail of the comment. CASE_ENV
# holds one KEY=VALUE per line; values may contain spaces, so the lines are read
# into an array rather than word-split.
CASES=(
  success success-full high-context failed-max-turns failed-no-pr partial
  unverifiable salvaged checks-blocked paused model-not-found
)

declare -A CASE_RESULT=(
  [success]=result-success-cheap.json
  [success-full]=result-success-expensive.json
  [high-context]=result-high-context.json
  [failed-max-turns]=result-max-turns.json
  [failed-no-pr]=result-success-cheap.json
  [partial]=result-success-expensive.json
  [unverifiable]=result-success-cheap.json
  [salvaged]=result-success-cheap.json
  [checks-blocked]=result-success-cheap.json
  [paused]=result-rate-limit.json
  [model-not-found]=result-opencode-model-not-found.json
)

declare -A CASE_ENV=(
  [success]=''
  [success-full]='MODEL=claude-sonnet-5
AGENT=claude
MAX_TURNS=80
HAS_PLAN=true
PR_PRESENT=true
PLAN_COVERAGE=complete'
  [high-context]="EXECUTION_FILE=$FIXTURES/exec-high-context.ndjson"
  [failed-max-turns]='FAILURE_CLASS=task_failure
MODEL=claude-sonnet-5
AGENT=claude
MAX_TURNS=60'
  [failed-no-pr]='PR_PRESENT=false'
  [partial]='PLAN_COVERAGE=partial
MISSING_TASKS=2,3
PR_PRESENT=true'
  [unverifiable]='PLAN_COVERAGE=unverifiable
PLAN_COVERAGE_REASON=no plan headings'
  [salvaged]='SALVAGED=true
PR_PRESENT=true'
  [checks-blocked]='CHECKS_RUNNABLE=false
CHECKS_BLOCKED_REASON=no-app-token'
  [paused]='FAILURE_CLASS=out_of_credits'
  [model-not-found]='FAILURE_CLASS=model_not_found
MODEL=z-ai/glm-9
AGENT=opencode'
)

# render_case <name> [EXTRA=VALUE ...] — the full RENDER_ONLY stdout for a case.
#
# `env -i` on purpose: the goldens must not depend on the ambient environment.
# On a GitHub Actions runner GITHUB_REPOSITORY and GITHUB_OUTPUT are always
# set and post-run-report.sh falls back to them (#354), and a job that exports
# MODEL/PR_NUMBER for a nested agent would leak into every case (#264).
render_case() {
  local name="$1"; shift
  local -a extra=() line
  while IFS= read -r line; do
    [[ -n "$line" ]] && extra+=("$line")
  done <<< "${CASE_ENV[$name]}"
  env -i \
    PATH="$PATH" HOME="${HOME:-/tmp}" LC_ALL=C \
    RENDER_ONLY=1 ISSUE_NUMBER=42 WORKFLOW_RUN_URL=https://example/run/test \
    RESULT_FILE="$FIXTURES/${CASE_RESULT[$name]}" \
    ${extra[@]+"${extra[@]}"} "$@" \
    bash "$SCRIPT"
}

# strip_marker — delete the run marker line. A no-op on a report that has none,
# so the same goldens pin the visible report before and after #585.
strip_marker() { sed -e '/^<!-- ai-run: .* -->$/d'; }

# --- golden files -----------------------------------------------------------

if [[ "${UPDATE_GOLDEN:-}" == "1" ]]; then
  section "regenerating golden files"
  mkdir -p "$GOLDEN"
  for name in "${CASES[@]}"; do
    render_case "$name" | strip_marker > "$GOLDEN/$name.txt"
    printf '  wrote %s\n' "$GOLDEN/$name.txt"
  done
  printf '\n%d golden files written — review the diff before committing.\n' "${#CASES[@]}"
  exit 0
fi

section "visible report — byte-identical to the golden files"

for name in "${CASES[@]}"; do
  golden="$GOLDEN/$name.txt"
  if [[ ! -r "$golden" ]]; then
    fail "golden: $name" "missing golden file $golden (regenerate with UPDATE_GOLDEN=1)"
    continue
  fi
  if diff_out="$(diff -u "$golden" <(render_case "$name" | strip_marker) 2>&1)"; then
    pass "golden: $name"
  else
    fail "golden: $name" "visible report changed:"
    printf '%s\n' "$diff_out" | sed -e 's/^/      /'
  fi
done

# --- the run marker (#585) --------------------------------------------------

# marker_lines <rendered> — every marker line in a rendered report.
marker_lines() { printf '%s\n' "$1" | sed -n '/^<!-- ai-run: .* -->$/p'; }

# marker_json <rendered> — the JSON between the marker's prefix and suffix.
marker_json() { printf '%s\n' "$1" | sed -n 's/^<!-- ai-run: \(.*\) -->$/\1/p'; }

# assert_jq <json> <filter> <name> — the filter must hold on the marker JSON.
assert_jq() {
  local out rc=0
  out="$(printf '%s' "$1" | jq -e "$2" 2>&1)" || rc=$?
  if (( rc == 0 )); then pass "$3"; else fail "$3" "jq '$2' → rc=$rc, out=$out, json=$1"; fi
}

# assert_one_marker <rendered> <name>
assert_one_marker() {
  local count
  count="$(marker_lines "$1" | grep -c . || true)"
  if [[ "$count" == "1" ]]; then pass "$2"; else fail "$2" "found $count marker lines"; fi
}

# assert_marker_tail <rendered> <name> — the marker is the last line of the
# comment: directly after the run link, directly before the RENDER_ONLY trailer.
assert_marker_tail() {
  local -a lines
  mapfile -t lines <<< "$1"
  local n=${#lines[@]}
  if (( n < 5 )); then fail "$2" "only $n lines rendered"; return 0; fi
  local link="${lines[n - 5]}" marker="${lines[n - 4]}" blank="${lines[n - 3]}"
  local rule="${lines[n - 2]}" labels="${lines[n - 1]}"
  if [[ "$link" == '[View workflow run](https://example/run/test)' \
     && "$marker" == '<!-- ai-run: '*' -->' \
     && -z "$blank" && "$rule" == '---' && "$labels" == 'LABELS:'* ]]; then
    pass "$2"
  else
    fail "$2" "tail was: [$link] [$marker] [$blank] [$rule] [$labels]"
  fi
}

section "run marker — on every case"

for name in "${CASES[@]}"; do
  out="$(render_case "$name")"
  assert_one_marker "$out" "marker: $name — exactly one marker line"
  assert_marker_tail "$out" "marker: $name — last line, right after the run link"
  json="$(marker_json "$out")"
  assert_jq "$json" '.v == 1' "marker: $name — v is 1"
  assert_jq "$json" '.run_url == "https://example/run/test"' "marker: $name — run_url"
done

section "run marker — fields"

json="$(marker_json "$(render_case success)")"
assert_jq "$json" '.status == "ai:done"'   "success — status"
assert_jq "$json" '.subtype == "success"'  "success — subtype"
assert_jq "$json" '.turns == 4'            "success — turns"
assert_jq "$json" '.cost_usd == 0.0042'    "success — cost_usd"
assert_jq "$json" '.counts == true'        "success — counts"
assert_jq "$json" 'has("decision") | not'  "success — no decision (Plan retry did not run)"
assert_jq "$json" 'has("attempt") | not'   "success — no attempt (cap step did not run)"
assert_jq "$json" 'has("pr") | not'        "success — no pr (none passed)"
assert_jq "$json" 'has("class") | not'     "success — no class (classifier did not run)"

json="$(marker_json "$(render_case success-full ATTEMPT=2 RETRY_ATTEMPT=1 PR_NUMBER=42)")"
assert_jq "$json" '.attempt == 2'                 "success-full — attempt (the cap's lifetime count)"
assert_jq "$json" '.retry_attempt == 1'           "success-full — retry_attempt (the chain position)"
assert_jq "$json" '.pr == 42'                     "success-full — pr"
assert_jq "$json" '.agent == "claude"'            "success-full — agent"
assert_jq "$json" '.model == "claude-sonnet-5"'   "success-full — model"
assert_jq "$json" '.max_turns == 80'              "success-full — max_turns"
assert_jq "$json" '.plan_coverage == "complete"'  "success-full — plan_coverage"
assert_jq "$json" 'has("has_plan") | not'         "success-full — no has_plan (#532)"

json="$(marker_json "$(render_case failed-max-turns RETRY_DECISION=stop ATTEMPT=2)")"
assert_jq "$json" '.class == "task_failure"'       "failed-max-turns — class"
assert_jq "$json" '.decision == "stop"'            "failed-max-turns — decision"
assert_jq "$json" '.status == "ai:failed"'         "failed-max-turns — status"
assert_jq "$json" '.subtype == "error_max_turns"'  "failed-max-turns — subtype"
assert_jq "$json" '.turns == 60'                   "failed-max-turns — turns"
assert_jq "$json" '.attempt == 2'                  "failed-max-turns — attempt"
assert_jq "$json" '.counts == true'                "failed-max-turns — counts"
assert_jq "$json" '.duration_ms == 612000'         "failed-max-turns — duration_ms"

json="$(marker_json "$(render_case paused ATTEMPT=3)")"
assert_jq "$json" '.class == "out_of_credits"' "paused — class"
assert_jq "$json" '.counts == false'           "paused — counts is false for a pause class"
assert_jq "$json" 'has("attempt") | not'       "paused — no attempt even with ATTEMPT set"
assert_jq "$json" 'has("status") | not'        "paused — no status (no label is stamped)"

json="$(marker_json "$(render_case model-not-found ATTEMPT=3)")"
assert_jq "$json" '.class == "model_not_found"' "model-not-found — class"
assert_jq "$json" '.status == "ai:failed"'      "model-not-found — status"
assert_jq "$json" '.turns == 0'                 "model-not-found — turns"
assert_jq "$json" '.cost_usd == 0'              "model-not-found — cost_usd"
assert_jq "$json" '.counts == false'            "model-not-found — counts is false for a non-start"
assert_jq "$json" 'has("attempt") | not'        "model-not-found — no attempt on a non-start"

json="$(marker_json "$(render_case partial)")"
assert_jq "$json" '.status == "ai:partial"'      "partial — status"
assert_jq "$json" '.plan_coverage == "partial"'  "partial — plan_coverage"

section "run marker — no free text (ADR-019)"

json="$(marker_json "$(render_case model-not-found)")"
assert_jq "$json" 'has("result") | not' "model-not-found — no result key"
if [[ "$json" != *"not on OpenRouter's model list"* && "$json" != *api_error* ]]; then
  pass "model-not-found — the fixture's free text is nowhere in the marker"
else
  fail "model-not-found — the fixture's free text is nowhere in the marker" "json=$json"
fi

section "run marker — a model id cannot break out of the HTML comment"

out="$(render_case success MODEL='x-->y<z')"
line="$(marker_lines "$out")"
arrows="$(printf '%s' "$line" | grep -o -- '-->' | grep -c . || true)"
if [[ "$arrows" == "1" ]]; then
  pass "escaping — the marker line contains '-->' exactly once"
else
  fail "escaping — the marker line contains '-->' exactly once" "found $arrows in: $line"
fi
if [[ "${line:4}" != *'<'* ]]; then
  pass "escaping — no '<' after the comment's own opener"
else
  fail "escaping — no '<' after the comment's own opener" "line=$line"
fi
assert_jq "$(marker_json "$out")" '.model == "x-->y<z"' "escaping — the model id decodes back exactly"

section "run marker — invalid and awkward numbers"

json="$(marker_json "$(render_case success ATTEMPT=abc RETRY_ATTEMPT= PR_NUMBER=3a)")"
assert_jq "$json" 'type == "object"'         "invalid numbers — still valid JSON"
assert_jq "$json" 'has("attempt") | not'     "invalid numbers — ATTEMPT=abc is omitted"
assert_jq "$json" 'has("retry_attempt")|not' "invalid numbers — an empty RETRY_ATTEMPT is omitted"
assert_jq "$json" 'has("pr") | not'          "invalid numbers — PR_NUMBER=3a is omitted"

# jq prints 0.000042 as 4.2e-05 — still a JSON number, and it must not be
# dropped or turned into a string on the way through.
TINY="$(mktemp)"
trap 'rm -f "$TINY"' EXIT
jq '.total_cost_usd = 0.000042' "$FIXTURES/result-success-cheap.json" > "$TINY"
json="$(marker_json "$(render_case success RESULT_FILE="$TINY")")"
assert_jq "$json" '(.cost_usd | type) == "number"' "tiny cost — cost_usd is a number"
assert_jq "$json" '.cost_usd == 0.000042'          "tiny cost — cost_usd round-trips"

# --- workflow wiring (#585) -------------------------------------------------

# The marker's four new inputs are useless unless the workflow passes them, and
# a typo in a `${{ steps.… }}` expression fails silently — the field is simply
# absent from every marker. Guard the wiring here, where it is cheap.

IMPLEMENT="$ROOT/.github/workflows/agent-implement.yml"
POST_RUN_STEP='- name: Post run report'

# post_run_env — the Post run report step's lines, leading indent stripped.
post_run_env() {
  awk -v want="$POST_RUN_STEP" '
    index($0, want) && $0 ~ /^[[:space:]]*- name: / { inside = 1; next }
    inside && /^[[:space:]]*- name: / { inside = 0 }
    inside { sub(/^[[:space:]]+/, ""); print }
  ' "$IMPLEMENT"
}

# line_of <regex> — line number of the first match, or 0.
line_of() {
  awk -v re="$1" '$0 ~ re { print NR; exit }' "$IMPLEMENT"
}

# enclosing_job <line> — line number of the job header the line sits under.
enclosing_job() {
  awk -v limit="$1" 'NR < limit && /^  [a-zA-Z_][a-zA-Z0-9_-]*:$/ { n = NR } END { print n + 0 }' "$IMPLEMENT"
}

section "workflow wiring — the marker inputs reach Post run report"

STEP_ENV="$(post_run_env)"
# shellcheck disable=SC2016  # `${{ … }}` is an Actions expression matched
# literally against the workflow file — expanding it is the opposite of the point.
for wiring in \
  'ATTEMPT: ${{ needs.implement.outputs.attempt }}' \
  'RETRY_ATTEMPT: ${{ inputs.attempt }}' \
  'RETRY_DECISION: ${{ steps.retry.outputs.decision }}' \
  'PR_NUMBER: ${{ steps.find_pr.outputs.pr-number }}'
do
  name="wiring: ${wiring%%:*}"
  if printf '%s\n' "$STEP_ENV" | grep -qxF -- "$wiring"; then
    pass "$name"
  else
    fail "$name" "no '$wiring' in the Post run report step"
  fi
done

POST_RUN_LINE="$(line_of "^[[:space:]]*$POST_RUN_STEP\$")"
POST_RUN_JOB="$(enclosing_job "$POST_RUN_LINE")"
for step_id in retry find_pr; do
  name="wiring: step '$step_id' is defined before Post run report, in the same job"
  id_line="$(awk -v limit="$POST_RUN_LINE" -v re="^[[:space:]]*id: $step_id\$" \
    'NR < limit && $0 ~ re { n = NR } END { print n + 0 }' "$IMPLEMENT")"
  if (( id_line > 0 )) && [[ "$(enclosing_job "$id_line")" == "$POST_RUN_JOB" ]]; then
    pass "$name"
  else
    fail "$name" "id line $id_line vs Post run report line $POST_RUN_LINE (job header $POST_RUN_JOB)"
  fi
done

# #535 splits judging into implement_gate, so the attempt number crosses the
# job boundary. It must come from attempt_cap, a pre-agent (trusted) step, and
# the gate job must list implement under needs.
# shellcheck disable=SC2016  # literal Actions expression, as above.
name="wiring: implement exposes attempt from the pre-agent attempt_cap step"
if grep -qE '^[[:space:]]+attempt:[[:space:]]+\$\{\{ steps\.attempt_cap\.outputs\.attempt \}\}$' "$IMPLEMENT"; then
  pass "$name"
else
  fail "$name" "no 'attempt: \${{ steps.attempt_cap.outputs.attempt }}' job output"
fi
name="wiring: the Post run report job needs implement"
if awk -v start="$POST_RUN_JOB" -v stop="$POST_RUN_LINE" \
     'NR > start && NR < stop && /^    needs:/ && /implement([^_]|$)/ { f = 1 } END { exit !f }' "$IMPLEMENT"; then
  pass "$name"
else
  fail "$name" "Post run report's job (line $POST_RUN_JOB) has no needs: implement"
fi

# --- summary ----------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'; printf '  - %s\n' "${FAIL_NAMES[@]}"
  exit 1
fi
