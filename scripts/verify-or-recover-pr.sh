#!/usr/bin/env bash
#
# verify-or-recover-pr.sh — after an implement run, ensure a draft PR exists
# for the issue. If the run looked successful but no PR was opened (e.g. a
# `gh pr create` secondary-rate-limit race, issue #100), recover by opening
# the PR for the agent's pushed branch. Reports whether a PR is now present
# so post-run-report.sh can pick ai:done vs ai:failed accurately.
#
# Required env: ISSUE_NUMBER. Optional: REPO (default $GITHUB_REPOSITORY),
# DEFAULT_BRANCH, IS_ERROR (default false), GH_TOKEN/ambient.
# Seams (tests): PIPELINE_PRS_JSON, BRANCH, BRANCH_REMOTE_EXISTS, BRANCH_AHEAD.
#
# Output: found=<bool> pr-present=<bool> recovered=<bool>
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
  printf 'found=%s pr-present=%s recovered=%s\n' "$1" "$2" "$3"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      printf 'found=%s\n' "$1"
      printf 'pr-present=%s\n' "$2"
      printf 'recovered=%s\n' "$3"
    } >> "$GITHUB_OUTPUT"
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

if [[ -z "$branch" || "$branch" == "HEAD" || "$branch" == "$default_branch" ]] \
   || ! remote_exists || ! branch_ahead; then
  emit false false false
  exit 0
fi

# 4. Recover — open the draft PR with retry/backoff.
set +x
recover_ec=0
recover_out="$(GH_TOKEN="${GH_TOKEN:-}" with_backoff \
  gh pr create --repo "$REPO" --draft \
    --base "$default_branch" --head "$branch" \
    --title "Implement #${ISSUE_NUMBER}" \
    --body "Recovered by pipeline. Closes #${ISSUE_NUMBER}." \
  2>&1)" || recover_ec=$?

if [[ "$recover_ec" -eq 0 ]]; then
  emit false true true
elif printf '%s' "$recover_out" | grep -qi 'already exists'; then
  # PR already existed — the search index lagged; treat as present but not recovered.
  emit false true false
else
  emit false false false
fi
exit 0
