#!/usr/bin/env bash
#
# run-handoff-resume-tests.sh — Layer-1 fixture tests for hooks/handoff-resume.sh.
#
# Feeds the hook the SessionStart JSON Claude Code sends it (on stdin) against
# throwaway git repos under a temp dir, and asserts what it injects. No network,
# no Claude Code — just the hook, git and jq.
#
# Usage: tests/run-handoff-resume-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/hooks/handoff-resume.sh"

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
  [[ -n "${2:-}" ]] && printf '    %s%s%s\n' "$C_DIM" "$2" "$C_OFF"
  return 0
}

assert_contains() {
  local hay="$1" needle="$2" name="$3"
  if [[ "$hay" == *"$needle"* ]]; then pass "$name"
  else fail "$name" "expected substring not found: $needle"; fi
}

assert_not_contains() {
  local hay="$1" needle="$2" name="$3"
  if [[ "$hay" != *"$needle"* ]]; then pass "$name"
  else fail "$name" "unexpected substring found: $needle"; fi
}

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then pass "$name"
  else fail "$name" "want [$want], got [$got]"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git_quiet() { git -c init.defaultBranch=main -c user.email=t@t -c user.name=t "$@" >/dev/null 2>&1; }

# make_repo <name> [branch] — repo with one commit, optionally on a feature branch.
make_repo() {
  local dir="$TMP/$1"
  mkdir -p "$dir/.claude"
  git_quiet init "$dir"
  printf 'x\n' >"$dir/README.md"
  git_quiet -C "$dir" add -A
  git_quiet -C "$dir" commit -m init
  [[ -z "${2:-}" ]] || git_quiet -C "$dir" checkout -b "$2"
  printf '%s' "$dir"
}

handoff() { printf '## Resume: %s\n\n**Next step:** %s\n' "$1" "$2"; }

# run_hook <dir> — the SessionStart payload Claude Code sends, on stdin.
run_hook() { printf '{"hookEventName":"SessionStart","source":"clear","cwd":"%s"}' "$1" | bash "$HOOK"; }

# context <hook-output> — the injected additionalContext, or empty.
context() { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true; }

# ============================================================================
section "injects the current branch's handoff"

REPO="$(make_repo slugged feature/nice-thing)"
handoff "the nice thing" "Wire the endpoint, then run the suite." \
  >"$REPO/.claude/handoff-feature-nice-thing.md"

out="$(run_hook "$REPO")"
ctx="$(context "$out")"
assert_contains "$ctx" 'Wire the endpoint, then run the suite.' "the handoff body is injected"
assert_contains "$ctx" '.claude/handoff-feature-nice-thing.md' "the injected text names the file it read"
assert_contains "$out" '"hookEventName": "SessionStart"' "output is a SessionStart hook payload"

# ============================================================================
section "another branch's handoff is never injected"

# The whole point of branch-keyed handoffs: a sibling worktree's saved phase must
# not be resumed here just because the file is sitting in .claude/.
REPO2="$(make_repo other-branch-only feature/mine)"
handoff "someone else's phase" "Do not resume me here." \
  >"$REPO2/.claude/handoff-feature-theirs.md"

out="$(run_hook "$REPO2")"
assert_eq "$out" "" "no injection when only another branch's handoff exists"

# ============================================================================
section "legacy unslugged handoff.md still works"

REPO3="$(make_repo legacy-only)"
handoff "pre-slug phase" "Read the plan first." >"$REPO3/.claude/handoff.md"
ctx="$(context "$(run_hook "$REPO3")")"
assert_contains "$ctx" 'Read the plan first.' "the legacy file is injected as a fallback"
assert_contains "$ctx" '.claude/handoff.md' "the injected text names the legacy file"

# ============================================================================
section "the branch-keyed file wins over the legacy one"

REPO4="$(make_repo both feature/current)"
handoff "current phase" "This is the live one." >"$REPO4/.claude/handoff-feature-current.md"
handoff "old phase" "This one is obsolete." >"$REPO4/.claude/handoff.md"
ctx="$(context "$(run_hook "$REPO4")")"
assert_contains "$ctx" 'This is the live one.' "branch-keyed handoff is preferred"
assert_not_contains "$ctx" 'This one is obsolete.' "legacy handoff is not injected alongside it"

# ============================================================================
section "detached HEAD uses the same slug /handoff would write"

REPO5="$(make_repo detached)"
sha="$(git -C "$REPO5" rev-parse --short HEAD)"
git_quiet -C "$REPO5" checkout --detach HEAD
handoff "detached phase" "Resume from the detached checkout." \
  >"$REPO5/.claude/handoff-detached-$sha.md"
ctx="$(context "$(run_hook "$REPO5")")"
assert_contains "$ctx" 'Resume from the detached checkout.' "detached-<sha> slug is resolved"

# ============================================================================
section "points at the index when there is one"

REPO6="$(make_repo with-index feature/indexed)"
handoff "indexed phase" "Carry on." >"$REPO6/.claude/handoff-feature-indexed.md"
printf '# Handoffs\n' >"$REPO6/.claude/handoffs.md"
ctx="$(context "$(run_hook "$REPO6")")"
assert_contains "$ctx" '.claude/handoffs.md' "the overview is mentioned when present"

REPO7="$(make_repo without-index feature/plain)"
handoff "plain phase" "Carry on." >"$REPO7/.claude/handoff-feature-plain.md"
ctx="$(context "$(run_hook "$REPO7")")"
assert_not_contains "$ctx" 'handoffs.md' "no dangling pointer when the overview is absent"

# ============================================================================
section "quiet and successful when there is nothing to inject"

REPO8="$(make_repo empty feature/nothing)"
set +e
out="$(run_hook "$REPO8")"; code=$?
set -e
assert_eq "$out" "" "no output when no handoff exists"
assert_eq "$code" "0" "exits 0 so the session start is never blocked"

# ============================================================================
section "degrades instead of failing outside a git repo"

NOGIT="$TMP/not-a-repo"
mkdir -p "$NOGIT/.claude"
handoff "no-git phase" "Still resumable." >"$NOGIT/.claude/handoff.md"
set +e
out="$(run_hook "$NOGIT")"; code=$?
set -e
assert_eq "$code" "0" "exits 0 with no git repo to read a branch from"
assert_contains "$(context "$out")" 'Still resumable.' "legacy file is still injected without git"

# ============================================================================
section "falls back to CLAUDE_PROJECT_DIR when the payload has no cwd"

REPO9="$(make_repo no-cwd feature/env)"
handoff "env phase" "Found via the env var." >"$REPO9/.claude/handoff-feature-env.md"
ctx="$(printf '{"hookEventName":"SessionStart","source":"clear"}' |
  CLAUDE_PROJECT_DIR="$REPO9" bash "$HOOK" | jq -r '.hookSpecificOutput.additionalContext // empty')"
assert_contains "$ctx" 'Found via the env var.' "CLAUDE_PROJECT_DIR is honoured"

# --- summary ----------------------------------------------------------------

printf '\n%s\n' "────────────────────────────────────────"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
if ((FAIL > 0)); then
  printf '\nfailures:\n'
  for n in "${FAIL_NAMES[@]}"; do printf '  - %s\n' "$n"; done
  exit 1
fi
