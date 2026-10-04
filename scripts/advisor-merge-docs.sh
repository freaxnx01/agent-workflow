#!/usr/bin/env bash
#
# advisor-merge-docs.sh — the one merge the factory advisor may arm.
#
# The advisor's deny-list (setup/advisor-settings.json) blocks `gh pr merge`.
# This script is the single, deliberate carve-out: it arms auto-merge for a
# PR only when that PR is documentation the advisor itself produced — a spec
# or plan under docs/superpowers/ — and leaves the merge to the repo's own
# gates (required checks, branch protection) via `--auto`.
#
# It refuses unless ALL hold:
#   - the PR is OPEN and not from a fork (isCrossRepository == false);
#   - it targets the repo's default branch;
#   - it changes at least one file, and EVERY changed file is under
#     docs/superpowers/ (a prefix match on the directory, so
#     docs/superpowers-evil/ does not pass).
#
# The merge is pinned with --match-head-commit to the head this script
# checked, so a commit pushed after arming cannot ride the auto-merge in.
#
# Usage: advisor-merge-docs.sh <pr-number>
# Env:   REPO  owner/name (default: the current repo, via `gh repo view`)
#
# Exit codes:
#   0  auto-merge armed
#   1  refused — the PR is not a docs-only PR the advisor may merge
#   2  usage error
#   3  a gh read failed; nothing was merged
set -euo pipefail
IFS=$'\n\t'

readonly DOCS_PREFIX='docs/superpowers/'

refuse()    { printf 'refused: %s\n' "$1" >&2; exit 1; }
gh_failed() { printf 'error: %s\n' "$1" >&2; exit 3; }

pr="${1:-}"
[[ "$pr" =~ ^[0-9]+$ ]] || { printf 'usage: %s <pr-number>\n' "$(basename "$0")" >&2; exit 2; }

repo="${REPO:-}"
if [[ -z "$repo" ]]; then
  repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" \
    || gh_failed "could not resolve the repo; set REPO"
fi

pr_json="$(gh pr view "$pr" --repo "$repo" --json state,baseRefName,headRefOid,isCrossRepository 2>/dev/null)" \
  || gh_failed "could not read PR #$pr"
default_branch="$(gh api "repos/$repo" 2>/dev/null | jq -r '.default_branch')" \
  || gh_failed "could not read $repo's default branch"
files="$(gh api --paginate "repos/$repo/pulls/$pr/files" 2>/dev/null | jq -rs 'add | .[].filename')" \
  || gh_failed "could not read PR #$pr's changed files"

state="$(jq -r '.state' <<< "$pr_json")"
base="$(jq -r '.baseRefName' <<< "$pr_json")"
head="$(jq -r '.headRefOid' <<< "$pr_json")"
fork="$(jq -r '.isCrossRepository' <<< "$pr_json")"

[[ "$state" == "OPEN" ]]           || refuse "PR #$pr is $state, not OPEN"
[[ "$fork" == "false" ]]           || refuse "PR #$pr comes from a fork"
[[ "$base" == "$default_branch" ]] || refuse "PR #$pr targets $base, not $default_branch"
[[ -n "$files" ]]                  || refuse "PR #$pr changes no files"

outside="$(grep -v "^${DOCS_PREFIX}" <<< "$files" || true)"
[[ -z "$outside" ]] || refuse "PR #$pr changes files outside ${DOCS_PREFIX}: $(tr '\n' ' ' <<< "$outside")"

gh pr merge "$pr" --repo "$repo" --squash --auto --match-head-commit "$head"
printf 'armed: PR #%s auto-merges at %s once its checks pass\n' "$pr" "${head:0:7}"
