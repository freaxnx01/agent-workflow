#!/usr/bin/env bash
#
# run-link-skills-tests.sh — Layer-1 tests for setup/link-skills.sh (no network).
#
# Each case builds a throwaway "repo" (setup/link-skills.sh + a skills/ tree) and
# a scratch $HOME, then runs the installer with --no-sync so it never touches the
# network or the real checkout. Asserts on the resulting ~/.claude/skills/ tree.
#
# Usage: tests/run-link-skills-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$ROOT/setup/link-skills.sh"

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

assert_exists() { if [ -e "$2" ]; then pass "$1"; else fail "$1" "missing: $2"; fi; }
assert_absent() { if [ ! -e "$2" ]; then pass "$1"; else fail "$1" "should be gone: $2"; fi; }

# --- harness ---------------------------------------------------------------

# Build a sandbox: $SANDBOX/repo/setup/link-skills.sh + $SANDBOX/repo/skills/,
# and an empty $SANDBOX/home. Echoes the sandbox path.
make_sandbox() {
  local sandbox; sandbox="$(mktemp -d)"
  mkdir -p "$sandbox/repo/setup" "$sandbox/repo/skills" "$sandbox/home"
  cp "$INSTALLER" "$sandbox/repo/setup/link-skills.sh"
  echo "$sandbox"
}

# add_skill <sandbox> <name> [relative-file...]  — defaults to SKILL.md
add_skill() {
  local sandbox="$1" name="$2"; shift 2
  local files=("$@"); [ ${#files[@]} -eq 0 ] && files=("SKILL.md")
  for rel in "${files[@]}"; do
    mkdir -p "$sandbox/repo/skills/$name/$(dirname "$rel")"
    printf 'content of %s/%s\n' "$name" "$rel" > "$sandbox/repo/skills/$name/$rel"
  done
}

run_installer() {
  local sandbox="$1"; shift
  HOME="$sandbox/home" bash "$sandbox/repo/setup/link-skills.sh" --no-sync "$@" >/dev/null 2>&1
}

# --- cases -----------------------------------------------------------------

section "fresh install"
SB="$(make_sandbox)"
add_skill "$SB" alpha
run_installer "$SB"
assert_exists "installs a skill's SKILL.md" "$SB/home/.claude/skills/alpha/SKILL.md"
rm -rf "$SB"

section "prune: skill removed upstream"
SB="$(make_sandbox)"
add_skill "$SB" alpha
add_skill "$SB" beta
run_installer "$SB"
assert_exists "both skills installed on first run" "$SB/home/.claude/skills/beta/SKILL.md"
rm -rf "$SB/repo/skills/beta"          # beta deleted upstream
run_installer "$SB"
assert_absent "prunes a skill deleted upstream" "$SB/home/.claude/skills/beta"
assert_exists "leaves surviving skills alone"  "$SB/home/.claude/skills/alpha/SKILL.md"
rm -rf "$SB"

section "prune: never touches foreign skills"
SB="$(make_sandbox)"
add_skill "$SB" alpha
run_installer "$SB"
mkdir -p "$SB/home/.claude/skills/handwritten"   # not ours — never in the manifest
echo "mine" > "$SB/home/.claude/skills/handwritten/SKILL.md"
run_installer "$SB"
assert_exists "leaves a hand-written skill untouched" "$SB/home/.claude/skills/handwritten/SKILL.md"
rm -rf "$SB"

section "prune: stale file inside a surviving skill"
SB="$(make_sandbox)"
add_skill "$SB" alpha "SKILL.md" "references/old.md"
run_installer "$SB"
assert_exists "installs nested reference files" "$SB/home/.claude/skills/alpha/references/old.md"
rm "$SB/repo/skills/alpha/references/old.md"     # reference dropped upstream
run_installer "$SB"
assert_absent "prunes a file dropped from a surviving skill" "$SB/home/.claude/skills/alpha/references/old.md"
assert_exists "keeps the skill itself" "$SB/home/.claude/skills/alpha/SKILL.md"
rm -rf "$SB"

# --- summary ---------------------------------------------------------------

printf '\n%s─────%s\n' "$C_DIM" "$C_OFF"
printf '  %s%d passed%s' "$C_GREEN" "$PASS" "$C_OFF"
[ "$FAIL" -gt 0 ] && printf ', %s%d failed%s' "$C_RED" "$FAIL" "$C_OFF"
printf '\n'
if [ "$FAIL" -gt 0 ]; then
  printf '\n  failed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf '    - %s\n' "$n"; done
  exit 1
fi
