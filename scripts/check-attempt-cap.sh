#!/usr/bin/env bash
#
# check-attempt-cap.sh — Stop an issue being redispatched forever.
#
# Measured across the fleet, redispatching does not pay: issues that took more
# than one dispatch ship at roughly the same rate as those that shipped on the
# first, while the dispatches spent on issues that never shipped were pure loss.
# So after MAX_ATTEMPTS the issue is parked for a human instead of being handed
# back to the agent.
#
# The attempt count is read from the `## ai-implement run` comments that
# post-run-report.sh leaves on the issue — the same record /ai-stats reads, so
# the cap counts exactly what the statistics count.
#
# Required environment variables:
#   ISSUE_NUMBER  GitHub issue number.
#   REPO          owner/repo (default: $GITHUB_REPOSITORY).
#   GH_TOKEN      (or ambient gh auth)
#
# Optional environment variables:
#   MAX_ATTEMPTS       Attempts allowed before parking. Default 2.
#   PARK_LABEL         Label applied when parking. Default "🧊 parked".
#   DISPATCH_LABEL     Label removed when parking. Default "ai-implement".
#   ISSUE_COMMENTS_JSON  Seam (tests): JSON array of {body}, skips the API call.
#   DRY_RUN            If "1", decide and report but make no GitHub writes.
#
# Output (stdout + GITHUB_OUTPUT when set):
#   proceed=true|false
#   attempt=<N>        the attempt this run would be (1-based)
#   max-attempts=<N>
#
# Exit codes:
#   0  decision produced (proceed or parked)
#   2  required env missing
set -euo pipefail
IFS=$'\n\t'

require_env() {
  if [[ -z "${!1:-}" ]]; then
    printf 'error: %s must be set\n' "$1" >&2
    exit 2
  fi
}

require_env ISSUE_NUMBER
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
if [[ -z "$REPO" ]]; then
  printf 'error: REPO or GITHUB_REPOSITORY must be set\n' >&2
  exit 2
fi

MAX_ATTEMPTS="${MAX_ATTEMPTS:-2}"
PARK_LABEL="${PARK_LABEL:-🧊 parked}"
DISPATCH_LABEL="${DISPATCH_LABEL:-ai-implement}"
DRY_RUN="${DRY_RUN:-0}"

emit() {
  printf '%s=%s\n' "$1" "$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}

# --- count prior attempts ---------------------------------------------------

comments_json() {
  if [[ -n "${ISSUE_COMMENTS_JSON:-}" ]]; then
    printf '%s' "$ISSUE_COMMENTS_JSON"
    return
  fi
  gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json comments \
    --jq '.comments' 2>/dev/null || printf '[]'
}

prior_attempts="$(comments_json \
  | jq '[.[] | select(.body | startswith("## ai-implement run"))] | length' 2>/dev/null || printf 0)"
attempt=$(( prior_attempts + 1 ))

emit attempt      "$attempt"
emit max-attempts "$MAX_ATTEMPTS"

if (( prior_attempts < MAX_ATTEMPTS )); then
  emit proceed true
  printf 'attempt %d of %d — proceeding\n' "$attempt" "$MAX_ATTEMPTS"
  exit 0
fi

# --- park -------------------------------------------------------------------

emit proceed false
printf 'attempt cap reached (%d prior attempts, max %d) — parking issue #%s\n' \
  "$prior_attempts" "$MAX_ATTEMPTS" "$ISSUE_NUMBER"

if [[ "$DRY_RUN" == "1" ]]; then
  exit 0
fi

park_body="$(cat <<PARK
## ai-implement parked

This issue has been dispatched **${prior_attempts} times** without shipping, which is
the configured cap (\`MAX_ATTEMPTS=${MAX_ATTEMPTS}\`). Further redispatches are not
worth the spend — across the fleet, extra attempts do not improve the odds.

Parked for a human. Unpark it once the underlying problem is addressed — usually the
issue needs re-enrichment (a sharper spec or plan) rather than another run.
PARK
)"

# ensure-issue-labels.sh runs later in the job, so the park label may not exist
# yet in a consumer repo. Create it first — --add-label fails on a missing label.
gh label create "$PARK_LABEL" --repo "$REPO" \
  --color BFD4F2 --description 'Parked for a human — agent attempt cap reached' \
  >/dev/null 2>&1 || true

gh issue comment "$ISSUE_NUMBER" --repo "$REPO" --body "$park_body" >/dev/null 2>&1 || true
gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
  --add-label "$PARK_LABEL" --remove-label "$DISPATCH_LABEL" >/dev/null 2>&1 || true

exit 0
