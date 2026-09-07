#!/usr/bin/env bash
#
# check-ai-merge-gate.sh — Decide whether to run the AI-review / AI-merge
# flow for this issue. The flow itself lives in the `ai_review_ai_merge`
# job; this script only computes the gate so callers can branch on its
# output.
#
# The flow (ADR-002, renamed by ADR-009): after the pipeline opens a draft
# PR, the agent reviews it and, inside the merge safety envelope,
# auto-merges. Sibling of check-human-merge-gate.sh.
#
# The gate is `true` iff BOTH:
#   - the workflow input `ai-review-ai-merge` is `true`, AND
#   - the issue carries the `ai-review-ai-merge` label.
#
# Either condition alone is a "no" — the input is a per-repo opt-in, the
# label is a per-issue opt-in. This script intentionally does NOT enforce
# the merge envelope (path checks, branch-protection checks); that lives
# in check-merge-envelope.sh per ADR-002.
#
# Deprecated spellings (ADR-009, removed in v3): the input `auto-review`
# and the label `ai-auto-review` are still honoured, each with a
# `::warning::` annotation naming the replacement.
#
# Required environment variables:
#   ISSUE_NUMBER  GitHub issue number
#   REPO          owner/repo (default: $GITHUB_REPOSITORY)
#   GH_TOKEN      (or ambient gh auth)
#
# Optional environment variables:
#   INPUT_AI_REVIEW_AI_MERGE  "true" or "false" (default "false")
#   INPUT_AUTO_REVIEW         deprecated alias of the above
#   ISSUE_LABELS  Newline- or space-separated labels. If set, skips the
#                 `gh issue view --json labels` call. Used by Layer-1 tests.
#
# Output:
#   Writes `enabled=true|false` and `reason=<text>` to $GITHUB_OUTPUT
#   when set, and prints a one-line `enabled=<bool> (<reason>)` summary
#   to stdout. Deprecation warnings precede that line on stdout, because
#   GitHub only parses workflow commands from stdout.
#
# Exit codes:
#   0  success
#   2  required env missing, or an input is not in {true,false}
set -euo pipefail
IFS=$'\n\t'

NEW_INPUT_NAME='ai-review-ai-merge'
OLD_INPUT_NAME='auto-review'
NEW_LABEL='ai-review-ai-merge'
OLD_LABEL='ai-auto-review'

require_env() {
  if [[ -z "${!1:-}" ]]; then
    printf 'error: %s must be set\n' "$1" >&2
    exit 2
  fi
}

require_bool() {
  local name="$1" value="$2"
  case "$value" in
    true|false) ;;
    *)
      printf 'error: %s must be "true" or "false" (got %q)\n' "$name" "$value" >&2
      exit 2
      ;;
  esac
}

require_env ISSUE_NUMBER
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
if [[ -z "$REPO" ]]; then
  printf 'error: REPO or GITHUB_REPOSITORY must be set\n' >&2
  exit 2
fi

INPUT_NEW="${INPUT_AI_REVIEW_AI_MERGE:-false}"
INPUT_OLD="${INPUT_AUTO_REVIEW:-false}"
require_bool INPUT_AI_REVIEW_AI_MERGE "$INPUT_NEW"
require_bool INPUT_AUTO_REVIEW "$INPUT_OLD"

# --- resolve the input, preferring the new spelling -----------------------

input_on=false
if [[ "$INPUT_NEW" == 'true' ]]; then
  input_on=true
elif [[ "$INPUT_OLD" == 'true' ]]; then
  input_on=true
  printf "::warning::workflow input '%s' is deprecated; rename it to '%s' (removed in v3)\n" \
    "$OLD_INPUT_NAME" "$NEW_INPUT_NAME"
fi

# --- short-circuit: input off ---------------------------------------------

if [[ "$input_on" != 'true' ]]; then
  enabled=false
  reason="workflow input ${NEW_INPUT_NAME}=false"
else
  # --- input on; check label --------------------------------------------

  if [[ -z "${ISSUE_LABELS:-}" ]]; then
    ISSUE_LABELS="$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json labels --jq '.labels[].name')"
  fi

  matched_label=''
  while IFS= read -r label; do
    if [[ "$label" == "$NEW_LABEL" ]]; then
      matched_label="$NEW_LABEL"
      break
    fi
    if [[ "$label" == "$OLD_LABEL" ]]; then
      matched_label="$OLD_LABEL"
    fi
  done <<< "$ISSUE_LABELS"

  if [[ "$matched_label" == "$OLD_LABEL" ]]; then
    printf "::warning::issue label '%s' is deprecated; relabel it to '%s' (removed in v3)\n" \
      "$OLD_LABEL" "$NEW_LABEL"
  fi

  if [[ -n "$matched_label" ]]; then
    enabled=true
    reason="input=true AND label ${matched_label} present"
  else
    enabled=false
    reason="input=true but label ${NEW_LABEL} missing"
  fi
fi

printf 'enabled=%s (%s)\n' "$enabled" "$reason"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'enabled=%s\n' "$enabled" >> "$GITHUB_OUTPUT"
  printf 'reason=%s\n'  "$reason"  >> "$GITHUB_OUTPUT"
fi
