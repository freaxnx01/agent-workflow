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

# --- summary ----------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'; printf '  - %s\n' "${FAIL_NAMES[@]}"
  exit 1
fi
