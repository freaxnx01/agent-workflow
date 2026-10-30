#!/usr/bin/env bash
#
# run-azdo-pipeline-run-tests.sh — Layer-1 tests for azdo-pipeline-run.sh and
# azdo-report-failure.sh. The guard and driver are replaced by stub scripts that
# exit with a set code and log their env; `az` is mocked. No network.
#
# Usage: tests/run-azdo-pipeline-run-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/scripts/azdo-pipeline-run.sh"
REPORT="$ROOT/scripts/azdo-report-failure.sh"
MOCKS="$ROOT/tests/mocks"
FIXTURES="$ROOT/tests/fixtures"

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
  if [[ "$3" == "$2" ]]; then pass "$1"; else fail "$1" "expected: $2 | actual: $3"; fi
}
assert_log_has() {
  if grep -q -- "$2" "$3"; then pass "$1"; else fail "$1" "missing '$2' in $3"; fi
}
assert_log_lacks() {
  if grep -q -- "$2" "$3"; then fail "$1" "unexpected '$2' in $3"; else pass "$1"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Stubs: exit with $STUB_RC and log the env they were started with.
cat > "$WORK/stub.sh" <<'STUB'
#!/usr/bin/env bash
{ env | grep -E '^(ISSUE_NUMBER|WORK_ITEM_ID|AZURE_DEVOPS_EXT_PAT)=' | sed -E 's/^(AZURE_DEVOPS_EXT_PAT)=.*/\1=<set>/'; echo "ran"; } >> "$STUB_LOG"
exit "${STUB_RC:-0}"
STUB
chmod +x "$WORK/stub.sh"

GUARD_LOG="$WORK/guard.log"; DRIVER_LOG="$WORK/driver.log"
# A throwaway repo gives resolve_azdo_context a real Azure DevOps origin.
REPO_DIR="$WORK/repo"
git init -q "$REPO_DIR"
git -C "$REPO_DIR" remote add origin https://dev.azure.com/contoso/MyProject/_git/my-repo

# run_dispatch <guard-rc> <driver-rc> — sets $rc, $out; extra env from caller.
run_dispatch() {
  : > "$GUARD_LOG"; : > "$DRIVER_LOG"
  printf '#!/usr/bin/env bash\nSTUB_LOG="%s" STUB_RC="%s" exec "%s"\n' "$GUARD_LOG" "$1" "$WORK/stub.sh" > "$WORK/guard"
  printf '#!/usr/bin/env bash\nSTUB_LOG="%s" STUB_RC="%s" exec "%s"\n' "$DRIVER_LOG" "$2" "$WORK/stub.sh" > "$WORK/driver"
  chmod +x "$WORK/guard" "$WORK/driver"
  rc=0
  out=$(
    cd "$REPO_DIR"
    GUARD_CMD="$WORK/guard" DRIVER_CMD="$WORK/driver" "$RUN" 2>&1
  ) || rc=$?
}

export WORK_ITEM_ID=7 TAGGER_ALLOWLIST="owner@example.com"
unset AZURE_DEVOPS_EXT_PAT TF_BUILD GITHUB_ACTIONS SYSTEM_ACCESSTOKEN GITHUB_TOKEN || true

section "dispatcher"

run_dispatch 0 0
assert_eq "run_guard_0_execs_driver_with_issue_number: exit" 0 "$rc"
assert_log_has "run_guard_0_execs_driver_with_issue_number: ISSUE_NUMBER" "ISSUE_NUMBER=7" "$DRIVER_LOG"

run_dispatch 64 0
assert_eq "run_guard_64_exits_0_without_driver: exit" 0 "$rc"
assert_eq "run_guard_64_exits_0_without_driver: driver not run" "" "$(cat "$DRIVER_LOG")"

run_dispatch 65 0
assert_eq "run_guard_65_exits_0_without_driver: exit" 0 "$rc"
assert_eq "run_guard_65_exits_0_without_driver: driver not run" "" "$(cat "$DRIVER_LOG")"

run_dispatch 1 0
assert_eq "run_guard_1_propagates_1_without_driver: exit" 1 "$rc"
assert_eq "run_guard_1_propagates_1_without_driver: driver not run" "" "$(cat "$DRIVER_LOG")"

run_dispatch 2 0
assert_eq "run_guard_2_propagates_2" 2 "$rc"

run_dispatch 0 1
assert_eq "run_driver_failure_propagates" 1 "$rc"

TF_BUILD=True SYSTEM_ACCESSTOKEN=tok run_dispatch 0 0
assert_log_has "run_exports_pipelines_token_to_guard" "AZURE_DEVOPS_EXT_PAT=<set>" "$GUARD_LOG"
assert_log_has "run_exports_pipelines_token_to_driver" "AZURE_DEVOPS_EXT_PAT=<set>" "$DRIVER_LOG"
if grep -q 'tok' <<<"$out"; then fail "run_never_prints_token" "token in output"; else pass "run_never_prints_token"; fi

run_dispatch 0 0
assert_log_lacks "run_local_leaves_pat_unset" "AZURE_DEVOPS_EXT_PAT" "$GUARD_LOG"

section "failure report"

AZ_LOG="$WORK/az.log"
run_report() {
  : > "$AZ_LOG"
  rc=0
  (
    cd "$REPO_DIR"
    export PATH="$MOCKS:$PATH"
    export AZ_MOCK_FIXTURE="$FIXTURES/azdo-wiql-rows.json" AZ_MOCK_LOG="$AZ_LOG"
    export AZURE_DEVOPS_EXT_PAT=not-a-real-token
    "$REPORT"
  ) >/dev/null 2>&1 || rc=$?
}

RUN_URL="https://example.com/run/42" run_report
assert_eq "report_failure_posts_run_url: exit" 0 "$rc"
assert_log_has "report_failure_posts_run_url: discussion" "--discussion ai-implement run failed: https://example.com/run/42. The ai-implement tag was removed when the run started; re-add it to retry." "$AZ_LOG"
assert_log_has "report_failure_posts_run_url: work item" "--id 7" "$AZ_LOG"

run_report
assert_eq "report_failure_missing_env_exits_2" 2 "$rc"
assert_eq "report_failure_missing_env_posts_nothing" "" "$(cat "$AZ_LOG")"
RUN_URL="" run_report
assert_eq "report_failure_empty_run_url_exits_2" 2 "$rc"

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
