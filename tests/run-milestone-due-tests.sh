#!/usr/bin/env bash
#
# run-milestone-due-tests.sh — Layer-1 contract tests for how the console sends
# a GitHub milestone due date.
#
# GitHub keeps only the date of `due_on` and reads it back as `T00:00:00Z`. #460
# switched the commands from midday to midnight UTC on the strength of a
# midday write reading back as midnight (2026-10-04, milestone #5). Sending
# midnight then rolled the date back: on 2026-10-16 a midnight-UTC write of
# 2026-11-30 read back as 2026-11-29 (anim-bossinfo-ch/ArchiveRestApiNextGen
# milestones 2 and 3), while the same dates sent via PATCH as `T12:00:00Z` read back
# correct. So the commands send midday again; the read-back still compares the
# date part only.
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

section "no command sends midnight, which can roll the date back"
if hits="$(grep -rnE 'due_on=.*T00:00:00Z' "$ROOT/commands")"; then
  fail "no T00:00:00Z due_on write in commands/" "$hits"
else
  pass "no T00:00:00Z due_on write in commands/"
fi

section "GitHub creation sends midday UTC"
for cmd in milestone.md new.md; do
  if grep -qF 'due_on="<YYYY-MM-DD>T12:00:00Z"' "$ROOT/commands/$cmd"; then
    pass "$cmd sends T12:00:00Z"
  else
    fail "$cmd sends T12:00:00Z"
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
