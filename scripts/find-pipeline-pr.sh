#!/usr/bin/env bash
#
# find-pipeline-pr.sh — Locate the draft PR the pipeline opened for an
# issue.
#
# The implement job invokes the agent which calls `gh pr create`; the PR
# number isn't returned as a workflow output. This script searches for the
# draft PR that closes the issue and is authored by the pipeline.
#
# Required environment variables:
#   ISSUE_NUMBER  GitHub issue number the run was implementing.
#   REPO          owner/repo (default: $GITHUB_REPOSITORY).
#   GH_TOKEN      (or ambient gh auth).
#
# Optional environment variables:
#   AUTHOR_ALLOWLIST   Newline-separated allowed pr.user.login values.
#                      Default: 'github-actions[bot]'. ADR-002 gate 1 also
#                      enforces this in check-merge-envelope.sh; we apply
#                      it here so that an unrelated higher-numbered draft
#                      PR (e.g. opened by a third party to hijack the
#                      auto-review target) is filtered out before we
#                      ever spend an agent turn on it.
#   PIPELINE_PRS_JSON  Skip the `gh pr list` call and parse this JSON
#                      blob instead. Used by Layer-1 tests.
#
# Output:
#   pr-number  PR number (empty if none found)
#   head-sha   PR head commit SHA (empty if none found)
#   found      true | false
#
# Exit codes:
#   0  success — `found` may be true or false
#   2  required env missing
set -euo pipefail
IFS=$'\n\t'

if [[ -z "${ISSUE_NUMBER:-}" ]]; then
  printf 'error: ISSUE_NUMBER must be set\n' >&2
  exit 2
fi
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
if [[ -z "$REPO" ]]; then
  printf 'error: REPO or GITHUB_REPOSITORY must be set\n' >&2
  exit 2
fi

AUTHOR_ALLOWLIST="${AUTHOR_ALLOWLIST:-github-actions[bot]}"

if [[ -z "${PIPELINE_PRS_JSON:-}" ]]; then
  # `closes #N in:body` is GitHub search syntax. We filter draft + open
  # client-side because the search-API state filter doesn't expose drafts.
  PIPELINE_PRS_JSON="$(gh pr list \
    --repo "$REPO" \
    --state open \
    --search "closes #${ISSUE_NUMBER} in:body" \
    --json number,isDraft,headRefOid,author \
    --limit 10 2>/dev/null || printf '[]')"
fi

# Build a JSON array of allowed authors to pass into jq.
ALLOWED_JSON="$(printf '%s\n' "$AUTHOR_ALLOWLIST" \
  | awk 'NF > 0' \
  | jq -R . | jq -sc .)"

# Pick the highest-numbered draft PR that closes the issue AND whose
# author is in the allowlist. Highest-numbered acts as a most-recent
# tiebreaker if a previous failed run left a stale draft. The author
# filter blocks a third-party-opened higher-numbered draft from
# hijacking the auto-review target.
pr_number="$(printf '%s' "$PIPELINE_PRS_JSON" \
  | jq -r --argjson allow "$ALLOWED_JSON" '
    [.[] | select(.isDraft == true and (.author.login | IN($allow[])))]
    | sort_by(-.number) | .[0].number // ""')"
head_sha="$(printf '%s' "$PIPELINE_PRS_JSON" \
  | jq -r --argjson allow "$ALLOWED_JSON" '
    [.[] | select(.isDraft == true and (.author.login | IN($allow[])))]
    | sort_by(-.number) | .[0].headRefOid // ""')"

if [[ -n "$pr_number" ]]; then
  found=true
else
  found=false
fi

printf 'found=%s pr-number=%s head-sha=%s\n' "$found" "$pr_number" "$head_sha"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    printf 'found=%s\n'     "$found"
    printf 'pr-number=%s\n' "$pr_number"
    printf 'head-sha=%s\n'  "$head_sha"
  } >> "$GITHUB_OUTPUT"
fi
