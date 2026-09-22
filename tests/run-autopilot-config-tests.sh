#!/usr/bin/env bash
#
# run-autopilot-config-tests.sh — Layer-1 fixture tests for
# scripts/lib/autopilot-config.sh (no network). Sources the lib and asserts
# what load_autopilot_config sets, and what it refuses.
#
# Usage: tests/run-autopilot-config-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib/autopilot-config.sh"
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

# shellcheck source=scripts/lib/autopilot-config.sh disable=SC1091
source "$LIB"

section "valid config"

rc=0; load_autopilot_config "$FIX/config-valid.conf" >/dev/null 2>&1 || rc=$?
assert_eq "valid config returns 0" "0" "$rc"
assert_eq "max_per_run parsed" "2" "$AUTOPILOT_MAX_PER_RUN"
assert_eq "enrich_timeout parsed" "900" "$AUTOPILOT_ENRICH_TIMEOUT"
assert_eq "two repos parsed" "2" "${#AUTOPILOT_REPOS[@]}"
assert_eq "first repo" "freaxnx01/agent-action-sandbox" "${AUTOPILOT_REPOS[0]}"
assert_eq "trailing comment stripped" "freaxnx01/game-tschau-sepp" "${AUTOPILOT_REPOS[1]}"
assert_eq "two gates parsed" "2" "${#AUTOPILOT_GATES[@]}"
assert_eq "first repo's gate" "ci.yml" "${AUTOPILOT_GATES[freaxnx01/agent-action-sandbox]}"
assert_eq "second repo's gate (trailing comment stripped)" "build.yml" "${AUTOPILOT_GATES[freaxnx01/game-tschau-sepp]}"

section "defaults"

printf 'repo=freaxnx01/agent-action-sandbox:ci.yml\n' > "$TMPDIR_T/minimal.conf"
rc=0; load_autopilot_config "$TMPDIR_T/minimal.conf" >/dev/null 2>&1 || rc=$?
assert_eq "minimal config returns 0" "0" "$rc"
assert_eq "max_per_run defaults to 3" "3" "$AUTOPILOT_MAX_PER_RUN"
assert_eq "enrich_timeout defaults to 1800" "1800" "$AUTOPILOT_ENRICH_TIMEOUT"

section "a second load does not inherit stale gates"

# The prior section left AUTOPILOT_GATES holding both config-valid.conf repos.
# A fresh load of a single-repo config must not still carry the other one —
# that would prove AUTOPILOT_GATES was reset like AUTOPILOT_REPOS, not just
# appended to.
rc=0; load_autopilot_config "$TMPDIR_T/minimal.conf" >/dev/null 2>&1 || rc=$?
assert_eq "reload after config-valid.conf returns 0" "0" "$rc"
assert_eq "reload has exactly one gate" "1" "${#AUTOPILOT_GATES[@]}"
assert_eq "reload's gate is the new repo's" "ci.yml" "${AUTOPILOT_GATES[freaxnx01/agent-action-sandbox]}"
if [[ -v 'AUTOPILOT_GATES[freaxnx01/game-tschau-sepp]' ]]; then
  fail "reload does not inherit the prior config's other repo" \
    "still present: ${AUTOPILOT_GATES[freaxnx01/game-tschau-sepp]}"
else
  pass "reload does not inherit the prior config's other repo"
fi

section "refusals"

for case_name in unknown-key bad-max bad-repo no-repos no-gate bad-gate gate-traversal; do
  rc=0; load_autopilot_config "$FIX/config-$case_name.conf" >/dev/null 2>&1 || rc=$?
  assert_eq "$case_name returns 1" "1" "$rc"
done

err="$(load_autopilot_config "$FIX/config-no-gate.conf" 2>&1 >/dev/null || true)"
case "$err" in
  *"needs a :<test-gate workflow file>"*) pass "a repo with no gate names the problem" ;;
  *) fail "a repo with no gate names the problem" "stderr was: $err" ;;
esac

err="$(load_autopilot_config "$FIX/config-bad-gate.conf" 2>&1 >/dev/null || true)"
case "$err" in
  *"gate must be a bare workflow filename"*) pass "a gate failing the filename pattern names the problem" ;;
  *) fail "a gate failing the filename pattern names the problem" "stderr was: $err" ;;
esac

err="$(load_autopilot_config "$FIX/config-gate-traversal.conf" 2>&1 >/dev/null || true)"
case "$err" in
  *"gate must be a bare workflow filename"*) pass "a gate containing ../ is rejected" ;;
  *) fail "a gate containing ../ is rejected" "stderr was: $err" ;;
esac

rc=0; load_autopilot_config "$FIX/does-not-exist.conf" >/dev/null 2>&1 || rc=$?
assert_eq "missing file returns 1" "1" "$rc"

err="$(load_autopilot_config "$FIX/config-unknown-key.conf" 2>&1 >/dev/null || true)"
case "$err" in
  *"unknown key"*) pass "unknown key names the problem" ;;
  *) fail "unknown key names the problem" "stderr was: $err" ;;
esac

section "AUTOPILOT_CONFIG env default"

rc=0
AUTOPILOT_CONFIG="$FIX/config-valid.conf" load_autopilot_config >/dev/null 2>&1 || rc=$?
assert_eq "reads AUTOPILOT_CONFIG when given no argument" "0" "$rc"

printf '\n%s──────────%s\n' "$C_DIM" "$C_OFF"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf -- '  - %s\n' "$n"; done
  exit 1
fi
exit 0
