#!/usr/bin/env bash
#
# run-autopilot-driver-tests.sh — Layer-1 fixture tests for
# scripts/autopilot.sh (no network, gh mocked). Asserts the driver's guards
# (usage, deps, disable flag, run lock), config-driven repo/issue selection,
# and that a dry run writes nothing.
#
# Usage: tests/run-autopilot-driver-tests.sh
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

DRIVER="$ROOT/scripts/autopilot.sh"

export PATH="$ROOT/tests/mocks:$PATH"
export GH_MOCK_LOG="$TMPDIR_T/gh.log"
export AUTOPILOT_CACHE_DIR="$TMPDIR_T/cache"
export AUTOPILOT_DISABLE_FLAG="$TMPDIR_T/disabled"

# Config: one allowlisted repo.
printf 'max_per_run=2\nrepo=o/r\n' > "$TMPDIR_T/ap.conf"

# gh responses: an eligible repo and three enrichable issues.
{
  printf 'contents/.github/workflows/agent.yml\t%s\n' "$FIX/agent-yml-good.yml"
  printf 'actions/workflows/\t%s\n' "$FIX/runs-one.json"
  printf 'issue list\t%s\n' "$FIX/issues-mixed.json"
  printf 'repos/o/r\t%s\n' "$FIX/repo-meta.json"
} > "$TMPDIR_T/gh.map"
export GH_MOCK_STDOUT_MAP="$TMPDIR_T/gh.map"

section "usage and dependencies"

rc=0; "$DRIVER" --nonsense >/dev/null 2>&1 || rc=$?
assert_eq "unknown flag is a usage error" "2" "$rc"

rc=0; "$DRIVER" --config "$TMPDIR_T/nope.conf" >/dev/null 2>&1 || rc=$?
assert_eq "unreadable config exits 4" "4" "$rc"

out="$("$DRIVER" --help)"
case "$out" in
  *--dry-run*) pass "help documents --dry-run" ;;
  *) fail "help documents --dry-run" "help was: $out" ;;
esac

section "the disable flag"

: > "$AUTOPILOT_DISABLE_FLAG"
: > "$GH_MOCK_LOG"
rc=0; out="$("$DRIVER" --config "$TMPDIR_T/ap.conf" 2>&1)" || rc=$?
assert_eq "disabled exits 0" "0" "$rc"
case "$out" in
  *disabled*) pass "disabled is logged" ;;
  *) fail "disabled is logged" "output was: $out" ;;
esac
assert_eq "disabled makes no gh calls at all" "" "$(cat "$GH_MOCK_LOG")"
rm -f "$AUTOPILOT_DISABLE_FLAG"

section "dry run"

: > "$GH_MOCK_LOG"
out="$("$DRIVER" --config "$TMPDIR_T/ap.conf" --dry-run)"

case "$out" in
  *"o/r#41"*) pass "names the oldest candidate" ;;
  *) fail "names the oldest candidate" "output was: $out" ;;
esac
case "$out" in
  *would:*) pass "dry-run lines are marked 'would:'" ;;
  *) fail "dry-run lines are marked 'would:'" "output was: $out" ;;
esac
assert_eq "dry run honours the cap" "2" "$(printf '%s\n' "$out" | grep -c 'would:')"
case "$out" in
  *"o/r#50"*) fail "cap excludes the third candidate" "50 appeared" ;;
  *) pass "cap excludes the third candidate" ;;
esac

if grep -q 'issue edit' "$GH_MOCK_LOG"; then
  fail "dry run writes no labels" "$(grep 'issue edit' "$GH_MOCK_LOG")"
else
  pass "dry run writes no labels"
fi
if grep -q 'issue comment' "$GH_MOCK_LOG"; then
  fail "dry run posts no comments" "$(grep 'issue comment' "$GH_MOCK_LOG")"
else
  pass "dry run posts no comments"
fi
# The cache root always exists after any run (acquire_run_lock mkdir -p's it
# to place run.lock) — the real assertion is that the per-repo clone dir was
# never created, i.e. sync_autopilot_clone was never called.
clone_dir="$(AUTOPILOT_CACHE_DIR="$AUTOPILOT_CACHE_DIR" bash -c '. "'"$ROOT"'/scripts/lib/autopilot-clone.sh"; autopilot_clone_dir o/r')"
if [[ -d "$clone_dir" ]]; then
  fail "dry run syncs no clones" "$clone_dir was created"
else
  pass "dry run syncs no clones"
fi

section "--max overrides the config"

out="$("$DRIVER" --config "$TMPDIR_T/ap.conf" --dry-run --max 1)"
assert_eq "--max 1 yields one line" "1" "$(printf '%s\n' "$out" | grep -c 'would:')"

section "an ineligible repo is skipped with its reason"

{
  printf 'contents/.github/workflows/agent.yml\t%s\n' "$FIX/agent-yml-no-merge.yml"
  printf 'issue list\t%s\n' "$FIX/issues-mixed.json"
  printf 'repos/o/r\t%s\n' "$FIX/repo-meta.json"
} > "$TMPDIR_T/gh-noeligible.map"
out="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/gh-noeligible.map" "$DRIVER" --config "$TMPDIR_T/ap.conf" --dry-run)"
case "$out" in
  *"ai-review-ai-merge"*) pass "logs the eligibility reason verbatim" ;;
  *) fail "logs the eligibility reason verbatim" "output was: $out" ;;
esac
case "$out" in
  *would:*) fail "an ineligible repo yields no candidates" "output was: $out" ;;
  *) pass "an ineligible repo yields no candidates" ;;
esac

section "the run lock"

# Hold the lock, then confirm a second run stands down instead of piling on.
lock="$AUTOPILOT_CACHE_DIR/run.lock"
mkdir -p "$AUTOPILOT_CACHE_DIR"
exec 8>"$lock"
flock -n 8
rc=0; out="$("$DRIVER" --config "$TMPDIR_T/ap.conf" --dry-run 2>&1)" || rc=$?
exec 8>&-
assert_eq "a concurrent run exits 0" "0" "$rc"
case "$out" in
  *"already running"*) pass "a concurrent run says so" ;;
  *) fail "a concurrent run says so" "output was: $out" ;;
esac

section "the log line format"

rm -rf "$AUTOPILOT_CACHE_DIR"
out="$("$DRIVER" --config "$TMPDIR_T/ap.conf" --dry-run | head -1)"
if [[ "$out" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\  ]]; then
  pass "log lines start with an ISO-8601 UTC timestamp"
else
  fail "log lines start with an ISO-8601 UTC timestamp" "line was: $out"
fi

printf '\n%s──────────%s\n' "$C_DIM" "$C_OFF"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf -- '  - %s\n' "$n"; done
  exit 1
fi
exit 0
