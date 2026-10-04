#!/usr/bin/env bash
#
# check-plan-coverage.sh — grade a PR's changed files against the issue's
# Implementation Plan (#457). Query only: no network, no writes.
#
# A run can end cleanly while whole plan tasks never reached the branch (#430:
# two of three tasks left as a patch in the PR body, graded ai:done). This maps
# each `### Task N` (or `## Task N`) heading to the paths its **Files** block
# names and checks them against the changed set.
#
# Every task is one of:
#   GRADED    it names at least one path. LANDED when at least one of those
#             paths is in the changed set. Known blind spot, by design: a task
#             whose paths all belong to another landed task is
#             indistinguishable from it and counts as landed — plans routinely
#             share a test file, and flagging that would fire on clean runs.
#   SKIPPED   it says `**Files:** none …` — a sweep or verification task with
#             nothing to land. Not graded.
#   UNPARSED  it names no path and does not say none. Cannot be graded.
#
# Grade, in order:
#   no plan heading, or no task headings        → unverifiable
#   any GRADED task not landed                  → partial (even next to
#                                                 UNPARSED tasks — one task we
#                                                 cannot read must not silence
#                                                 the ones we can)
#   any UNPARSED task                           → unverifiable
#   no GRADED task at all (every task SKIPPED)  → unverifiable
#   otherwise                                   → complete
#
# Parsing rules:
#   - only from a `## Implementation Plan` heading onward (a suffix such as
#     "(revised)" is fine); once a task has been seen, the next non-task h2
#     (e.g. `## Spec`) ends the plan. h2s before the first task
#     (`## Global Constraints`) do not;
#   - lines inside fenced code blocks are ignored (a fence closes on a line of
#     at least as many backticks as opened it, so ```` can wrap ```);
#   - file lines are `- Create|Modify|Test|Delete|Rename: ...`; each backticked
#     token on the line counts when it is path-shaped (contains `/` or ends in
#     a `.ext`), with a trailing `:<digit>...` line range stripped. A Rename
#     line contributes both paths.
#
# Env (required):
#   ISSUE_BODY_FILE     the issue body
#   CHANGED_FILES_FILE  the PR's changed paths, one per line
#
# Stdout, always these four lines:
#   coverage=complete|partial|unverifiable
#   missing-tasks=<comma-separated GRADED tasks not landed>   (partial only)
#   unparsed-tasks=<comma-separated UNPARSED tasks>
#   reason=no-plan|no-tasks|task-without-files:<N,...>|no-gradable-tasks
#                                                             (unverifiable only)
#
# Exit codes:
#   0  graded (any grade)
#   2  usage error: an input unset or unreadable
set -euo pipefail
IFS=$'\n\t'

usage_error() { printf 'error: %s\n' "$1" >&2; exit 2; }

[[ -n "${ISSUE_BODY_FILE:-}" && -r "${ISSUE_BODY_FILE:-}" ]] \
  || usage_error "ISSUE_BODY_FILE must name a readable file"
[[ -n "${CHANGED_FILES_FILE:-}" && -r "${CHANGED_FILES_FILE:-}" ]] \
  || usage_error "CHANGED_FILES_FILE must name a readable file"

emit() {
  printf 'coverage=%s\nmissing-tasks=%s\nunparsed-tasks=%s\nreason=%s\n' "$1" "$2" "$3" "$4"
}

# One record per line:
#   P               the plan heading was seen
#   T<TAB>n         a task heading
#   N<TAB>n         task n says `**Files:** none`
#   F<TAB>n<TAB>p   task n names path p
parse_plan() {
  awk '
    function ticks(s,   n) { n = 0; while (substr(s, n + 1, 1) == "`") n++; return n }
    {
      t = ticks($0)
      if (infence) { if (t >= flen && $0 ~ /^`+[[:space:]]*$/) infence = 0; next }
      if (t >= 3) { infence = 1; flen = t; next }
    }
    !inplan && tolower($0) ~ /^## implementation plan/ { inplan = 1; print "P"; next }
    !inplan { next }
    /^###? Task [0-9]+/ {
      match($0, /Task [0-9]+/)
      task = substr($0, RSTART + 5, RLENGTH - 5)
      print "T\t" task
      next
    }
    /^## / && task != "" { exit }
    task != "" && tolower($0) ~ /^\*\*files:\*\*[[:space:]]*none/ { print "N\t" task; next }
    task != "" && /^- (Create|Modify|Test|Delete|Rename): / {
      line = $0
      while (match(line, /`[^`]+`/)) {
        path = substr(line, RSTART + 1, RLENGTH - 2)
        line = substr(line, RSTART + RLENGTH)
        sub(/:[0-9].*$/, "", path)
        if (path ~ /\// || path ~ /\.[A-Za-z0-9]+$/) print "F\t" task "\t" path
      }
    }
  ' "$ISSUE_BODY_FILE"
}

records_of() { awk -F'\t' -v kind="$2" -v t="$3" '$1 == kind && $2 == t { print ($3 != "" ? $3 : $2) }' <<< "$1"; }

task_landed() {
  local plan="$1" task="$2" path
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    grep -qxF -- "$path" "$CHANGED_FILES_FILE" && return 0
  done <<< "$(records_of "$plan" F "$task")"
  return 1
}

join_commas() { local IFS=,; printf '%s' "$*"; }

main() {
  local plan tasks=() task missing=() unparsed=() graded=0
  plan="$(parse_plan)"

  if ! grep -qx 'P' <<< "$plan"; then
    emit unverifiable '' '' no-plan; return 0
  fi
  mapfile -t tasks < <(awk -F'\t' '$1 == "T" { print $2 }' <<< "$plan")
  if (( ${#tasks[@]} == 0 )); then
    emit unverifiable '' '' no-tasks; return 0
  fi

  for task in "${tasks[@]}"; do
    if [[ -n "$(records_of "$plan" F "$task")" ]]; then
      graded=$((graded + 1))
      task_landed "$plan" "$task" || missing+=("$task")
    elif [[ -z "$(records_of "$plan" N "$task")" ]]; then
      unparsed+=("$task")
    fi
  done

  local missing_csv unparsed_csv
  missing_csv="$(join_commas "${missing[@]}")"
  unparsed_csv="$(join_commas "${unparsed[@]}")"

  if (( ${#missing[@]} > 0 )); then
    emit partial "$missing_csv" "$unparsed_csv" ''
  elif (( ${#unparsed[@]} > 0 )); then
    emit unverifiable '' "$unparsed_csv" "task-without-files:$unparsed_csv"
  elif (( graded == 0 )); then
    emit unverifiable '' '' no-gradable-tasks
  else
    emit complete '' '' ''
  fi
}

main
