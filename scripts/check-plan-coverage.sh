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
# A task is LANDED when at least one of its files is in the changed set. Known
# blind spot, by design: a task whose files all belong to another landed task
# is indistinguishable from it and counts as landed. Flagging those would make
# `partial` fire on clean runs, because plans routinely share a test file.
#
# Parsing rules:
#   - only from the `## Implementation Plan` heading onward; once a task has
#     been seen, the next non-task h2 (e.g. `## Spec`) ends the plan. h2s before
#     the first task (`## Global Constraints`) do not;
#   - lines inside fenced code blocks are ignored (a fence closes on a line of
#     at least as many backticks as opened it, so ```` can wrap ```);
#   - file lines are `- Create|Modify|Test|Delete: ...`; every backticked token
#     on the line counts, with a trailing `:<digit>...` line range stripped.
#
# Env (required):
#   ISSUE_BODY_FILE     the issue body
#   CHANGED_FILES_FILE  the PR's changed paths, one per line
#
# Stdout, always these three lines:
#   coverage=complete|partial|unverifiable
#   missing-tasks=<comma-separated task numbers>   (partial only)
#   reason=no-plan|no-tasks|task-without-files:<N> (unverifiable only)
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

emit() { printf 'coverage=%s\nmissing-tasks=%s\nreason=%s\n' "$1" "$2" "$3"; }

# One "T<TAB>n" line per task heading and one "F<TAB>n<TAB>path" per planned file.
parse_plan() {
  awk '
    function ticks(s,   n) { n = 0; while (substr(s, n + 1, 1) == "`") n++; return n }
    {
      t = ticks($0)
      if (infence) { if (t >= flen && $0 ~ /^`+[[:space:]]*$/) infence = 0; next }
      if (t >= 3) { infence = 1; flen = t; next }
    }
    tolower($0) ~ /^## implementation plan[[:space:]]*$/ { inplan = 1; next }
    !inplan { next }
    /^###? Task [0-9]+/ {
      match($0, /Task [0-9]+/)
      task = substr($0, RSTART + 5, RLENGTH - 5)
      print "T\t" task
      next
    }
    /^## / && task != "" { exit }
    task != "" && /^- (Create|Modify|Test|Delete): / {
      line = $0
      while (match(line, /`[^`]+`/)) {
        path = substr(line, RSTART + 1, RLENGTH - 2)
        line = substr(line, RSTART + RLENGTH)
        sub(/:[0-9].*$/, "", path)
        if (path != "") print "F\t" task "\t" path
      }
    }
  ' "$ISSUE_BODY_FILE"
}

files_of_task() { awk -F'\t' -v t="$2" '$1 == "F" && $2 == t { print $3 }' <<< "$1"; }

task_landed() {
  local plan="$1" task="$2" path
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    grep -qxF -- "$path" "$CHANGED_FILES_FILE" && return 0
  done <<< "$(files_of_task "$plan" "$task")"
  return 1
}

main() {
  if ! grep -qi '^## Implementation Plan' "$ISSUE_BODY_FILE"; then
    emit unverifiable '' no-plan; return 0
  fi

  local plan tasks=() task missing=()
  plan="$(parse_plan)"
  mapfile -t tasks < <(awk -F'\t' '$1 == "T" { print $2 }' <<< "$plan")
  if (( ${#tasks[@]} == 0 )); then
    emit unverifiable '' no-tasks; return 0
  fi

  for task in "${tasks[@]}"; do
    if [[ -z "$(files_of_task "$plan" "$task")" ]]; then
      emit unverifiable '' "task-without-files:$task"; return 0
    fi
  done

  for task in "${tasks[@]}"; do
    task_landed "$plan" "$task" || missing+=("$task")
  done

  if (( ${#missing[@]} > 0 )); then
    emit partial "$(IFS=,; printf '%s' "${missing[*]}")" ''
  else
    emit complete '' ''
  fi
}

main
