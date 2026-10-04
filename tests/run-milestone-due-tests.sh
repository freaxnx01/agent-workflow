#!/usr/bin/env bash
#
# run-milestone-due-tests.sh — Layer-1 contract tests for how the console sends
# a GitHub milestone due date.
#
# GitHub keeps only the date of `due_on`: a milestone created or patched with
# `2026-10-11T12:00:00Z` reads back as `2026-10-11T00:00:00Z` (verified
# 2026-10-04 on freaxnx01/agent-workflow milestone #5). The commands used to
# send midday UTC "so a viewer timezone can't roll the date back"; that time
# never survives the write, so the commands now send the midnight form the API
# stores, and a read-back can compare the date exactly.
#
# Usage: tests/run-milestone-due-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

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

section "no command sends a time GitHub discards"
if hits="$(grep -rn 'T12:00:00Z' "$ROOT/commands")"; then
  fail "no T12:00:00Z due_on in commands/" "$hits"
else
  pass "no T12:00:00Z due_on in commands/"
fi

section "GitHub creation sends the stored midnight form"
for cmd in milestone.md new.md; do
  if grep -qF 'T00:00:00Z' "$ROOT/commands/$cmd"; then
    pass "$cmd sends T00:00:00Z"
  else
    fail "$cmd sends T00:00:00Z"
  fi
done

# --- summary ---------------------------------------------------------------

printf '\n%s─────%s\n' "$C_DIM" "$C_OFF"
printf '  %s%d passed%s' "$C_GREEN" "$PASS" "$C_OFF"
[ "$FAIL" -gt 0 ] && printf ', %s%d failed%s' "$C_RED" "$FAIL" "$C_OFF"
printf '\n'
if [ "$FAIL" -gt 0 ]; then
  printf '\n  failed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf '    - %s\n' "$n"; done
  exit 1
fi
