#!/usr/bin/env bash
#
# run-ci-host-tests.sh — Layer-1 tests for scripts/lib/ci-host.sh.
# Every case runs in a subshell with a scrubbed environment; no network.
#
# Usage: tests/run-ci-host-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib/ci-host.sh"

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
assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$name"
  else
    fail "$name" "expected to contain: $needle | actual: $haystack"
  fi
}

# run_lib <env-assignments> <command> — sources the library in a scrubbed env,
# runs the command, and sets OUT, ERR and RC.
OUT=''; ERR=''; RC=0
run_lib() {
  local cmd="$2" err_file
  local -a envs=()
  IFS=' ' read -ra envs <<<"$1"
  err_file="$(mktemp)"
  RC=0
  OUT="$(env -i PATH="$PATH" "${envs[@]}" bash -c "source '$LIB'; $cmd" 2>"$err_file")" || RC=$?
  ERR="$(cat "$err_file")"
  rm -f "$err_file"
}

section "ci_host"
run_lib "TF_BUILD=True" "ci_host"
assert_eq "host_pipelines_when_tf_build_true" "pipelines" "$OUT"
run_lib "TF_BUILD=true" "ci_host"
assert_eq "host_pipelines_case_insensitive" "pipelines" "$OUT"
run_lib "GITHUB_ACTIONS=true" "ci_host"
assert_eq "host_actions_when_github_actions_true" "actions" "$OUT"
run_lib "" "ci_host"
assert_eq "host_local_when_neither" "local" "$OUT"

section "ci_host_token"
run_lib "TF_BUILD=True SYSTEM_ACCESSTOKEN=abc" "ci_host_token"
assert_eq "token_pipelines_returns_system_accesstoken" "abc|0" "$OUT|$RC"
run_lib "TF_BUILD=True" "ci_host_token"
assert_eq "token_pipelines_without_accesstoken_rc" "1|" "$RC|$OUT"
assert_contains "token_pipelines_without_accesstoken_hint" "System.AccessToken" "$ERR"
run_lib "GITHUB_ACTIONS=true GITHUB_TOKEN=ghs_x" "ci_host_token"
assert_eq "token_actions_returns_github_token" "ghs_x|0" "$OUT|$RC"
run_lib "GITHUB_ACTIONS=true" "ci_host_token"
assert_eq "token_actions_without_token_rc" "1" "$RC"
assert_contains "token_actions_without_token_names_var" "GITHUB_TOKEN" "$ERR"
run_lib "" "ci_host_token"
assert_eq "token_local_exits_64_empty_stdout" "64|" "$RC|$OUT"

# --- summary -------------------------------------------------------------

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
