#!/usr/bin/env bash
#
# run-check-pr-checks-runnable-tests.sh — Layer-1 tests for
# scripts/check-pr-checks-runnable.sh.
#
# Drives the script against the shared `gh` mock (tests/mocks/gh), using its
# GH_MOCK_STDOUT_MAP seam to serve a canned `statusCheckRollup` count. Every
# test pins POLL_TIMEOUT=0 ("probe once, never wait"), so no test ever sleeps
# and the suite stays sub-second. The one test that must exercise the poll loop
# uses its own counting `gh` shim instead.
#
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/check-pr-checks-runnable.sh"
MOCKS="$HERE/mocks"

# Hermetic by contract: a GitHub Actions runner always exports these, and the
# script under test falls back to GITHUB_REPOSITORY / appends to GITHUB_OUTPUT.
unset GITHUB_REPOSITORY GITHUB_OUTPUT GITHUB_ACTIONS GITHUB_TOKEN

PASS=0; FAIL=0; FAIL_NAMES=()

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
  [[ -n "${2:-}" ]] && printf '    %s%s%s\n' "$C_DIM" "$2" "$C_OFF"
  return 0
}
assert_contains() {
  local hay="$1" needle="$2" name="$3"
  if [[ "$hay" == *"$needle"* ]]; then pass "$name"
  else fail "$name" "expected substring not found: $needle"; fi
}
assert_equals() {
  if [[ "$1" == "$2" ]]; then pass "$3"
  else fail "$3" "expected '$2' got '$1'"; fi
}

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# The script asks `gh` for `.statusCheckRollup | length`, so the mock serves
# what that --jq would have produced: a bare count. The mock does not run jq.
printf '2\n' > "$tmp/rollup-two.txt"
printf '0\n' > "$tmp/rollup-empty.txt"

map_for() {
  # Build a GH_MOCK_STDOUT_MAP serving $1 for any `pr view` invocation.
  local map
  map="$tmp/map-$(basename "$1").tsv"
  printf 'pr view\t%s\n' "$1" > "$map"
  printf '%s' "$map"
}

run_probe() {
  # Usage: run_probe [VAR=value ...] — stdout and stderr merged.
  env PATH="$MOCKS:$PATH" GH_MOCK_LOG="$tmp/gh.log" POLL_INTERVAL=0 \
    "$@" bash "$SCRIPT" 2>&1
}

section "required env"

ec=0
out="$(run_probe GH_MOCK_STDOUT_MAP="$(map_for "$tmp/rollup-two.txt")")" || ec=$?
assert_equals "$ec" "2"                 "missing PR_NUMBER → exit 2"
assert_contains "$out" "PR_NUMBER"      "missing PR_NUMBER → names PR_NUMBER"

section "checks are running"

ec=0
out="$(run_probe PR_NUMBER=7 REPO=o/r POLL_TIMEOUT=0 \
  GH_MOCK_STDOUT_MAP="$(map_for "$tmp/rollup-two.txt")")" || ec=$?
assert_equals "$ec" "0"                             "non-empty rollup → exit 0"
assert_contains "$out" "checks-runnable=true"       "non-empty rollup → runnable=true"
assert_contains "$out" "checks-blocked-reason="     "non-empty rollup → reason key present"

section "checks are blocked — no app token"

ec=0
out="$(run_probe PR_NUMBER=7 REPO=o/r POLL_TIMEOUT=0 APP_TOKEN_CONFIGURED=false \
  GH_MOCK_STDOUT_MAP="$(map_for "$tmp/rollup-empty.txt")")" || ec=$?
assert_equals "$ec" "0"                                    "empty rollup → still exit 0"
assert_contains "$out" "checks-runnable=false"             "empty rollup → runnable=false"
assert_contains "$out" "checks-blocked-reason=no-app-token" "no app token → no-app-token reason"
assert_contains "$out" "docs/PIPELINE-APP-SETUP.md"        "no app token → names the runbook"

section "checks are blocked — app token configured"

out="$(run_probe PR_NUMBER=7 REPO=o/r POLL_TIMEOUT=0 APP_TOKEN_CONFIGURED=true \
  GH_MOCK_STDOUT_MAP="$(map_for "$tmp/rollup-empty.txt")")"
assert_contains "$out" "checks-runnable=false"              "app configured, empty → runnable=false"
assert_contains "$out" "checks-blocked-reason=rollup-empty" "app configured → rollup-empty reason"

section "GITHUB_OUTPUT"

gh_out="$tmp/gh_output"; : > "$gh_out"
run_probe PR_NUMBER=7 REPO=o/r POLL_TIMEOUT=0 APP_TOKEN_CONFIGURED=false \
  GITHUB_OUTPUT="$gh_out" \
  GH_MOCK_STDOUT_MAP="$(map_for "$tmp/rollup-empty.txt")" >/dev/null
written="$(cat "$gh_out")"
assert_contains "$written" "checks-runnable=false"              "GITHUB_OUTPUT → runnable key"
assert_contains "$written" "checks-blocked-reason=no-app-token" "GITHUB_OUTPUT → reason key"

section "gh failure is not fatal"

# A `gh` outage must not fail a diagnostic step. It counts as zero checks and
# the determination is still made.
printf 'pr view\n' > "$tmp/failmap.tsv"
ec=0
out="$(run_probe PR_NUMBER=7 REPO=o/r POLL_TIMEOUT=0 APP_TOKEN_CONFIGURED=false \
  GH_MOCK_FAIL_MAP="$tmp/failmap.tsv")" || ec=$?
assert_equals "$ec" "0"                          "gh failing → still exit 0"
assert_contains "$out" "checks-runnable=false"   "gh failing → treated as not runnable"

section "polls until the checks appear"

# Checks attach a moment after the PR opens, so a single probe would report a
# false blockage. A counting shim returns 0 on the first call and 2 on the
# second; the script must keep polling and settle on runnable.
shim_dir="$tmp/shim"; mkdir -p "$shim_dir"
ctr="$tmp/shim.ctr"; : > "$ctr"
cat > "$shim_dir/gh" <<EOF
#!/usr/bin/env bash
n=\$(cat "$ctr" 2>/dev/null || printf 0); n=\$((n + 1)); printf '%s' "\$n" > "$ctr"
if (( n <= 1 )); then printf '0\n'; else printf '2\n'; fi
EOF
chmod +x "$shim_dir/gh"
out="$(env PATH="$shim_dir:$PATH" POLL_INTERVAL=0 POLL_TIMEOUT=60 \
  PR_NUMBER=7 REPO=o/r bash "$SCRIPT" 2>&1)"
assert_contains "$out" "checks-runnable=true" "empty then non-empty → polls again, runnable"
assert_equals "$(cat "$ctr")" "2"             "  → exactly 2 polls, stops as soon as checks appear"

# --- summary ---------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'; printf '  - %s\n' "${FAIL_NAMES[@]}"
  exit 1
fi
