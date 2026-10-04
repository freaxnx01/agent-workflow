#!/usr/bin/env bash
#
# check-issue-link.sh — Warn when the pipeline's PR will not auto-close its issue.
#
# GitHub forms a PR's closing-issue reference by parsing `Closes #N` from the PR
# description — but it does NOT form one for a PR authored by the `github-actions`
# app. So when the pipeline opens its PR with GITHUB_TOKEN (i.e. PIPELINE_APP_ID is
# unset), the keyword sits inert in the body: merging the PR does not close the
# issue, and /ai-stats reads the issue as never shipped because it keys off that same
# reference.
#
# Both consequences were silent before this check. Observed on
# anim-bossinfo-ch/BI-ArchiveUploader: three pipeline PRs each carried `Closes #N`
# and had zero closing references, and the issues stayed open after their PRs were
# approved and promoted to ready.
#
# This script only reports. It never edits the PR or the issue: there is no API to
# create a closing reference, and closing the issue here would be wrong on the
# human-merge path, where the PR has not been merged yet.
#
# Required environment variables:
#   ISSUE_NUMBER  GitHub issue number
#   PR_NUMBER     The pipeline's pull request number
#   REPO          owner/repo (default: $GITHUB_REPOSITORY)
#   GH_TOKEN      (or ambient gh auth)
#
# Optional environment variables:
#   CLOSING_REFS  Newline- or space-separated issue numbers the PR closes. When
#                 set (even empty), the gh query is skipped — this is how the
#                 tests drive the script without a network call, mirroring
#                 check-human-merge-gate.sh's ISSUE_LABELS override.
#
# Output (stdout one line; GITHUB_OUTPUT key=value when set):
#   linked=true|false
#
# A `false` also emits a ::warning:: naming both consequences and the remedy.
#
# Exit codes:
#   0   check completed (regardless of linked=)
#   2   ISSUE_NUMBER or PR_NUMBER unset
#   3   REPO unset and GITHUB_REPOSITORY unset
set -euo pipefail
IFS=$'\n\t'

if [[ -z "${ISSUE_NUMBER:-}" || -z "${PR_NUMBER:-}" ]]; then
  printf 'error: ISSUE_NUMBER and PR_NUMBER must be set\n' >&2
  exit 2
fi

REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
if [[ -z "$REPO" ]]; then
  printf 'error: REPO or GITHUB_REPOSITORY must be set\n' >&2
  exit 3
fi

if [[ -z "${CLOSING_REFS+x}" ]]; then
  # `|| true`: a transient API failure must not fail the run over a diagnostic.
  # An unreachable API is indistinguishable from "no refs" here, and reporting
  # linked=false in that case is the safe direction — it over-warns rather than
  # letting a genuinely unlinked PR through silently.
  CLOSING_REFS="$(gh api graphql -f query="
    {
      repository(owner: \"${REPO%%/*}\", name: \"${REPO##*/}\") {
        pullRequest(number: $PR_NUMBER) {
          closingIssuesReferences(first: 20) { nodes { number } }
        }
      }
    }" --jq '.data.repository.pullRequest.closingIssuesReferences.nodes[].number' 2>/dev/null || true)"
fi

linked=false
# Split on spaces as well as newlines. The gh query yields newline-separated numbers,
# but a hand-passed or test-passed CLOSING_REFS is naturally space-separated, and this
# script's file-wide `IFS=$'\n\t'` excludes space — so a space-separated list would
# never split and every entry would miss.
saved_ifs="$IFS"
IFS=$' \n\t'
for n in $CLOSING_REFS; do
  if [[ "$n" == "$ISSUE_NUMBER" ]]; then
    linked=true
    break
  fi
done
IFS="$saved_ifs"

if [[ "$linked" != "true" ]]; then
  printf '::warning::PR #%s has no closing-issue reference to #%s. Merging it will NOT close the issue, and /ai-stats will read #%s as never shipped. GitHub does not create the reference for a PR authored by the github-actions app; set PIPELINE_APP_ID/PIPELINE_APP_PRIVATE_KEY so the PR is authored by your App, or close the issue by hand after merging.\n' \
    "$PR_NUMBER" "$ISSUE_NUMBER" "$ISSUE_NUMBER"
fi

printf 'linked=%s\n' "$linked"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'linked=%s\n' "$linked" >> "$GITHUB_OUTPUT"
fi
