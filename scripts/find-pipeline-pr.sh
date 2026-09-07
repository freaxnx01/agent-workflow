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
#                      review target) is filtered out before we
#                      ever spend an agent turn on it.
#   PIPELINE_PRS_JSON  Skip the `gh pr list` call and parse this JSON
#                      blob instead. Used by Layer-1 tests.
#   PIPELINE_PRS_JSON_SEQUENCE_CMD  Path to an executable that replaces
#                      the `gh pr list` call when set. Each retry re-invokes it.
#   FIND_PR_RETRY_MAX  Max total attempts (including the first). Default: 3.
#   FIND_PR_RETRY_BASE_SLEEP  Base sleep duration in seconds. Default: 2.
#   FIND_PR_RETRY_SLEEP_CMD  Command to sleep; default: sleep.
#
# Output:
#   pr-number  PR number (empty if none found)
#   head-sha   PR head commit SHA (empty if none found)
#   head-ref   PR head branch name (empty if none found)
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

FIND_PR_RETRY_MAX="${FIND_PR_RETRY_MAX:-3}"
[[ "$FIND_PR_RETRY_MAX" =~ ^[0-9]+$ ]] || FIND_PR_RETRY_MAX=3
FIND_PR_RETRY_BASE_SLEEP="${FIND_PR_RETRY_BASE_SLEEP:-2}"
[[ "$FIND_PR_RETRY_BASE_SLEEP" =~ ^[0-9]+$ ]] || FIND_PR_RETRY_BASE_SLEEP=2
FIND_PR_RETRY_SLEEP_CMD="${FIND_PR_RETRY_SLEEP_CMD:-sleep}"

fetch_prs() {
  if [[ -n "${PIPELINE_PRS_JSON_SEQUENCE_CMD:-}" ]]; then
    local output
    output="$("$PIPELINE_PRS_JSON_SEQUENCE_CMD")" || output='[]'
    printf '%s' "$output"
    return
  fi
  gh pr list \
    --repo "$REPO" \
    --state open \
    --search "closes #${ISSUE_NUMBER} in:body" \
    --json number,isDraft,headRefOid,headRefName,author \
    --limit 10 2>/dev/null || printf '[]'
}

# Pick the highest-numbered draft PR that closes the issue AND whose
# author is in the allowlist. Highest-numbered acts as a most-recent
# tiebreaker if a previous failed run left a stale draft. The author
# filter blocks a third-party-opened higher-numbered draft from
# hijacking the review target.
#
# Author logins are normalized before the allowlist check: `gh pr list --json
# author` reports the GitHub-Actions bot as `app/github-actions`, while the REST
# `user.login` (and the configured allowlist) use `github-actions[bot]`. Without
# normalizing, gate 1 never matches a GITHUB_TOKEN-authored PR (#54). The same
# maps any App, e.g. `app/my-app` ⇄ `my-app[bot]`.
#
# select_from_json <json> <allowed_json> → prints the selected PR object (or {}).
select_from_json() {
  printf '%s' "$1" \
    | jq -c --argjson allow "$2" '
      def norm: (. // "") | sub("^app/"; "") | sub("\\[bot\\]$"; "");
      ($allow | map(norm)) as $a
      | [ .[]
          | select(.isDraft == true
                   and ((.author.login | norm) as $au | ($a | index($au)) != null)) ]
      | sort_by(-.number) | .[0] // {}'
}

# Build a JSON array of allowed authors to pass into jq.
ALLOWED_JSON="$(printf '%s\n' "$AUTHOR_ALLOWLIST" \
  | awk 'NF > 0' \
  | jq -R . | jq -sc .)"

if [[ -n "${PIPELINE_PRS_JSON:-}" ]]; then
  # Explicit static seam — used by every non-retry test. No retry: a caller
  # that already knows the exact JSON to return doesn't want the loop.
  SELECTED="$(select_from_json "$PIPELINE_PRS_JSON" "$ALLOWED_JSON")"
else
  attempt=1
  SELECTED='{}'
  while :; do
    PRS_JSON="$(fetch_prs)"
    SELECTED="$(select_from_json "$PRS_JSON" "$ALLOWED_JSON")"
    [[ "$(printf '%s' "$SELECTED" | jq -r '.number // ""')" ]] && break
    (( attempt >= FIND_PR_RETRY_MAX )) && break
    "$FIND_PR_RETRY_SLEEP_CMD" "$(( FIND_PR_RETRY_BASE_SLEEP * attempt ))"
    attempt=$(( attempt + 1 ))
  done
fi
pr_number="$(printf '%s' "$SELECTED" | jq -r '.number // ""')"
head_sha="$(printf '%s' "$SELECTED" | jq -r '.headRefOid // ""')"
head_ref="$(printf '%s' "$SELECTED" | jq -r '.headRefName // ""')"

if [[ -n "$pr_number" ]]; then
  found=true
else
  found=false
fi

printf 'found=%s pr-number=%s head-sha=%s head-ref=%s\n' "$found" "$pr_number" "$head_sha" "$head_ref"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    printf 'found=%s\n'     "$found"
    printf 'pr-number=%s\n' "$pr_number"
    printf 'head-sha=%s\n'  "$head_sha"
    printf 'head-ref=%s\n'  "$head_ref"
  } >> "$GITHUB_OUTPUT"
fi
