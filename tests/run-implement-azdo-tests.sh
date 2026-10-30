#!/usr/bin/env bash
#
# run-implement-azdo-tests.sh — Layer-1 tests for how scripts/implement-azdo.sh
# obtains its Azure DevOps token (explicit PAT vs. the CI-host adapter).
# `az` is mocked via tests/mocks/az; DRY_RUN=1 stops the driver before the agent.
#
# Usage: tests/run-implement-azdo-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then pass "$name"; else fail "$name" "expected: $expected | actual: $actual"; fi
}
assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$name"; else fail "$name" "missing: $needle"; fi
}
assert_not_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then pass "$name"; else fail "$name" "unexpected: $needle"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

REPO_AZ="$TMP/repo"
mkdir "$REPO_AZ"
git -C "$REPO_AZ" init -q
git -C "$REPO_AZ" remote add origin 'https://dev.azure.com/contoso/MyProject/_git/my-repo'

AZ_MAP="$TMP/map"
printf 'work-item show\t%s/forge-workitem-azdo.json\n' "$FIXTURES" > "$AZ_MAP"
printf 'resource comments\t%s/forge-comments-azdo.json\n' "$FIXTURES" >> "$AZ_MAP"

# run_driver [VAR=value ...] — runs the driver dry against the fake ADO repo
# under a scrubbed environment; sets RC, OUT (stdout) and ERR (stderr).
RC=0; OUT=''; ERR=''
run_driver() {
  RC=0
  # shellcheck disable=SC2016  # $1/$2 are for the inner bash, not this one
  env -i HOME="$TMP" PATH="$MOCKS:$PATH" \
    ISSUE_NUMBER=7 DRY_RUN=1 AZ_MOCK_FIXTURE="$FIXTURES/forge-workitem-azdo.json" AZ_MOCK_MAP="$AZ_MAP" \
    "$@" bash -c 'cd "$1" && bash "$2"' _ "$REPO_AZ" "$ROOT/scripts/implement-azdo.sh" \
    >"$TMP/out" 2>"$TMP/err" || RC=$?
  OUT="$(cat "$TMP/out")"; ERR="$(cat "$TMP/err")"
}

section "token source"

SENTINEL="tok-SECRET-9f3a"

run_driver TF_BUILD=True SYSTEM_ACCESSTOKEN="$SENTINEL"
assert_eq "pipelines_token_used_when_pat_unset: rc" "0" "$RC"
assert_contains "pipelines_token_used_when_pat_unset: dry run reached" "DRY_RUN=1" "$OUT"
assert_not_contains "token_never_printed" "$SENTINEL" "$OUT$ERR"

run_driver AZURE_DEVOPS_EXT_PAT=pat TF_BUILD=True SYSTEM_ACCESSTOKEN="$SENTINEL"
assert_eq "explicit_pat_wins: rc" "0" "$RC"

run_driver AZURE_DEVOPS_EXT_PAT=pat TF_BUILD=True
assert_eq "explicit_pat_wins_without_system_accesstoken: rc" "0" "$RC"

run_driver TF_BUILD=True SYSTEM_ACCESSTOKEN=
assert_eq "pipelines_empty_token_exits_2: rc" "2" "$RC"

run_driver GITHUB_ACTIONS=true GITHUB_TOKEN="$SENTINEL"
assert_eq "actions_github_token_not_used_as_pat: rc" "2" "$RC"
assert_contains "actions_github_token_not_used_as_pat: message" "AZURE_DEVOPS_EXT_PAT must be set" "$ERR"
assert_not_contains "actions_github_token_never_printed" "$SENTINEL" "$OUT$ERR"

run_driver
assert_eq "local_without_pat_exits_2: rc" "2" "$RC"
assert_contains "local_without_pat_exits_2: message" "AZURE_DEVOPS_EXT_PAT must be set" "$ERR"

section "run context label"

run_driver TF_BUILD=True SYSTEM_ACCESSTOKEN="$SENTINEL"
assert_contains "pipeline_run_labelled_pipeline" "implement (pipeline, Azure DevOps)" "$OUT"

run_driver AZURE_DEVOPS_EXT_PAT=pat
assert_contains "local_run_labelled_local" "implement (local, Azure DevOps)" "$OUT"

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
