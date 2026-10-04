#!/usr/bin/env bash
#
# run-parse-enrich-args-tests.sh — Layer-1 fixture tests for scripts/lib/parse-enrich-args.sh
# (no network). Sources the script and asserts parse_enrich_args's output.
#
# Usage: tests/run-parse-enrich-args-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib/parse-enrich-args.sh"

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

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$name"
  else
    fail "$name" "expected: $expected | actual: $actual"
  fi
}

# run_parse <args>  — parses and returns "ISSUE=<n>|QUICK=yes|no"
run_parse() {
  local args="$1"
  # shellcheck disable=SC1090
  source "$LIB"
  local output
  output=$(parse_enrich_args "$args" 2>&1) || true
  echo "$output"
}

run_parse_exit() {
  local args="$1"
  # shellcheck disable=SC1090
  source "$LIB"
  parse_enrich_args "$args" >/dev/null 2>&1 && echo "0" || echo "1"
}

# --- cases -----------------------------------------------------------------

section "basic cases"

assert_eq "issue number only" \
  "ISSUE=256
QUICK=no" \
  "$(run_parse "256")"

assert_eq "issue with --quick flag" \
  "ISSUE=256
QUICK=yes" \
  "$(run_parse "256 --quick")"

assert_eq "--quick before issue" \
  "ISSUE=256
QUICK=yes" \
  "$(run_parse "--quick 256")"

assert_eq "issue with leading #" \
  "ISSUE=256
QUICK=no" \
  "$(run_parse "#256")"

assert_eq "issue with # and --quick" \
  "ISSUE=256
QUICK=yes" \
  "$(run_parse "#256 --quick")"

section "error cases"

assert_eq "no issue number, exit 1" \
  "1" \
  "$(run_parse_exit "--quick")"

assert_eq "no issue number, no flag, exit 1" \
  "1" \
  "$(run_parse_exit "")"

assert_eq "non-numeric issue, exit 1" \
  "1" \
  "$(run_parse_exit "abc")"

# --- summary ---------------------------------------------------------------

printf '\n%s─────%s\n' "$C_DIM" "$C_OFF"
printf '  %s%d passed%s' "$C_GREEN" "$PASS" "$C_OFF"
if [ "$FAIL" -gt 0 ]; then
  printf ', %s%d failed%s\n' "$C_RED" "$FAIL" "$C_OFF"
  printf '\nFailed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf '  - %s\n' "$n"; done
  exit 1
fi
printf '\n'
exit 0
