#!/usr/bin/env bash
#
# classify-turns.sh — Pick max_turns for an issue. Two-stage decision,
# mirroring classify-task.sh's model triage:
#
#   1. Explicit override via a `turns:<N>` label on the issue (N one of
#      50/80/120/160). This always wins.
#   2. Heuristic over the issue body — counts `### Task` headings under an
#      `## Implementation Plan` section (the shape /enrich writes). More
#      tasks means more file edits + test runs + a regression pass before
#      the agent can commit/push/open a PR, so it needs a bigger budget.
#      An issue with no Implementation Plan section (not enriched, or a
#      trivial one-liner) falls through to DEFAULT_MAX_TURNS.
#
# Tiers tuned from one real run (game-tschau-sepp#9): a 4-task enriched plan
# actually used 110 turns to succeed, after failing outright at a 30-turn
# cap (all edits done, nothing committed — see agent-implement.yml's
# max-turns description for the full story). Thin evidence (n=1), but the
# cost is asymmetric: running out loses all uncommitted work, overshooting
# just costs a bit more compute. Err generous; revisit as more real runs land.
#
# Required environment variables:
#   ISSUE_NUMBER  GitHub issue number
#   REPO          owner/repo (default: $GITHUB_REPOSITORY)
#   GH_TOKEN      (or ambient gh auth)
#
# Optional environment variables:
#   DEFAULT_MAX_TURNS  Fallback when no override label + no plan found.
#                      Default: 50 (matches agent-implement.yml's own default).
#   ISSUE_LABELS       Newline- or space-separated labels. If set, skips the
#                      `gh issue view --json labels` call. Used by tests.
#   ISSUE_BODY         Free-form issue title+body string. If set, skips the
#                      `gh issue view --json title,body` call. Used by tests.
#
# Output:
#   Writes `turns=<N>` and `reason=<text>` to $GITHUB_OUTPUT when set,
#   and prints a one-line `chosen: <N> (<reason>)` summary to stdout.
#
# Exit codes:
#   0  success
#   2  required env missing
set -euo pipefail
IFS=$'\n\t'

require_env() {
  if [[ -z "${!1:-}" ]]; then
    printf 'error: %s must be set\n' "$1" >&2
    exit 2
  fi
}

require_env ISSUE_NUMBER
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
if [[ -z "$REPO" ]]; then
  printf 'error: REPO or GITHUB_REPOSITORY must be set\n' >&2
  exit 2
fi

DEFAULT_MAX_TURNS="${DEFAULT_MAX_TURNS:-50}"

# --- 1) explicit override label -------------------------------------------

if [[ -z "${ISSUE_LABELS:-}" ]]; then
  ISSUE_LABELS="$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json labels --jq '.labels[].name')"
fi

chosen=''
reason=''
while IFS= read -r label; do
  case "$label" in
    turns:50)  chosen=50;  reason='label turns:50' ;;
    turns:80)  chosen=80;  reason='label turns:80' ;;
    turns:120) chosen=120; reason='label turns:120' ;;
    turns:160) chosen=160; reason='label turns:160' ;;
  esac
done <<< "$ISSUE_LABELS"

# --- 2) heuristic over title+body -----------------------------------------

if [[ -z "$chosen" ]]; then
  if [[ -z "${ISSUE_BODY:-}" ]]; then
    ISSUE_BODY="$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json title,body --jq '.title + "\n" + .body')"
  fi

  # Feed grep via a here-string, NOT `printf ... | grep -q`. `grep -q` exits
  # on its first match, so the writer is often still going: printf then dies
  # of SIGPIPE and `set -o pipefail` turns a SUCCESSFUL match into a false
  # condition, silently downgrading a big enriched plan to the default
  # budget. Lost ~42% of the time on the 57KB body of #280 (which burned a
  # full run at 50 turns instead of 160). A here-string has no pipe and no
  # race. See tests/fixtures/issue-body-large-plan.md.
  if grep -qi '^## Implementation Plan' <<< "$ISSUE_BODY"; then
    # `grep -c` exits 1 on zero matches (a heading level other than "### Task
    # N", or a plan with no numbered task headings at all) -- under
    # set -euo pipefail that would kill this whole script silently before it
    # writes anything to $GITHUB_OUTPUT, aborting the implement job before
    # the implementer ever runs. `-c` still prints "0" on no match; the
    # `|| true` only neutralizes the exit code.
    task_count="$(grep -cE '^### Task [0-9]+' <<< "$ISSUE_BODY" || true)"
    if   (( task_count >= 6 )); then chosen=160; reason="heuristic: ${task_count} plan tasks"
    elif (( task_count >= 4 )); then chosen=120; reason="heuristic: ${task_count} plan tasks"
    elif (( task_count >= 2 )); then chosen=80;  reason="heuristic: ${task_count} plan tasks"
    else chosen="$DEFAULT_MAX_TURNS"; reason="heuristic: ${task_count} plan task(s), default budget enough"
    fi
  else
    chosen="$DEFAULT_MAX_TURNS"
    reason='heuristic: no Implementation Plan section found'
  fi
fi

printf 'chosen: %s (%s)\n' "$chosen" "$reason"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'turns=%s\n'  "$chosen" >> "$GITHUB_OUTPUT"
  printf 'reason=%s\n' "$reason" >> "$GITHUB_OUTPUT"
fi
