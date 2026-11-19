#!/usr/bin/env bash
#
# backfill-backlog-milestone.sh — one-off: give every open issue without a
# milestone the standing `backlog` milestone (#646).
#
# The guard (assign-backlog-milestone.sh) only sees issues opened after it is
# wired, and never sees one created with a workflow's GITHUB_TOKEN. This sweeps
# the rest. Operator-invoked, so flag-driven; a dry run unless --apply, like
# migrate-consumers.sh. Pull requests are excluded.
#
# Usage: backfill-backlog-milestone.sh -R <owner/repo> [--apply]
#
# Exit codes:
#   0   dry run done, or every listed issue assigned
#   1   a read failed, or at least one assignment failed
#   2   usage error
#   64  the repo has no open `backlog` milestone — never created here
set -euo pipefail
IFS=$'\n\t'

_BBM_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/backlog-milestone.sh
source "$_BBM_HERE/lib/backlog-milestone.sh"

REPO=''
APPLY=false

usage_error() { printf 'error: %s\nusage: %s -R <owner/repo> [--apply]\n' "$1" "${0##*/}" >&2; exit 2; }
fatal() { printf 'error: %s\n' "$1" >&2; exit 1; }

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      -R|--repo) [[ $# -ge 2 ]] || usage_error "$1 needs a value"; REPO="$2"; shift 2 ;;
      --apply)   APPLY=true; shift ;;
      -h|--help) printf 'usage: %s -R <owner/repo> [--apply]\n' "${0##*/}"; exit 0 ;;
      *)         usage_error "unknown argument: $1" ;;
    esac
  done
  [[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
    || usage_error "-R owner/name is required (got: ${REPO:-})"
}

# list_unmilestoned — open issue numbers with no milestone, every page,
# pull requests dropped. One number per line. Query.
list_unmilestoned() {
  local pages
  pages="$(gh api "repos/$REPO/issues?state=open&milestone=none&per_page=100" --paginate)" || return 1
  printf '%s\n' "$pages" | jq -rs '.[][] | select(.pull_request == null) | .number'
}

# assign_all <milestone-number> <issues> <total> — assigns each, keeps going past a
# failure, prints the tally. Returns 1 if any write failed. Command.
assign_all() {
  local number="$1" issues="$2" total="$3" n assigned=0 failed=0
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    if assign_milestone "$REPO" "$n" "$number"; then
      assigned=$((assigned + 1))
    else
      failed=$((failed + 1))
      printf 'error: could not assign %s to #%s\n' "$BACKLOG_MILESTONE" "$n" >&2
    fi
  done <<< "$issues"
  printf 'backfill: assigned %s of %s\n' "$assigned" "$total"
  (( failed == 0 ))
}

main() {
  parse_args "$@"
  local number issues count=0
  number="$(backlog_milestone_number "$REPO")" || fatal "could not read the milestones of $REPO"
  if [[ -z "$number" ]]; then
    printf 'error: %s has no open "%s" milestone — create it first (/milestone new %s); nothing assigned\n' \
      "$REPO" "$BACKLOG_MILESTONE" "$BACKLOG_MILESTONE" >&2
    exit 64
  fi
  issues="$(list_unmilestoned)" || fatal "could not list the open issues of $REPO"
  [[ -z "$issues" ]] || count="$(printf '%s\n' "$issues" | wc -l | tr -d ' ')"
  printf 'backfill: %s open issues without a milestone in %s\n' "$count" "$REPO"
  [[ -z "$issues" ]] || printf '%s\n' "$issues" | sed 's/^/  #/'

  if [[ "$APPLY" != true ]]; then
    printf 'DRY_RUN: would assign %s (#%s) to %s issues — re-run with --apply\n' \
      "$BACKLOG_MILESTONE" "$number" "$count"
    return 0
  fi
  assign_all "$number" "$issues" "$count" || exit 1
}

main "$@"
