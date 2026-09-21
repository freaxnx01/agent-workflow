#!/usr/bin/env bash
#
# run-autopilot-eligible-tests.sh — Layer-1 fixture tests for
# scripts/lib/autopilot-eligible.sh (no network, gh mocked). Asserts the
# repo-eligibility gate: ai-review-ai-merge, autopilot-test-gate, and #263
# (the gate must have at least one completed run).
#
# Usage: tests/run-autopilot-eligible-tests.sh
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

# shellcheck source=scripts/lib/autopilot-eligible.sh disable=SC1091
source "$ROOT/scripts/lib/autopilot-eligible.sh"

# The three gh calls repo_eligible makes are distinguished by these substrings:
#   contents/.github/workflows/agent.yml   → the consumer stub
#   actions/workflows/                     → the test gate's runs
#   repos/o/r --jq .default_branch         → the default branch
write_map() {
  local agent_yml="$1" runs="$2" dest="$3"
  {
    printf 'contents/.github/workflows/agent.yml\t%s\n' "$agent_yml"
    printf 'actions/workflows/\t%s\n' "$runs"
    printf 'repos/o/r\t%s\n' "$FIX/repo-meta.json"
  } > "$dest"
}

section "eligible"

write_map "$FIX/agent-yml-good.yml" "$FIX/runs-one.json" "$TMPDIR_T/good.map"
rc=0
reason="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/good.map" repo_eligible o/r)" || rc=$?
assert_eq "all conditions met returns 0" "0" "$rc"
case "$reason" in
  *eligible*) pass "reason says eligible" ;;
  *) fail "reason says eligible" "reason was: $reason" ;;
esac
case "$reason" in
  *ci.yml*) pass "reason names the gate" ;;
  *) fail "reason names the gate" "reason was: $reason" ;;
esac

section "ai-review-ai-merge not set"

write_map "$FIX/agent-yml-no-merge.yml" "$FIX/runs-one.json" "$TMPDIR_T/nomerge.map"
rc=0
reason="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/nomerge.map" repo_eligible o/r)" || rc=$?
assert_eq "ai-review-ai-merge false returns 1" "1" "$rc"
case "$reason" in
  *ai-review-ai-merge*) pass "reason names ai-review-ai-merge" ;;
  *) fail "reason names ai-review-ai-merge" "reason was: $reason" ;;
esac

section "no test gate declared"

write_map "$FIX/agent-yml-no-gate.yml" "$FIX/runs-one.json" "$TMPDIR_T/nogate.map"
rc=0
reason="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/nogate.map" repo_eligible o/r)" || rc=$?
assert_eq "missing autopilot-test-gate returns 1" "1" "$rc"
case "$reason" in
  *autopilot-test-gate*) pass "reason names autopilot-test-gate" ;;
  *) fail "reason names autopilot-test-gate" "reason was: $reason" ;;
esac

section "test gate has never run"

write_map "$FIX/agent-yml-good.yml" "$FIX/runs-none.json" "$TMPDIR_T/noruns.map"
rc=0
reason="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/noruns.map" repo_eligible o/r)" || rc=$?
assert_eq "zero completed runs returns 1" "1" "$rc"
case "$reason" in
  *"never completed"*) pass "reason says the gate never ran" ;;
  *) fail "reason says the gate never ran" "reason was: $reason" ;;
esac

section "test gate does not exist"

write_map "$FIX/agent-yml-good.yml" "$FIX/runs-one.json" "$TMPDIR_T/gate404.map"
printf 'actions/workflows/\n' > "$TMPDIR_T/gate404.fail"
rc=0
reason="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/gate404.map" GH_MOCK_FAIL_MAP="$TMPDIR_T/gate404.fail" repo_eligible o/r)" || rc=$?
assert_eq "gate 404 returns 1" "1" "$rc"
case "$reason" in
  *"not found"*) pass "reason says the gate was not found" ;;
  *) fail "reason says the gate was not found" "reason was: $reason" ;;
esac

section "no agent.yml at all"

printf 'contents/.github/workflows/agent.yml\n' > "$TMPDIR_T/noyml.fail"
rc=0
reason="$(GH_MOCK_FAIL_MAP="$TMPDIR_T/noyml.fail" repo_eligible o/r)" || rc=$?
assert_eq "no agent.yml returns 1" "1" "$rc"
case "$reason" in
  *agent.yml*) pass "reason names the missing agent.yml" ;;
  *) fail "reason names the missing agent.yml" "reason was: $reason" ;;
esac

printf '\n%s──────────%s\n' "$C_DIM" "$C_OFF"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf -- '  - %s\n' "$n"; done
  exit 1
fi
exit 0
