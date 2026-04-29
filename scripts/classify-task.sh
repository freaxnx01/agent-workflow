#!/usr/bin/env bash
#
# classify-task.sh — Pick the Claude model for an issue. Two-stage decision:
#
#   1. Explicit override via `model:opus` / `model:sonnet` / `model:haiku`
#      label on the issue. This always wins.
#   2. Heuristic over the issue body — keyword-based for now. The DESIGN
#      target is a Haiku-powered classifier; that's a future swap-in. Until
#      then the heuristic + the override label are good enough and cost
#      nothing to run.
#
# Required environment variables:
#   ISSUE_NUMBER  GitHub issue number
#   REPO          owner/repo (default: $GITHUB_REPOSITORY)
#   GH_TOKEN      (or ambient gh auth)
#
# Optional environment variables:
#   DEFAULT_MODEL  Fallback when no override + no heuristic match.
#                  Default: claude-sonnet-4-6.
#   ISSUE_LABELS   Newline- or space-separated labels. If set, skips the
#                  `gh issue view --json labels` call. Used by Layer-1 tests.
#   ISSUE_BODY     Free-form issue title+body string. If set, skips the
#                  `gh issue view --json title,body` call. Used by Layer-1 tests.
#
# Output:
#   Writes `model=<chosen>` and `reason=<text>` to $GITHUB_OUTPUT when set,
#   and prints a one-line `chosen: <model> (<reason>)` summary to stdout.
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

DEFAULT_MODEL="${DEFAULT_MODEL:-claude-sonnet-4-6}"

# --- 1) explicit override label -------------------------------------------

if [[ -z "${ISSUE_LABELS:-}" ]]; then
  ISSUE_LABELS="$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json labels --jq '.labels[].name')"
fi

chosen=''
reason=''
while IFS= read -r label; do
  case "$label" in
    model:opus)   chosen=claude-opus-4-7;    reason='label model:opus' ;;
    model:sonnet) chosen=claude-sonnet-4-6;  reason='label model:sonnet' ;;
    model:haiku)  chosen=claude-haiku-4-5;   reason='label model:haiku' ;;
  esac
done <<< "$ISSUE_LABELS"

# --- 2) heuristic over title+body -----------------------------------------

if [[ -z "$chosen" ]]; then
  if [[ -z "${ISSUE_BODY:-}" ]]; then
    ISSUE_BODY="$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json title,body --jq '.title + "\n" + .body')"
  fi

  if   printf '%s' "$ISSUE_BODY" | grep -qiE 'refactor|redesign|architecture|migrat[ei]|complex|cross-cutting'; then
    chosen=claude-opus-4-7
    reason='heuristic: refactor/architecture keywords'
  elif printf '%s' "$ISSUE_BODY" | grep -qiE 'typo|spelling|grammar|wording|rename|comment-only'; then
    chosen=claude-haiku-4-5
    reason='heuristic: trivial-edit keywords'
  else
    chosen="$DEFAULT_MODEL"
    reason='heuristic: default'
  fi
fi

printf 'chosen: %s (%s)\n' "$chosen" "$reason"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'model=%s\n'  "$chosen" >> "$GITHUB_OUTPUT"
  printf 'reason=%s\n' "$reason" >> "$GITHUB_OUTPUT"
fi
