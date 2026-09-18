#!/usr/bin/env bash
#
# claim-issue.sh — take the implement claim on an issue before the agent runs.
#
# `agent-implement.yml`'s `concurrency:` key serialises pipeline against
# pipeline, but it is invisible outside GitHub Actions, so nothing stopped a
# local session and a run from implementing the same issue at once
# (freaxnx01/flowhub#93 — a wasted run and two PRs closing one issue). The
# claim is the part both parties can see: a label plus a comment on the issue
# (ADR-015, #366).
#
#   🔒 Implement claim by run <run-id>
#   <run-url>
#   claimed <ISO-8601 UTC>
#
# Whether a claim is *held* is decided by the referenced run's own state, never
# by elapsed time — see scripts/lib/issue-claim.sh for why unresolvable means
# stale. A label with no parseable claim comment is therefore stale too.
#
# Acquire is check → claim → **re-check**. The re-check is not belt and braces:
# acquire is not atomic, and the whole point of the claim is a second party
# that Actions' `concurrency` cannot see. The run that claimed *first* wins;
# the loser stands down rather than implementing alongside the winner.
#
# Required environment variables:
#   ISSUE_NUMBER  GitHub issue number.
#   REPO          owner/repo (default: $GITHUB_REPOSITORY).
#   RUN_ID        The run taking the claim (GitHub Actions run id).
#   GH_TOKEN      (or ambient gh auth)
#
# Optional environment variables:
#   RUN_URL       Link recorded in the claim. Defaults to the Actions run URL
#                 built from $GITHUB_SERVER_URL, $REPO and $RUN_ID.
#   DRY_RUN       If "1", decide and report but make no GitHub writes.
#   ISSUE_LABELS  Seam (tests): newline-separated labels; if set (even empty),
#                 skips the `gh issue view --json labels` call.
#   ISSUE_COMMENTS          Seam (tests): comment bodies as one blob; if set
#                           (even empty), skips the comments API call.
#   ISSUE_COMMENTS_RECHECK  Seam (tests): the blob the post-claim re-check
#                           reads, so the lost-a-race branch is coverable.
#   RUN_STATE     Seam (tests): see scripts/lib/issue-claim.sh.
#
# Output (stdout + GITHUB_OUTPUT when set):
#   claimed=true|false
#   holder=<run-url>    this run's URL when claimed; the holding run's when not
#
# Exit codes:
#   0  the claim is held by this run (fresh, taken over, or already ours)
#   2  required env missing
#   3  a live claim is held by another run — this run must not implement
set -euo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/issue-claim.sh disable=SC1091  # hook runs without -x; SC1091 is conventionally suppressed
source "$HERE/lib/issue-claim.sh"

require_env() {
  if [[ -z "${!1:-}" ]]; then
    printf 'error: %s must be set\n' "$1" >&2
    exit 2
  fi
}

require_env ISSUE_NUMBER
require_env RUN_ID
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
if [[ -z "$REPO" ]]; then
  printf 'error: REPO or GITHUB_REPOSITORY must be set\n' >&2
  exit 2
fi

RUN_URL="${RUN_URL:-${GITHUB_SERVER_URL:-https://github.com}/$REPO/actions/runs/$RUN_ID}"
DRY_RUN="${DRY_RUN:-0}"

emit() {
  printf '%s=%s\n' "$1" "$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}

summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
  fi
}

read_labels() {
  if [[ -n "${ISSUE_LABELS+x}" ]]; then
    printf '%s' "$ISSUE_LABELS"
    return 0
  fi
  gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json labels --jq '.labels[].name' 2>/dev/null || true
}

read_comments() {
  if [[ -n "${ISSUE_COMMENTS+x}" ]]; then
    printf '%s' "$ISSUE_COMMENTS"
    return 0
  fi
  gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json comments --jq '.comments[].body' 2>/dev/null || true
}

# The re-check must read the issue again — reusing the first read would make
# the whole race check a no-op.
read_comments_again() {
  if [[ -n "${ISSUE_COMMENTS_RECHECK+x}" ]]; then
    printf '%s' "$ISSUE_COMMENTS_RECHECK"
    return 0
  fi
  read_comments
}

has_claim_label() {
  local label
  while IFS= read -r label; do
    if [[ "$label" == "$CLAIM_LABEL" ]]; then
      return 0
    fi
  done <<< "$1"
  return 1
}

# refuse <holding-run-id> <holding-run-url> <reason>
refuse() {
  emit claimed false
  emit holder "$2"
  printf 'refused: issue #%s is claimed by run %s (%s)\n' "$ISSUE_NUMBER" "$1" "$3"
  printf '  %s\n' "$2"
  printf 'Cancelling that run is a deliberate act — it discards whatever it has\n'
  printf 'not yet pushed. If you mean to take the issue over:\n'
  printf '  gh run cancel %s --repo %s\n' "$1" "$REPO"
  summary "### Implement claim held by another run"
  summary ""
  summary "Issue #${ISSUE_NUMBER} is claimed by run [\`${1}\`](${2}), which is still $3."
  summary "This run stopped before the agent started; nothing was implemented."
  summary ""
  summary "To take the issue over, cancel the holding run first: \`gh run cancel ${1} --repo ${REPO}\`"
  exit 3
}

# --- 1) is the issue already claimed? ---------------------------------------

labels="$(read_labels)"
comments="$(read_comments)"
latest="$(parse_latest_claim "$comments")"

held_run_id=''
held_run_url=''
if [[ -n "$latest" ]]; then
  IFS=$'\t' read -r held_run_id held_run_url _ <<< "$latest"
fi

if [[ -n "$held_run_id" && "$held_run_id" == "$RUN_ID" ]]; then
  # Already ours — a re-run of this step must not post a second claim.
  emit claimed true
  emit holder "$RUN_URL"
  printf 'issue #%s is already claimed by this run (%s)\n' "$ISSUE_NUMBER" "$RUN_ID"
  exit 0
fi

if [[ -n "$held_run_id" ]]; then
  state="$(claim_state "$held_run_id")"
  if [[ "$state" == "live" ]]; then
    refuse "$held_run_id" "${held_run_url:-$REPO run $held_run_id}" 'live'
  fi
  printf 'claim by run %s is stale (its run is no longer in progress) — taking over\n' "$held_run_id"
elif has_claim_label "$labels"; then
  # A label with no run reference cannot be judged, so it holds nothing. This
  # is the branch that stops a crashed run blocking the issue indefinitely.
  printf 'the %s label is set but no claim comment names a run — treating as stale\n' "$CLAIM_LABEL"
fi

# --- 2) claim ---------------------------------------------------------------

claimed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
claim_body="$(printf '%s%s\n%s\nclaimed %s\n\nThis run is implementing issue #%s. The claim is released when the run ends;\na claim whose run is no longer in progress is stale and may be taken over.' \
  "$CLAIM_MARKER" "$RUN_ID" "$RUN_URL" "$claimed_at" "$ISSUE_NUMBER")"

if [[ "$DRY_RUN" == "1" ]]; then
  emit claimed true
  emit holder "$RUN_URL"
  printf 'DRY_RUN: would claim issue #%s for run %s\n' "$ISSUE_NUMBER" "$RUN_ID"
  exit 0
fi

# ensure-issue-labels.sh runs later in this job, so on a consumer repo the
# label may not exist yet — and `--add-label` fails outright on a missing
# label, which is the bootstrap deadlock #301 documents. Create it first.
gh label create "$CLAIM_LABEL" --repo "$REPO" \
  --color FBCA04 --description 'An implement run is working this issue — see the claim comment for the run' \
  >/dev/null 2>&1 || true

# Comment first, label second, matching the enrich lock's ordering: a label
# must never exist without a run reference for a reader to judge it by.
if ! gh issue comment "$ISSUE_NUMBER" --repo "$REPO" --body "$claim_body" >/dev/null 2>&1; then
  printf 'warn: could not post the claim comment — continuing unclaimed\n' >&2
fi

label_added=0
if has_claim_label "$labels"; then
  printf 'the %s label was already set\n' "$CLAIM_LABEL"
elif gh issue edit "$ISSUE_NUMBER" --repo "$REPO" --add-label "$CLAIM_LABEL" >/dev/null 2>&1; then
  label_added=1
else
  printf 'warn: could not add the %s label\n' "$CLAIM_LABEL" >&2
fi

# --- 3) re-check: did this run actually win? --------------------------------

lost_run_id=''
lost_run_url=''
while IFS=$'\t' read -r rid rurl _; do
  [[ -n "$rid" ]] || continue
  if [[ "$rid" == "$RUN_ID" ]]; then
    break  # this run's claim is the oldest one still live — it won
  fi
  if [[ "$(claim_state "$rid")" == "live" ]]; then
    lost_run_id="$rid"
    lost_run_url="$rurl"
    break
  fi
done <<< "$(parse_claims "$(read_comments_again)")"

if [[ -n "$lost_run_id" ]]; then
  # Retire this run's claim so the loser's own release step cannot later strip
  # the winner's label.
  standdown_body="$(printf '%s%s\n\nStood down: run %s claimed issue #%s first. This run implemented nothing.' \
    "$CLAIM_RELEASE_MARKER" "$RUN_ID" "$lost_run_id" "$ISSUE_NUMBER")"
  gh issue comment "$ISSUE_NUMBER" --repo "$REPO" --body "$standdown_body" >/dev/null 2>&1 || true
  if (( label_added == 1 )); then
    gh issue edit "$ISSUE_NUMBER" --repo "$REPO" --remove-label "$CLAIM_LABEL" >/dev/null 2>&1 || true
  fi
  refuse "$lost_run_id" "${lost_run_url:-$REPO run $lost_run_id}" 'live, and claimed first'
fi

emit claimed true
emit holder "$RUN_URL"
printf 'claimed issue #%s for run %s\n' "$ISSUE_NUMBER" "$RUN_ID"
