#!/usr/bin/env bash
#
# check-preview-gate.sh — Decide whether to run the pre-preview flow for
# this issue. The flow itself lives in the `pre_preview` job; this script
# only computes the gate so callers can branch on its output.
#
# Pre-preview mode (ADR-004 / #77): after the pipeline opens a draft PR,
# the agent reviews it and, on approve, promotes it to ready so a HUMAN
# can merge. It never auto-merges. This gate is the sibling of
# check-auto-review-gate.sh.
#
# The gate is `true` iff BOTH:
#   - the workflow input `pre-preview` is `true`, AND
#   - the issue carries the `ai-pre-preview` label.
#
# Either condition alone is a "no" — the input is a per-repo opt-in, the
# label is a per-issue opt-in. Precedence vs. auto-review (pre-preview
# wins when both are enabled) is enforced in the workflow, not here.
#
# Required environment variables:
#   ISSUE_NUMBER       GitHub issue number
#   REPO               owner/repo (default: $GITHUB_REPOSITORY)
#   INPUT_PRE_PREVIEW  "true" or "false" — the workflow input value
#   GH_TOKEN           (or ambient gh auth)
#
# Optional environment variables:
#   ISSUE_LABELS  Newline- or space-separated labels. If set, skips the
#                 `gh issue view --json labels` call. Used by Layer-1 tests.
#
# Output:
#   Writes `enabled=true|false` and `reason=<text>` to $GITHUB_OUTPUT
#   when set, and prints a one-line `enabled=<bool> (<reason>)` summary
#   to stdout.
#
# Exit codes:
#   0  success
#   2  required env missing or INPUT_PRE_PREVIEW not in {true,false}
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

INPUT_PRE_PREVIEW="${INPUT_PRE_PREVIEW:-false}"
case "$INPUT_PRE_PREVIEW" in
  true|false) ;;
  *)
    printf 'error: INPUT_PRE_PREVIEW must be "true" or "false" (got %q)\n' "$INPUT_PRE_PREVIEW" >&2
    exit 2
    ;;
esac

# --- short-circuit: input off ---------------------------------------------

if [[ "$INPUT_PRE_PREVIEW" != "true" ]]; then
  enabled=false
  reason='workflow input pre-preview=false'
else
  # --- input on; check label --------------------------------------------

  if [[ -z "${ISSUE_LABELS:-}" ]]; then
    ISSUE_LABELS="$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json labels --jq '.labels[].name')"
  fi

  has_label=false
  while IFS= read -r label; do
    if [[ "$label" == 'ai-pre-preview' ]]; then
      has_label=true
      break
    fi
  done <<< "$ISSUE_LABELS"

  if [[ "$has_label" == 'true' ]]; then
    enabled=true
    reason='input=true AND label ai-pre-preview present'
  else
    enabled=false
    reason='input=true but label ai-pre-preview missing'
  fi
fi

printf 'enabled=%s (%s)\n' "$enabled" "$reason"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'enabled=%s\n' "$enabled" >> "$GITHUB_OUTPUT"
  printf 'reason=%s\n'  "$reason"  >> "$GITHUB_OUTPUT"
fi
