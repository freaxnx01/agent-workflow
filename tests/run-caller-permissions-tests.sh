#!/usr/bin/env bash
#
# run-caller-permissions-tests.sh — Layer-1 tests for
# scripts/check-caller-permissions.sh, plus the invariant it exists for: every
# consumer stub this repo ships or documents grants every permission the
# reusable workflow it calls requests (#434).
#
# A caller that grants less makes GitHub refuse the run at `startup_failure`,
# with zero jobs and no logs. That shipped once already: agent-implement.yml
# gained `actions: write` (#351) and 38 consumer stubs did not.
#
# Usage: tests/run-caller-permissions-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/scripts/check-caller-permissions.sh"
FIX="$ROOT/tests/fixtures/caller-permissions"

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

# check <reusable> — caller on stdin; sets OUT and RC. Feed it with `< <(...)`,
# never a pipe: a piped call runs in a subshell and OUT/RC never reach us.
check() {
  RC=0
  OUT="$(bash "$CHECK" - "$1" 2>&1)" || RC=$?
}
assert_clean() {  # <name>
  if [[ "$RC" -eq 0 && -z "$OUT" ]]; then pass "$1"; else fail "$1" "rc=$RC out=$OUT"; fi
}
assert_gap() {  # <expected line> <name>
  if [[ "$RC" -eq 1 && "$OUT" == *"$1"* ]]; then pass "$2"; else fail "$2" "rc=$RC out=$OUT"; fi
}

# --- the checker --------------------------------------------------------

section "checker — semantics"

check "$FIX/reusable.yml" < <(printf 'permissions:\n  contents: write\n  issues: read\n  actions: write\n')
assert_clean "a caller granting every requested scope passes"

check "$FIX/reusable.yml" < <(printf 'permissions:\n  contents: write\n  issues: read\n')
assert_gap 'actions: needs write, caller grants none' "a missing scope is reported (the #434 shape)"

check "$FIX/reusable.yml" < <(printf 'permissions:\n  contents: read\n  issues: read\n  actions: write\n')
assert_gap 'contents: needs write, caller grants read' "read does not satisfy write"

check "$FIX/reusable.yml" < <(printf 'permissions:\n  contents: write\n  actions: write\n')
assert_gap 'issues: needs read, caller grants none' "a job without its own block inherits the workflow-level one"

check "$FIX/reusable.yml" < <(printf 'on: push\njobs:\n  c:\n    uses: x\n')
assert_gap 'contents: needs write, caller grants none' "no permissions block grants nothing"

check "$FIX/reusable.yml" < <(printf 'permissions: write-all\n')
assert_clean "write-all satisfies everything"

check "$FIX/reusable.yml" < <(printf 'permissions: read-all\n')
assert_gap 'actions: needs write, caller grants read' "read-all does not satisfy write"

check "$FIX/reusable.yml" < <(printf 'permissions:\n  contents: read\njobs:\n  c:\n    permissions:\n      contents: write\n      issues: write\n      actions: write\n    uses: x\n')
assert_clean "a caller's job-level block replaces its workflow-level one"

RC=0; bash "$CHECK" >/dev/null 2>&1 || RC=$?
if [[ "$RC" -eq 2 ]]; then pass "missing arguments exit 2"; else fail "missing arguments exit 2" "rc=$RC"; fi

IMPLEMENT="$ROOT/.github/workflows/agent-implement.yml"
CHAIN="$ROOT/.github/workflows/chain-dispatch.yml"

# yaml_fences <md> <uses-pattern> — every complete stub (a fence with both an
# `on:` trigger and a `uses:` of the pattern) in a doc, NUL-separated.
yaml_fences() {
  awk -v pat="$2" '
    /^```yaml/ { inside = 1; buf = ""; next }
    /^```/     { if (inside && buf ~ pat && buf ~ /(^|\n)on:/) printf "%s%c", buf, 0; inside = 0; next }
    inside     { buf = buf $0 "\n" }' "$1"
}

# onboard_stub <function> — what onboard-consumer.sh generates, extracted from
# the shipped script so the test cannot drift from it.
onboard_stub() {
  # shellcheck disable=SC2034
  (
    AGENT=claude MODEL=claude-sonnet-5 REF=v2 RUNNER_LABELS='["ubuntu-latest"]'
    PIPELINE_REPO=freaxnx01/agent-workflow AI_MERGE=false HUMAN_MERGE=true
    # shellcheck disable=SC1090
    source <(sed -n "/^$1()/,/^}/p" "$ROOT/scripts/onboard-consumer.sh")
    "$1"
  )
}

# --- the invariant ------------------------------------------------------

section "invariant — every shipped stub grants what its reusable workflow requests"

n=0
while IFS= read -r -d '' stub; do
  n=$((n + 1))
  check "$IMPLEMENT" < <(printf '%s' "$stub")
  assert_clean "CONSUMER-SETUP.md agent stub #$n ⊇ agent-implement.yml"
done < <(yaml_fences "$ROOT/docs/CONSUMER-SETUP.md" 'agent-implement[.]yml@')
# A vacuous pass is the failure mode to fear here: rename the fence and the
# loop above silently checks nothing.
if (( n >= 1 )); then pass "found the documented agent stub"; else fail "found the documented agent stub" "no fence matched"; fi

n=0
while IFS= read -r -d '' stub; do
  n=$((n + 1))
  check "$CHAIN" < <(printf '%s' "$stub")
  assert_clean "CONSUMER-SETUP.md chain stub #$n ⊇ chain-dispatch.yml"
done < <(yaml_fences "$ROOT/docs/CONSUMER-SETUP.md" 'chain-dispatch[.]yml@')
if (( n >= 1 )); then pass "found the documented chain stub"; else fail "found the documented chain stub" "no fence matched"; fi

check "$IMPLEMENT" < <(onboard_stub build_agent_yml)
assert_clean "onboard-consumer.sh agent stub ⊇ agent-implement.yml"

check "$CHAIN" < <(onboard_stub build_chain_yml)
assert_clean "onboard-consumer.sh chain stub ⊇ chain-dispatch.yml"

check "$IMPLEMENT" < "$ROOT/.github/workflows/agent.yml"
assert_clean "this repo's own agent.yml ⊇ agent-implement.yml"

# --- summary ------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'; printf '  - %s\n' "${FAIL_NAMES[@]}"
  exit 1
fi
