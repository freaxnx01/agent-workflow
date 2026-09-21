#!/usr/bin/env bash
#
# run-autopilot-candidates-tests.sh — Layer-1 fixture tests for
# scripts/lib/autopilot-candidates.sh (no network, gh mocked). Asserts the
# selection query: exclusion rules, ordering, the limit, and gh-failure
# propagation.
#
# Usage: tests/run-autopilot-candidates-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/tests/fixtures/autopilot"
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

# shellcheck source=scripts/lib/autopilot-candidates.sh disable=SC1091
source "$ROOT/scripts/lib/autopilot-candidates.sh"

printf 'issue list\t%s\n' "$FIX/issues-mixed.json" > "$TMPDIR_T/mixed.map"
printf 'issue list\t%s\n' "$FIX/issues-empty.json" > "$TMPDIR_T/empty.map"

section "selection and ordering"

out="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/mixed.map" autopilot_candidates o/r 10 | tr '\n' ' ')"
assert_eq "eligible issues, oldest first" "41 49 50 " "$out"

section "the limit"

out="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/mixed.map" autopilot_candidates o/r 2 | tr '\n' ' ')"
assert_eq "limit truncates, keeping the oldest" "41 49 " "$out"

out="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/mixed.map" autopilot_candidates o/r 1 | tr '\n' ' ')"
assert_eq "limit of 1 yields the oldest" "41 " "$out"

section "exclusions"

# Each of these numbers is in the fixture and must never be selected.
out="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/mixed.map" autopilot_candidates o/r 10)"
for n in 42 43 44 45 46 47 48; do
  if printf '%s\n' "$out" | grep -qx "$n"; then
    fail "issue $n excluded" "it was selected"
  else
    pass "issue $n excluded"
  fi
done

section "empty result"

out="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/empty.map" autopilot_candidates o/r 10)"
assert_eq "no issues yields no output" "" "$out"

section "the query"

: > "$GH_MOCK_LOG"
GH_MOCK_STDOUT_MAP="$TMPDIR_T/mixed.map" autopilot_candidates o/r 10 >/dev/null
logged="$(tail -1 "$GH_MOCK_LOG")"
case "$logged" in
  *"--repo o/r"*) pass "queries the named repo" ;;
  *) fail "queries the named repo" "argv was: $logged" ;;
esac
case "$logged" in
  *"--label needs-enrichment"*) pass "filters needs-enrichment server-side" ;;
  *) fail "filters needs-enrichment server-side" "argv was: $logged" ;;
esac
case "$logged" in
  *"--state open"*) pass "asks for open issues only" ;;
  *) fail "asks for open issues only" "argv was: $logged" ;;
esac

section "gh failure"

printf 'issue list\n' > "$TMPDIR_T/fail.map"
rc=0
GH_MOCK_FAIL_MAP="$TMPDIR_T/fail.map" autopilot_candidates o/r 10 >/dev/null 2>&1 || rc=$?
if (( rc != 0 )); then pass "gh failure propagates"; else fail "gh failure propagates" "returned 0"; fi

printf '\n%s──────────%s\n' "$C_DIM" "$C_OFF"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf -- '  - %s\n' "$n"; done
  exit 1
fi
exit 0
