#!/usr/bin/env bash
#
# classify-agent.sh — Pick the agent (claude | opencode) for an issue.
# Four-stage decision, same precedence as classify-task.sh:
#
#   1. Explicit override via `agent:claude` / `agent:opencode` label on the
#      issue. This wins over the default and over retry escalation.
#   2. Retry escalation: from ATTEMPT 2 onwards, fall forward to claude. The
#      cheap OpenRouter models carry ordinary work at a better rate than Claude
#      for a fraction of the cost, but when one of them cannot do a job, a
#      second cheap run on the same job is the losing move.
#   3. Fall back to $DEFAULT_AGENT (the workflow input).
#   4. Credential guard, applied last and overriding all of the above: opencode
#      needs an OpenRouter credential, and a label cannot conjure a secret. With
#      none available the run goes to claude rather than dying on
#      ProviderModelNotFoundError.
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
#   ATTEMPT           1-based attempt number for this issue. Default 1.
#   ESCALATE_ON_RETRY "false" disables the attempt-2 escalation. Default true.
#   ESCALATE_AGENT    Agent escalated to on retry. Default claude.
#   HAS_OPENROUTER_KEY  "true"/"false" seam for the credential guard; when
#                  unset it is derived from $OPENROUTER_API_KEY.
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

ATTEMPT="${ATTEMPT:-1}"
ESCALATE_ON_RETRY="${ESCALATE_ON_RETRY:-true}"
ESCALATE_AGENT="${ESCALATE_AGENT:-claude}"

# --- 2) retry escalation ---------------------------------------------------

if [[ -z "$chosen" && "$ESCALATE_ON_RETRY" != "false" ]] && (( ATTEMPT > 1 )); then
  chosen="$ESCALATE_AGENT"
  reason="retry escalation (attempt $ATTEMPT)"
fi

# --- 3) workflow input default ---------------------------------------------

if [[ -z "$chosen" ]]; then
  chosen="$DEFAULT_AGENT"
  reason="workflow input default ($DEFAULT_AGENT)"
fi

# --- 4) credential guard ---------------------------------------------------

has_openrouter_key() {
  if [[ -n "${HAS_OPENROUTER_KEY:-}" ]]; then
    [[ "$HAS_OPENROUTER_KEY" == "true" ]]
    return
  fi
  [[ -n "${OPENROUTER_API_KEY:-}" ]]
}

if [[ "$chosen" == "opencode" ]] && ! has_openrouter_key; then
  chosen=claude
  reason="OPENROUTER_API_KEY unavailable — opencode not runnable, using claude"
fi

printf 'chosen: %s (%s)\n' "$chosen" "$reason"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'agent=%s\n'  "$chosen" >> "$GITHUB_OUTPUT"
  printf 'reason=%s\n' "$reason" >> "$GITHUB_OUTPUT"
fi
