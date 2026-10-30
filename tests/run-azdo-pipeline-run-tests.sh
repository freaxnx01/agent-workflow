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
SENTINEL="tok-SECRET-9f3a"

# The dispatcher resolves the guard and the driver ONLY next to itself ($HERE),
# so it is copied into a temp dir beside stub azdo-tag-guard.sh /
# implement-azdo.sh. Copied, not symlinked: $HERE is not resolved with -P.
BIN="$WORK/bin"
mkdir -p "$BIN/lib"
cp "$RUN" "$BIN/azdo-pipeline-run.sh"
cp "$ROOT/scripts/lib/ci-host.sh" "$BIN/lib/ci-host.sh"

# Stubs: exit with $STUB_RC and log the env they were started with.
cat > "$WORK/stub.sh" <<'STUB'
#!/usr/bin/env bash
{ env | grep -E '^(ISSUE_NUMBER|WORK_ITEM_ID|AZURE_DEVOPS_EXT_PAT)=' | sed -E 's/^(AZURE_DEVOPS_EXT_PAT)=.*/\1=<set>/'; echo "ran"; } >> "$STUB_LOG"
exit "${STUB_RC:-0}"
STUB
chmod +x "$WORK/stub.sh"

# A decoy that must never run: GUARD_CMD / DRIVER_CMD point at it.
DECOY_LOG="$WORK/decoy.log"
printf '#!/usr/bin/env bash\necho ran >> "%s"\nexit 0\n' "$DECOY_LOG" > "$WORK/decoy"
chmod +x "$WORK/decoy"

GUARD_LOG="$WORK/guard.log"; DRIVER_LOG="$WORK/driver.log"
# A throwaway repo gives resolve_azdo_context a real Azure DevOps origin.
REPO_DIR="$WORK/repo"
git init -q "$REPO_DIR"
git -C "$REPO_DIR" remote add origin https://dev.azure.com/contoso/MyProject/_git/my-repo

# run_dispatch <guard-rc> <driver-rc> — sets $rc, $out; extra env from caller.
run_dispatch() {
  : > "$GUARD_LOG"; : > "$DRIVER_LOG"; : > "$DECOY_LOG"
  printf '#!/usr/bin/env bash\nSTUB_LOG="%s" STUB_RC="%s" exec "%s"\n' "$GUARD_LOG" "$1" "$WORK/stub.sh" > "$BIN/azdo-tag-guard.sh"
  printf '#!/usr/bin/env bash\nSTUB_LOG="%s" STUB_RC="%s" exec "%s"\n' "$DRIVER_LOG" "$2" "$WORK/stub.sh" > "$BIN/implement-azdo.sh"
  chmod +x "$BIN/azdo-tag-guard.sh" "$BIN/implement-azdo.sh"
  rc=0
  out=$(
    cd "$REPO_DIR"
    "$BIN/azdo-pipeline-run.sh" 2>&1
  ) || rc=$?
}

export WORK_ITEM_ID=7 TAGGER_ALLOWLIST="owner@example.com"
unset AZURE_DEVOPS_EXT_PAT TF_BUILD GITHUB_ACTIONS SYSTEM_ACCESSTOKEN GITHUB_TOKEN GUARD_CMD DRIVER_CMD || true

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

run_dispatch 66 0
assert_eq "run_guard_66_exits_0_without_driver: exit" 0 "$rc"
assert_eq "run_guard_66_exits_0_without_driver: driver not run" "" "$(cat "$DRIVER_LOG")"

run_dispatch 1 0
assert_eq "run_guard_1_propagates_1_without_driver: exit" 1 "$rc"
assert_eq "run_guard_1_propagates_1_without_driver: driver not run" "" "$(cat "$DRIVER_LOG")"

run_dispatch 2 0
assert_eq "run_guard_2_propagates_2" 2 "$rc"

run_dispatch 0 1
assert_eq "run_driver_failure_propagates" 1 "$rc"

section "script paths cannot be overridden from the environment"

GUARD_CMD="$WORK/decoy" run_dispatch 0 0
assert_log_has "run_ignores_guard_cmd: guard stub still runs" "ran" "$GUARD_LOG"
assert_eq "run_ignores_guard_cmd: decoy not run" "" "$(cat "$DECOY_LOG")"

GUARD_CMD=true run_dispatch 1 0
assert_eq "run_guard_cmd_true_cannot_skip_guard: exit" 1 "$rc"
assert_log_has "run_guard_cmd_true_cannot_skip_guard: guard ran" "ran" "$GUARD_LOG"
assert_eq "run_guard_cmd_true_cannot_skip_guard: driver blocked" "" "$(cat "$DRIVER_LOG")"

DRIVER_CMD="$WORK/decoy" run_dispatch 0 0
assert_log_has "run_ignores_driver_cmd: driver stub runs" "ran" "$DRIVER_LOG"
assert_eq "run_ignores_driver_cmd: decoy not run" "" "$(cat "$DECOY_LOG")"

section "work item id"

WORK_ITEM_ID="7; rm -rf /" run_dispatch 0 0
assert_eq "run_non_numeric_work_item_exits_2" 2 "$rc"
assert_eq "run_non_numeric_work_item_runs_no_guard" "" "$(cat "$GUARD_LOG")"
WORK_ITEM_ID="" run_dispatch 0 0
assert_eq "run_empty_work_item_exits_2" 2 "$rc"
assert_eq "run_empty_work_item_runs_no_guard" "" "$(cat "$GUARD_LOG")"

section "token"

TF_BUILD=True SYSTEM_ACCESSTOKEN="$SENTINEL" run_dispatch 0 0
assert_log_has "run_exports_pipelines_token_to_guard" "AZURE_DEVOPS_EXT_PAT=<set>" "$GUARD_LOG"
assert_log_has "run_exports_pipelines_token_to_driver" "AZURE_DEVOPS_EXT_PAT=<set>" "$DRIVER_LOG"
if grep -q -- "$SENTINEL" <<<"$out"; then fail "run_never_prints_token" "token in output"; else pass "run_never_prints_token"; fi

TF_BUILD=True SYSTEM_ACCESSTOKEN="" run_dispatch 0 0
assert_eq "run_pipelines_empty_token_exits_2" 2 "$rc"
assert_eq "run_pipelines_empty_token_runs_no_guard" "" "$(cat "$GUARD_LOG")"

GITHUB_ACTIONS=true GITHUB_TOKEN="$SENTINEL" run_dispatch 0 0
assert_log_lacks "run_actions_github_token_not_exported" "AZURE_DEVOPS_EXT_PAT" "$GUARD_LOG"
if grep -q -- "$SENTINEL" <<<"$out"; then fail "run_actions_never_prints_token" "token in output"; else pass "run_actions_never_prints_token"; fi

run_dispatch 0 0
assert_log_lacks "run_local_leaves_pat_unset" "AZURE_DEVOPS_EXT_PAT" "$GUARD_LOG"

section "failure report"

# az is wrapped so a test can see which credential reached it: the wrapper logs
# whether AZURE_DEVOPS_EXT_PAT was unset, the sentinel, or something else --
# never its value -- then hands over to the az mock.
AZ_LOG="$WORK/az.log"; AZ_PAT_LOG="$WORK/az-pat.log"
mkdir -p "$WORK/azwrap"
cat > "$WORK/azwrap/az" <<WRAP
#!/usr/bin/env bash
case "\${AZURE_DEVOPS_EXT_PAT-}" in
  "") s=unset ;;
  "$SENTINEL") s=sentinel ;;
  *) s=other ;;
esac
printf 'PAT=%s\n' "\$s" >> "\$AZ_PAT_LOG"
exec "$MOCKS/az" "\$@"
WRAP
chmod +x "$WORK/azwrap/az"

# run_report [VAR=value ...] — runs the report script with the az wrapper;
# sets $rc and $out (stdout+stderr).
run_report() {
  : > "$AZ_LOG"; : > "$AZ_PAT_LOG"
  rc=0
  out=$(
    cd "$REPO_DIR"
    env PATH="$WORK/azwrap:$MOCKS:$PATH" \
      AZ_MOCK_FIXTURE="$FIXTURES/azdo-wiql-rows.json" AZ_MOCK_LOG="$AZ_LOG" AZ_PAT_LOG="$AZ_PAT_LOG" \
      "$@" "$REPORT" 2>&1
  ) || rc=$?
}

RUN_URL="https://example.com/run/42" run_report AZURE_DEVOPS_EXT_PAT=not-a-real-token
assert_eq "report_failure_posts_run_url: exit" 0 "$rc"
assert_log_has "report_failure_posts_run_url: discussion" "--discussion ai-implement run failed: https://example.com/run/42. If the ai-implement tag is no longer on this work item, re-add it to retry." "$AZ_LOG"
assert_log_has "report_failure_posts_run_url: work item" "--id 7" "$AZ_LOG"
assert_log_lacks "report_failure_never_claims_tag_removed" "tag was removed" "$AZ_LOG"

RUN_URL="https://example.com/run/42" run_report TF_BUILD=True SYSTEM_ACCESSTOKEN="$SENTINEL"
assert_eq "report_exports_pipelines_token: exit" 0 "$rc"
assert_log_has "report_exports_pipelines_token: az sees it" "PAT=sentinel" "$AZ_PAT_LOG"
if grep -q -- "$SENTINEL" <<<"$out" || grep -q -- "$SENTINEL" "$AZ_LOG"; then
  fail "report_never_prints_token" "token in output or az argv"
else
  pass "report_never_prints_token"
fi

RUN_URL="https://example.com/run/42" run_report TF_BUILD=True SYSTEM_ACCESSTOKEN=
assert_eq "report_pipelines_empty_token_exits_2" 2 "$rc"
assert_eq "report_pipelines_empty_token_posts_nothing" "" "$(cat "$AZ_LOG")"

RUN_URL="https://example.com/run/42" run_report GITHUB_ACTIONS=true GITHUB_TOKEN="$SENTINEL"
assert_log_lacks "report_actions_github_token_not_exported" "PAT=sentinel" "$AZ_PAT_LOG"
assert_log_has "report_actions_leaves_pat_unset" "PAT=unset" "$AZ_PAT_LOG"

run_report AZURE_DEVOPS_EXT_PAT=not-a-real-token
assert_eq "report_failure_missing_env_exits_2" 2 "$rc"
assert_eq "report_failure_missing_env_posts_nothing" "" "$(cat "$AZ_LOG")"
RUN_URL="" run_report AZURE_DEVOPS_EXT_PAT=not-a-real-token
assert_eq "report_failure_empty_run_url_exits_2" 2 "$rc"

RUN_URL="https://example.com/run/42" WORK_ITEM_ID="7 --discussion x" run_report AZURE_DEVOPS_EXT_PAT=not-a-real-token
assert_eq "report_non_numeric_work_item_exits_2" 2 "$rc"
assert_eq "report_non_numeric_work_item_posts_nothing" "" "$(cat "$AZ_LOG")"

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
