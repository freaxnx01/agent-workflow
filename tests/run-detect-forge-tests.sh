#!/usr/bin/env bash
#
# run-detect-forge-tests.sh — Layer-1 fixture tests for scripts/lib/detect-forge.sh
# (no network). Builds a throwaway git repo per case, points PATH at tests/mocks/,
# sources the script, and asserts detect_forge's output.
#
# Usage: tests/run-detect-forge-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib/detect-forge.sh"
MOCKS="$ROOT/tests/mocks"

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

# make_repo <remote-url>  — throwaway git repo with that origin, echoes its path
make_repo() {
  local dir; dir="$(mktemp -d)"
  git -C "$dir" init -q
  git -C "$dir" remote add origin "$1"
  echo "$dir"
}

# run_detect_forge <repo-dir> [GH_MOCK_AUTH_HOSTS] [TEA_MOCK_LOGINS]
run_detect_forge() {
  local dir="$1" auth_hosts="${2:-}" tea_logins="${3:-}"
  (
    cd "$dir"
    export PATH="$MOCKS:$PATH"
    export GH_MOCK_AUTH_HOSTS="$auth_hosts"
    export TEA_MOCK_LOGINS="$tea_logins"
    # shellcheck disable=SC1090
    source "$LIB"
    detect_forge
  )
}

# run_resolve_azdo <repo-dir> — echoes "org|project|repo", or "FAIL" when the
# remote is not an Azure DevOps one. Pipe-separated, not space-separated: ADO
# project names may contain spaces.
run_resolve_azdo() {
  local dir="$1"
  (
    cd "$dir"
    # No PATH mock needed: resolve_azdo_context shells out to git and sed only,
    # never to gh/tea/az.
    # shellcheck disable=SC1090
    source "$LIB"
    if resolve_azdo_context; then
      printf '%s|%s|%s\n' "$AZDO_ORG" "$AZDO_PROJECT" "$AZDO_REPO"
    else
      echo "FAIL"
    fi
  )
}

# --- cases -------------------------------------------------------------

section "github"

REPO="$(make_repo "https://github.com/freaxnx01/agent-workflow.git")"
assert_eq "https remote, gh authed" "github github.com" \
  "$(run_detect_forge "$REPO" "github.com" "")"
rm -rf "$REPO"

REPO="$(make_repo "git@github.com:freaxnx01/agent-workflow.git")"
assert_eq "scp-style remote, gh authed" "github github.com" \
  "$(run_detect_forge "$REPO" "github.com" "")"
rm -rf "$REPO"

REPO="$(make_repo "https://github.com/freaxnx01/agent-workflow.git")"
assert_eq "github.com fallback when gh not authed" "github github.com" \
  "$(run_detect_forge "$REPO" "" "")"
rm -rf "$REPO"

section "forgejo"

REPO="$(make_repo "ssh://git@git.home.freaxnx01.ch/freax/hello-forgejo.git")"
assert_eq "ssh remote, tea login matches" "forgejo git.home.freaxnx01.ch" \
  "$(run_detect_forge "$REPO" "" "git.home.freaxnx01.ch")"
rm -rf "$REPO"

section "unknown"

REPO="$(make_repo "https://gitlab.example.com/freax/whatever.git")"
assert_eq "unrecognized host, no gh/tea match" "unknown gitlab.example.com" \
  "$(run_detect_forge "$REPO" "" "")"
rm -rf "$REPO"

section "azure devops — detection"

REPO="$(make_repo "https://dev.azure.com/contoso/MyProject/_git/my-repo")"
assert_eq "https dev.azure.com remote" "azdo dev.azure.com" \
  "$(run_detect_forge "$REPO" "" "")"
rm -rf "$REPO"

REPO="$(make_repo "git@ssh.dev.azure.com:v3/contoso/MyProject/my-repo")"
assert_eq "scp-style ssh.dev.azure.com remote" "azdo ssh.dev.azure.com" \
  "$(run_detect_forge "$REPO" "" "")"
rm -rf "$REPO"

REPO="$(make_repo "https://contoso.visualstudio.com/MyProject/_git/my-repo")"
assert_eq "legacy visualstudio.com remote" "azdo contoso.visualstudio.com" \
  "$(run_detect_forge "$REPO" "" "")"
rm -rf "$REPO"

# Detection must not need an `az` login: the ADO hostnames collide with nothing,
# so an unauthenticated machine still routes to the ADO section (which is where
# the missing login gets reported). Same precedent as the github.com fallback.
REPO="$(make_repo "https://dev.azure.com/contoso/MyProject/_git/my-repo")"
assert_eq "ADO detected with no gh/tea auth at all" "azdo dev.azure.com" \
  "$(run_detect_forge "$REPO" "" "")"
rm -rf "$REPO"

section "azure devops — context resolution"

REPO="$(make_repo "https://dev.azure.com/contoso/MyProject/_git/my-repo")"
assert_eq "https form" "contoso|MyProject|my-repo" "$(run_resolve_azdo "$REPO")"
rm -rf "$REPO"

REPO="$(make_repo "https://contoso@dev.azure.com/contoso/MyProject/_git/my-repo")"
assert_eq "https form with org@ prefix" "contoso|MyProject|my-repo" \
  "$(run_resolve_azdo "$REPO")"
rm -rf "$REPO"

REPO="$(make_repo "git@ssh.dev.azure.com:v3/contoso/MyProject/my-repo")"
assert_eq "scp-style v3 form (no _git segment)" "contoso|MyProject|my-repo" \
  "$(run_resolve_azdo "$REPO")"
rm -rf "$REPO"

REPO="$(make_repo "ssh://git@ssh.dev.azure.com:v3/contoso/MyProject/my-repo")"
assert_eq "ssh:// v3 form" "contoso|MyProject|my-repo" \
  "$(run_resolve_azdo "$REPO")"
rm -rf "$REPO"

# The reason AZDO_* are variables rather than a space-separated echo.
REPO="$(make_repo "https://dev.azure.com/contoso/My%20Project/_git/my-repo")"
assert_eq "percent-encoded space in project name" "contoso|My Project|my-repo" \
  "$(run_resolve_azdo "$REPO")"
rm -rf "$REPO"

REPO="$(make_repo "https://contoso.visualstudio.com/MyProject/_git/my-repo")"
assert_eq "legacy form takes org from the hostname" "contoso|MyProject|my-repo" \
  "$(run_resolve_azdo "$REPO")"
rm -rf "$REPO"

REPO="$(make_repo "https://contoso.visualstudio.com/DefaultCollection/MyProject/_git/my-repo")"
assert_eq "legacy form with DefaultCollection segment" "contoso|MyProject|my-repo" \
  "$(run_resolve_azdo "$REPO")"
rm -rf "$REPO"

REPO="$(make_repo "https://dev.azure.com/contoso/MyProject/_git/my-repo.git")"
assert_eq "trailing .git stripped" "contoso|MyProject|my-repo" \
  "$(run_resolve_azdo "$REPO")"
rm -rf "$REPO"

REPO="$(make_repo "https://dev.azure.com/contoso/MyApp/_git/MyApp")"
assert_eq "project and repo sharing a name (ADO's default)" "contoso|MyApp|MyApp" \
  "$(run_resolve_azdo "$REPO")"
rm -rf "$REPO"

REPO="$(make_repo "https://dev.azure.com/contoso")"
assert_eq "org-only ADO url resolves nothing and fails" "FAIL" \
  "$(run_resolve_azdo "$REPO")"
rm -rf "$REPO"

REPO="$(make_repo "https://github.com/freaxnx01/agent-workflow.git")"
assert_eq "non-ADO remote resolves nothing and fails" "FAIL" \
  "$(run_resolve_azdo "$REPO")"
rm -rf "$REPO"

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
