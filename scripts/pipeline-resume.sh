#!/usr/bin/env bash
#
# pipeline-resume.sh — Clear the pause and put the queued issues back in flight.
#
# Run by an operator once the cause is fixed (credits topped up, key limit
# raised). It closes every open alarm issue and re-dispatches the issues the
# pause stopped — each as a FRESH attempt 1 on the default agent: a paused run
# did no work, so nothing was learned that justifies escalating the next one.
#
# The paused issues are the OPEN issues carrying the `ai:paused` label
# (scripts/lib/paused-issues.sh). Nothing is read out of an alarm's body: it
# quotes the agent's error text, and text is not state (#521, ADR-019).
#
# Order matters. The alarm is closed FIRST: check-pipeline-pause.sh reads the
# open alarm as the pause state, so a dispatch sent while it is still open is
# stopped by the gate and the resume would achieve nothing.
#
# Required environment variables:
#   REPO      owner/repo.
#   GH_TOKEN  (or ambient gh auth) with `issues: write` and `actions: write`.
#
# Optional environment variables:
#   CONSUMER_WORKFLOW  Workflow to dispatch. Default agent.yml.
#   ALARM_LABEL        Default "pipeline-paused".
#   DISPATCH_LABEL     Default "ai-implement". An issue that lost it was parked
#                      or handled by hand in the meantime — not dispatched.
#   AGENT_PAUSED_VAR   Value of the repo variable AGENT_PAUSED; warned about
#                      when set, because this script cannot clear it.
#   DRY_RUN            If "1", report what would happen and write nothing.
#
# Exit codes:
#   0  resumed, or nothing to resume
#   2  required env missing
set -euo pipefail
IFS=$'\n\t'

_PR_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/detect-forge.sh
source "$_PR_HERE/lib/detect-forge.sh"
# shellcheck source=scripts/lib/paused-issues.sh
source "$_PR_HERE/lib/paused-issues.sh"

REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
[[ -n "$REPO" ]] || { printf 'error: REPO or GITHUB_REPOSITORY must be set\n' >&2; exit 2; }

CONSUMER_WORKFLOW="${CONSUMER_WORKFLOW:-agent.yml}"
ALARM_LABEL="${ALARM_LABEL:-pipeline-paused}"
DISPATCH_LABEL="${DISPATCH_LABEL:-ai-implement}"
DRY_RUN="${DRY_RUN:-0}"

if [[ "$(detect_forge | awk '{print $1}')" != "github" ]]; then
  printf 'pipeline-resume: no alarm adapter for this forge — nothing to resume\n'
  exit 0
fi

alarms="$(gh issue list --repo "$REPO" --label "$ALARM_LABEL" --state open \
  --json number --limit 20 2>/dev/null || printf '[]')"
mapfile -t alarm_numbers < <(jq -r 'sort_by(.number) | .[].number' <<<"$alarms")

paused="$(paused_issues_open)"
mapfile -t paused_issues < <(jq -r 'sort_by(.number) | .[].number' <<<"$paused")

# An operator may have closed the alarm by hand already — the alarm's own
# steps say to — so labelled issues without an open alarm are still resumed.
if (( ${#alarm_numbers[@]} == 0 && ${#paused_issues[@]} == 0 )); then
  printf 'pipeline-resume: no open %s alarm and no %s issue in %s — nothing to resume\n' \
    "$ALARM_LABEL" "$PAUSED_ISSUE_LABEL" "$REPO"
  exit 0
fi

listed=''
for issue in ${paused_issues[@]+"${paused_issues[@]}"}; do listed+=" #${issue}"; done
closing=''
for alarm in ${alarm_numbers[@]+"${alarm_numbers[@]}"}; do closing+=" #${alarm}"; done
printf 'pipeline-resume: open alarm(s):%s; %s issue(s):%s\n' \
  "${closing:- none}" "$PAUSED_ISSUE_LABEL" "${listed:- none}"

if [[ -n "${AGENT_PAUSED_VAR:-}" ]]; then
  printf 'warning: the AGENT_PAUSED repo variable is still set to %q — the gate\n' "$AGENT_PAUSED_VAR" >&2
  printf '         keeps pausing every dispatch until it is cleared by hand:\n' >&2
  printf '         gh variable delete AGENT_PAUSED --repo %s\n' "$REPO" >&2
fi

if [[ "$DRY_RUN" == "1" ]]; then
  printf 'DRY_RUN: would close alarm(s)%s and re-dispatch%s as attempt 1\n' \
    "${closing:- none}" "${listed:- none}"
  exit 0
fi

# --- clear the pause --------------------------------------------------------

for alarm in ${alarm_numbers[@]+"${alarm_numbers[@]}"}; do
  gh issue close "$alarm" --repo "$REPO" \
    --comment "Resumed by \`pipeline-resume.sh\`: the pause is cleared and the \`${PAUSED_ISSUE_LABEL}\` issues are re-dispatched as attempt 1." \
    >/dev/null 2>&1 || printf 'warning: could not close alarm #%s\n' "$alarm" >&2
done

# --- re-dispatch ------------------------------------------------------------

resumed=0
for issue in ${paused_issues[@]+"${paused_issues[@]}"}; do
  has_label="$(jq -r --argjson n "$issue" --arg l "$DISPATCH_LABEL" \
    '(map(select(.number == $n)) | .[0].labels // []) | map(.name) | index($l) != null' <<<"$paused")"
  if [[ "$has_label" != "true" ]]; then
    printf 'skipping #%s: no %s label — parked or handled by hand\n' "$issue" "$DISPATCH_LABEL"
    paused_issue_clear "$issue"
    continue
  fi
  # No `-f attempt=` on purpose: the paused run never reached the agent, so the
  # re-run is attempt 1 and classify-agent.sh's escalation does not fire.
  if gh workflow run "$CONSUMER_WORKFLOW" --repo "$REPO" -f issue-number="$issue" >/dev/null 2>&1; then
    paused_issue_clear "$issue"
    printf 're-dispatched #%s as attempt 1\n' "$issue"
    resumed=$((resumed + 1))
  else
    # The label stays: running this script again retries exactly these.
    printf 'warning: could not re-dispatch #%s — it keeps %s; run this again or dispatch it by hand\n' \
      "$issue" "$PAUSED_ISSUE_LABEL" >&2
  fi
done

printf 'pipeline-resume: resumed %d issue(s) in %s\n' "$resumed" "$REPO"
