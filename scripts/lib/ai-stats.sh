#!/usr/bin/env bash
#
# ai-stats.sh — ai-implement dispatch statistics across one or many repos.
#
# Reconstructs every ai-implement dispatch from two GitHub sources that the
# pipeline already writes, so no extra bookkeeping is needed:
#
#   1. `ai-implement` LabeledEvent timeline entries  → one per dispatch attempt
#   2. `## ai-implement run` issue comments          → outcome, agent, model,
#      turns and cost per attempt (rendered by scripts/post-run-report.sh)
#
# An issue "shipped" when a pull request that closed it was merged.
#
# Usage:
#   ai-stats.sh                      # current repo (from git remote)
#   ai-stats.sh --repo owner/name    # a named repo (repeatable)
#   ai-stats.sh --all                # every repo under --owner
#   ai-stats.sh --since 30d          # only dispatches in the last 30 days
#   ai-stats.sh --json               # raw per-issue records, no report
#   ai-stats.sh --from records.json  # render a previously collected --json dump
#
# Options:
#   --repo <owner/name>  Repo to scan. Repeatable. Default: the current clone.
#   --all                Scan every non-archived repo under --owner.
#   --owner <login>      Owner for --all. Default: the authenticated gh user.
#   --since <spec>       ISO date (2026-08-01) or Nd / Nw / Nm relative window.
#   --json               Emit the collected records as JSON and exit.
#   --from <file>        Skip collection; render the report from <file>.
#   --limit <n>          Rows in the per-issue table. Default 40. `all` for every row.
#   --exclude <glob>     Drop repos matching <glob> from the totals. Repeatable.
#                        Default: *-sandbox — a sandbox exists to absorb failed
#                        runs, so its zeroes are noise, not signal. Excluded
#                        repos are still listed at the foot of the report.
#   --no-exclude         Keep every repo, including the defaults above.
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

OWNER=''
SINCE=''
OUTPUT_JSON=0
FROM_FILE=''
ROW_LIMIT=40
SCAN_ALL=0
REPOS=()
EXCLUDES=('*-sandbox')
EXCLUDES_CLEARED=0

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-2}"; }

# --- argument parsing -------------------------------------------------------

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)  [[ -n "${2:-}" ]] || die "--repo needs owner/name"; REPOS+=("$2"); shift 2 ;;
      --all)   SCAN_ALL=1; shift ;;
      --owner) [[ -n "${2:-}" ]] || die "--owner needs a login"; OWNER="$2"; shift 2 ;;
      --since) [[ -n "${2:-}" ]] || die "--since needs a date or Nd/Nw/Nm"; SINCE="$(to_iso_date "$2")"; shift 2 ;;
      --json)  OUTPUT_JSON=1; shift ;;
      --from)  [[ -r "${2:-}" ]] || die "--from file not readable: ${2:-}"; FROM_FILE="$2"; shift 2 ;;
      --limit) [[ -n "${2:-}" ]] || die "--limit needs a number or 'all'"; ROW_LIMIT="$2"; shift 2 ;;
      --exclude)
        [[ -n "${2:-}" ]] || die "--exclude needs a glob"
        (( EXCLUDES_CLEARED )) || { EXCLUDES=(); EXCLUDES_CLEARED=1; }
        EXCLUDES+=("$2"); shift 2 ;;
      --no-exclude) EXCLUDES=(); EXCLUDES_CLEARED=1; shift ;;
      -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done
}

to_iso_date() {
  local spec="$1"
  case "$spec" in
    *d) date -u -d "${spec%d} days ago"   +%Y-%m-%d ;;
    *w) date -u -d "${spec%w} weeks ago"  +%Y-%m-%d ;;
    *m) date -u -d "${spec%m} months ago" +%Y-%m-%d ;;
    *)  printf '%s' "$spec" ;;
  esac
}

require_tools() {
  command -v gh >/dev/null 2>&1 || die "gh CLI not found" 3
  command -v jq >/dev/null 2>&1 || die "jq not found" 3
}

# --- repo discovery ---------------------------------------------------------

current_repo() {
  gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true
}

# Repos worth scanning are the ones that carry the `ai-implement` label at all;
# asking for the label by exact name is the only cheap pre-filter (the GraphQL
# `labels(query:)` search is fuzzy and matches almost everything).
discover_repos() {
  local owner="$1" names query i=0
  names="$(gh repo list "$owner" --limit 300 --no-archived --json name -q '.[].name')"
  query='{'
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    i=$((i + 1))
    query+="a${i}: repository(owner:\"${owner}\",name:\"${name}\"){nameWithOwner issues{totalCount} label(name:\"ai-implement\"){name}} "
  done <<< "$names"
  query+='}'
  gh api graphql -f query="$query" \
    -q '.data|to_entries[]|.value|select(.!=null)|select(.label!=null and .issues.totalCount>0)|.nameWithOwner'
}

resolve_repos() {
  if (( SCAN_ALL )); then
    [[ -n "$OWNER" ]] || OWNER="$(gh api user -q .login)"
    mapfile -t REPOS < <(discover_repos "$OWNER")
  elif [[ ${#REPOS[@]} -eq 0 ]]; then
    local here; here="$(current_repo)"
    [[ -n "$here" ]] || die "not in a GitHub repo — pass --repo or --all" 4
    REPOS=("$here")
  fi
  [[ ${#REPOS[@]} -gt 0 ]] || die "no repos to scan" 4
}

# --- collection -------------------------------------------------------------

issue_query() {
  cat <<EOF
query(\$endCursor:String){
  repository(owner:"$1",name:"$2"){
    issues(first:25, after:\$endCursor){
      pageInfo{hasNextPage endCursor}
      nodes{ number title state
        timelineItems(first:100, itemTypes:[LABELED_EVENT]){nodes{... on LabeledEvent{createdAt label{name}}}}
        closedByPullRequestsReferences(first:10, includeClosedPrs:true){nodes{number merged}}
        comments(first:60){nodes{createdAt body}}
      }
    }
  }
}
EOF
}

# Turn one repo's raw GraphQL pages into one record per dispatched issue.
# Kept as a jq program so the same shaping is testable from a fixture.
shape_program() {
  cat <<'EOF'
[.[].data.repository.issues.nodes] | flatten | .[] | . as $i
| { repo: $repo,
    issue: $i.number,
    title: $i.title,
    state: $i.state,
    dispatches: [ $i.timelineItems.nodes[]
                  | select(.label.name == "ai-implement")
                  | .createdAt ],
    shipped_prs: [ $i.closedByPullRequestsReferences.nodes[]
                   | select(.merged) | .number ],
    runs: [ $i.comments.nodes[]
            | select(.body | startswith("## ai-implement run"))
            | { at: .createdAt,
                ok: (.body | test("Outcome:\\*\\* :white_check_mark:")),
                reason: ((.body | capture("Outcome:\\*\\* :[a-z_]+: (?<r>[^\n]*)").r) // "unknown"),
                agent: ((.body | capture("\\*\\*Agent:\\*\\* (?<a>[^\n ]+)").a) // "unknown"),
                model: ((.body | capture("\\*\\*Model:\\*\\* (?<m>[^ \n]+)").m) // "unknown"),
                turns: ((.body | capture("Turns:\\*\\* (?<t>[0-9]+)").t | tonumber) // 0),
                cost:  ((.body | capture("Cost:\\*\\* \\$(?<c>[0-9.]+)").c | tonumber) // 0),
                plan:  ((.body | capture("\\*\\*Plan:\\*\\* (?<p>[^ \n]+)").p) // "unknown") } ] }
| select(.dispatches | length > 0)
EOF
}

collect() {
  local repo owner name
  for repo in "${REPOS[@]}"; do
    owner="${repo%%/*}"; name="${repo#*/}"
    gh api graphql --paginate -f query="$(issue_query "$owner" "$name")" 2>/dev/null \
      | jq -rs --arg repo "$repo" "$(shape_program)" || true
  done | jq -s '.'
}

# --- grading ----------------------------------------------------------------

# A–F per issue. Attempts and money are the two things a dispatch actually
# costs, so the grade is a function of both, gated on whether it shipped.
grade_program() {
  cat <<'EOF'
def cheap: 2;      # USD — an A must also have been cheap
def costly: 10;    # USD — enough money to cap the grade at D
map(
  . as $i
  | (if $since == "" then .dispatches else [.dispatches[] | select(. >= $since)] end) as $d
  | select($d | length > 0)
  | (if $since == "" then .runs else [.runs[] | select(.at >= $since)] end) as $r
  | ($d | length) as $attempts
  | ([$r[].cost] | add // 0) as $cost
  | ((.shipped_prs | length) > 0) as $shipped
  | $i + {
      dispatches: $d, runs: $r, attempts: $attempts,
      cost: ($cost * 100 | round / 100),
      shipped: $shipped,
      plan: ([$r[].plan // "unknown"] | (map(select(. != "unknown")) | first) // "unknown"),
      grade: (if   $shipped | not      then "F"
              elif $attempts > 3
                or $cost >= costly     then "D"
              elif $attempts >= 3      then "C"
              elif $attempts == 2      then "B"
              elif $cost < cheap       then "A"
              else                          "B" end) } )
EOF
}

# Split the graded records into the ones that count and the ones excluded by
# glob. Excluded repos are reported separately rather than dropped silently — a
# number that quietly omits repos is worse than the noise it removes.
partition_program() {
  cat <<'EOF'
def matches($globs): . as $repo
  | ($repo | split("/") | last) as $name
  | any($globs[]; . as $g
        | ($g | gsub("\\."; "\\\\.") | gsub("\\*"; ".*")) as $re
        | ($name | test("^" + $re + "$")) or ($repo | test("^" + $re + "$")));
{ kept:     map(select((.repo | matches($excludes)) and (.repo | IN($named[])) == false | not)),
  excluded: map(select((.repo | matches($excludes)) and (.repo | IN($named[])) == false)) }
EOF
}

# --- rendering --------------------------------------------------------------

render_report() {
  local records="$1"
  jq -r --arg since "$SINCE" --arg limit "$ROW_LIMIT" '
    def pct(n; d): if d == 0 then "n/a" else "\((n / d * 100) | round)%" end;
    def sum(f): [.[] | f] | add // 0;
    def money(v): (v * 100 | round) as $c
      | "$\($c / 100 | floor).\($c % 100 | tostring | if length == 1 then "0" + . else . end)";

    .kept as $all
    | .excluded as $excluded
    | $all
    | (map(.runs[]))                                  as $runs
    | (sum(.attempts))                                as $dispatches
    | (map(select(.shipped)) | length)                as $shipped
    | ([$runs[] | select(.ok)] | length)              as $ok
    | ([$runs[] | select(.ok | not)] | length)        as $bad
    | (sum(.cost))                                    as $cost
    | (map(.dispatches[]) | sort)                     as $dates
    | (if ($limit == "all") then 10000 else ($limit | tonumber) end) as $rows
    |
      "# ai-implement stats"
    , ""
    , "**Repos:** \(map(.repo) | unique | length) · **Issues:** \($all | length) · **Dispatches:** \($dispatches) · **Shipped:** \($shipped)"
    , "**Window:** \(if $since == "" then "all time" else "since \($since)" end) · \((($dates | first) // "-")[:10]) → \((($dates | last) // "-")[:10])"
    , "**Spend:** \(money($cost)) · \(money(if $shipped == 0 then 0 else $cost / $shipped end)) per shipped issue"
    , ""
    , "| Rate | Value |"
    , "|---|---|"
    , "| Issue shipped | \(pct($shipped; $all | length)) (\($shipped)/\($all | length)) |"
    , "| Per dispatch shipped | \(pct($shipped; $dispatches)) (\($shipped)/\($dispatches)) |"
    , "| Run verdict ok | \(pct($ok; $ok + $bad)) (\($ok)/\($ok + $bad)) |"
    , "| First-attempt shipped | \(pct((map(select(.attempts == 1 and .shipped)) | length); (map(select(.attempts == 1)) | length))) |"
    , "| Attempts per issue | \(if ($all | length) == 0 then 0 else (($dispatches / ($all | length)) * 10 | round / 10) end) |"
    , ""
    , "## Grades"
    , ""
    , "| Grade | Issues | Meaning |"
    , "|---|---|---|"
    , (["A","B","C","D","F"] as $g
       | {A:"shipped first try, cheap", B:"shipped in 1-2 attempts",
          C:"shipped, 3 attempts", D:"shipped, >3 attempts or costly",
          F:"never shipped"} as $meaning
       | $g[] as $k
       | "| \($k) | \(map(select(.grade == $k)) | length) | \($meaning[$k]) |")
    , ""
    , "## By agent"
    , ""
    , "| Agent | Runs | OK | Rate | Cost | Avg turns |"
    , "|---|---|---|---|---|---|"
    , ($runs | group_by(.agent)[]
       | "| \(.[0].agent) | \(length) | \([.[] | select(.ok)] | length) | \(pct(([.[] | select(.ok)] | length); length)) | \(money([.[].cost] | add)) | \(([.[].turns] | add / length) | round) |")
    , ""
    , "## By model"
    , ""
    , "| Model | Runs | OK | Rate | Cost | Avg turns |"
    , "|---|---|---|---|---|---|"
    , ($runs | group_by(.model) | sort_by(-length)[]
       | "| \(.[0].model) | \(length) | \([.[] | select(.ok)] | length) | \(pct(([.[] | select(.ok)] | length); length)) | \(money([.[].cost] | add)) | \(([.[].turns] | add / length) | round) |")
    , ""
    , "## By enrichment"
    , ""
    , "Did the issue carry an `## Implementation Plan` when it was dispatched?"
    , ""
    , "| Plan | Issues | Shipped | Rate | Attempts/issue |"
    , "|---|---|---|---|---|"
    , (["enriched","none","unknown"][] as $k
       | ($all | map(select(.plan == $k))) as $g
       | if ($g | length) == 0 then empty else
           "| \($k) | \($g | length) | \($g | map(select(.shipped)) | length) | \(pct(($g | map(select(.shipped)) | length); ($g | length))) | \((($g | map(.attempts) | add) / ($g | length) * 10 | round / 10)) |"
         end)
    , ""
    , "## By repo"
    , ""
    , "| Repo | Issues | Dispatches | Shipped | Rate | Cost |"
    , "|---|---|---|---|---|---|"
    , ($all | group_by(.repo) | sort_by(-(sum(.attempts)))[]
       | "| \(.[0].repo) | \(length) | \(sum(.attempts)) | \(map(select(.shipped)) | length) | \(pct((map(select(.shipped)) | length); length)) | \(money(sum(.cost))) |")
    , ""
    , "## Per issue"
    , ""
    , "| Grade | Issue | Attempts | Cost | Agent/model | Title |"
    , "|---|---|---|---|---|---|"
    , ($all
       | sort_by(.grade, -.attempts, -.cost)
       | .[:$rows][]
       | "| \(.grade) | \(.repo)#\(.issue) | \(.attempts) | \(money(.cost)) | \((.runs | last | if . == null then "-" else "\(.agent)/\(.model)" end)) | \(.title[:52]) |")
    , (if ($excluded | length) == 0 then empty else
        ""
        , "## Excluded"
        , ""
        , "Not counted above (`--no-exclude` to include them):"
        , ""
        , ($excluded | group_by(.repo)[]
           | "- **\(.[0].repo)** — \(length) issues, \(sum(.attempts)) dispatches, \(map(select(.shipped)) | length) shipped, \(money(sum(.cost)))")
       end)
  ' "$records"
}

# --- main -------------------------------------------------------------------

main() {
  parse_args "$@"
  require_tools

  RECORDS="$(mktemp)"
  trap 'rm -f "${RECORDS:-}" "${RECORDS:-}.graded"' EXIT

  if [[ -n "$FROM_FILE" ]]; then
    cp "$FROM_FILE" "$RECORDS"
  else
    resolve_repos
    collect > "$RECORDS"
  fi

  local excludes_json named_json
  excludes_json="$(printf '%s\n' "${EXCLUDES[@]+"${EXCLUDES[@]}"}" | jq -Rs 'split("\n") | map(select(. != ""))')"
  named_json="$(printf '%s\n' "${REPOS[@]+"${REPOS[@]}"}" | jq -Rs 'split("\n") | map(select(. != ""))')"

  jq --arg since "$SINCE" "$(grade_program)" "$RECORDS" \
    | jq --argjson excludes "$excludes_json" --argjson named "$named_json" "$(partition_program)" \
    > "$RECORDS.graded"

  if (( OUTPUT_JSON )); then
    jq '.kept' "$RECORDS.graded"
  else
    render_report "$RECORDS.graded"
  fi
}

# Only run when executed, not when sourced — link-commands.sh installs every
# scripts/lib/*.sh, and some of those are sourced by slash commands.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
