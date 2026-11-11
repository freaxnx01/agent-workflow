#!/usr/bin/env bash
#
# run-retry-policy-tests.sh — Layer-1 tests for scripts/lib/retry-policy.sh:
# the retry decision table, one case per class x attempt boundary.
#
# Usage: tests/run-retry-policy-tests.sh
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
assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then pass "$name"; else fail "$name" "expected: $expected | actual: $actual"; fi
}
assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$name"; else fail "$name" "missing: $needle"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=../scripts/lib/retry-policy.sh
source "$ROOT/scripts/lib/retry-policy.sh"

# check <name> <class> <attempt> <decision> <delay> — env is inherited from the caller's subshell.
check() {
  local name="$1" class="$2" attempt="$3" want_decision="$4" want_delay="$5" out
  out="$(retry_policy "$class" "$attempt")"
  assert_eq "$name" "decision=$want_decision"$'\n'"delay=$want_delay" "$out"
}

section "decision table"
check "success 1"         success 1 stop 0
check "rate_limit 1"      rate_limit 1 retry 300
check "rate_limit 2"      rate_limit 2 retry 300
check "rate_limit 3"      rate_limit 3 stop 0
check "transient 1"       transient 1 retry 10
check "transient 2"       transient 2 retry 20
check "transient 3"       transient 3 stop 0
check "task_failure 1"    task_failure 1 retry 10
check "task_failure 2"    task_failure 2 stop 0

section "operator-intervention classes stop silently"
for cls in out_of_credits model_not_found api_auth bug; do
  check "$cls 1" "$cls" 1 stop 0
  retry_policy "$cls" 1 >/dev/null 2>"$TMP/err"
  assert_eq "$cls 1 stderr empty" "" "$(cat "$TMP/err")"
done

section "unknown class"
out="$(retry_policy nonsense 1 2>"$TMP/err")"
assert_eq "nonsense 1 stops" $'decision=stop\ndelay=0' "$out"
assert_contains "nonsense 1 warns" 'unknown CLASS "nonsense"' "$(cat "$TMP/err")"

section "env overrides"
out="$(MAX_RETRIES_TASK=2 retry_policy task_failure 2)"
assert_eq "MAX_RETRIES_TASK=2 task_failure 2 retries" $'decision=retry\ndelay=10' "$out"
out="$(DELAY_OVERRIDE_SEC=0 retry_policy rate_limit 1)"
assert_eq "DELAY_OVERRIDE_SEC=0 rate_limit 1" $'decision=retry\ndelay=0' "$out"
out="$(DELAY_OVERRIDE_SEC=7 retry_policy api_auth 1)"
assert_eq "DELAY_OVERRIDE_SEC=7 api_auth 1 overrides on stop" $'decision=stop\ndelay=7' "$out"

out="$(MAX_RETRIES_RATE=1 retry_policy rate_limit 1)"
assert_eq "MAX_RETRIES_RATE=1 rate_limit 1 stops" $'decision=stop\ndelay=0' "$out"
out="$(MAX_RETRIES_TRANS=1 retry_policy transient 1)"
assert_eq "MAX_RETRIES_TRANS=1 transient 1 stops" $'decision=stop\ndelay=0' "$out"

section "usage"
rc=0; retry_policy >/dev/null 2>&1 || rc=$?
assert_eq "no arguments returns 2" "2" "$rc"
rc=0; retry_policy rate_limit >/dev/null 2>&1 || rc=$?
assert_eq "one argument returns 2" "2" "$rc"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
