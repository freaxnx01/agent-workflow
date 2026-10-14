#!/usr/bin/env bash
#
# paused-issues.sh — Label-based paused issue tracking for the pipeline alarm.
#
# The paused list (which issues the resume script re-dispatches) is stored via
# a per-issue label, not in the alarm body. This prevents untrusted error text
# from altering the list (#521).
#
# Requires: REPO environment variable (owner/name format).
# Exports: PAUSED_ISSUE_LABEL, paused_issue_mark(), paused_issue_clear(),
#          paused_issues_open().
#
set -euo pipefail
IFS=$'\n\t'

PAUSED_ISSUE_LABEL='ai:paused'
PAUSED_ISSUE_LABEL_COLOR='FBCA04'
PAUSED_ISSUE_LABEL_DESC='Stopped by a pipeline pause — pipeline-resume.sh re-dispatches it'

# paused_issue_mark <issue> — adds the paused label to the issue. Creates the
# label if it doesn't exist (fails safe: warns and returns 0 if the label
# creation or add fails, so the alarm can still raise). Idempotent: no error if
# the label is already there.
paused_issue_mark() {
  local issue="$1"
  [[ -n "$issue" ]] || return 0

  gh label create "$PAUSED_ISSUE_LABEL" \
    --color "$PAUSED_ISSUE_LABEL_COLOR" \
    --description "$PAUSED_ISSUE_LABEL_DESC" \
    --repo "$REPO" 2>/dev/null || true

  gh issue edit "$issue" --repo "$REPO" \
    --add-label "$PAUSED_ISSUE_LABEL" 2>/dev/null || {
    printf 'warning: could not label issue #%s with %s\n' "$issue" "$PAUSED_ISSUE_LABEL" >&2
    return 0
  }
}

# paused_issue_clear <issue> — removes the paused label. Silent, always succeeds.
paused_issue_clear() {
  local issue="$1"
  [[ -n "$issue" ]] || return 0
  gh issue edit "$issue" --repo "$REPO" \
    --remove-label "$PAUSED_ISSUE_LABEL" 2>/dev/null || true
}

# paused_issues_open — prints a JSON array of open issues with the paused label
# (format: [{"number":N,"labels":[{"name":"…"}]}]), or [] on failure.
paused_issues_open() {
  gh issue list --repo "$REPO" --label "$PAUSED_ISSUE_LABEL" \
    --json number,labels 2>/dev/null || printf '[]'
}
