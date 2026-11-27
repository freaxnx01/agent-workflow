#!/usr/bin/env bash
#
# run-azdo-pr-feed-restore-tests.sh — Layer-1 tests for
# scripts/azdo-pr-feed-restore.sh (#699), the trusted step that restores a
# private Azure Artifacts feed for an Azure DevOps PR build validation.
#
# `dotnet` is a copy of tests/mocks/dotnet, so there is no SDK, no feed and no
# network. What the cases assert is the part that has to be right: the token
# reaches one hermetic step that runs MSBuild only on the PR's target-branch
# commit, every input that could point that step at code from the PR is
# refused, and the build step learns the fallback folder only after a
# successful restore.
#
# Usage: tests/run-azdo-pr-feed-restore-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESTORE="$ROOT/scripts/azdo-pr-feed-restore.sh"
MOCKS="$ROOT/tests/mocks"

ADO_FEED='https://pkgs.dev.azure.com/org/_packaging/f/nuget/v3/index.json'
SECRET='tok-SECRET'

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
  if [[ "$actual" == "$expected" ]]; then pass "$name"; else
    fail "$name" "expected: $expected | actual: $actual"; fi
}
assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$name"; else
    fail "$name" "missing: $needle | in: $haystack"; fi
}
assert_not_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then pass "$name"; else
    fail "$name" "unexpected: $needle"; fi
}

TMP="$(mktemp -d)"
# The read-only hermetic bin directory below has to be made writable again
# before it can be deleted.
trap 'chmod -R u+w "$TMP" 2>/dev/null || true; rm -rf "$TMP"' EXIT

# The PATH the entry point re-executes with (AWF_TEST_HERMETIC_PATH stands in
# for the fixed one). `dotnet` is a copy rather than a symlink, and neither it
# nor the directory is writable: the entry point refuses a `dotnet` this user
# could replace, and a symlink would resolve to one in a writable place.
BIN="$TMP/bin"
mkdir -p "$BIN"
cp "$MOCKS/dotnet" "$BIN/dotnet"
for tool in bash git env mktemp realpath rm mkdir chmod cat head find cp stat \
  dirname sort id sed; do
  ln -s "$(command -v "$tool")" "$BIN/$tool"
done
chmod a-w "$BIN/dotnet" "$BIN"

CACHE_ROOT="$TMP/c"
mkdir -p "$CACHE_ROOT/var/cache/awf-nuget"

# make_pr_checkout <name> — a checkout whose HEAD is what Azure DevOps checks
# out for a PR build: the merge commit of refs/pull/<n>/merge, whose FIRST
# parent is the target branch's tip. Echoes that first parent's SHA.
make_pr_checkout() {
  local dir="$TMP/$1" first
  mkdir -p "$dir"
  git init -q -b main "$dir"
  printf '<Solution/>\n' > "$dir/Sample.sln"
  git -C "$dir" add -A
  git -C "$dir" -c user.name=t -c user.email=t@example.invalid commit -q -m target
  first="$(git -C "$dir" rev-parse HEAD)"
  git -C "$dir" checkout -q -b feature
  printf 'from the PR\n' > "$dir/pr.txt"
  git -C "$dir" add -A
  git -C "$dir" -c user.name=t -c user.email=t@example.invalid commit -q -m pr
  git -C "$dir" checkout -q --detach "$first"
  git -C "$dir" -c user.name=t -c user.email=t@example.invalid \
    merge -q --no-ff -m merge feature
  printf '%s' "$first"
}

REPO="$TMP/repo"
SEED="$(make_pr_checkout repo)"

CASE_N=0
RC=0; OUT=''; ERR=''
# Every byte the entry point ever printed, so one case can prove the token is
# in none of it.
TRANSCRIPT=''

# run_restore [VAR=value ...] — runs the entry point for a PR build of $REPO
# with a work directory of its own. A later VAR=value overrides a default; an
# empty value stands in for an unset variable.
run_restore() {
  CASE_N=$((CASE_N + 1))
  RC=0
  OUT="$(env -i PATH="$BIN" HOME="$TMP/caller-home" \
    AWF_TEST_HERMETIC_PATH="$BIN" AWF_TEST_CACHE_ROOT="$CACHE_ROOT" \
    AWF_NUGET_FEEDS="$ADO_FEED" SYSTEM_ACCESSTOKEN="$SECRET" \
    BUILD_SOURCESDIRECTORY="$REPO" AWF_PR_RESTORE_WORK_DIR="$TMP/w/$CASE_N" \
    SYSTEM_PULLREQUEST_TARGETBRANCH=refs/heads/main \
    BUILD_REPOSITORY_DEFAULTBRANCH=refs/heads/main \
    "$@" bash "$RESTORE" 2>"$TMP/err-$CASE_N")" || RC=$?
  ERR="$(cat "$TMP/err-$CASE_N")"
  TRANSCRIPT+="$OUT$ERR"
}

mkdir -p "$TMP/w" "$TMP/caller-home"

section "nothing to do, and usage"

BLANK_LOG="$TMP/dotnet-blank.log"
run_restore AWF_NUGET_FEEDS='  ' DOTNET_LOG="$BLANK_LOG"
assert_eq "blank_feeds_exits_0_without_dotnet: rc" "0" "$RC"
assert_eq "blank_feeds_exits_0_without_dotnet: no dotnet call" "0" \
  "$([[ -e "$BLANK_LOG" ]] && echo 1 || echo 0)"
assert_contains "blank_feeds_exits_0_without_dotnet: says nothing to restore" \
  "nothing to restore" "$OUT$ERR"

run_restore SYSTEM_ACCESSTOKEN=''
assert_eq "missing_token_exits_2: rc" "2" "$RC"

section "refusals"

run_restore AWF_NUGET_FEEDS='https://example.com/v3/index.json'
assert_eq "non_ado_feed_refused: rc" "1" "$RC"
assert_contains "non_ado_feed_refused: prefixed cause" "pr feed restore:" "$ERR"
assert_contains "non_ado_feed_refused: names the URL" \
  "https://example.com/v3/index.json" "$ERR"

run_restore AWF_PR_RESTORE_WORK_DIR="$REPO/work"
assert_eq "work_dir_inside_sources_refused: rc" "1" "$RC"
assert_contains "work_dir_inside_sources_refused: says why" \
  "pr feed restore:" "$ERR"

# MSBuild walks up from the seed worktree, so nothing above the work directory
# may be an import — on a persistent agent an earlier job could have left one.
mkdir -p "$TMP/anc/work"
: > "$TMP/anc/Directory.Build.props"
run_restore AWF_PR_RESTORE_WORK_DIR="$TMP/anc/work"
rm -f "$TMP/anc/Directory.Build.props"
assert_eq "ancestor_directory_build_props_refused: rc" "1" "$RC"
assert_contains "ancestor_directory_build_props_refused: names the file" \
  "Directory.Build.props" "$ERR"

# A `.git` an earlier job tampered with: a filter driver runs during the
# worktree add, which happens with the token in the environment.
git -C "$REPO" config filter.x.smudge cat
run_restore
git -C "$REPO" config --unset filter.x.smudge
assert_eq "git_filter_in_checkout_config_refused: rc" "1" "$RC"
assert_contains "git_filter_in_checkout_config_refused: names the key" \
  "filter.x.smudge" "$ERR"

mkdir -p "$REPO/.git/info"
printf '* filter=x\n' > "$REPO/.git/info/attributes"
run_restore
rm -f "$REPO/.git/info/attributes"
assert_eq "info_attributes_refused: rc" "1" "$RC"
assert_contains "info_attributes_refused: names the file" "attributes" "$ERR"

# A manual queue, not a PR build: HEAD has one parent, and HEAD~1 is then not
# a commit any policy vouched for.
SINGLE="$TMP/single"
make_pr_checkout single >/dev/null
git -C "$SINGLE" checkout -q --detach main
run_restore BUILD_SOURCESDIRECTORY="$SINGLE"
assert_eq "single_parent_head_refused: rc" "1" "$RC"
assert_contains "single_parent_head_refused: says why" \
  "not a PR merge commit" "$ERR"

run_restore SYSTEM_PULLREQUEST_TARGETBRANCH=refs/heads/agent/x
assert_eq "target_not_default_refused: rc" "1" "$RC"
assert_contains "target_not_default_refused: names both branches" \
  "refs/heads/agent/x" "$ERR"

section "the seed commit"

run_restore BUILD_REPOSITORY_DEFAULTBRANCH=''
assert_eq "default_branch_falls_back_to_main: rc" "0" "$RC"

SEED_LOG="$TMP/dotnet-seed.log"
run_restore DOTNET_LOG="$SEED_LOG"
assert_eq "seed_is_first_parent: rc" "0" "$RC"
assert_contains "seed_is_first_parent: the first parent is the seed" \
  "seed $SEED" "$OUT"

section "the token"

assert_not_contains "token_never_printed" "$SECRET" "$TRANSCRIPT"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then printf 'Failed:\n'; printf '  - %s\n' "${FAIL_NAMES[@]}"; exit 1; fi
