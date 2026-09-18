#!/usr/bin/env bash
#
# release-issue-claim.sh — give back the implement claim when the run ends.
#
# Runs from an `always()` step, so it releases on success, failure and
# cancellation (ADR-015, #366). With `cancel-in-progress: true` the common path
# here is a *cancellation*, not a clean exit — GitHub runs `always()` steps
# during the grace period, but a hard timeout can still kill the job first.
#
# So this script is an optimisation, not the correctness mechanism: a claim
# whose run is no longer in progress is stale and takeable by anyone with no
# waiting (see scripts/lib/issue-claim.sh). What this buys is a tidy issue —
# the label comes off as soon as the run is done.
#
# **It must never fail the job.** Every `gh` failure is reported and swallowed,
# and missing configuration is a warning rather than an error: a release that
# breaks a cancelled run's report is worse than a claim left to go stale.
#
# The claim is only released when this run is the one holding it. A cancelled
# run's release can land *after* its replacement has claimed, and releasing the
# successor's claim would hand the issue to a third party mid-implementation.
#
# Required environment variables:
#   ISSUE_NUMBER  GitHub issue number.
#   REPO          owner/repo (default: $GITHUB_REPOSITORY).
#   RUN_ID        The run releasing its claim.
#   GH_TOKEN      (or ambient gh auth)
#
# Optional environment variables:
#   ISSUE_COMMENTS  Seam (tests): comment bodies as one blob; if set (even
#                   empty), skips the comments API call.
#
# Exit codes:
#   0  always
set -euo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/issue-claim.sh disable=SC1091  # hook runs without -x; SC1091 is conventionally suppressed
source "$HERE/lib/issue-claim.sh"

REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
if [[ -z "${ISSUE_NUMBER:-}" || -z "${RUN_ID:-}" || -z "$REPO" ]]; then
  printf 'warn: ISSUE_NUMBER, RUN_ID and REPO are all required to release a claim — skipping\n' >&2
  exit 0
fi

read_comments() {
  if [[ -n "${ISSUE_COMMENTS+x}" ]]; then
    printf '%s' "$ISSUE_COMMENTS"
    return 0
  fi
  gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json comments --jq '.comments[].body' 2>/dev/null || true
}

latest="$(parse_latest_claim "$(read_comments)" || true)"

held_run_id=''
if [[ -n "$latest" ]]; then
  IFS=$'\t' read -r held_run_id _ _ <<< "$latest"
fi

if [[ -z "$held_run_id" ]]; then
  printf 'no claim stands on issue #%s — nothing to release\n' "$ISSUE_NUMBER"
  exit 0
fi

if [[ "$held_run_id" != "$RUN_ID" ]]; then
  printf 'issue #%s is claimed by run %s, not by this run (%s) — leaving it alone\n' \
    "$ISSUE_NUMBER" "$held_run_id" "$RUN_ID"
  exit 0
fi

release_body="$(printf '%s%s\n\nThis run has ended; issue #%s is free for the next run or session.' \
  "$CLAIM_RELEASE_MARKER" "$RUN_ID" "$ISSUE_NUMBER")"

if ! gh issue comment "$ISSUE_NUMBER" --repo "$REPO" --body "$release_body" >/dev/null 2>&1; then
  printf 'warn: could not post the release note — the claim will go stale on its own\n' >&2
fi

if ! gh issue edit "$ISSUE_NUMBER" --repo "$REPO" --remove-label "$CLAIM_LABEL" >/dev/null 2>&1; then
  printf 'warn: could not remove the %s label — the claim will go stale on its own\n' "$CLAIM_LABEL" >&2
fi

printf 'released the claim on issue #%s held by run %s\n' "$ISSUE_NUMBER" "$RUN_ID"
exit 0
