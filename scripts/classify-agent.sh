#!/usr/bin/env bash
#
# classify-agent.sh — Pick the agent (claude | opencode) for an issue.
# Two-stage decision, same precedence as classify-task.sh:
#
#   1. Explicit override via `agent:claude` / `agent:opencode` label on the
#      issue. This always wins.
#   2. Fall back to $DEFAULT_AGENT (the workflow input).
#
# See docs/DECISIONS.md ADR-001 for the contract this script implements.
#
# Required environment variables:
#   ISSUE_NUMBER  GitHub issue number
#   REPO          owner/repo (default: $GITHUB_REPOSITORY)
#   GH_TOKEN      (or ambient gh auth)
#
# Optional environment variables:
#   DEFAULT_AGENT  Fallback when no override label is present.
#                  Default: claude. Must be one of: claude | opencode.
#   ISSUE_LABELS   Newline- or space-separated labels. If set, skips the
#                  `gh issue view --json labels` call. Used by Layer-1 tests.
#
# Output:
#   Writes `agent=<chosen>` and `reason=<text>` to $GITHUB_OUTPUT when set,
#   and prints a one-line `chosen: <agent> (<reason>)` summary to stdout.
#
# Exit codes:
#   0  success
#   2  required env missing or DEFAULT_AGENT invalid
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

DEFAULT_AGENT="${DEFAULT_AGENT:-claude}"
case "$DEFAULT_AGENT" in
  claude|opencode) ;;
  *)
    printf 'error: DEFAULT_AGENT must be one of: claude | opencode (got %q)\n' "$DEFAULT_AGENT" >&2
    exit 2
    ;;
esac

# --- 1) explicit override label -------------------------------------------

if [[ -z "${ISSUE_LABELS:-}" ]]; then
  ISSUE_LABELS="$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json labels --jq '.labels[].name')"
fi

chosen=''
reason=''
while IFS= read -r label; do
  case "$label" in
    agent:claude)   chosen=claude;   reason='label agent:claude' ;;
    agent:opencode) chosen=opencode; reason='label agent:opencode' ;;
  esac
done <<< "$ISSUE_LABELS"

# --- 2) fall back to workflow input ---------------------------------------

if [[ -z "$chosen" ]]; then
  chosen="$DEFAULT_AGENT"
  reason="workflow input default ($DEFAULT_AGENT)"
fi

printf 'chosen: %s (%s)\n' "$chosen" "$reason"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'agent=%s\n'  "$chosen" >> "$GITHUB_OUTPUT"
  printf 'reason=%s\n' "$reason" >> "$GITHUB_OUTPUT"
fi
