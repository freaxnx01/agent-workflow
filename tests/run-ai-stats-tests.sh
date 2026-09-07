#!/usr/bin/env bash
#
# run-ai-stats-tests.sh — Layer-1 fixture tests for scripts/lib/ai-stats.sh.
#
# Drives the grading and rendering halves of ai-stats.sh from a curated records
# fixture via --from, so no network, no gh and no GitHub API are involved. The
# collection half (GraphQL) is covered by Layer 3, not here.
#
# Usage: tests/run-ai-stats-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/lib/ai-stats.sh"
FIXTURE="$ROOT/tests/fixtures/ai-stats-records.json"

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

grade_of() {
  jq -r --argjson n "$2" '.[] | select(.issue == $n) | .grade' <<< "$1"
}

# --- grading ----------------------------------------------------------------

section "grading"

GRADED="$(bash "$SCRIPT" --from "$FIXTURE" --json)"

assert_eq "$(grade_of "$GRADED" 1)" "A" "shipped on one cheap attempt grades A"
assert_eq "$(grade_of "$GRADED" 2)" "B" "shipped on the second attempt grades B"
assert_eq "$(grade_of "$GRADED" 3)" "B" "one attempt over the cheap threshold grades B"
assert_eq "$(grade_of "$GRADED" 4)" "C" "shipped on the third attempt grades C"
assert_eq "$(grade_of "$GRADED" 5)" "D" "shipped but costly grades D"
assert_eq "$(grade_of "$GRADED" 6)" "F" "never shipped grades F"

assert_eq "$(jq -r '.[] | select(.issue == 4) | .attempts | tostring' <<< "$GRADED")" "3" \
  "attempts counts every ai-implement label event"
assert_eq "$(jq -r '.[] | select(.issue == 4) | .cost | tostring' <<< "$GRADED")" "0.4" \
  "cost sums every run report on the issue"

# --- --since windowing ------------------------------------------------------

section "--since windowing"

WINDOWED="$(bash "$SCRIPT" --from "$FIXTURE" --since 2026-08-01 --json)"

assert_eq "$(jq -r 'length | tostring' <<< "$WINDOWED")" "6" \
  "--since drops issues whose dispatches all predate the window"
assert_not_contains "$WINDOWED" "claude-haiku-4-5" \
  "--since drops the run reports of excluded issues"

# --- report rendering -------------------------------------------------------

section "report rendering"

REPORT="$(bash "$SCRIPT" --from "$FIXTURE" --limit all)"

assert_contains "$REPORT" "**Repos:** 2"        "report counts distinct repos"
assert_contains "$REPORT" "**Issues:** 7"       "report counts dispatched issues"
assert_contains "$REPORT" "**Dispatches:** 11"  "report counts dispatch attempts"
assert_contains "$REPORT" "**Shipped:** 5"      "report counts shipped issues"
assert_contains "$REPORT" "| Issue shipped | 71% (5/7) |" "report derives the issue ship rate"
assert_contains "$REPORT" "| Per dispatch shipped | 45% (5/11) |" "report derives the per-dispatch rate"
assert_contains "$REPORT" "| A | 1 |"           "grade table counts A issues"
assert_contains "$REPORT" "| F | 2 |"           "grade table counts F issues"
assert_contains "$REPORT" "| claude |"          "agent table lists claude"
assert_contains "$REPORT" "| opencode |"        "agent table lists opencode"
assert_contains "$REPORT" "| openai/gpt-oss-120b |" "model table lists the OpenRouter model"
assert_contains "$REPORT" "acme/beta#5"         "per-issue table names repo and issue"

# Money is always rendered with two decimals — $0.4 / $12.8 read as truncated.
# shellcheck disable=SC2016  # literal dollar amounts, not expansions
assert_contains "$REPORT" '$0.40'               "money renders trailing cents"
# shellcheck disable=SC2016  # literal dollar amounts, not expansions
assert_not_contains "$REPORT" '$0.4 '           "money never renders a single decimal"

# --- enrichment correlation -------------------------------------------------

section "enrichment correlation"

assert_contains "$REPORT" "## By enrichment"  "report has an enrichment section"
assert_contains "$REPORT" "| enriched |"      "enrichment table lists enriched issues"
assert_contains "$REPORT" "| none |"          "enrichment table lists unenriched issues"
assert_contains "$REPORT" "| unknown |"       "runs predating the Plan stamp are counted separately"

assert_eq "$(bash "$SCRIPT" --from "$FIXTURE" --json \
              | jq -r '.[] | select(.issue == 1) | .plan')" "enriched" \
  "an issue whose run reported a plan is marked enriched"
assert_eq "$(bash "$SCRIPT" --from "$FIXTURE" --json \
              | jq -r '.[] | select(.issue == 6) | .plan')" "none" \
  "an issue whose run reported no plan is marked none"
assert_eq "$(bash "$SCRIPT" --from "$FIXTURE" --json \
              | jq -r '.[] | select(.issue == 3) | .plan')" "unknown" \
  "an issue with no Plan field is marked unknown"

# --- repo exclusion ---------------------------------------------------------

section "repo exclusion"

# A sandbox repo exists to absorb failed runs; counting its zeroes drags every
# fleet number down for no signal. Excluded by default, but reported, never
# silently dropped.
assert_not_contains "$REPORT" "acme/demo-sandbox#8" "sandbox issues stay out of the per-issue table"
assert_contains "$REPORT" "## Excluded"             "excluded repos get their own section"
assert_contains "$REPORT" "acme/demo-sandbox"       "the excluded repo is named"
assert_contains "$REPORT" "3 dispatches"            "the excluded repo's dispatches are still reported"

KEPT_JSON="$(bash "$SCRIPT" --from "$FIXTURE" --json)"
assert_eq "$(jq -r '[.[] | select(.repo == "acme/demo-sandbox")] | length | tostring' <<< "$KEPT_JSON")" "0" \
  "--json emits only the kept records"

ALL_REPOS="$(bash "$SCRIPT" --from "$FIXTURE" --no-exclude)"
assert_contains "$ALL_REPOS" "**Repos:** 3"        "--no-exclude counts the sandbox"
assert_contains "$ALL_REPOS" "**Dispatches:** 14"  "--no-exclude counts the sandbox dispatches"
assert_not_contains "$ALL_REPOS" "## Excluded"     "--no-exclude has nothing to exclude"

CUSTOM="$(bash "$SCRIPT" --from "$FIXTURE" --exclude 'beta')"
assert_contains "$CUSTOM" "**Repos:** 2"           "--exclude replaces the default globs"
assert_contains "$CUSTOM" "acme/beta"              "--exclude names what it dropped"
assert_contains "$CUSTOM" "acme/demo-sandbox#8"    "--exclude 'beta' lets the sandbox back in"

# A repo named explicitly on the command line always counts, glob or not.
NAMED="$(bash "$SCRIPT" --from "$FIXTURE" --repo acme/demo-sandbox)"
assert_contains "$NAMED" "acme/demo-sandbox#8"     "an explicitly named repo is never excluded"

# --- row limit --------------------------------------------------------------

section "row limit"

LIMITED="$(bash "$SCRIPT" --from "$FIXTURE" --limit 2)"
assert_eq "$(awk '/^## Per issue/{f=1} f && /^\| [A-F] \|/{n++} END{print n+0}' <<< "$LIMITED")" "2" \
  "--limit caps the per-issue table"

# --- usage errors -----------------------------------------------------------

section "usage errors"

set +e
bash "$SCRIPT" --nope >/dev/null 2>&1; rc_unknown=$?
bash "$SCRIPT" --from /nonexistent.json >/dev/null 2>&1; rc_missing=$?
set -e
assert_eq "$rc_unknown" "2" "unknown option exits 2"
assert_eq "$rc_missing" "2" "unreadable --from file exits 2"

# --- summary ----------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf '  - %s\n' "$n"; done
  exit 1
fi
