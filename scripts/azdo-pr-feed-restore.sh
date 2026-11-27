#!/usr/bin/env bash
#
# azdo-pr-feed-restore.sh — the trusted step of an Azure DevOps PR build
# validation that restores a private Azure Artifacts feed (#699).
#
# docs/AZDO-PIPELINE-SETUP.md section 9 forbids mapping the job token into any
# step of that pipeline, because it runs code from the PR. A repo whose build
# needs a package only a private feed serves therefore cannot restore, so with
# a required build-validation policy every one of its PRs is red.
#
# This step takes the token instead, and never runs code from the PR with it:
# it restores the PR merge commit's FIRST parent, which is the target branch's
# tip at merge time and therefore a commit the policy already vouched for, into
# the read-only fallback folder of #641. Only after that does it hand the
# untokened build step NUGET_FALLBACK_PACKAGES. A PR that adds or raises a
# private reference still fails and needs a human override — see section 9.6.
#
# Environment (the template of templates/azdo/pr-validation.yml sets these):
#   AWF_NUGET_FEEDS               the feeds; empty or unset = nothing to do
#   AWF_NUGET_RESTORE             what to restore; see section 14.2
#   SYSTEM_ACCESSTOKEN            the job token, mapped into this step only
#   AWF_PR_RESTORE_WORK_DIR       where the seed worktree goes, outside the
#                                 checkout: $(Agent.TempDirectory)
#   BUILD_SOURCESDIRECTORY        the PR checkout
#   SYSTEM_PULLREQUEST_TARGETBRANCH, BUILD_REPOSITORY_DEFAULTBRANCH
#   AWF_DEFAULT_BRANCH            the default branch when Azure DevOps does not
#                                 report one (default `main`)
#
# Exit codes: 0 restored, or nothing to restore; 1 refused or the restore
# failed; 2 usage — feeds are set and SYSTEM_ACCESSTOKEN is not mapped.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/agent-boundary.sh
source "$ROOT/scripts/lib/agent-boundary.sh"
# shellcheck source=scripts/lib/private-feed-restore.sh
source "$ROOT/scripts/lib/private-feed-restore.sh"

# The MSBuild and NuGet files whose presence above the work directory would be
# read by the restore. MSBuild walks up from the seed worktree, so on a
# persistent agent an earlier job could plant one of these and have it
# evaluated — which is to say executed — with the token in the environment.
ANCESTOR_IMPORTS=(
  Directory.Build.props Directory.Build.targets Directory.Packages.props
  Directory.Solution.props Directory.Solution.targets
  nuget.config NuGet.Config NuGet.config global.json
)

# The .git/config keys that make a plain git command run something or reach
# somewhere else. `git worktree add` runs with the token in the environment, so
# a checkout carrying one of these is refused rather than used.
TAMPER_KEYS='^(filter\.|include\.|includeif\.|core\.hookspath|core\.fsmonitor|core\.sshcommand|core\.gitproxy|uploadpack\.|credential\.)'

WORK_DIR=''
SOURCES_DIR=''
SEED_SHA=''

refuse() {
  printf 'pr feed restore: %s\n' "$1" >&2
  exit 1
}

# Defence in depth: the template's step condition already skips this step when
# there is no feed, so a consumer without private feeds never gets here.
guard_feeds() {
  feed_restore_enabled && return 0
  printf 'pr feed restore: AWF_NUGET_FEEDS is empty, nothing to restore\n'
  exit 0
}

guard_token() {
  [[ -z "${SYSTEM_ACCESSTOKEN:-}" ]] || return 0
  printf 'pr feed restore: SYSTEM_ACCESSTOKEN is not mapped into this step; see docs/AZDO-PIPELINE-SETUP.md section 9.6\n' >&2
  exit 2
}

# The same cheap checks the implement run makes before it restores. The cache
# check runs in this shell because it sets AWF_NUGET_CACHE.
guard_library_checks() {
  local cause
  if ! cause="$(feed_restore_config_check 2>&1)" ||
     ! cause="$(feed_restore_targets_syntax_check 2>&1)"; then
    refuse "$(printf '%s' "$cause" | head -n1)"
  fi
  feed_cache_path_check 2>/dev/null || refuse "$FEED_CACHE_CAUSE"
}

guard_work_dir() {
  local work="${AWF_PR_RESTORE_WORK_DIR:-}"
  [[ -d "${BUILD_SOURCESDIRECTORY:-}" ]] ||
    refuse "BUILD_SOURCESDIRECTORY is not a directory: '${BUILD_SOURCESDIRECTORY:-}'"
  [[ "$work" == /* ]] ||
    refuse "AWF_PR_RESTORE_WORK_DIR must be an absolute path, not '$work'"
  WORK_DIR="$(realpath -m "$work")"
  SOURCES_DIR="$(realpath -m "$BUILD_SOURCESDIRECTORY")"
  [[ "$WORK_DIR" != "$SOURCES_DIR" && "$WORK_DIR" != "$SOURCES_DIR"/* ]] ||
    refuse "AWF_PR_RESTORE_WORK_DIR $WORK_DIR is inside the checkout $SOURCES_DIR"
}

guard_ancestor_imports() {
  local dir="$WORK_DIR" name
  while :; do
    for name in "${ANCESTOR_IMPORTS[@]}"; do
      [[ ! -e "$dir/$name" ]] ||
        refuse "$dir/$name is above the work directory and would be read by the restore"
    done
    [[ "$dir" != / ]] || return 0
    dir="$(dirname "$dir")"
  done
}

# The checkout's own .git is the one thing here that the PR's own job cannot
# write but an earlier job on a persistent agent can.
guard_checkout_not_tampered() {
  local git_dir="$SOURCES_DIR/.git" key
  [[ -d "$git_dir" ]] || refuse "$SOURCES_DIR holds no .git directory"
  if [[ -f "$git_dir/config" ]]; then
    while read -r key; do
      [[ "${key,,}" =~ $TAMPER_KEYS ]] || continue
      refuse "the checkout's .git/config sets $key"
    done < <(bgit config --file "$git_dir/config" --list --name-only 2>/dev/null || true)
  fi
  [[ ! -s "$git_dir/info/attributes" ]] ||
    refuse "the checkout's .git/info/attributes is not empty"
}

# A PR build checks out refs/pull/<n>/merge, so HEAD has exactly two parents.
# Anything else — a manual queue above all — has no first parent the branch
# policy vouched for, and HEAD~1 would be a guess.
guard_merge_head() {
  local line fields=()
  line="$(bgit rev-list --parents -n1 HEAD 2>/dev/null || true)"
  IFS=' ' read -r -a fields <<<"$line"
  (( ${#fields[@]} - 1 == 2 )) ||
    refuse 'the build is not a PR merge commit; run this only from PR build validation'
}

# The first parent is trustworthy only when the PR targets the default branch:
# a PR retargeted onto an agent-pushed branch would otherwise make agent-written
# code the seed. `refs/heads/` is optional on both sides, because Azure DevOps
# reports the target branch in both forms.
guard_target_is_default() {
  local target="${SYSTEM_PULLREQUEST_TARGETBRANCH:-}"
  local default="${BUILD_REPOSITORY_DEFAULTBRANCH:-refs/heads/${AWF_DEFAULT_BRANCH:-main}}"
  [[ "${target#refs/heads/}" != "${default#refs/heads/}" ]] || return 0
  refuse "the PR targets $target, not the default branch $default"
}

main() {
  guard_feeds
  guard_token
  guard_library_checks
  guard_work_dir
  guard_ancestor_imports
  cd "$SOURCES_DIR"
  guard_checkout_not_tampered
  guard_merge_head
  guard_target_is_default
  SEED_SHA="$(bgit rev-parse HEAD^1)"
  printf 'pr feed restore: seed %s\n' "$SEED_SHA"
}

main "$@"
