#!/usr/bin/env bash
#
# check-auto-review-gate.sh — Decide whether to run the auto-review +
# auto-merge flow for this issue. The flow itself lives in #14 / #15; this
# script only computes the gate so callers can branch on its output.
#
# The gate is `true` iff BOTH:
#   - the workflow input `auto-review` is `true`, AND
#   - the issue carries the `ai-auto-review` label.
#
# Either condition alone is a "no" — the input is a per-repo opt-in, the
# label is a per-issue opt-in. See the auto-merge ADR (#12) for the full
# safety envelope; this script intentionally does NOT enforce the envelope
# (path checks, branch-protection checks, etc.) — that lives in #15.
#
# Required environment variables:
#   ISSUE_NUMBER       GitHub issue number
#   REPO               owner/repo (default: $GITHUB_REPOSITORY)
#   INPUT_AUTO_REVIEW  "true" or "false" — the workflow input value
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
#   2  required env missing or INPUT_AUTO_REVIEW not in {true,false}
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

INPUT_AUTO_REVIEW="${INPUT_AUTO_REVIEW:-false}"
case "$INPUT_AUTO_REVIEW" in
  true|false) ;;
  *)
    printf 'error: INPUT_AUTO_REVIEW must be "true" or "false" (got %q)\n' "$INPUT_AUTO_REVIEW" >&2
    exit 2
    ;;
esac

# --- short-circuit: input off ---------------------------------------------

if [[ "$INPUT_AUTO_REVIEW" != "true" ]]; then
  enabled=false
  reason='workflow input auto-review=false'
else
  # --- input on; check label --------------------------------------------

  if [[ -z "${ISSUE_LABELS:-}" ]]; then
    ISSUE_LABELS="$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json labels --jq '.labels[].name')"
  fi

  has_label=false
  while IFS= read -r label; do
    if [[ "$label" == 'ai-auto-review' ]]; then
      has_label=true
      break
    fi
  done <<< "$ISSUE_LABELS"

  if [[ "$has_label" == 'true' ]]; then
    enabled=true
    reason='input=true AND label ai-auto-review present'
  else
    enabled=false
    reason='input=true but label ai-auto-review missing'
  fi
fi

printf 'enabled=%s (%s)\n' "$enabled" "$reason"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'enabled=%s\n' "$enabled" >> "$GITHUB_OUTPUT"
  printf 'reason=%s\n'  "$reason"  >> "$GITHUB_OUTPUT"
fi
