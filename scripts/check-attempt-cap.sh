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
#   MAX_NON_STARTS     Non-start reports tolerated before parking. Default 5.
#                      A non-start is a run report stating 0 turns AND $0.00 —
#                      it never reached the agent, so it is not an attempt at
#                      the work (#393). They still need a ceiling: a missing or
#                      invalid credential produces them indefinitely.
#   PARK_LABEL         Label applied when parking. Default "parked".
#   DISPATCH_LABEL     Label removed when parking. Default "ai-implement".
#   ISSUE_COMMENTS_JSON  Seam (tests): JSON array of {body}, skips the API call.
#   DRY_RUN            If "1", decide and report but make no GitHub writes.
#
# Output (stdout + GITHUB_OUTPUT when set):
#   proceed=true|false
#   attempt=<N>            the attempt this run would be (1-based), counting
#                          only runs that actually ran
#   max-attempts=<N>
#   non-starts=<N>         prior reports that never reached the agent
#   max-non-starts=<N>
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
MAX_NON_STARTS="${MAX_NON_STARTS:-5}"
PARK_LABEL="${PARK_LABEL:-parked}"
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

# Split prior run reports by whether the run actually ran. A report stating
# 0 turns AND $0.00 never reached the agent — it executed no step of the plan
# and spent nothing, so it is not evidence about the plan (#393).
#
# Fail closed: `capture` yields no output when the pattern does not match, so a
# report missing either field — or whose format has drifted — falls through to
# the real-attempt count. ai-stats.sh defaults these to 0 because it aggregates;
# doing that here would let a malformed report excuse itself.
count_reports() {
  comments_json | jq --argjson want_nonstart "$1" '
    def nonstart:
      ( [ (.body | capture("Turns:\\*\\* (?<t>[0-9]+)") | .t | tonumber) ] ) as $t
      | ( [ (.body | capture("Cost:\\*\\* \\$(?<c>[0-9.]+)") | .c | tonumber) ] ) as $c
      | ( ($t | length) == 1 and ($c | length) == 1
          and $t[0] == 0 and $c[0] == 0 );
    [ .[]
      | select(.body | startswith("## ai-implement run"))
      | select((nonstart) == ($want_nonstart | . == 1)) ]
    | length' 2>/dev/null || printf 0
}

prior_attempts="$(count_reports 0)"
non_starts="$(count_reports 1)"
attempt=$(( prior_attempts + 1 ))

emit attempt        "$attempt"
emit max-attempts   "$MAX_ATTEMPTS"
emit non-starts     "$non_starts"
emit max-non-starts "$MAX_NON_STARTS"

# Attempts first: an issue that has hit both ceilings is more usefully
# described as failing at the work than as failing to start.
park_reason=''
if (( prior_attempts >= MAX_ATTEMPTS )); then
  park_reason=attempts
elif (( non_starts >= MAX_NON_STARTS )); then
  park_reason=non-starts
fi

if [[ -z "$park_reason" ]]; then
  emit proceed true
  printf 'attempt %d of %d (%d non-start(s) ignored) — proceeding\n' \
    "$attempt" "$MAX_ATTEMPTS" "$non_starts"
  exit 0
fi

# --- park -------------------------------------------------------------------

emit proceed false

if [[ "$park_reason" == attempts ]]; then
  printf 'attempt cap reached (%d prior attempts, max %d) — parking issue #%s\n' \
    "$prior_attempts" "$MAX_ATTEMPTS" "$ISSUE_NUMBER"
else
  printf 'non-start cap reached (%d non-starts, max %d) — parking issue #%s\n' \
    "$non_starts" "$MAX_NON_STARTS" "$ISSUE_NUMBER"
fi

if [[ "$DRY_RUN" == "1" ]]; then
  exit 0
fi

if [[ "$park_reason" == attempts ]]; then
  park_body="$(cat <<PARK
## ai-implement parked

This issue has been dispatched **${prior_attempts} times** without shipping, which is
the configured cap (\`MAX_ATTEMPTS=${MAX_ATTEMPTS}\`). Further redispatches are not
worth the spend — across the fleet, extra attempts do not improve the odds.

Parked for a human. Unpark it once the underlying problem is addressed — usually the
issue needs re-enrichment (a sharper spec or plan) rather than another run.
PARK
)"
else
  park_body="$(cat <<PARK
## ai-implement parked — the run never started

**${non_starts} dispatches** ended with 0 turns and \$0.00, which is the configured
cap (\`MAX_NON_STARTS=${MAX_NON_STARTS}\`). A run that spends nothing never reached the
agent, so this is not a problem with the issue.

**Do not re-enrich.** The plan was never read. Check, in the order these
actually occur:

1. The credential for the selected agent — \`CLAUDE_CODE_OAUTH_TOKEN\`, or
   \`OPENROUTER_API_KEY\` when the run resolves to opencode.
2. An \`agent:\` override on this issue pointing at an agent whose key is absent.
3. The runner toolchain — see \`docs/RUNNER-REQUIREMENTS.md\`.

The run reports above record which agent and model each attempt resolved to.
PARK
)"
fi

# ensure-issue-labels.sh runs later in the job, so the park label may not exist
# yet in a consumer repo. Create it first — --add-label fails on a missing label.
gh label create "$PARK_LABEL" --repo "$REPO" \
  --color BFD4F2 --description 'Parked for a human — agent attempt cap reached' \
  >/dev/null 2>&1 || true

gh issue comment "$ISSUE_NUMBER" --repo "$REPO" --body "$park_body" >/dev/null 2>&1 || true
gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
  --add-label "$PARK_LABEL" --remove-label "$DISPATCH_LABEL" >/dev/null 2>&1 || true

exit 0
