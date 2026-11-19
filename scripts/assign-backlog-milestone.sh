#!/usr/bin/env bash
#
# assign-backlog-milestone.sh — give an issue opened (or reopened) without a
# milestone the standing `backlog` milestone (#646).
#
# Every open issue carries a milestone (freaxnx01/ai-instructions#61). Several
# paths file issues without one — agent-filed follow-ups, scripts — so one
# event-driven guard catches them instead of patching each creator. Issues
# created with a workflow's GITHUB_TOKEN start no workflow and are never seen
# here; the backfill script catches those.
#
# Skipped: a closed issue, a pull request, an issue that already has any
# milestone. A repo with no open `backlog` milestone gets a ::warning:: and
# exit 0 — this script never creates the milestone.
#
# Required env: REPO (owner/name), ISSUE_NUMBER, GH_TOKEN (or ambient gh auth).
# Optional: DRY_RUN=1 decides and prints, writes nothing.
#
# Output: `milestone: #<n> assigned backlog` or `milestone: #<n> skipped
# (<reason>)`; `decision=` and `reason=` appended to $GITHUB_OUTPUT when set.
#
# Exit codes:
#   0  assigned, or skipped by rule (a missing backlog milestone is a skip)
#   1  the issue or the milestone list could not be read, or the write failed
#   2  REPO or ISSUE_NUMBER missing or invalid
set -euo pipefail
IFS=$'\n\t'

_ABM_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/backlog-milestone.sh
source "$_ABM_HERE/lib/backlog-milestone.sh"

# milestone_decision — a REST issue object on stdin. Prints `assign` or
# `skip <reason>`. Query.
milestone_decision() {
  jq -r '
    if (.state // "") != "open" then "skip issue is closed"
    elif .pull_request != null then "skip is a pull request"
    elif .milestone != null then "skip has milestone " + (.milestone.title // "?")
    else "assign" end'
}

usage_error() { printf 'error: %s\n' "$1" >&2; exit 2; }
fatal() { printf 'error: %s\n' "$1" >&2; exit 1; }

# report <decision> <reason> — the stdout line plus $GITHUB_OUTPUT. Command.
report() {
  local decision="$1" reason="$2"
  if [[ "$decision" == assigned ]]; then
    printf 'milestone: #%s assigned %s\n' "$ISSUE_NUMBER" "$BACKLOG_MILESTONE"
  else
    printf 'milestone: #%s skipped (%s)\n' "$ISSUE_NUMBER" "$reason"
  fi
  [[ -n "${GITHUB_OUTPUT:-}" ]] || return 0
  # The reason can carry a milestone title, which is free text: flatten line
  # breaks so it cannot add lines (a forged decision=) to $GITHUB_OUTPUT.
  printf 'decision=%s\nreason=%s\n' "$decision" "${reason//[$'\r\n']/ }" >> "$GITHUB_OUTPUT"
}

validate_env() {
  [[ "${REPO:-}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
    || usage_error "REPO must be owner/name (got: ${REPO:-})"
  [[ "${ISSUE_NUMBER:-}" =~ ^[1-9][0-9]*$ ]] \
    || usage_error "ISSUE_NUMBER must be a positive integer (got: ${ISSUE_NUMBER:-})"
}

main() {
  validate_env
  local json decision number
  # Re-read, not the event payload: a milestone set between the event and this
  # run must win.
  json="$(gh api "repos/$REPO/issues/$ISSUE_NUMBER")" \
    || fatal "could not read issue #$ISSUE_NUMBER in $REPO — no milestone assigned"
  decision="$(printf '%s' "$json" | milestone_decision)" \
    || fatal "could not decide on issue #$ISSUE_NUMBER in $REPO"
  if [[ "$decision" != assign ]]; then
    report skipped "${decision#skip }"
    return 0
  fi

  number="$(backlog_milestone_number "$REPO")" \
    || fatal "could not read the milestones of $REPO — no milestone assigned"
  if [[ -z "$number" ]]; then
    printf '::warning::%s has no open "%s" milestone; #%s stays without one. Create it with /milestone new %s.\n' \
      "$REPO" "$BACKLOG_MILESTONE" "$ISSUE_NUMBER" "$BACKLOG_MILESTONE"
    report skipped "no $BACKLOG_MILESTONE milestone"
    return 0
  fi
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf 'DRY_RUN: would assign #%s to %s (#%s)\n' "$ISSUE_NUMBER" "$BACKLOG_MILESTONE" "$number"
    return 0
  fi
  assign_milestone "$REPO" "$ISSUE_NUMBER" "$number" \
    || fatal "could not assign $BACKLOG_MILESTONE to #$ISSUE_NUMBER in $REPO"
  report assigned ''
}

# Sourced by tests/run-backlog-milestone-guard-tests.sh to call milestone_decision.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
