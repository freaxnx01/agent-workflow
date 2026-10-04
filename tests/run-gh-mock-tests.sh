#!/usr/bin/env bash
#
# run-gh-mock-tests.sh — Layer-1 fixture tests for tests/mocks/gh.
# Tests the response seams (GH_MOCK_FAIL_MAP and GH_MOCK_STDOUT_MAP).
#
# Usage: tests/run-gh-mock-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT

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

export PATH="$ROOT/tests/mocks:$PATH"
export GH_MOCK_LOG="$TMPDIR_T/gh.log"
: > "$GH_MOCK_LOG"

section "argv logging still works"

gh issue list --repo o/r >/dev/null
assert_eq "argv logged" "issue list --repo o/r" "$(tail -1 "$GH_MOCK_LOG")"

section "GH_MOCK_STDOUT_MAP"

printf '{"ok":true}\n' > "$TMPDIR_T/body.json"
printf 'issue list\t%s\n' "$TMPDIR_T/body.json" > "$TMPDIR_T/stdout.map"

out="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/stdout.map" gh issue list --repo o/r)"
assert_eq "matching pattern serves the fixture" '{"ok":true}' "$out"

out="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/stdout.map" gh pr list --repo o/r)"
assert_eq "non-matching pattern serves nothing" "" "$out"

printf 'issue list\t%s\nissue\t/dev/null\n' "$TMPDIR_T/body.json" > "$TMPDIR_T/first.map"
out="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/first.map" gh issue list --repo o/r)"
assert_eq "first matching line wins" '{"ok":true}' "$out"

section "GH_MOCK_FAIL_MAP"

printf 'actions/workflows\n' > "$TMPDIR_T/fail.map"
rc=0
GH_MOCK_FAIL_MAP="$TMPDIR_T/fail.map" gh api repos/o/r/actions/workflows/ci.yml/runs >/dev/null 2>&1 || rc=$?
assert_eq "matching fail pattern exits 1" "1" "$rc"

rc=0
GH_MOCK_FAIL_MAP="$TMPDIR_T/fail.map" gh api repos/o/r >/dev/null 2>&1 || rc=$?
assert_eq "non-matching fail pattern exits 0" "0" "$rc"

rc=0
GH_MOCK_FAIL_MAP="$TMPDIR_T/fail.map" GH_MOCK_STDOUT_MAP="$TMPDIR_T/stdout.map" \
  gh api repos/o/r/actions/workflows/ci.yml/runs >/dev/null 2>&1 || rc=$?
assert_eq "fail map is consulted before stdout map" "1" "$rc"

printf '\n%s──────────%s\n' "$C_DIM" "$C_OFF"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf -- '  - %s\n' "$n"; done
  exit 1
fi
exit 0
