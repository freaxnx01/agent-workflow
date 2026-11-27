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
CLEANUP="$ROOT/scripts/azdo-pr-feed-cleanup.sh"
MOCKS="$ROOT/tests/mocks"
TEMPLATE="$ROOT/templates/azdo/pr-validation.yml"

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

# The entry point refuses a `dotnet` the current user can write, and root can
# write every file, so as root there is nothing these cases could prove. The
# pipeline runs as the unprivileged agent user, which is what they model.
if [[ "$(id -u)" == 0 ]]; then
  echo "SKIP: running as root"
  exit 0
fi

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
CACHE="$CACHE_ROOT/var/cache/awf-nuget"

# make_pr_checkout <name> [root-file] — a checkout whose HEAD is what Azure
# DevOps checks out for a PR build: the merge commit of refs/pull/<n>/merge,
# whose FIRST parent is the target branch's tip. <root-file> is what the target
# commit holds at the root, a solution by default. Echoes that parent's SHA.
make_pr_checkout() {
  local dir="$TMP/$1" root_file="${2:-Sample.sln}" first
  mkdir -p "$dir"
  git init -q -b main "$dir"
  printf '<Solution/>\n' > "$dir/$root_file"
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

# The other ways an earlier job could make git read or run something else: each
# case gets a checkout of its own, so no leftover decides a later case.
REPL="$TMP/repl"
make_pr_checkout repl >/dev/null
git -C "$REPL" update-ref "refs/replace/$(git -C "$REPL" rev-parse HEAD^1)" HEAD
run_restore BUILD_SOURCESDIRECTORY="$REPL"
assert_eq "loose_replace_ref_refused: rc" "1" "$RC"
assert_contains "loose_replace_ref_refused: says why" "refs/replace/" "$ERR"

PREPL="$TMP/prepl"
make_pr_checkout prepl >/dev/null
git -C "$PREPL" update-ref "refs/replace/$(git -C "$PREPL" rev-parse HEAD^1)" HEAD
git -C "$PREPL" pack-refs --all
run_restore BUILD_SOURCESDIRECTORY="$PREPL"
assert_eq "packed_replace_ref_refused: rc" "1" "$RC"
assert_contains "packed_replace_ref_refused: says why" "refs/replace/" "$ERR"

GRAFTS="$TMP/grafts"
make_pr_checkout grafts >/dev/null
mkdir -p "$GRAFTS/.git/info"
: > "$GRAFTS/.git/info/grafts"
run_restore BUILD_SOURCESDIRECTORY="$GRAFTS"
assert_eq "info_grafts_refused: rc" "1" "$RC"
assert_contains "info_grafts_refused: names the file" "info/grafts" "$ERR"

ALT="$TMP/alt"
make_pr_checkout alt >/dev/null
: > "$ALT/.git/objects/info/alternates"
run_restore BUILD_SOURCESDIRECTORY="$ALT"
assert_eq "objects_alternates_refused: rc" "1" "$RC"
assert_contains "objects_alternates_refused: names the file" "alternates" "$ERR"

WTC="$TMP/wtc"
make_pr_checkout wtc >/dev/null
: > "$WTC/.git/config.worktree"
run_restore BUILD_SOURCESDIRECTORY="$WTC"
assert_eq "config_worktree_refused: rc" "1" "$RC"
assert_contains "config_worktree_refused: names the file" "config.worktree" "$ERR"

for key in extensions.worktreeConfig core.attributesFile; do
  KEYREPO="$TMP/key-${key%%.*}"
  make_pr_checkout "key-${key%%.*}" >/dev/null
  git -C "$KEYREPO" config "$key" true
  run_restore BUILD_SOURCESDIRECTORY="$KEYREPO"
  assert_eq "tamper_key_${key}_refused: rc" "1" "$RC"
  assert_contains "tamper_key_${key}_refused: names the key" "${key,,}" "$ERR"
done

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

section "the default branch"

run_restore BUILD_REPOSITORY_DEFAULTBRANCH=''
assert_eq "default_branch_falls_back_to_main: rc" "0" "$RC"

# A repo whose default branch is not `main`: Azure DevOps does not report it,
# so the refusal must name the variable that fixes it.
run_restore BUILD_REPOSITORY_DEFAULTBRANCH='' \
  SYSTEM_PULLREQUEST_TARGETBRANCH=refs/heads/master
assert_eq "non_main_default_refused_without_variable: rc" "1" "$RC"
assert_contains "non_main_default_refused_without_variable: names the fix" \
  "AWF_DEFAULT_BRANCH" "$ERR"

run_restore BUILD_REPOSITORY_DEFAULTBRANCH='' AWF_DEFAULT_BRANCH=master \
  SYSTEM_PULLREQUEST_TARGETBRANCH=refs/heads/master
assert_eq "awf_default_branch_master_accepted: rc" "0" "$RC"

section "the restore and the handoff"

RLOG="$TMP/dotnet-restore.log"
ELOG="$TMP/dotnet-env.log"
run_restore DOTNET_LOG="$RLOG" DOTNET_ENV_LOG="$ELOG" CANARY_VAR=canary
LOGTEXT="$(cat "$RLOG" 2>/dev/null || true)"
ENVTEXT="$(cat "$ELOG" 2>/dev/null || true)"
assert_eq "restore_runs_on_seed_worktree: rc" "0" "$RC"
assert_contains "restore_runs_on_seed_worktree: the seed is the first parent" \
  "head=$SEED" "$LOGTEXT"
assert_contains "restore_runs_on_seed_worktree: in a worktree under the work dir" \
  "pwd=$TMP/w/" "$LOGTEXT"
assert_not_contains "token_not_in_argv" "$SECRET" "$LOGTEXT"
assert_eq "temp_config_removed" "" \
  "$(find "$TMP/w" -name 'feed-config.*' | head -n1)"
assert_eq "success_emits_setvariable" \
  "##vso[task.setvariable variable=NUGET_FALLBACK_PACKAGES]$CACHE" "$OUT"

# The environment the restore itself ran in, as the mock saw it. Everything an
# earlier job on a persistent agent could have left behind — a user HOME, a
# global git config, an MSBuild user-location import — is out of reach.
assert_not_contains "hermetic_env: HOME is not the caller's" \
  "HOME=$TMP/caller-home" "$ENVTEXT"
assert_contains "hermetic_env: the global git config is /dev/null" \
  "GIT_CONFIG_GLOBAL=/dev/null" "$ENVTEXT"
assert_contains "hermetic_env: no system git config" \
  "GIT_CONFIG_NOSYSTEM=1" "$ENVTEXT"
assert_contains "hermetic_env: git ignores replace refs" \
  "GIT_NO_REPLACE_OBJECTS=1" "$ENVTEXT"
for switch in BeforeMicrosoftCommonProps AfterMicrosoftCommonProps \
  BeforeMicrosoftCommonTargets AfterMicrosoftCommonTargets; do
  assert_contains "hermetic_env: ImportUserLocationsByWildcard$switch is off" \
    "ImportUserLocationsByWildcard$switch=false" "$ENVTEXT"
done
assert_not_contains "hermetic_env: nothing outside the allowlist" \
  "CANARY_VAR" "$ENVTEXT"

# A `core.hooksPath` in the caller's HOME would run during the worktree add,
# with the token in the environment.
HOOKS="$TMP/hooks"
mkdir -p "$HOOKS"
printf '#!/bin/sh\ntouch %s/hook-ran\n' "$TMP" > "$HOOKS/post-checkout"
chmod 0755 "$HOOKS/post-checkout"
printf '[core]\n\thooksPath = %s\n' "$HOOKS" > "$TMP/caller-home/.gitconfig"
run_restore
rm -f "$TMP/caller-home/.gitconfig"
assert_eq "planted_global_hook_not_run: rc" "0" "$RC"
assert_eq "planted_global_hook_not_run: the hook did not run" "0" \
  "$([[ -e "$TMP/hook-ran" ]] && echo 1 || echo 0)"

# The same writable directory comes first on the PATH the step inherits, so
# the tools the outer phase runs before the re-exec, with the token already in
# the environment, must not be looked up on it.
PLANTED="$TMP/planted"
mkdir -p "$PLANTED"
for tool in env mktemp chmod; do
  printf '#!/bin/sh\n%s %s/planted-%s-ran\nexec %s "$@"\n' \
    "$(command -v touch)" "$TMP" "$tool" "$(command -v "$tool")" > "$PLANTED/$tool"
  chmod 0755 "$PLANTED/$tool"
done
run_restore PATH="$PLANTED:$BIN"
assert_eq "planted_outer_tools_not_run: rc" "0" "$RC"
for tool in env mktemp chmod; do
  assert_eq "planted_outer_tools_not_run: $tool" "0" \
    "$([[ -e "$TMP/planted-$tool-ran" ]] && echo 1 || echo 0)"
done

# The image's PATH holds a directory the job user can write, so a `dotnet` of
# an earlier job's making must not be the one that gets the token.
chmod u+w "$BIN/dotnet"
run_restore
chmod a-w "$BIN/dotnet"
assert_eq "writable_dotnet_refused: rc" "1" "$RC"
assert_contains "writable_dotnet_refused: says why" "is writable by" "$ERR"

run_restore DOTNET_MOCK_FAIL=1
assert_eq "restore_failure_message_and_no_setvariable: rc" "1" "$RC"
assert_contains "restore_failure_message_and_no_setvariable: the Feed Reader message" \
  "private feed restore failed ($ADO_FEED): check that the build service has the Feed Reader role on the feed" \
  "$ERR"
assert_not_contains "restore_failure_message_and_no_setvariable: no handoff" \
  "task.setvariable" "$OUT"
assert_eq "restore_failure_message_and_no_setvariable: nothing left behind" "" \
  "$(find "$TMP/w" -name 'feed-config.*' | head -n1)"

NOSLN="$TMP/nosln"
make_pr_checkout nosln README.md >/dev/null
run_restore BUILD_SOURCESDIRECTORY="$NOSLN"
assert_eq "nothing_to_restore: rc" "1" "$RC"
assert_contains "nothing_to_restore: names the cause, not the Feed Reader role" \
  "private feed restore: no solution or project" "$ERR"

section "the cleanup step"

# run_cleanup [VAR=value ...] — the always() step. It holds no token and does
# not re-exec, so it runs with the PATH it is given.
run_cleanup() {
  CASE_N=$((CASE_N + 1))
  RC=0
  OUT="$(env -i PATH="$BIN" HOME="$TMP/caller-home" \
    AWF_TEST_CACHE_ROOT="$CACHE_ROOT" \
    "$@" bash "$CLEANUP" 2>"$TMP/err-$CASE_N")" || RC=$?
  ERR="$(cat "$TMP/err-$CASE_N")"
  TRANSCRIPT+="$OUT$ERR"
}

: > "$CACHE/x"
run_cleanup
assert_eq "cleanup_empties_cache: rc" "0" "$RC"
assert_eq "cleanup_empties_cache: emptied" "" \
  "$(find "$CACHE" -mindepth 1 | head -n1)"
assert_eq "cleanup_empties_cache: the folder itself stays" "1" \
  "$([[ -d "$CACHE" ]] && echo 1 || echo 0)"

run_cleanup AWF_TEST_CACHE_ROOT="$TMP/no-cache-root"
assert_eq "cleanup_absent_cache_ok: rc" "0" "$RC"

mkdir -p "$TMP/clink/var/cache" "$TMP/clink-target"
ln -s "$TMP/clink-target" "$TMP/clink/var/cache/awf-nuget"
: > "$TMP/clink-target/keep"
run_cleanup AWF_TEST_CACHE_ROOT="$TMP/clink"
assert_eq "cleanup_symlink_refused: rc" "1" "$RC"
assert_contains "cleanup_symlink_refused: says why" "pr feed cleanup:" "$ERR"
assert_eq "cleanup_symlink_refused: the target is untouched" "1" \
  "$([[ -f "$TMP/clink-target/keep" ]] && echo 1 || echo 0)"

section "the template"

# block_from <marker> — the template from the first line holding <marker> to
# the line before the next `# ---` section comment, so an assertion about one
# step cannot be satisfied by another step's text.
block_from() {
  awk -v marker="$1" 'index($0, marker) { on = 1; print; next }
    on && index($0, "# ---") { on = 0 }
    on { print }' "$TEMPLATE"
}

TEMPLATE_TEXT="$(cat "$TEMPLATE")"
assert_contains "template_fetch_depth_2" "fetchDepth: 2" "$TEMPLATE_TEXT"
assert_eq "template_token_only_in_restore_step: one occurrence" "1" \
  "$(grep -cF 'System.AccessToken' "$TEMPLATE" || true)"
assert_contains "template_token_only_in_restore_step: it is the restore step" \
  "System.AccessToken" "$(block_from 'azdo-pr-feed-restore.sh')"
assert_eq "template_feed_steps_conditional" "3" \
  "$(grep -cF "ne(variables['AWF_NUGET_FEEDS'], '')" "$TEMPLATE" || true)"
assert_contains "template_cleanup_always" "always()" \
  "$(block_from 'azdo-pr-feed-cleanup.sh')"
BUILD_BLOCK="$(block_from 'BUILD/TEST')"
assert_not_contains "template_build_step_has_no_env_token: no token" \
  "System.AccessToken" "$BUILD_BLOCK"
assert_not_contains "template_build_step_has_no_env_token: no fallback folder" \
  "NUGET_FALLBACK_PACKAGES" "$BUILD_BLOCK"
FEED_BLOCK="$(block_from 'PRIVATE FEEDS')"
assert_contains "template_fetch_hermetic: no global git config" \
  "GIT_CONFIG_GLOBAL=/dev/null" "$FEED_BLOCK"
assert_contains "template_fetch_hermetic: no hooks" \
  "core.hooksPath=/dev/null" "$FEED_BLOCK"
# Nothing a trusted step runs may be looked up on the inherited PATH: not the
# restore's interpreter (its shebang is `/usr/bin/env bash`), not the fetch's
# tools.
assert_contains "template_restore_interpreter_absolute" \
  "bash: '/usr/bin/bash \"\$(Agent.TempDirectory)/aw/scripts/azdo-pr-feed-restore.sh\"'" \
  "$TEMPLATE_TEXT"
for tool in env mkdir git; do
  assert_eq "template_fetch_tool_absolute: $tool" "" \
    "$(printf '%s\n' "$FEED_BLOCK" | grep -E "(^|[^/[:alnum:]_.-])$tool( |$)" |
      grep -vE '^ *#|displayName' || true)"
done

section "the token"

assert_not_contains "token_never_printed" "$SECRET" "$TRANSCRIPT"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then printf 'Failed:\n'; printf '  - %s\n' "${FAIL_NAMES[@]}"; exit 1; fi
