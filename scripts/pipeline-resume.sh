#!/usr/bin/env bash
#
# pipeline-resume.sh — Clear the pause and put the queued issues back in flight.
#
# Run by an operator once the cause is fixed (credits topped up, key limit
# raised). It closes every open alarm issue and re-dispatches the issues the
# alarm listed — each as a FRESH attempt 1 on the default agent: a paused run
# did no work, so nothing was learned that justifies escalating the next one.
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
#                      or handled by hand in the meantime — left alone.
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

REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
[[ -n "$REPO" ]] || { printf 'error: REPO or GITHUB_REPOSITORY must be set\n' >&2; exit 2; }

CONSUMER_WORKFLOW="${CONSUMER_WORKFLOW:-agent.yml}"
ALARM_LABEL="${ALARM_LABEL:-pipeline-paused}"
DISPATCH_LABEL="${DISPATCH_LABEL:-ai-implement}"
DRY_RUN="${DRY_RUN:-0}"
MARKER_OPEN='<!-- paused-issues -->'
MARKER_CLOSE='<!-- /paused-issues -->'

if [[ "$(detect_forge | awk '{print $1}')" != "github" ]]; then
  printf 'pipeline-resume: no alarm adapter for this forge — nothing to resume\n'
  exit 0
fi

alarms="$(gh issue list --repo "$REPO" --label "$ALARM_LABEL" --state open \
  --json number,body --limit 20 2>/dev/null || printf '[]')"

if [[ "$(jq -r 'length' <<<"$alarms")" == "0" ]]; then
  printf 'pipeline-resume: no open %s alarm in %s — nothing to resume\n' "$ALARM_LABEL" "$REPO"
  exit 0
fi

mapfile -t alarm_numbers < <(jq -r 'sort_by(.number) | .[].number' <<<"$alarms")

# Every alarm's marker block, deduped: several alarms can list the same issue
# when one key serves several repos and the operator merged them by hand.
mapfile -t paused_issues < <(
  jq -r '.[].body // ""' <<<"$alarms" \
    | sed -n "s|.*${MARKER_OPEN}\(.*\)${MARKER_CLOSE}.*|\1|p" \
    | tr ' ' '\n' | sed -n 's/^#\([0-9][0-9]*\)$/\1/p' | sort -un
)

printf 'pipeline-resume: alarm(s) %s list issue(s) %s\n' \
  "${alarm_numbers[*]}" "${paused_issues[*]:-none}"

if [[ -n "${AGENT_PAUSED_VAR:-}" ]]; then
  printf 'warning: the AGENT_PAUSED repo variable is still set to %q — the gate\n' "$AGENT_PAUSED_VAR" >&2
  printf '         keeps pausing every dispatch until it is cleared by hand:\n' >&2
  printf '         gh variable delete AGENT_PAUSED --repo %s\n' "$REPO" >&2
fi

if [[ "$DRY_RUN" == "1" ]]; then
  printf 'DRY_RUN: would close alarm(s) %s and re-dispatch' "${alarm_numbers[*]}"
  for issue in ${paused_issues[@]+"${paused_issues[@]}"}; do printf ' #%s' "$issue"; done
  printf ' as attempt 1\n'
  exit 0
fi

# --- clear the pause --------------------------------------------------------

for alarm in "${alarm_numbers[@]}"; do
  gh issue close "$alarm" --repo "$REPO" \
    --comment "Resumed by \`pipeline-resume.sh\`: the pause is cleared and the listed issues are re-dispatched as attempt 1." \
    >/dev/null 2>&1 || printf 'warning: could not close alarm #%s\n' "$alarm" >&2
done

# --- re-dispatch ------------------------------------------------------------

resumed=0
for issue in ${paused_issues[@]+"${paused_issues[@]}"}; do
  state_json="$(gh issue view "$issue" --repo "$REPO" --json state,labels 2>/dev/null || printf '{}')"
  state="$(jq -r '.state // ""' <<<"$state_json")"
  has_label="$(jq -r --arg l "$DISPATCH_LABEL" \
    '[(.labels // [])[].name] | index($l) != null' <<<"$state_json")"
  if [[ "$state" != "OPEN" ]]; then
    printf 'skipping #%s: no longer open (%s)\n' "$issue" "${state:-unknown}"
    continue
  fi
  if [[ "$has_label" != "true" ]]; then
    printf 'skipping #%s: no %s label — parked or handled by hand\n' "$issue" "$DISPATCH_LABEL"
    continue
  fi
  # No `-f attempt=` on purpose: the paused run never reached the agent, so the
  # re-run is attempt 1 and classify-agent.sh's escalation does not fire.
  if gh workflow run "$CONSUMER_WORKFLOW" --repo "$REPO" -f issue-number="$issue" >/dev/null 2>&1; then
    printf 're-dispatched #%s as attempt 1\n' "$issue"
    resumed=$((resumed + 1))
  else
    printf 'warning: could not re-dispatch #%s — dispatch it by hand\n' "$issue" >&2
  fi
done

printf 'pipeline-resume: resumed %d issue(s) in %s\n' "$resumed" "$REPO"
