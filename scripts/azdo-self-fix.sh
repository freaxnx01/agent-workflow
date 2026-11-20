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
# In a PIPELINE run the fix agent also runs as a different Linux user,
# `awf-agent`, in a workspace of its own seeded from the PR branch (#591,
# ADR-024). It commits inside that boundary and the commit returns as a verified
# bundle that this checkout fast-forwards to. A missing boundary, a surviving
# agent process or a commit that does not fast-forward all stop the fix before
# the push. A local run is unchanged.
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
SF_AGENT_WS=''   # the fix agent's own workspace in pipeline mode; empty locally
SF_TMP=''        # handoff dir for the bundles that cross the boundary
SF_REAP_PENDING=0  # 1 from the fix agent's start until a reap succeeded

# Fixed 20-minute ceiling for one fix run; see the setup guide's §11 budget.
FIX_TIMEOUT=20m

# shellcheck source=implement-azdo.sh
source "$SF_SCRIPT_DIR/implement-azdo.sh"

# stop <code> <line> — reaps first when a fix agent may still be running: the
# caller posts the review report with the token right after this exits.
stop() {
  local code="$1" line="$2"
  if [[ "$SF_REAP_PENDING" == 1 ]]; then
    SF_REAP_PENDING=0
    boundary_reap >/dev/null 2>&1 || line="$line; an agent process survived the reap"
  fi
  [[ -z "$SF_STOP_FILE" ]] || printf '%s\n' "$line" > "$SF_STOP_FILE"
  printf '%s\n' "$line" >&2
  exit "$code"
}

run_fix_without_push() {
  # With a workspace (pipeline mode) the agent runs as awf-agent in there and
  # commits through the boundary afterwards, so this call owns neither the
  # commit nor the "made no change" verdict.
  local boundary=()
  [[ -z "$SF_AGENT_WS" ]] || boundary=(SKIP_COMMIT=1 "AGENT_WORKSPACE=$SF_AGENT_WS")
  # The fix never pushes (push_branch runs afterwards, in this process), so the
  # agent gets neither credential.
  env -u AZURE_DEVOPS_EXT_PAT -u SYSTEM_ACCESSTOKEN \
    SKIP_CLONE=1 SKIP_PUSH=1 WORK_DIR="$PWD" \
    FIX_GIT_NAME=ai-implement FIX_GIT_EMAIL=ai-implement@noreply.invalid \
    GIT_AUTHOR_NAME=ai-implement GIT_AUTHOR_EMAIL=ai-implement@noreply.invalid \
    GIT_COMMITTER_NAME=ai-implement GIT_COMMITTER_EMAIL=ai-implement@noreply.invalid \
    HEAD_REF="$SF_HEAD_REF" REPO="$REPO" ITERATION="$ITERATION" \
    "${boundary[@]}" \
    timeout --kill-after=30s "$FIX_TIMEOUT" bash "$SF_SCRIPT_DIR/self-fix-pr.sh" "$@"
}

# In a pipeline run the fix agent runs as awf-agent, in a workspace seeded from
# the PR branch (#591): it never touches this checkout, and its commit comes
# back the same way the implement agent's does — as a verified bundle.
run_fix_in_boundary() {
  boundary_check >/dev/null 2>&1 ||
    stop 1 "self-fix stopped: the agent user boundary is not available"
  SF_TMP="$(mktemp -d)"
  trap '[[ -z "$SF_TMP" ]] || rm -rf "$SF_TMP"' EXIT
  # 0711: the agent user reaches the seed bundle inside and nothing else.
  chmod 0711 "$SF_TMP"
  SF_AGENT_WS="$(boundary_new_workspace "sf$ITERATION")"
  boundary_seed "$SF_AGENT_WS" "$SF_TMP/handoff" "$SF_HEAD_REF" ||
    stop 1 "self-fix stopped: the agent workspace could not be prepared"
  SF_REAP_PENDING=1
  run_fix_without_push "$@" ||
    stop 1 "self-fix stopped: the fix failed, timed out or made no change"
  commit_in_boundary
  collect_fix
}

# The commit is the agent's, made inside the boundary, so the bundle carries it.
# Nothing to commit is the same verdict a local run reports, with its wording.
commit_in_boundary() {
  local rc=0
  boundary_commit "$SF_AGENT_WS" "address self-review (iteration $ITERATION)" || rc=$?
  [[ "$rc" -ne 3 ]] ||
    stop 1 "self-fix stopped: the fix failed, timed out or made no change"
  [[ "$rc" -eq 0 ]] || stop 1 "self-fix stopped: the fix could not be committed"
  SF_REAP_PENDING=0
  boundary_reap || stop 1 "self-fix stopped: an agent process survived the fix"
}

# Brings the fix onto the PR branch in this checkout. require_pr_branch runs
# first: the fast-forward moves whatever branch HEAD is on.
collect_fix() {
  require_pr_branch
  boundary_collect "$SF_AGENT_WS" "$(git rev-parse "$SF_HEAD_REF")" "$SF_TMP/handoff" >/dev/null ||
    stop 4 "self-fix stopped: the fix did not come back as a verifiable commit"
  bgit merge --ff-only refs/awf/collected >/dev/null 2>&1 ||
    stop 4 "self-fix stopped: the fix does not fast-forward $SF_HEAD_REF"
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
  if pipeline_mode; then
    run_fix_in_boundary "$@"
  else
    run_fix_without_push "$@" ||
      stop 1 "self-fix stopped: the fix failed, timed out or made no change"
  fi
  require_pr_branch
  run_pipeline_file_guard

  push_branch "$SF_HEAD_REF" || stop 4 "self-fix stopped: could not push the fix to $SF_HEAD_REF"
}

main "$@"
