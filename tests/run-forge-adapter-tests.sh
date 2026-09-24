#!/usr/bin/env bash
#
# run-forge-adapter-tests.sh — Layer-1 tests for scripts/lib/forge.sh.
# `gh` is mocked; no network, no live forge.
#
# Usage: tests/run-forge-adapter-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib/forge.sh"
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

# make_repo <remote-url> — throwaway git repo with that origin, echoes its path.
# detect_forge reads the remote, so the forge under test is chosen by this URL.
make_repo() {
  local dir; dir="$(mktemp -d)"
  git -C "$dir" init -q
  git -C "$dir" remote add origin "$1"
  echo "$dir"
}

# _forge_env <repo-dir> — runs forge_export_issue in a subshell and dumps the
# two variables it exports, NUL-free and one per record, for the callers below.
# Structured this way rather than eval'ing snippets so nothing has to be quoted
# past shellcheck.
# SC2030/SC2031: the exports are deliberately local to the subshell; that
# isolation is what keeps each case independent.
# shellcheck disable=SC2030,SC2031
_forge_env() {
  local dir="$1" map ghlog
  map="$(mktemp)"; ghlog="$(mktemp)"
  printf 'issue view\t%s/forge-issue-github.json\n' "$FIXTURES" > "$map"
  (
    cd "$dir"
    export PATH="$MOCKS:$PATH"
    export GH_MOCK_LOG="$ghlog"
    export GH_MOCK_STDOUT_MAP="$map"
    export GH_MOCK_AUTH_HOSTS="github.com"
    export REPO=o/r
    # shellcheck disable=SC1090
    source "$ROOT/scripts/lib/detect-forge.sh"
    # shellcheck disable=SC1090
    source "$LIB"
    rc=0
    forge_export_issue 42 >/dev/null 2>&1 || rc=$?
    printf 'RC=%s\n' "$rc"
    # `env` proves they are EXPORTED, not merely set: the classifiers are
    # separate processes and would never see a shell-local variable.
    env | grep -c '^ISSUE_LABELS=' | sed 's/^/EXPORTED_LABELS=/'
    env | grep -c '^ISSUE_BODY=' | sed 's/^/EXPORTED_BODY=/'
    printf 'LABELS<<\n%s\n>>\n' "${ISSUE_LABELS:-}"
    printf 'BODY<<\n%s\n>>\n' "${ISSUE_BODY:-}"
  )
  rm -f "$map" "$ghlog"
}

# forge_field <repo-dir> <RC|EXPORTED_LABELS|EXPORTED_BODY>
forge_field() { _forge_env "$1" | sed -n "s/^$2=//p"; }

# forge_block <repo-dir> <LABELS|BODY> — the value between the << >> markers.
forge_block() { _forge_env "$1" | sed -n "/^$2<</,/^>>$/p" | sed '1d;$d'; }

# --- cases -------------------------------------------------------------

section "forge_export_issue — fills what the classifiers already prefer"

REPO_GH="$(make_repo 'https://github.com/o/r.git')"

# classify-agent / classify-task / classify-turns read ISSUE_LABELS one name per
# line and call gh only when it is unset. Filling it is the whole adapter.
assert_eq "labels arrive one per line" "$(printf 'ai-implement\nturns:80')" \
  "$(forge_block "$REPO_GH" LABELS)"

assert_eq "body is exported" "Implement the thing." \
  "$(forge_block "$REPO_GH" BODY)"

assert_eq "ISSUE_LABELS is exported, not shell-local" "1" \
  "$(forge_field "$REPO_GH" EXPORTED_LABELS)"

assert_eq "ISSUE_BODY is exported, not shell-local" "1" \
  "$(forge_field "$REPO_GH" EXPORTED_BODY)"

assert_eq "github path succeeds" "0" "$(forge_field "$REPO_GH" RC)"

section "an unsupported forge fails loudly, never silently empty"

# An empty ISSUE_LABELS is indistinguishable from "this issue has no labels",
# which every classifier would act on: no agent override, no model override,
# default turn budget. Exit 2 rather than leave that ambiguity.
REPO_ADO="$(make_repo 'https://dev.azure.com/contoso/MyProject/_git/my-repo')"
assert_eq "azdo returns 2 (no read adapter yet)" "2" "$(forge_field "$REPO_ADO" RC)"

rm -rf "$REPO_GH" "$REPO_ADO"

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
