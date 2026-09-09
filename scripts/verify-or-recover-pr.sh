#!/usr/bin/env bash
#
# verify-or-recover-pr.sh — after an implement run, ensure a draft PR exists
# for the issue. If the run looked successful but no PR was opened (e.g. a
# `gh pr create` secondary-rate-limit race, issue #100), recover by opening
# the PR for the agent's pushed branch. Reports whether a PR is now present
# so post-run-report.sh can pick ai:done vs ai:failed accurately.
#
# If the run exited cleanly but never committed, the work is still sitting
# uncommitted in the workspace. That is the largest measured failure mode
# ("run completed but no PR was opened" — 24 of 48 failures across the fleet),
# and bailing there threw the work away. Salvage commits and pushes it to a
# dedicated branch so the run ends in a reviewable draft PR instead. Salvage is
# deliberately scoped to the clean-exit case; a genuine agent error
# (IS_ERROR=true) is still owned by the existing handling.
#
# Required env: ISSUE_NUMBER. Optional: REPO (default $GITHUB_REPOSITORY),
# DEFAULT_BRANCH, IS_ERROR (default false), GH_TOKEN/ambient.
# Seams (tests): PIPELINE_PRS_JSON, BRANCH, BRANCH_REMOTE_EXISTS, BRANCH_AHEAD,
#                WORKTREE_DIRTY, SALVAGE_APPLY.
#
# SALVAGE_APPLY gates the git writes and defaults to ON ONLY inside GitHub
# Actions ($GITHUB_ACTIONS == true). Salvage commits, branches and pushes — on a
# developer machine that is someone's working tree, not a disposable runner
# checkout. Defaulting it on everywhere meant a single unpinned test run
# committed and pushed a real branch out of this repo. Set SALVAGE_APPLY=1
# explicitly to force it elsewhere.
#
# Output: found=<bool> pr-present=<bool> recovered=<bool> salvaged=<bool>
# Exit: 0 success; 2 required env missing.
set -euo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/gh-retry.sh disable=SC1091  # hook runs without -x; SC1091 is conventionally suppressed
source "$HERE/lib/gh-retry.sh"

if [[ -z "${ISSUE_NUMBER:-}" ]]; then
  printf 'error: ISSUE_NUMBER must be set\n' >&2
  exit 2
fi
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
IS_ERROR="${IS_ERROR:-false}"

emit() {
  local salvaged="${4:-false}"
  printf 'found=%s pr-present=%s recovered=%s salvaged=%s\n' "$1" "$2" "$3" "$salvaged"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      printf 'found=%s\n' "$1"
      printf 'pr-present=%s\n' "$2"
      printf 'recovered=%s\n' "$3"
      printf 'salvaged=%s\n' "$salvaged"
    } >> "$GITHUB_OUTPUT"
  fi
}

# Open the draft PR for $1 (head branch) with body $2. Echoes nothing; returns
# the classification via the global PR_CREATE_RESULT: created | exists | failed.
open_draft_pr() {
  local head="$1" body="$2" out ec=0
  set +x
  out="$(GH_TOKEN="${GH_TOKEN:-}" with_backoff \
    gh pr create --repo "$REPO" --draft \
      --base "$default_branch" --head "$head" \
      --title "Implement #${ISSUE_NUMBER}" \
      --body "$body" 2>&1)" || ec=$?
  if [[ "$ec" -eq 0 ]]; then
    PR_CREATE_RESULT=created
  elif printf '%s' "$out" | grep -qi 'already exists'; then
    PR_CREATE_RESULT=exists
  else
    PR_CREATE_RESULT=failed
  fi
}

# 1. Genuine agent failure — existing handling owns it.
if [[ "$IS_ERROR" == "true" ]]; then
  emit false false false
  exit 0
fi

# 2. Does a pipeline PR already exist?
pr_out="$(ISSUE_NUMBER="$ISSUE_NUMBER" REPO="$REPO" \
  PIPELINE_PRS_JSON="${PIPELINE_PRS_JSON:-}" bash "$HERE/find-pipeline-pr.sh" 2>/dev/null || printf 'found=false')"
if [[ "$pr_out" == *"found=true"* ]]; then
  emit true true false
  exit 0
fi

# 3. Recovery eligibility — discover the agent's branch from the live checkout
#    (the workflow leaves HEAD on the branch the agent created and pushed).
branch="${BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || printf '')}"
default_branch="${DEFAULT_BRANCH:-}"

remote_exists() {
  [[ -n "${BRANCH_REMOTE_EXISTS:-}" ]] && { [[ "$BRANCH_REMOTE_EXISTS" == "true" ]]; return; }
  git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1
}
branch_ahead() {
  [[ -n "${BRANCH_AHEAD:-}" ]] && { [[ "$BRANCH_AHEAD" == "true" ]]; return; }
  [[ -n "$default_branch" ]] || return 1
  local n; n="$(git rev-list --count "origin/${default_branch}..${branch}" 2>/dev/null || printf 0)"
  (( n > 0 ))
}

worktree_dirty() {
  [[ -n "${WORKTREE_DIRTY:-}" ]] && { [[ "$WORKTREE_DIRTY" == "true" ]]; return; }
  [[ -n "$(git status --porcelain 2>/dev/null)" ]]
}

# Commit whatever the agent left behind onto a dedicated salvage branch and
# push it. SALVAGE_APPLY=0 skips the writes so Layer-1 tests can drive the
# decision path without a real repo.
salvage_apply_enabled() {
  if [[ -n "${SALVAGE_APPLY:-}" ]]; then
    [[ "$SALVAGE_APPLY" == "1" ]]
    return
  fi
  [[ "${GITHUB_ACTIONS:-}" == "true" ]]
}

salvage_worktree() {
  local head="$1"
  salvage_apply_enabled || {
    printf 'salvage: not applying git writes (set SALVAGE_APPLY=1 to force)\n' >&2
    return 0
  }
  git checkout -b "$head" >/dev/null 2>&1 || git checkout "$head" >/dev/null 2>&1 || return 1
  git add -A || return 1
  git -c user.name="${SALVAGE_AUTHOR_NAME:-github-actions[bot]}" \
      -c user.email="${SALVAGE_AUTHOR_EMAIL:-github-actions[bot]@users.noreply.github.com}" \
      commit -m "chore(salvage): uncommitted work from the run on #${ISSUE_NUMBER}" || return 1
  git push -u origin "$head" || return 1
}

if [[ -z "$branch" || "$branch" == "HEAD" || "$branch" == "$default_branch" ]] \
   || ! remote_exists || ! branch_ahead; then
  # The branch is unusable, but the run may still have left work behind.
  if ! worktree_dirty; then
    emit false false false false
    exit 0
  fi

  salvage_branch="salvage/issue-${ISSUE_NUMBER}"
  if ! salvage_worktree "$salvage_branch"; then
    emit false false false false
    exit 0
  fi

  open_draft_pr "$salvage_branch" \
    "Salvaged by pipeline: the run finished without opening a PR, so its uncommitted work was committed here for review. Closes #${ISSUE_NUMBER}."
  case "$PR_CREATE_RESULT" in
    created) emit false true true true ;;
    exists)  emit false true false false ;;
    *)       emit false false false false ;;
  esac
  exit 0
fi

# 4. Recover — open the draft PR with retry/backoff.
open_draft_pr "$branch" "Recovered by pipeline. Closes #${ISSUE_NUMBER}."
case "$PR_CREATE_RESULT" in
  created) emit false true true ;;
  # PR already existed — the search index lagged; treat as present but not recovered.
  exists)  emit false true false ;;
  *)       emit false false false ;;
esac
exit 0
