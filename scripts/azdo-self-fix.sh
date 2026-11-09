#!/usr/bin/env bash
#
# azdo-self-fix.sh — the FIX_CMD of self-fix-loop.sh on Azure DevOps.
#
# Contract: azdo-self-fix.sh <pr-number> <concerns-json-file>
#
# Runs self-fix-pr.sh in the job's checkout WITHOUT pushing, runs the
# pipeline-file guard on what it committed, and only then pushes with the
# extraheader Basic auth of implement-azdo.sh's push_branch. The push is not
# done inside self-fix-pr.sh because that script pushes with the remote URL's
# credentials (GitHub token) and cannot sit behind the guard; here the guard
# is the driver's only path to the push (the agent itself has Bash, so it is
# also run without the PAT), and the PAT never enters a URL or .git/config.
#
# Required environment variables:
#   HEAD_REF               PR head branch — pushed to
#   ITERATION              integer, used in the commit message
#   REPO                   project/repo
#   DEFAULT_BRANCH         the guard diffs origin/<DEFAULT_BRANCH>...HEAD
#   AZURE_DEVOPS_EXT_PAT   PAT used by push_branch
#
# Optional environment variables:
#   AGENT, MODEL           forwarded to self-fix-pr.sh
#   SELF_FIX_STOP_FILE     file that receives one line explaining exit 3 or 4
#
# Exit codes:
#   0  fixed and pushed
#   1  the fix failed, timed out, or made no change
#   3  the pipeline-file guard refused, or could not check: nothing pushed
#   4  the fix left the checkout off HEAD_REF, or the push failed
set -euo pipefail
IFS=$'\n\t'

# Read every input before sourcing: implement-azdo.sh initialises its own
# globals (MODEL, DEFAULT_BRANCH, ...) at top level.
: "${HEAD_REF:?HEAD_REF must be set}"
: "${ITERATION:?ITERATION must be set}"
: "${REPO:?REPO must be set}"
: "${DEFAULT_BRANCH:?DEFAULT_BRANCH must be set}"
: "${AZURE_DEVOPS_EXT_PAT:?AZURE_DEVOPS_EXT_PAT must be set}"
SF_HEAD_REF="$HEAD_REF"
SF_BASE_REF="origin/$DEFAULT_BRANCH"
SF_STOP_FILE="${SELF_FIX_STOP_FILE:-}"
SF_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Fixed 20-minute ceiling for one fix run; see the setup guide's §11 budget.
FIX_TIMEOUT=20m

# shellcheck source=implement-azdo.sh
source "$SF_SCRIPT_DIR/implement-azdo.sh"

stop() {
  local code="$1" line="$2"
  [[ -z "$SF_STOP_FILE" ]] || printf '%s\n' "$line" > "$SF_STOP_FILE"
  printf '%s\n' "$line" >&2
  exit "$code"
}

run_fix_without_push() {
  # The fix never pushes (push_branch runs afterwards, in this process), so the
  # agent gets neither credential.
  env -u AZURE_DEVOPS_EXT_PAT -u SYSTEM_ACCESSTOKEN \
    SKIP_CLONE=1 SKIP_PUSH=1 WORK_DIR="$PWD" \
    FIX_GIT_NAME=ai-implement FIX_GIT_EMAIL=ai-implement@noreply.invalid \
    GIT_AUTHOR_NAME=ai-implement GIT_AUTHOR_EMAIL=ai-implement@noreply.invalid \
    GIT_COMMITTER_NAME=ai-implement GIT_COMMITTER_EMAIL=ai-implement@noreply.invalid \
    HEAD_REF="$SF_HEAD_REF" REPO="$REPO" ITERATION="$ITERATION" \
    timeout --kill-after=30s "$FIX_TIMEOUT" bash "$SF_SCRIPT_DIR/self-fix-pr.sh" "$@"
}

# Refuses (no push) unless the fix commit sits on the PR branch.
require_pr_branch() {
  [[ "$(git symbolic-ref --quiet --short HEAD || true)" == "$SF_HEAD_REF" ]] ||
    stop 4 "self-fix stopped: the fix left the checkout off $SF_HEAD_REF"
}

# Exit 3 with a line that tells a refusal (rc 1) from a failed check (rc 2).
run_pipeline_file_guard() {
  local guard_err guard_rc=0 paths
  guard_err="$(mktemp)"
  pipeline_file_guard "$SF_BASE_REF" 2> "$guard_err" || guard_rc=$?
  paths="$(sed -e 's/^[[:space:]]*//' -e '/^$/d' "$guard_err" | paste -sd, -)"
  rm -f "$guard_err"
  [[ "$guard_rc" -ne 0 ]] || return 0
  [[ "$guard_rc" -eq 1 ]] || stop 3 "self-fix stopped: could not check the fix for pipeline files"
  stop 3 "self-fix stopped: the fix changed pipeline files: $paths"
}

main() {
  run_fix_without_push "$@" ||
    stop 1 "self-fix stopped: the fix failed, timed out or made no change"
  require_pr_branch
  run_pipeline_file_guard

  push_branch "$SF_HEAD_REF" || stop 4 "self-fix stopped: could not push the fix to $SF_HEAD_REF"
}

main "$@"
