#!/usr/bin/env bash
#
# backlog-milestone.sh — the standing `backlog` milestone, looked up and
# assigned in one place (#646, freaxnx01/ai-instructions#61).
#
# Sourced by assign-backlog-milestone.sh (per issue, from a workflow),
# backfill-backlog-milestone.sh (one-off, by an operator) and
# migrate-consumers.sh --add-milestone-guard (the #653 rollout), so none of
# them can disagree about which milestone counts or how it is written.
#
# Sourced, not executed. Exposes:
#   BACKLOG_MILESTONE          the milestone title
#   backlog_milestone_number   query — prints the number, or nothing
#   backlog_milestone_state    query — prints `open <n>`, `closed <n>`, `missing`
#   create_backlog_milestone   command — creates it, prints the new number
#   list_unmilestoned_issues   query — open issues with no milestone
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

# backlog_milestone_state <repo> — `open <number>`, `closed <number>` or
# `missing`. The rollout (#653) needs the three apart: it may create a missing
# one, but a CLOSED `backlog` is a repo it refuses to touch — reopening someone
# else's closed milestone is the operator's decision, not a tool's. Both states
# are read in one pass (`state=all`); an open one wins over a closed namesake.
# Returns 1 when the list cannot be read. Query.
backlog_milestone_state() {
  local repo="$1" pages
  pages="$(gh api "repos/$repo/milestones?state=all&per_page=100" --paginate)" || return 1
  printf '%s\n' "$pages" | jq -rs --arg t "$BACKLOG_MILESTONE" '
    [.[][] | select(.title == $t)] as $found
    | ($found | map(select(.state == "open")) | first) as $open
    | if   $open        then "open \($open.number)"
      elif $found != [] then "closed \($found[0].number)"
      else "missing" end'
}

# create_backlog_milestone <repo> — creates the standing milestone and prints
# its number. Only the #653 rollout's --apply calls this: the guard and the
# commands never create it, so a repo cannot acquire one as a side effect of an
# issue being filed. Returns 1 when the creation failed. Command.
create_backlog_milestone() {
  local repo="$1" created
  created="$(gh api -X POST "repos/$repo/milestones" \
               -f "title=$BACKLOG_MILESTONE" \
               -f 'description=Default milestone for open issues that are not scheduled yet. Every open issue carries a milestone (freaxnx01/ai-instructions#61).')" \
    || return 1
  # The number is parsed here, not with `gh --jq`: the caller needs the whole
  # response to have arrived successfully before it writes anything.
  printf '%s\n' "$created" | jq -er '.number'
}

# list_unmilestoned_issues <repo> — open issue numbers with no milestone, every
# page, pull requests dropped. One number per line. Returns 1 when the list
# cannot be read. Query.
list_unmilestoned_issues() {
  local repo="$1" pages
  pages="$(gh api "repos/$repo/issues?state=open&milestone=none&per_page=100" --paginate)" || return 1
  printf '%s\n' "$pages" | jq -rs '.[][] | select(.pull_request == null) | .number'
}

# assign_milestone <repo> <issue> <milestone-number> — sets the milestone and
# nothing else. A PATCH carrying only `milestone` cannot clobber a label that
# issue-intake writes on the same `opened` event. Command.
assign_milestone() {
  local repo="$1" issue="$2" number="$3"
  gh api -X PATCH "repos/$repo/issues/$issue" -F "milestone=$number" >/dev/null
}
