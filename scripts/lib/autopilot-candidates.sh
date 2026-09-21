#!/usr/bin/env bash
#
# autopilot-candidates.sh — sourced, not executed.
#   autopilot_candidates <owner/repo> <limit>
#
# Writes the issue numbers the unattended lane may enrich, one per line, oldest
# first, at most <limit> of them. Query-only: reads GitHub and writes nothing.
#
# An issue is a candidate iff all of:
#   - open, and carries needs-enrichment              (both filtered server-side)
#   - carries none of: 🧊 parked, enrichment-ongoing, needs-human, ai-implement
#   - has a non-whitespace body
#
# enrichment-ongoing is an *exclusion only*. /enrich owns that lock and acquires
# it itself; a caller that pre-applied it would make every enrich session think
# it had lost a race. needs-human is what stops the lane re-enriching an issue a
# human has already been asked to decide on.
#
# Returns non-zero if the gh query fails. Requires: gh (authenticated), jq.
set -euo pipefail
IFS=$'\n\t'

autopilot_candidates() {
  local repo="$1" limit="$2" json

  json="$(gh issue list --repo "$repo" --state open --label needs-enrichment \
            --limit 100 --json number,body,createdAt,labels)" || return 1

  printf '%s' "$json" | jq -r --argjson limit "$limit" '
    [ .[]
      | select(((.body // "") | gsub("\\s"; "") | length) > 0)
      | select(
          [.labels[].name]
          | any(. == "🧊 parked"
                or . == "enrichment-ongoing"
                or . == "needs-human"
                or . == "ai-implement")
          | not
        )
    ]
    | sort_by(.createdAt)
    | .[:$limit]
    | .[].number
  '
}
