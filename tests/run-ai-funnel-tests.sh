#!/usr/bin/env bash
#
# run-ai-funnel-tests.sh — Layer-1 fixture tests for scripts/lib/ai-funnel.sh.
#
# Drives the classification and rendering halves from a curated records fixture
# via --from, so no network, no gh and no GitHub API are involved. The
# collection half (GraphQL) is not covered here — see the shaping notes in
# ai-funnel.sh for why closer and closedByPullRequestsReferences are unioned.
#
# Usage: tests/run-ai-funnel-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/lib/ai-funnel.sh"
FIXTURE="$ROOT/tests/fixtures/ai-funnel-records.json"

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
  [[ -n "${2:-}" ]] && printf '    %s%s%s\n' "$C_DIM" "$2" "$C_OFF"
  return 0
}

assert_contains() {
  local hay="$1" needle="$2" name="$3"
  if [[ "$hay" == *"$needle"* ]]; then pass "$name"
  else fail "$name" "expected substring not found: $needle"; fi
}

assert_not_contains() {
  local hay="$1" needle="$2" name="$3"
  if [[ "$hay" != *"$needle"* ]]; then pass "$name"
  else fail "$name" "unexpected substring present: $needle"; fi
}

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then pass "$name"
  else fail "$name" "want [$want], got [$got]"; fi
}

field_of() {
  jq -r --argjson n "$2" --arg f "$3" '.[] | select(.issue == $n) | .[$f] | tostring' <<< "$1"
}

# --- classification ---------------------------------------------------------

section "stage classification"

ALL="$(bash "$SCRIPT" --from "$FIXTURE" --json)"

assert_eq "$(field_of "$ALL" 1 stage)" "shipped"          "a merged agent PR marks the issue shipped"
assert_eq "$(field_of "$ALL" 3 stage)" "dispatched"        "dispatched with nothing merged is not shipped"
assert_eq "$(field_of "$ALL" 4 stage)" "ready"             "enriched and undispatched is ready"
assert_eq "$(field_of "$ALL" 5 stage)" "needs enrichment"  "the needs-enrichment label sets the stage"
assert_eq "$(field_of "$ALL" 6 stage)" "needs enrichment"  "the to-be-defined label sets the same stage"
assert_eq "$(field_of "$ALL" 7 stage)" "unplanned"         "no plan and no label is still not ready"
assert_eq "$(field_of "$ALL" 8 stage)" "parked"            "parked outranks needs-enrichment"
assert_eq "$(field_of "$ALL" 10 stage)" "closed unshipped" "closed by hand is not shipped"
assert_eq "$(field_of "$ALL" 13 stage)" "shipped"          "a merged PR ships the issue even with no dispatch"

# --- dispatchability mirrors /gh:implement's preconditions ------------------

section "dispatchability"

assert_eq "$(field_of "$ALL" 4 dispatchable)"  "true"  "issue 4 is dispatchable"
assert_eq "$(field_of "$ALL" 9 dispatchable)"  "true"  "a wrong-level plan is still dispatchable, just mis-budgeted"
assert_eq "$(field_of "$ALL" 3 dispatchable)"  "false" "an issue already carrying ai-implement is not re-offered"
assert_eq "$(field_of "$ALL" 5 dispatchable)"  "false" "needs-enrichment blocks dispatch"
assert_eq "$(field_of "$ALL" 7 dispatchable)"  "false" "a missing plan blocks dispatch"
assert_eq "$(field_of "$ALL" 8 dispatchable)"  "false" "parked blocks dispatch"
assert_eq "$(field_of "$ALL" 1 dispatchable)"  "false" "a closed issue is never dispatchable"

assert_eq "$(jq -r '.[] | select(.issue == 8) | .blockers | length | tostring' <<< "$ALL")" "3" \
  "every blocker is listed, not just the first"

# --- turn budget mirrors classify-turns.sh ----------------------------------

section "turn budget"

assert_eq "$(field_of "$ALL" 4 budget)"  "80"              "2 tasks -> 80 turns"
assert_eq "$(field_of "$ALL" 1 budget)"  "120"             "4 tasks -> 120 turns"
assert_eq "$(field_of "$ALL" 3 budget)"  "120"             "5 tasks -> 120 turns, not 160"
assert_eq "$(field_of "$ALL" 2 budget)"  "160"             "6 tasks -> 160 turns"
assert_eq "$(field_of "$ALL" 7 budget)"  "unplanned (120)" "no plan -> the discovery budget"
assert_eq "$(field_of "$ALL" 9 budget)"  "floor (50)"      "a plan with zero countable tasks -> the floor"

assert_eq "$(field_of "$ALL" 9 miscounted)" "true"  "wrong-level task headings are flagged"
assert_eq "$(field_of "$ALL" 7 miscounted)" "false" "an unplanned issue is not a miscount"
assert_eq "$(field_of "$ALL" 4 miscounted)" "false" "a correctly-levelled plan is not a miscount"

# --- milestone filtering ----------------------------------------------------

section "--milestone"

MS="$(bash "$SCRIPT" --from "$FIXTURE" --milestone "september" --json)"

assert_eq "$(jq -r 'length | tostring' <<< "$MS")" "11" \
  "a substring match keeps only the milestone's issues"
assert_eq "$(jq -r '[.[] | select(.issue == 11 or .issue == 12)] | length | tostring' <<< "$MS")" "0" \
  "another milestone and no milestone are both excluded"

MS_CASE="$(bash "$SCRIPT" --from "$FIXTURE" --milestone "SEPTEMBER" --json)"
assert_eq "$(jq -r 'length | tostring' <<< "$MS_CASE")" "11" "the match is case-insensitive"

# --- rendering --------------------------------------------------------------

section "report"

REPORT="$(bash "$SCRIPT" --from "$FIXTURE" --milestone "september")"

assert_contains "$REPORT" "# ai-implement funnel"     "report has a title"
assert_contains "$REPORT" "| Open | 7 |"              "7 of the 11 milestone issues are open"
assert_contains "$REPORT" "| — parked | 1 |"          "the parked issue is counted separately"
assert_contains "$REPORT" "| Live (open, not parked) | 6 |" "live excludes parked"
assert_contains "$REPORT" "| — blocked on enrichment | 2 |" "parked is not double-counted as blocked"
assert_contains "$REPORT" "| **Ready to dispatch** | **2** |" "queue depth is the headline number"
assert_contains "$REPORT" "| Dispatched at least once | 3 |" "dispatch count spans open and closed"
assert_contains "$REPORT" "| Re-dispatched | 1 |"     "a second label event counts as a re-dispatch"
assert_contains "$REPORT" "| Shipped by the pipeline | 2 |" "shipped counts merged agent PRs"
assert_contains "$REPORT" "| Shipped by the pipeline | 2 | 67% of dispatched |" \
  "the shipped rate is against dispatched issues only, so it cannot exceed 100%"
assert_contains "$REPORT" "| Shipped by hand | 1 |" \
  "an issue that shipped without ever being dispatched is counted apart, not folded in"
assert_contains "$REPORT" "Queue depth: 2"            "the queue-depth line states the actionable number"
assert_contains "$REPORT" "plan(s) will be miscounted" "the #297 warning fires"
assert_contains "$REPORT" "#9 — 7 task(s) at the wrong heading level" "the warning names the issue"
assert_contains "$REPORT" "no ## Implementation Plan" "blockers are spelled out per issue"
assert_contains "$REPORT" "## Ready to dispatch now"  "the ready table is rendered"

# An issue in another milestone must not leak into any table.
assert_not_contains "$REPORT" "different milestone" "milestone filtering reaches the report"

section "empty and degenerate input"

EMPTY_FIXTURE="$(mktemp)"
trap 'rm -f "$EMPTY_FIXTURE"' EXIT
echo '[]' > "$EMPTY_FIXTURE"
EMPTY="$(bash "$SCRIPT" --from "$EMPTY_FIXTURE")"
assert_contains "$EMPTY" "**Issues:** 0"  "an empty record set still renders"
assert_contains "$EMPTY" "n/a"            "percentages of zero read n/a, not a division error"

NO_MISCOUNT="$(bash "$SCRIPT" --from "$FIXTURE" --milestone "backlog-2027")"
assert_not_contains "$NO_MISCOUNT" "will be miscounted" "the #297 warning stays silent when clean"
assert_contains "$NO_MISCOUNT" "Nothing — every live issue is dispatchable." "a clean backlog says so"

section "usage errors"

set +e
bash "$SCRIPT" --state sideways >/dev/null 2>&1; assert_eq "$?" "2" "an invalid --state exits 2"
bash "$SCRIPT" --limit banana  >/dev/null 2>&1; assert_eq "$?" "2" "an invalid --limit exits 2"
bash "$SCRIPT" --nope          >/dev/null 2>&1; assert_eq "$?" "2" "an unknown option exits 2"
bash "$SCRIPT" --repo          >/dev/null 2>&1; assert_eq "$?" "2" "a flag with no value exits 2"
set -e

# --- summary ----------------------------------------------------------------

printf '\n%s\n' "────────────────────────────────"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf '\nfailed assertions:\n'
  printf '  - %s\n' "${FAIL_NAMES[@]}"
  exit 1
fi
