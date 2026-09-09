#!/usr/bin/env bash
#
# run-handoff-index-tests.sh — Layer-1 fixture tests for scripts/lib/handoff-index.sh.
#
# Builds throwaway git repositories with worktrees and handoff files under a
# temp dir, then asserts what the index renderer writes. No network, no gh, no
# herdr — the script only reads the filesystem and git.
#
# Usage: tests/run-handoff-index-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/lib/handoff-index.sh"

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

# --- fixture builders -------------------------------------------------------

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git_quiet() { git -c init.defaultBranch=main -c user.email=t@t -c user.name=t "$@" >/dev/null 2>&1; }

# make_repo <name> — a repo with one commit on main, worktree dir ignored.
make_repo() {
  local name="$1" dir="$TMP/$1"
  mkdir -p "$dir/.claude"
  git_quiet init "$dir"
  printf '.worktrees/\n.claude/handoffs.md\n' >"$dir/.gitignore"
  git_quiet -C "$dir" add -A
  git_quiet -C "$dir" commit -m "init"
  printf '%s' "$dir"
}

# add_worktree <repo-dir> <branch> — checks a new branch out under .worktrees/
add_worktree() {
  local dir="$1" branch="$2"
  git_quiet -C "$dir" worktree add -b "$branch" "$dir/.worktrees/$branch"
}

# write_handoff <working-copy> <slug> <next-step> — a handoff file, committed.
write_handoff() {
  local copy="$1" slug="$2" next="$3"
  mkdir -p "$copy/.claude"
  cat >"$copy/.claude/handoff-$slug.md" <<EOF
## Resume: $slug work, implementation phase

**Artifact:** \`docs/plans/$slug.md\`

**Phase:** Plan written and approved.

**Next step:** $next

**Also note:** nothing else.
EOF
  git_quiet -C "$copy" add -A
  git_quiet -C "$copy" commit -m "docs(handoff): $slug"
}

run_index() { bash "$SCRIPT" "$@"; }

# ============================================================================
section "renders one row per branch-keyed handoff"

REPO_A="$(make_repo repo-a)"
add_worktree "$REPO_A" feature-alpha
write_handoff "$REPO_A/.worktrees/feature-alpha" feature-alpha "Run the migration, then wire the endpoint."

out="$(run_index --repo "$REPO_A/.worktrees/feature-alpha" --global-index "$TMP/global.md" --stdout)"
assert_contains "$out" 'feature-alpha' "branch name appears"
assert_contains "$out" '.worktrees/feature-alpha' "worktree path appears"
assert_contains "$out" 'Run the migration, then wire the endpoint.' "next step is extracted"
assert_contains "$out" '.claude/handoff-feature-alpha.md' "handoff file path appears"
assert_contains "$out" '/pickup' "resume prompt appears"
assert_contains "$out" 'repo-a' "repo name appears in the heading"

# ============================================================================
section "a handoff for a branch that is not checked out anywhere"

write_handoff "$REPO_A/.worktrees/feature-alpha" ghost-branch "Nothing checked this out."
out="$(run_index --repo "$REPO_A/.worktrees/feature-alpha" --global-index "$TMP/global.md" --stdout)"
assert_contains "$out" 'ghost-branch' "orphan handoff still listed"
rows="$(printf '%s\n' "$out" | grep -c '^| `' || true)"
assert_eq "$rows" "2" "one row per handoff (2 rows)"
assert_contains "$out" 'not checked out' "orphan row says the branch is not checked out"

# ============================================================================
section "the same handoff file present in two working copies is one row"

add_worktree "$REPO_A" feature-beta
git_quiet -C "$REPO_A/.worktrees/feature-beta" merge feature-alpha
out="$(run_index --repo "$REPO_A" --global-index "$TMP/global.md" --stdout)"
rows="$(printf '%s\n' "$out" | grep -c '^| `' || true)"
assert_eq "$rows" "2" "duplicate copies of a handoff collapse to one row"
assert_contains "$out" '.worktrees/feature-alpha' "row keeps the worktree whose branch matches"

# ============================================================================
section "legacy unslugged handoff.md"

printf 'Read the plan first, no heading in this one.\n\n**Next step:** Rename me on the next /handoff.\n' \
  >"$REPO_A/.claude/handoff.md"
out="$(run_index --repo "$REPO_A" --global-index "$TMP/global.md" --stdout)"
assert_contains "$out" 'legacy' "legacy handoff.md is listed and flagged"
assert_contains "$out" 'Read the plan first' "a headingless handoff falls back to its first line"
assert_not_contains "$out" 'check out `(legacy' "legacy row resumes in the copy holding it, not a branch"
rm -f "$REPO_A/.claude/handoff.md"

# ============================================================================
section "writes the repo-local index and upserts the global one"

run_index --repo "$REPO_A" --global-index "$TMP/global.md" >/dev/null
repo_index="$(cat "$REPO_A/.claude/handoffs.md")"
assert_contains "$repo_index" 'feature-alpha' "repo index written to .claude/handoffs.md"
assert_contains "$repo_index" 'Derived index' "repo index says it is derived"

global="$(cat "$TMP/global.md")"
assert_contains "$global" 'handoff-index:begin' "global index has section markers"
assert_contains "$global" 'repo-a' "global index has the repo section"
assert_contains "$global" 'feature-alpha' "global index carries the rows"

# ============================================================================
section "a second repo's section is added without disturbing the first"

REPO_B="$(make_repo repo-b)"
add_worktree "$REPO_B" fix-thing
write_handoff "$REPO_B/.worktrees/fix-thing" fix-thing "Ship the fix."
run_index --repo "$REPO_B" --global-index "$TMP/global.md" >/dev/null
global="$(cat "$TMP/global.md")"
assert_contains "$global" 'repo-a' "first repo section survives"
assert_contains "$global" 'repo-b' "second repo section added"
assert_contains "$global" 'Ship the fix.' "second repo rows present"

# ============================================================================
section "regeneration is idempotent"

before="$(cat "$TMP/global.md")"
run_index --repo "$REPO_B" --global-index "$TMP/global.md" >/dev/null
run_index --repo "$REPO_A" --global-index "$TMP/global.md" >/dev/null
after="$(cat "$TMP/global.md")"
markers="$(grep -c 'handoff-index:begin' "$TMP/global.md" || true)"
assert_eq "$markers" "2" "no duplicate sections after re-running"
assert_eq "${after//[0-9:-]/}" "${before//[0-9:-]/}" "content stable apart from timestamps"

# ============================================================================
section "a repo with no handoffs drops out of the global index"

rm -f "$REPO_B/.worktrees/fix-thing/.claude/handoff-fix-thing.md"
git_quiet -C "$REPO_B/.worktrees/fix-thing" commit -am "chore: pickup done"
run_index --repo "$REPO_B" --global-index "$TMP/global.md" >/dev/null
global="$(cat "$TMP/global.md")"
assert_not_contains "$global" 'fix-thing' "emptied repo section removed"
assert_contains "$global" 'repo-a' "other repo untouched"
assert_contains "$(cat "$REPO_B/.claude/handoffs.md")" 'No handoffs' "repo index states there are none"

# ============================================================================
section "a repo that never handed anything off gets no index file"

REPO_C="$(make_repo repo-c)"
run_index --repo "$REPO_C" --global-index "$TMP/global.md" >/dev/null
if [[ -e "$REPO_C/.claude/handoffs.md" ]]; then
  fail "no index file created for a handoff-free repo" "the file was written anyway"
else
  pass "no index file created for a handoff-free repo"
fi

# ============================================================================
section "the machine-wide index is locked while it is rewritten"

# A held lock times out instead of racing the holder. Attempts/sleep are env-
# tunable precisely so this assertion costs no wall clock.
mkdir "$TMP/global.md.lock"
before="$(cat "$TMP/global.md")"
set +e
HANDOFF_INDEX_LOCK_ATTEMPTS=1 HANDOFF_INDEX_LOCK_SLEEP=0 \
  bash "$SCRIPT" --repo "$REPO_A" --global-index "$TMP/global.md" >/dev/null 2>&1
code=$?
set -e
assert_eq "$code" "4" "a held lock exits 4"
assert_eq "$(cat "$TMP/global.md")" "$before" "a locked run leaves the index untouched"

# A lock left behind by a crashed run is reclaimed rather than waited on.
touch -d '-5 minutes' "$TMP/global.md.lock"
HANDOFF_INDEX_LOCK_ATTEMPTS=2 HANDOFF_INDEX_LOCK_SLEEP=0 \
  bash "$SCRIPT" --repo "$REPO_A" --global-index "$TMP/global.md" >/dev/null
assert_contains "$(cat "$TMP/global.md")" 'feature-alpha' "a stale lock is reclaimed and the run completes"
if [[ -e "$TMP/global.md.lock" ]]; then
  fail "the lock is released on exit" "lock dir still present"
else
  pass "the lock is released on exit"
fi

# ============================================================================
section "error handling"

set +e
bash "$SCRIPT" --bogus-flag >/dev/null 2>&1; code=$?
set -e
assert_eq "$code" "2" "unknown flag exits 2 (usage error)"

mkdir -p "$TMP/not-a-repo"
set +e
bash "$SCRIPT" --repo "$TMP/not-a-repo" --global-index "$TMP/global.md" >/dev/null 2>&1; code=$?
set -e
assert_eq "$code" "3" "outside a git repo exits 3"

# --- summary ----------------------------------------------------------------

printf '\n%s\n' "────────────────────────────────────────"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
if ((FAIL > 0)); then
  printf '\nfailures:\n'
  for n in "${FAIL_NAMES[@]}"; do printf '  - %s\n' "$n"; done
  exit 1
fi
