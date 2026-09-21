#!/usr/bin/env bash
#
# run-autopilot-clone-tests.sh — Layer-1 fixture tests for
# scripts/lib/autopilot-clone.sh (no network; a local file:// origin stands
# in for GitHub, so this is still hermetic).
#
# Usage: tests/run-autopilot-clone-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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

# shellcheck source=scripts/lib/autopilot-clone.sh disable=SC1091
source "$ROOT/scripts/lib/autopilot-clone.sh"

export AUTOPILOT_CACHE_DIR="$TMPDIR_T/cache"
export AUTOPILOT_CLONE_URL_BASE="file://$TMPDIR_T/origins"

# A local bare origin with one commit on main. Hermetic: file:// is not network.
setup_origin() {
  local bare="$TMPDIR_T/origins/o/r.git" work="$TMPDIR_T/work"
  mkdir -p "$(dirname "$bare")"
  git init --quiet --bare --initial-branch=main "$bare"
  git init --quiet --initial-branch=main "$work"
  git -C "$work" -c user.email=t@t -c user.name=t commit --quiet --allow-empty -m "initial"
  printf 'hello\n' > "$work/README.md"
  git -C "$work" add README.md
  git -C "$work" -c user.email=t@t -c user.name=t commit --quiet -m "readme"
  git -C "$work" remote add origin "$bare"
  git -C "$work" push --quiet origin main
}
setup_origin

section "autopilot_clone_dir"

assert_eq "path mangles the slash" "$TMPDIR_T/cache/o__r" "$(autopilot_clone_dir o/r)"
if [[ -e "$TMPDIR_T/cache/o__r" ]]; then
  fail "the query creates nothing" "the directory exists"
else
  pass "the query creates nothing"
fi

section "first sync clones"

rc=0; sync_autopilot_clone o/r >/dev/null 2>&1 || rc=$?
assert_eq "first sync returns 0" "0" "$rc"
dir="$(autopilot_clone_dir o/r)"
if [[ -d "$dir/.git" ]]; then pass "clone exists"; else fail "clone exists" "$dir has no .git"; fi
assert_eq "checked out content" "hello" "$(cat "$dir/README.md")"
assert_eq "on the default branch" "main" "$(git -C "$dir" rev-parse --abbrev-ref HEAD)"

section "sync discards local mess"

printf 'tampered\n' > "$dir/README.md"
printf 'junk\n' > "$dir/untracked.txt"
git -C "$dir" -c user.email=t@t -c user.name=t commit --quiet -am "local junk commit"

rc=0; sync_autopilot_clone o/r >/dev/null 2>&1 || rc=$?
assert_eq "second sync returns 0" "0" "$rc"
assert_eq "tracked change discarded" "hello" "$(cat "$dir/README.md")"
if [[ -e "$dir/untracked.txt" ]]; then
  fail "untracked file cleaned" "untracked.txt survived"
else
  pass "untracked file cleaned"
fi
assert_eq "local commit discarded" "$(git -C "$dir" rev-parse origin/main)" "$(git -C "$dir" rev-parse HEAD)"

section "sync picks up new upstream commits"

work="$TMPDIR_T/work"
printf 'updated\n' > "$work/README.md"
git -C "$work" -c user.email=t@t -c user.name=t commit --quiet -am "update"
git -C "$work" push --quiet origin main

rc=0; sync_autopilot_clone o/r >/dev/null 2>&1 || rc=$?
assert_eq "third sync returns 0" "0" "$rc"
assert_eq "fast-forwarded to upstream" "updated" "$(cat "$dir/README.md")"

section "a missing origin fails"

rc=0; sync_autopilot_clone o/does-not-exist >/dev/null 2>&1 || rc=$?
if (( rc != 0 )); then pass "unknown repo returns non-zero"; else fail "unknown repo returns non-zero" "returned 0"; fi

printf '\n%s──────────%s\n' "$C_DIM" "$C_OFF"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf -- '  - %s\n' "$n"; done
  exit 1
fi
exit 0
