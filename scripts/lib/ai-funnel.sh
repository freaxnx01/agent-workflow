#!/usr/bin/env bash
#
# ai-funnel.sh — backlog readiness for the ai-implement pipeline, one repo.
#
# ai-stats.sh answers "how did the dispatches go?". This answers the question
# that comes before it: "how many issues could be dispatched at all?" On
# anim-bossinfo-ch/BI-ArchiveUploader on 2026-09-09, only 5 of 30 open
# milestone issues were dispatchable — every other one was waiting on
# enrichment. No dispatch-outcome report can see that, because an issue that
# was never dispatched leaves no dispatch record.
#
# The funnel, in order:
#
#   total → open → parked → blocked on enrichment → planned → dispatchable
#         → dispatched → re-dispatched → shipped
#
# Every stage is derived from labels, the issue body and the timeline. Nothing
# extra is tracked, and nothing here writes.
#
# Usage:
#   ai-funnel.sh                        # current repo, every issue
#   ai-funnel.sh --milestone "general september 2026"
#   ai-funnel.sh --repo owner/name --state open
#   ai-funnel.sh --json                 # raw per-issue records
#   ai-funnel.sh --from records.json    # render a previously collected dump
#
# Options:
#   --repo <owner/name>  Repo to scan. Default: the current clone.
#   --milestone <title>  Only issues in this milestone. Case-insensitive; a
#                        substring match, so "september" finds
#                        "general-september-2026".
#   --state <s>          open | closed | all. Default: all.
#   --limit <n>          Rows in the blocked/ready tables. Default 20.
#                        `all` for every row.
#   --json               Emit the collected records as JSON and exit.
#   --from <file>        Skip collection; render the report from <file>.
#
# Requires: gh (authenticated), jq.
#
# Exit codes:
#   0  success
#   2  usage error
#   3  missing dependency (gh or jq)
#   4  no repo could be determined
set -euo pipefail
IFS=$'\n\t'

REPO=''
MILESTONE=''
STATE='all'
ROW_LIMIT=20
OUTPUT_JSON=0
FROM_FILE=''

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-2}"; }

# --- argument parsing -------------------------------------------------------

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)      [[ $# -ge 2 ]] || die "--repo needs a value"; REPO="$2"; shift 2 ;;
      --milestone) [[ $# -ge 2 ]] || die "--milestone needs a value"; MILESTONE="$2"; shift 2 ;;
      --state)     [[ $# -ge 2 ]] || die "--state needs a value"; STATE="$2"; shift 2 ;;
      --limit)     [[ $# -ge 2 ]] || die "--limit needs a value"; ROW_LIMIT="$2"; shift 2 ;;
      --json)      OUTPUT_JSON=1; shift ;;
      --from)      [[ $# -ge 2 ]] || die "--from needs a value"; FROM_FILE="$2"; shift 2 ;;
      -h|--help)   sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *)           die "unknown option: $1" ;;
    esac
  done

  case "$STATE" in
    open|closed|all) ;;
    *) die "--state must be open, closed or all (got: $STATE)" ;;
  esac
  [[ "$ROW_LIMIT" == "all" || "$ROW_LIMIT" =~ ^[0-9]+$ ]] || die "--limit must be a number or 'all'"
}

require_tools() {
  command -v gh >/dev/null 2>&1 || die "gh is required" 3
  command -v jq >/dev/null 2>&1 || die "jq is required" 3
}

current_repo() {
  gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true
}

# --- collection -------------------------------------------------------------

# CLOSED_EVENT is fetched alongside LABELED_EVENT because
# `closedByPullRequestsReferences` is NOT reliable here: GitHub forms no closing
# reference for a PR authored by `app/github-actions`, which is every PR this
# pipeline opens. On BI-ArchiveUploader, #263, #328 and #258 all shipped via a
# merged agent PR and every one of them reads as an empty
# closedByPullRequestsReferences. `ClosedEvent.closer` sees all three. Both are
# collected and unioned: closer catches agent PRs, the reference list catches an
# issue closed by hand that a merged PR still points at.
#
# The ClosedEvent selection is aliased and queried with `last:` rather than folded
# into the LABELED_EVENT window. A ClosedEvent is late in an issue's timeline, so
# sharing a `first:100` page with label events would let a heavily relabelled issue
# push the closer off the page -- silently reintroducing the very undercount this
# exists to fix.
issue_query() {
  cat <<EOF
query(\$endCursor:String){
  repository(owner:"$1",name:"$2"){
    issues(first:25, after:\$endCursor, states:$3){
      pageInfo{hasNextPage endCursor}
      nodes{ number title state createdAt closedAt body
        milestone{title}
        labels(first:40){nodes{name}}
        closedByPullRequestsReferences(first:10, includeClosedPrs:true){nodes{number merged}}
        timelineItems(first:100, itemTypes:[LABELED_EVENT]){nodes{... on LabeledEvent{createdAt label{name}}}}
        closedEvents: timelineItems(last:10, itemTypes:[CLOSED_EVENT]){nodes{... on ClosedEvent{closer{__typename ... on PullRequest{number merged}}}}}
      }
    }
  }
}
EOF
}

# Turn the raw GraphQL pages into one record per issue. Kept as a jq program so
# the same shaping is testable from a fixture.
#
# `tasks` counts `### Task N` exactly as classify-turns.sh:113 does, so the
# turn-budget tier this reports is the tier the pipeline will actually pick.
# `loose_tasks` counts the same headings at the WRONG level (`## Task N` or
# `# Task N`), which score zero there — that is #297, and it is otherwise
# invisible: the plan looks complete and silently gets the 50-turn floor.
shape_program() {
  cat <<'EOF'
[.[].data.repository.issues.nodes] | flatten | .[] | . as $i
| ([$i.labels.nodes[].name]) as $labels
| (($i.body // "")) as $body
| { repo: $repo,
    issue: $i.number,
    title: $i.title,
    state: $i.state,
    created_at: $i.createdAt,
    closed_at: $i.closedAt,
    milestone: ($i.milestone.title // ""),
    labels: $labels,
    # Exactly `grep -qi '^## Implementation Plan'` — classify-turns.sh:106 and
    # commands/gh/implement.md's precondition 5 both use that, with ONE space.
    # A `+` here would call a body with two spaces planned while the command
    # that has to accept it prints NO PLAN.
    has_plan: ($body | test("(?im)^## Implementation Plan")),
    tasks: ($body | [match("(?m)^### Task [0-9]+"; "g")] | length),
    loose_tasks: ($body | [match("(?m)^#{1,2} Task [0-9]+"; "g")] | length),
    dispatches: [ $i.timelineItems.nodes[]
                  | select(.label.name? == "ai-implement")
                  | .createdAt ],
    shipped_prs: ( [ $i.closedEvents.nodes[]
                     | .closer
                     | select(. != null and .__typename == "PullRequest" and .merged)
                     | .number ]
                 + [ $i.closedByPullRequestsReferences.nodes[]
                     | select(.merged) | .number ]
                 | unique ) }
EOF
}

collect() {
  local repo="$1" owner name states
  owner="${repo%%/*}"; name="${repo#*/}"
  case "$STATE" in
    open)   states='[OPEN]' ;;
    closed) states='[CLOSED]' ;;
    *)      states='[OPEN,CLOSED]' ;;
  esac
  gh api graphql --paginate -f query="$(issue_query "$owner" "$name" "$states")" \
    | jq -rs --arg repo "$repo" "$(shape_program)" \
    | jq -s '.'
}

# --- classification ---------------------------------------------------------

# One stage per issue, plus the readiness verdict. The blocker list mirrors
# commands/gh/implement.md's own preconditions exactly, so "dispatchable" here
# means "/gh:implement will accept it" and not merely "it looks ready".
classify_program() {
  cat <<'EOF'
def has($l): .labels | index($l) != null;

map(
  select($milestone == "" or (.milestone | ascii_downcase | contains($milestone | ascii_downcase)))
  | . as $i
  | (.dispatches | length) as $attempts
  | ((.shipped_prs | length) > 0) as $shipped
  | (has("🧊 parked")) as $parked
  | (has("needs-enrichment") or has("❓ to-be-defined")) as $needs_enrichment
  | (has("ai-implement")) as $queued
  | ([ (if $parked then "parked" else empty end),
       # A body that already carries a plan but still wears the label is a
       # one-second fix (remove the label), not twenty minutes of enrichment.
       # Saying so is the whole job of this table.
       (if $needs_enrichment and .has_plan then "stale needs-enrichment label (plan is already in the body)"
        elif $needs_enrichment            then "needs-enrichment"
        else empty end),
       (if $queued then "already dispatched" else empty end),
       (if .has_plan then empty else "no ## Implementation Plan" end) ]) as $blockers
  | $i + {
      attempts: $attempts,
      shipped: $shipped,
      parked: $parked,
      needs_enrichment: $needs_enrichment,
      queued: $queued,
      blockers: $blockers,
      dispatchable: (.state == "OPEN" and ($blockers | length) == 0),
      # The tier classify-turns.sh will choose. `unplanned` is the 120-turn
      # discovery budget, which is a guess, not a measurement.
      budget: (if .has_plan | not     then "unplanned (120)"
               elif .tasks >= 6       then "160"
               elif .tasks >= 4       then "120"
               elif .tasks >= 2       then "80"
               else                        "floor (50)" end),
      # #297: a plan whose task headings are at the wrong level counts zero and
      # silently lands on the floor budget, however large the plan really is.
      miscounted: (.has_plan and .tasks == 0 and .loose_tasks > 0),
      stage: (if   $shipped              then "shipped"
              elif $attempts > 0         then "dispatched"
              elif .state == "CLOSED"    then "closed unshipped"
              elif $parked               then "parked"
              elif $needs_enrichment     then "needs enrichment"
              elif .has_plan | not       then "unplanned"
              else                            "ready" end) } )
EOF
}

# --- rendering --------------------------------------------------------------

render_report() {
  local records="$1"
  jq -r --arg milestone "$MILESTONE" --arg limit "$ROW_LIMIT" --arg state "$STATE" '
    def pct(n; d): if d == 0 then "n/a" else "\((n / d * 100) | round)%" end;
    def bar(n; d): if d == 0 then "" else
      ((n / d * 20) | round) as $f | ("#" * $f) + ("." * (20 - $f)) end;

    . as $all
    | (if ($limit == "all") then 10000 else ($limit | tonumber) end) as $rows
    | ($all | length)                                        as $total
    | ($all | map(select(.state == "OPEN")))                 as $open
    | ($open | map(select(.parked)))                         as $parked
    | ($open | map(select(.parked | not)))                   as $live
    | ($live | map(select(.needs_enrichment)))               as $blocked
    | ($live | map(select(.has_plan)))                       as $planned
    | ($live | map(select(.needs_enrichment and .has_plan))) as $stale_label
    | ($all  | map(select(.dispatchable)))                   as $ready
    | ($all  | map(select(.attempts > 0)))                   as $dispatched
    | ($all  | map(select(.attempts > 1)))                   as $redispatched
    | ($all  | map(select(.shipped)))                        as $shipped
    | ($dispatched | map(select(.shipped)))                  as $shipped_by_pipeline
    | ($shipped | map(select(.attempts == 0)))               as $shipped_by_hand
    | ($open | map(select(.miscounted)))                     as $miscounted
    |
      "# ai-implement funnel"
    , ""
    , "**Repo:** \(($all | map(.repo) | unique | first) // "-")\(if $milestone == "" then "" else " · **Milestone:** ~\($milestone)" end) · **State:** \($state) · **Issues:** \($total)"
    , ""
    , "## Funnel"
    , ""
    , "Each stage is a subset of the one above it. `Ready to dispatch` is the"
    , "queue depth an operator can actually fill right now."
    , ""
    , "| Stage | Count | Of open | |"
    , "|---|---:|---:|---|"
    , "| Open | \($open | length) | \(pct(($open | length); $total)) | `\(bar(($open | length); $total))` |"
    , "| — parked | \($parked | length) | \(pct(($parked | length); ($open | length))) | `\(bar(($parked | length); ($open | length)))` |"
    , "| Live (open, not parked) | \($live | length) | \(pct(($live | length); ($open | length))) | `\(bar(($live | length); ($open | length)))` |"
    , "| — blocked on enrichment | \($blocked | length) | \(pct(($blocked | length); ($live | length))) | `\(bar(($blocked | length); ($live | length)))` |"
    , "| — carrying a plan | \($planned | length) | \(pct(($planned | length); ($live | length))) | `\(bar(($planned | length); ($live | length)))` |"
    , "| **Ready to dispatch** | **\($ready | length)** | \(pct(($ready | length); ($live | length))) | `\(bar(($ready | length); ($live | length)))` |"
    , ""
    , "| Outcome | Count | Rate |"
    , "|---|---:|---:|"
    , "| Dispatched at least once | \($dispatched | length) | \(pct(($dispatched | length); $total)) of all issues |"
    , "| Re-dispatched | \($redispatched | length) | \(pct(($redispatched | length); ($dispatched | length))) of dispatched |"
    , "| Shipped by the pipeline | \($shipped_by_pipeline | length) | \(pct(($shipped_by_pipeline | length); ($dispatched | length))) of dispatched |"
    , "| Shipped by hand | \($shipped_by_hand | length) | never carried `ai-implement` |"
    , ""
    , "**Enrichment coverage:** \(pct(($planned | length); ($live | length))) of live issues carry an `## Implementation Plan`."
    , (if ($stale_label | length) == 0 then empty else
        "**\($stale_label | length) of those also still carry `needs-enrichment`** — the plan is in the body, so the label is stale and removing it is the whole fix. They are counted in both rows above, which is why the two do not sum to the live total."
       end)
    , (if ($live | length) == 0 then empty
       elif ($ready | length) == 0 then "**Queue depth: 0** — nothing can be dispatched without enriching something first."
       else "**Queue depth: \($ready | length)** issue(s) can be dispatched right now." end)
    , ""
    , "## Turn budget the pipeline will pick"
    , ""
    , "For the **open** issues only — this is what the next dispatches will cost."
    , "Counted from `### Task N` headings under `## Implementation Plan`, exactly"
    , "as `classify-turns.sh` counts them."
    , ""
    , "| Budget | Issues |"
    , "|---|---:|"
    , (["160","120","80","floor (50)","unplanned (120)"][] as $b
       | ($open | map(select(.budget == $b))) as $g
       | if ($g | length) == 0 then empty else "| \($b) | \($g | length) |" end)
    , (if ($miscounted | length) == 0 then empty else
        ""
        , "> **\($miscounted | length) plan(s) will be miscounted.** The task headings are"
        , "> `## Task N` or `# Task N`, not `### Task N`, so `classify-turns.sh` scores them"
        , "> zero and the run gets the 50-turn floor however large the plan is:"
        , ""
        , ($miscounted | .[:$rows][] | "> - #\(.issue) — \(.loose_tasks) task(s) at the wrong heading level")
       end)
    , ""
    , "## What is blocking the rest"
    , ""
    , (($live | map(select(.dispatchable | not)))) as $stuck
    | (if ($stuck | length) == 0 then "Nothing — every live issue is dispatchable." else
        ( "| Issue | Blocker(s) | Title |"
        , "|---|---|---|"
        , ($stuck | sort_by(.issue) | .[:$rows][]
           | "| #\(.issue) | \(.blockers | join(", ")) | \(.title[:60]) |")
        , (if ($stuck | length) > $rows then "" , "_… and \(($stuck | length) - $rows) more (`--limit all`)._" else empty end))
       end)
    , ""
    , "## Ready to dispatch now"
    , ""
    , (if ($ready | length) == 0 then "None." else
        ( "| Issue | Budget | Title |"
        , "|---|---|---|"
        , ($ready | sort_by(-.tasks, .issue) | .[:$rows][]
           | "| #\(.issue) | \(.budget) | \(.title[:60]) |"))
       end)
  ' "$records"
}

# --- main -------------------------------------------------------------------

main() {
  parse_args "$@"
  require_tools

  RECORDS="$(mktemp)"
  trap 'rm -f "${RECORDS:-}" "${RECORDS:-}.classified"' EXIT

  if [[ -n "$FROM_FILE" ]]; then
    [[ -f "$FROM_FILE" ]] || die "no such file: $FROM_FILE"
    cp "$FROM_FILE" "$RECORDS"
  else
    [[ -n "$REPO" ]] || REPO="$(current_repo)"
    [[ -n "$REPO" ]] || die "not in a GitHub repo — pass --repo" 4
    collect "$REPO" > "$RECORDS"
  fi

  jq --arg milestone "$MILESTONE" "$(classify_program)" "$RECORDS" > "$RECORDS.classified"

  if (( OUTPUT_JSON )); then
    cat "$RECORDS.classified"
  else
    render_report "$RECORDS.classified"
  fi
}

# Only run when executed, not when sourced — link-commands.sh installs every
# scripts/lib/*.sh, and some of those are sourced by slash commands.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
