#!/usr/bin/env bash
#
# paused-issues.sh — the issues a pipeline pause stopped.
#
# The paused list is the set of OPEN issues carrying $PAUSED_ISSUE_LABEL. It is
# deliberately not text: the alarm issue quotes the agent's error, and a list
# kept in the same body can be rewritten by whoever can influence that error
# (#521). A label is set only by the pipeline's token or by someone with triage
# rights, and adding one is not a read-modify-write, so two pauses in the same
# second cannot drop each other's entry.
#
# Sourced, not executed. GitHub only, like the alarm itself — every caller has
# already returned on any other forge. Requires $REPO. Exposes:
#   PAUSED_ISSUE_LABEL            the label name; with its colour and
#   PAUSED_ISSUE_LABEL_COLOR      description, defined here once —
#   PAUSED_ISSUE_LABEL_DESC       ensure-issue-labels.sh seeds from these
#   paused_issue_mark <issue>     label it. On failure it warns on stderr, names
#                                 the issue in $GITHUB_STEP_SUMMARY (when set)
#                                 and returns 1 — the issue is then on no list,
#                                 so the caller decides where else to name it.
#                                 Callers that cannot add anything use `|| true`.
#   paused_issue_clear <issue>    remove the label. Returns 1 when gh could not
#                                 remove it, silently — the caller decides what
#                                 that means (#536). Removing a label the issue
#                                 does not carry is not a failure.
#   paused_issues_open            JSON array of {number, labels[].name} for the
#                                 open labelled issues; returns 1 when it cannot
#                                 read — an unreadable list is not an empty one
set -euo pipefail
IFS=$'\n\t'

PAUSED_ISSUE_LABEL='ai:paused'
PAUSED_ISSUE_LABEL_COLOR='FBCA04'
PAUSED_ISSUE_LABEL_DESC='Stopped by a pipeline pause — pipeline-resume.sh re-dispatches it'

paused_issue_mark() {
  local issue="${1:?paused_issue_mark requires an issue number}"
  # `gh label create` errors on an existing label — the expected, tolerated
  # path. Created here because ensure-issue-labels.sh runs later in the job.
  gh label create "$PAUSED_ISSUE_LABEL" --repo "$REPO" --color "$PAUSED_ISSUE_LABEL_COLOR" \
    --description "$PAUSED_ISSUE_LABEL_DESC" >/dev/null 2>&1 || true
  gh issue edit "$issue" --repo "$REPO" --add-label "$PAUSED_ISSUE_LABEL" >/dev/null 2>&1 && return 0
  printf 'warning: could not label issue #%s %s — re-dispatch it by hand after the resume\n' \
    "$issue" "$PAUSED_ISSUE_LABEL" >&2
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    # shellcheck disable=SC2016  # markdown code spans, not command substitution
    printf -- '- ⚠️ Issue #%s could not be labelled `%s`: `pipeline-resume.sh` will not find it — re-dispatch it by hand after the resume.\n' \
      "$issue" "$PAUSED_ISSUE_LABEL" >> "$GITHUB_STEP_SUMMARY" || true
  fi
  return 1
}

paused_issue_clear() {
  local issue="${1:?paused_issue_clear requires an issue number}"
  gh issue edit "$issue" --repo "$REPO" --remove-label "$PAUSED_ISSUE_LABEL" >/dev/null 2>&1
}

paused_issues_open() {
  gh issue list --repo "$REPO" --label "$PAUSED_ISSUE_LABEL" --state open \
    --json number,labels --limit 200 2>/dev/null
}
