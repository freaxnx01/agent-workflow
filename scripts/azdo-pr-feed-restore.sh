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
#   SYSTEM_PULLREQUEST_TARGETBRANCH
#   BUILD_REPOSITORY_DEFAULTBRANCH  read first when set, but not a predefined
#                                 Azure Pipelines variable, so usually empty
#   AWF_DEFAULT_BRANCH            the default branch's short name (default
#                                 `main`); set it on the validation pipeline
#                                 when the default branch is not `main`
#
# Exit codes: 0 restored, or nothing to restore; 1 refused or the restore
# failed; 2 usage — feeds are set and SYSTEM_ACCESSTOKEN is not mapped.
set -euo pipefail
IFS=$'\n\t'

# The PATH of the hermetic re-exec. AWF_TEST_HERMETIC_PATH replaces it in the
# tests, which have no SDK and must reach their mocks.
HERMETIC_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# The hermetic re-exec, before anything else is sourced or read. The validation
# pipeline has no user boundary: the PR's own build step runs as the same user
# as this step, so within one job the order protects the token, but across jobs
# on a persistent agent it does not. Everything an earlier job could have left
# for this one to pick up — a user HOME, a global or system git config, a NuGet
# credential plugin, an MSBuild user-location import — is dropped here, and
# only the variables this script needs survive. Section 9.6 still asks for an
# agent that is fresh per job; this reduces the damage, it does not remove the
# precondition.
#
# Until the re-exec, the PATH is the inherited one, whose first entry the job
# user can write; every tool this phase runs is therefore named by absolute
# path. On Debian 13 /bin is a symlink to /usr/bin, so /usr/bin/ always holds
# them.
if [[ "${AWF_PR_RESTORE_HERMETIC:-}" != 1 ]]; then
  hermetic_home="$(/usr/bin/mktemp -d)"
  /usr/bin/chmod 0700 "$hermetic_home"
  : > "$hermetic_home/no-plugins"
  passthrough=(
    "SYSTEM_ACCESSTOKEN=${SYSTEM_ACCESSTOKEN:-}"
    "AWF_NUGET_FEEDS=${AWF_NUGET_FEEDS:-}"
    "AWF_NUGET_RESTORE=${AWF_NUGET_RESTORE:-}"
    "AWF_PR_RESTORE_WORK_DIR=${AWF_PR_RESTORE_WORK_DIR:-}"
    "BUILD_SOURCESDIRECTORY=${BUILD_SOURCESDIRECTORY:-}"
    "SYSTEM_PULLREQUEST_TARGETBRANCH=${SYSTEM_PULLREQUEST_TARGETBRANCH:-}"
    "BUILD_REPOSITORY_DEFAULTBRANCH=${BUILD_REPOSITORY_DEFAULTBRANCH:-}"
    "AWF_DEFAULT_BRANCH=${AWF_DEFAULT_BRANCH:-}"
    "AWF_TEST_CACHE_ROOT=${AWF_TEST_CACHE_ROOT:-}"
    "AWF_TEST_HERMETIC_PATH=${AWF_TEST_HERMETIC_PATH:-}"
  )
  # The mock's own channels, test-only: without a test PATH there is no mock to
  # talk to, so they cannot reach a real `dotnet` run.
  if [[ -n "${AWF_TEST_HERMETIC_PATH:-}" ]]; then
    for mock_var in DOTNET_LOG DOTNET_ENV_LOG DOTNET_CONFIG_COPY \
      DOTNET_MODE_LOG DOTNET_MOCK_FAIL; do
      passthrough+=("$mock_var=${!mock_var:-}")
    done
  fi
  exec /usr/bin/env -i \
    "PATH=${AWF_TEST_HERMETIC_PATH:-$HERMETIC_PATH}" \
    "HOME=$hermetic_home" \
    "DOTNET_CLI_HOME=$hermetic_home" \
    "NUGET_PLUGIN_PATHS=$hermetic_home/no-plugins" \
    "AWF_PR_RESTORE_HOME=$hermetic_home" \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_NO_REPLACE_OBJECTS=1 \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 \
    ImportUserLocationsByWildcardBeforeMicrosoftCommonProps=false \
    ImportUserLocationsByWildcardAfterMicrosoftCommonProps=false \
    ImportUserLocationsByWildcardBeforeMicrosoftCommonTargets=false \
    ImportUserLocationsByWildcardAfterMicrosoftCommonTargets=false \
    AWF_PR_RESTORE_HERMETIC=1 \
    "${passthrough[@]}" \
    bash "$0"
fi

# The re-executed process owns the temp HOME it was handed.
[[ -z "${AWF_PR_RESTORE_HOME:-}" ]] || trap 'rm -rf "$AWF_PR_RESTORE_HOME"' EXIT

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
  Directory.Build.props Directory.Build.targets Directory.Build.rsp
  Directory.Packages.props
  Directory.Solution.props Directory.Solution.targets
  nuget.config NuGet.Config NuGet.config global.json
)

# The .git/config keys that make a plain git command run something or reach
# somewhere else. `git worktree add` runs with the token in the environment, so
# a checkout carrying one of these is refused rather than used.
TAMPER_KEYS='^(filter\.|include\.|includeif\.|core\.hookspath|core\.fsmonitor|core\.sshcommand|core\.gitproxy|core\.attributesfile|extensions\.worktreeconfig|uploadpack\.|credential\.)'

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
  guard_object_redirects "$git_dir"
}

# What would make git read objects or config from somewhere the PR's job did
# not put there: replace refs (loose or packed; GIT_NO_REPLACE_OBJECTS already
# ignores them, this refuses them as evidence of tampering), grafts, alternates
# and a per-worktree config, which .git/config's keys do not cover.
guard_object_redirects() {
  local git_dir="$1" path
  [[ -z "$(bgit for-each-ref --count=1 refs/replace/ 2>/dev/null || true)" ]] ||
    refuse "the checkout holds refs under refs/replace/"
  for path in info/grafts objects/info/alternates; do
    [[ ! -e "$git_dir/$path" ]] || refuse "the checkout has .git/$path"
  done
  path="$(find "$git_dir" -maxdepth 3 -name config.worktree -print -quit 2>/dev/null || true)"
  [[ -z "$path" ]] || refuse "the checkout has $path (config.worktree)"
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
  refuse "the PR targets $target, not the default branch $default; if the default branch is not main, set AWF_DEFAULT_BRANCH on this pipeline (section 9.6)"
}

# The image's PATH holds a directory the job user can write (`~/.local/bin`), so
# the `dotnet` that gets the token must be one an earlier job could not have
# replaced: neither the resolved binary nor its directory may be writable here.
guard_dotnet_trusted() {
  local dotnet_path
  dotnet_path="$(command -v dotnet 2>/dev/null || true)"
  [[ -n "$dotnet_path" ]] ||
    refuse 'dotnet is not on PATH; rebuild the agent image with --target dotnet'
  dotnet_path="$(realpath "$dotnet_path")"
  [[ ! -w "$dotnet_path" && ! -w "$(dirname "$dotnet_path")" ]] ||
    refuse "dotnet at $dotnet_path is writable by $(id -un)"
}

# The credentialed restore, on a detached worktree of the seed commit. The
# cause goes to a file rather than into a command substitution: the job log
# must keep `dotnet restore`'s own error, which section 9.6 sends the operator
# to read. Only the first line becomes the message.
restore_seed() {
  local cause_file rc=0
  export AZURE_DEVOPS_EXT_PAT="$SYSTEM_ACCESSTOKEN"
  mkdir -p "$WORK_DIR" || refuse "could not create the work directory $WORK_DIR"
  cause_file="$WORK_DIR/pr-feed-restore.err"
  : > "$cause_file"
  feed_pre_restore "$SEED_SHA" "$WORK_DIR" 2>"$cause_file" || rc=$?
  [[ ! -s "$cause_file" ]] || cat "$cause_file" >&2
  [[ "$rc" -ne 0 ]] || return 0
  if [[ "$rc" -eq 2 ]]; then
    # Nothing to restore (#682): the restore never ran, so the Feed Reader role
    # is not the cause and naming it would send the operator the wrong way.
    printf 'private feed restore: %s\n' "$(head -n1 "$cause_file")" >&2
  else
    printf 'private feed restore failed (%s): check that the build service has the Feed Reader role on the feed\n' \
      "${FEED_URLS[0]}" >&2
  fi
  exit 1
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
  guard_dotnet_trusted
  SEED_SHA="$(bgit rev-parse HEAD^1)"
  restore_seed
  # Only now, and only for this job: the build step reads private packages from
  # the folder this job filled, never from one an earlier job left behind.
  printf '##vso[task.setvariable variable=NUGET_FALLBACK_PACKAGES]%s\n' "$AWF_NUGET_CACHE"
}

main "$@"
