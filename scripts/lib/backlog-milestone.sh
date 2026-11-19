#!/usr/bin/env bash
#
# backlog-milestone.sh — the standing `backlog` milestone, looked up and
# assigned in one place (#646, freaxnx01/ai-instructions#61).
#
# Sourced by assign-backlog-milestone.sh (per issue, from a workflow) and
# backfill-backlog-milestone.sh (one-off, by an operator), so the two cannot
# disagree about which milestone counts or how it is written.
#
# Sourced, not executed. Exposes:
#   BACKLOG_MILESTONE          the milestone title
#   backlog_milestone_number   query — prints the number, or nothing
#   assign_milestone           command — writes the milestone field only
set -euo pipefail
IFS=$'\n\t'

BACKLOG_MILESTONE='backlog'

# backlog_milestone_number <repo> — the number of the OPEN milestone titled
# exactly $BACKLOG_MILESTONE, or nothing when there is none. A closed one does
# not count: the convention says it is never closed, so one that is should
# surface as "missing" rather than collect issues out of sight. Every page is
# slurped (`jq -s`); `gh --jq` would run once per page. Returns 1 when the list
# cannot be read. Query.
backlog_milestone_number() {
  local repo="$1" pages
  pages="$(gh api "repos/$repo/milestones?state=open&per_page=100" --paginate)" || return 1
  printf '%s\n' "$pages" | jq -rs --arg t "$BACKLOG_MILESTONE" \
    '[.[][] | select(.title == $t) | .number] | first // empty'
}

# assign_milestone <repo> <issue> <milestone-number> — sets the milestone and
# nothing else. A PATCH carrying only `milestone` cannot clobber a label that
# issue-intake writes on the same `opened` event. Command.
assign_milestone() {
  local repo="$1" issue="$2" number="$3"
  gh api -X PATCH "repos/$repo/issues/$issue" -F "milestone=$number" >/dev/null
}
