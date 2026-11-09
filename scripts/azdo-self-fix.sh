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
# is the only path to the push, and the PAT never enters a URL or .git/config.
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
#   3  the pipeline-file guard refused (any non-zero from it): nothing pushed
#   4  the push failed
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
  SKIP_CLONE=1 SKIP_PUSH=1 WORK_DIR="$PWD" \
    FIX_GIT_NAME=ai-implement FIX_GIT_EMAIL=ai-implement@noreply.invalid \
    GIT_AUTHOR_NAME=ai-implement GIT_AUTHOR_EMAIL=ai-implement@noreply.invalid \
    GIT_COMMITTER_NAME=ai-implement GIT_COMMITTER_EMAIL=ai-implement@noreply.invalid \
    HEAD_REF="$SF_HEAD_REF" REPO="$REPO" ITERATION="$ITERATION" \
    timeout --kill-after=30s "$FIX_TIMEOUT" bash "$SF_SCRIPT_DIR/self-fix-pr.sh" "$@"
}

main() {
  local guard_err paths
  run_fix_without_push "$@" || exit 1

  guard_err="$(mktemp)"
  if ! pipeline_file_guard "$SF_BASE_REF" 2> "$guard_err"; then
    paths="$(sed -e 's/^[[:space:]]*//' -e '/^$/d' "$guard_err" | paste -sd, -)"
    rm -f "$guard_err"
    stop 3 "self-fix stopped: the fix changed pipeline files: $paths"
  fi
  rm -f "$guard_err"

  push_branch "$SF_HEAD_REF" || stop 4 "self-fix stopped: could not push the fix to $SF_HEAD_REF"
}

main "$@"
