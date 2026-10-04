#!/usr/bin/env bash
#
# run-autopilot-eligible-tests.sh — Layer-1 fixture tests for
# scripts/lib/autopilot-eligible.sh (no network, gh mocked). Asserts the
# repo-eligibility gate: ai-review-ai-merge, and #263 (the gate — now passed
# in as an argument, named by the host's autopilot.conf — must have at least
# one completed run).
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

# The gh calls repo_eligible makes, distinguished by these substrings.
#
# ORDER MATTERS: the mock returns the FIRST matching line, and both run queries
# contain `actions/workflows/`. The event=pull_request line must come first or
# it can never be reached — and the pull-request check would silently read the
# branch query's fixture instead of its own.
write_map() {
  local agent_yml="$1" runs="$2" dest="$3"
  local pr_runs="${4:-$FIX/runs-one.json}"
  local protection="${5:-$FIX/protection-required.json}"
  {
    printf 'event=pull_request\t%s\n'                      "$pr_runs"
    printf 'contents/.github/workflows/agent.yml\t%s\n'    "$agent_yml"
    printf 'actions/workflows/\t%s\n'                      "$runs"
    printf 'branches/main/protection\t%s\n'                "$protection"
    printf 'repos/o/r\t%s\n'                               "$FIX/repo-meta.json"
  } > "$dest"
}

section "eligible"

write_map "$FIX/agent-yml-good.yml" "$FIX/runs-one.json" "$TMPDIR_T/good.map"
rc=0
reason="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/good.map" repo_eligible o/r ci.yml)" || rc=$?
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
reason="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/nomerge.map" repo_eligible o/r ci.yml)" || rc=$?
assert_eq "ai-review-ai-merge false returns 1" "1" "$rc"
case "$reason" in
  *ai-review-ai-merge*) pass "reason names ai-review-ai-merge" ;;
  *) fail "reason names ai-review-ai-merge" "reason was: $reason" ;;
esac

section "test gate has never run"

write_map "$FIX/agent-yml-good.yml" "$FIX/runs-none.json" "$TMPDIR_T/noruns.map"
rc=0
reason="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/noruns.map" repo_eligible o/r ci.yml)" || rc=$?
assert_eq "zero completed runs returns 1" "1" "$rc"
case "$reason" in
  *"never completed"*) pass "reason says the gate never ran" ;;
  *) fail "reason says the gate never ran" "reason was: $reason" ;;
esac

section "default branch unreadable"

{
  printf 'contents/.github/workflows/agent.yml\t%s\n' "$FIX/agent-yml-good.yml"
  printf 'actions/workflows/\t%s\n' "$FIX/runs-one.json"
  printf 'repos/o/r\t%s\n' "$FIX/repo-meta-no-branch.json"
} > "$TMPDIR_T/nobranch.map"
rc=0
reason="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/nobranch.map" repo_eligible o/r ci.yml)" || rc=$?
assert_eq "missing default_branch returns 1" "1" "$rc"
case "$reason" in
  *"could not read the default branch"*) pass "reason says the default branch could not be read" ;;
  *) fail "reason says the default branch could not be read" "reason was: $reason" ;;
esac

section "test gate total_count missing"

write_map "$FIX/agent-yml-good.yml" "$FIX/runs-null.json" "$TMPDIR_T/nullruns.map"
rc=0
reason="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/nullruns.map" repo_eligible o/r ci.yml)" || rc=$?
assert_eq "missing total_count returns 1" "1" "$rc"
case "$reason" in
  *"not found"*) pass "reason says the gate was not found" ;;
  *) fail "reason says the gate was not found" "reason was: $reason" ;;
esac

section "test gate does not exist (a genuine 404)"

# The stderr signature is what makes this a real absence rather than a `gh`
# outage; without it this case asserted the conflation #381 fixes — see "gate
# runs query unreadable" below.
write_map "$FIX/agent-yml-good.yml" "$FIX/runs-one.json" "$TMPDIR_T/gate404.map"
printf 'actions/workflows/\tHTTP 404: Not Found\n' > "$TMPDIR_T/gate404.fail"
rc=0
reason="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/gate404.map" GH_MOCK_FAIL_MAP="$TMPDIR_T/gate404.fail" repo_eligible o/r ci.yml)" || rc=$?
assert_eq "gate 404 returns 1" "1" "$rc"
case "$reason" in
  *"not found"*) pass "reason says the gate was not found" ;;
  *) fail "reason says the gate was not found" "reason was: $reason" ;;
esac

section "no agent.yml at all (a genuine 404)"

printf 'contents/.github/workflows/agent.yml\tHTTP 404: Not Found\n' > "$TMPDIR_T/noyml.fail"
rc=0
reason="$(GH_MOCK_FAIL_MAP="$TMPDIR_T/noyml.fail" repo_eligible o/r ci.yml)" || rc=$?
assert_eq "no agent.yml returns 1" "1" "$rc"
case "$reason" in
  *agent.yml*) pass "reason names the missing agent.yml" ;;
  *) fail "reason names the missing agent.yml" "reason was: $reason" ;;
esac

section "gh outage reading agent.yml (D5 — not the same as a missing file)"

# No stderr on this failure, unlike the 404 above — an opaque `gh` failure
# (outage, auth) must NOT be reported as "no .github/workflows/agent.yml":
# that reads as "this repo isn't onboarded" when the real problem is `gh`
# itself, and sends whoever's debugging at 3am down the wrong path.
printf 'contents/.github/workflows/agent.yml\n' > "$TMPDIR_T/outage.fail"
rc=0
reason="$(GH_MOCK_FAIL_MAP="$TMPDIR_T/outage.fail" repo_eligible o/r ci.yml)" || rc=$?
assert_eq "a gh outage returns 1" "1" "$rc"
case "$reason" in
  *"eligibility check failed"*) pass "reason says the check failed, not that the file is missing" ;;
  *) fail "reason says the check failed, not that the file is missing" "reason was: $reason" ;;
esac
case "$reason" in
  *"no .github/workflows/agent.yml"*)
    fail "an outage is not reported as a missing file" "reason was: $reason" ;;
  *) pass "an outage is not reported as a missing file" ;;
esac

section "gate has never run on a pull request (#381)"

# The condition exists to satisfy #263 — no auto-merge on an unrun gate. A
# workflow_dispatch-only workflow satisfies "has completed a run on the default
# branch" while gating nothing: observed on agent-action-sandbox, whose gate
# file's own header read "Manual only. Not part of the agent pipeline".
write_map "$FIX/agent-yml-good.yml" "$FIX/runs-one.json" "$TMPDIR_T/noprruns.map" \
  "$FIX/runs-none.json"
rc=0
reason="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/noprruns.map" repo_eligible o/r ci.yml)" || rc=$?
assert_eq "gate with no pull_request runs returns 1" "1" "$rc"
case "$reason" in
  *"pull request"*) pass "reason names the pull request" ;;
  *) fail "reason names the pull request" "reason was: $reason" ;;
esac

section "default branch has no required status checks (#381)"

write_map "$FIX/agent-yml-good.yml" "$FIX/runs-one.json" "$TMPDIR_T/nocontexts.map" \
  "$FIX/runs-one.json" "$FIX/protection-no-contexts.json"
rc=0
reason="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/nocontexts.map" repo_eligible o/r ci.yml)" || rc=$?
assert_eq "protection with empty contexts returns 1" "1" "$rc"
case "$reason" in
  *"required status checks"*) pass "reason names required status checks" ;;
  *) fail "reason names required status checks" "reason was: $reason" ;;
esac

section "branch protection absent vs unreadable (#381)"

# A genuine 404 means the branch is unprotected. Both refuse — the distinction
# is what the operator reads at 3am. Reporting an outage as "no protection"
# sends them to configure something already configured.
write_map "$FIX/agent-yml-good.yml" "$FIX/runs-one.json" "$TMPDIR_T/prot404.map"
printf 'branches/main/protection\tHTTP 404: Not Found\n' > "$TMPDIR_T/prot404.fail"
rc=0
reason="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/prot404.map" \
          GH_MOCK_FAIL_MAP="$TMPDIR_T/prot404.fail" repo_eligible o/r ci.yml)" || rc=$?
assert_eq "protection 404 returns 1" "1" "$rc"
case "$reason" in
  *"no branch protection"*) pass "404 reads as unprotected" ;;
  *) fail "404 reads as unprotected" "reason was: $reason" ;;
esac

# No stderr message at all — an opaque gh failure, i.e. an outage.
printf 'branches/main/protection\n' > "$TMPDIR_T/protdown.fail"
rc=0
reason="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/prot404.map" \
          GH_MOCK_FAIL_MAP="$TMPDIR_T/protdown.fail" repo_eligible o/r ci.yml)" || rc=$?
assert_eq "protection outage returns 1" "1" "$rc"
case "$reason" in
  *"check failed"*) pass "an outage reads as a failed check" ;;
  *) fail "an outage reads as a failed check" "reason was: $reason" ;;
esac
case "$reason" in
  *"no branch protection"*) fail "an outage is not reported as unprotected" "reason was: $reason" ;;
  *) pass "an outage is not reported as unprotected" ;;
esac

section "gate runs query unreadable is not 'gate not found' (#381)"

# The same conflation, three lines above the one the agent.yml check fixes.
printf 'actions/workflows/\n' > "$TMPDIR_T/runsdown.fail"
rc=0
reason="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/prot404.map" \
          GH_MOCK_FAIL_MAP="$TMPDIR_T/runsdown.fail" repo_eligible o/r ci.yml)" || rc=$?
assert_eq "gate runs outage returns 1" "1" "$rc"
case "$reason" in
  *"check failed"*) pass "a runs outage reads as a failed check" ;;
  *) fail "a runs outage reads as a failed check" "reason was: $reason" ;;
esac
case "$reason" in
  *"not found"*) fail "a runs outage is not reported as 'gate not found'" "reason was: $reason" ;;
  *) pass "a runs outage is not reported as 'gate not found'" ;;
esac

section "pull-request runs query absent vs unreadable (#381)"

# The third gh call deserves the same absent-vs-unreadable pair as the other
# two. The fail-map key matches only this query: the branch-runs URL carries
# no `event=` parameter.
printf 'event=pull_request\n' > "$TMPDIR_T/prrunsdown.fail"
rc=0
reason="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/prot404.map" \
          GH_MOCK_FAIL_MAP="$TMPDIR_T/prrunsdown.fail" repo_eligible o/r ci.yml)" || rc=$?
assert_eq "pull-request runs outage returns 1" "1" "$rc"
case "$reason" in
  *"check failed (gate pull-request runs)"*) pass "a pull-request runs outage reads as a failed check" ;;
  *) fail "a pull-request runs outage reads as a failed check" "reason was: $reason" ;;
esac
case "$reason" in
  *"never run on a pull request"*)
    fail "an outage is not reported as 'never ran on a pull request'" "reason was: $reason" ;;
  *) pass "an outage is not reported as 'never ran on a pull request'" ;;
esac

# A genuine 404 means the gate was deleted between the two run queries.
printf 'event=pull_request\tHTTP 404: Not Found\n' > "$TMPDIR_T/prruns404.fail"
rc=0
reason="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/prot404.map" \
          GH_MOCK_FAIL_MAP="$TMPDIR_T/prruns404.fail" repo_eligible o/r ci.yml)" || rc=$?
assert_eq "pull-request runs 404 returns 1" "1" "$rc"
case "$reason" in
  *"not found"*) pass "404 on the pull-request query reads as a missing gate" ;;
  *) fail "404 on the pull-request query reads as a missing gate" "reason was: $reason" ;;
esac

printf '\n%s──────────%s\n' "$C_DIM" "$C_OFF"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf -- '  - %s\n' "$n"; done
  exit 1
fi
exit 0
