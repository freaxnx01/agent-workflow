#!/usr/bin/env bash
#
# post-chain-audit.sh — Render the chain-audit comment template and
# post it on a single candidate issue. Called once per candidate
# (dispatched / capped / paused) by the chain-dispatch workflow.
#
# Required environment variables:
#   REPO              owner/repo
#   ISSUE_NUMBER      Candidate issue to comment on
#   CLOSED_ISSUE      Originating closed issue
#   DECISION          dispatched | capped | paused
#   DEPTH             Current chain depth (integer)
#   MAX_DEPTH         Configured cap (integer)
#   GH_TOKEN          (or ambient gh auth)
#
# Optional:
#   TEMPLATE_FILE     Default: <script-dir>/lib/chain-audit-comment.md
#
# Exit codes:
#   0  comment posted
#   2  required env missing or invalid
set -euo pipefail
IFS=$'\n\t'

for var in REPO ISSUE_NUMBER CLOSED_ISSUE DECISION DEPTH MAX_DEPTH; do
  if [[ -z "${!var:-}" ]]; then
    printf 'error: %s must be set\n' "$var" >&2
    exit 2
  fi
done

case "$DECISION" in
  dispatched|capped|paused) ;;
  *)
    printf 'error: DECISION must be dispatched|capped|paused (got %q)\n' "$DECISION" >&2
    exit 2
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_FILE="${TEMPLATE_FILE:-$SCRIPT_DIR/lib/chain-audit-comment.md}"

if [[ ! -r "$TEMPLATE_FILE" ]]; then
  printf 'error: template not readable: %s\n' "$TEMPLATE_FILE" >&2
  exit 2
fi

# Backticks in these reasons are Markdown code spans rendered into the
# comment body, not command substitutions.
# shellcheck disable=SC2016
case "$DECISION" in
  dispatched) reason='all blockers closed; chain dispatcher fired `gh workflow run` on this issue.' ;;
  capped)     reason="chain depth ${DEPTH} reached the configured cap ${MAX_DEPTH}; refused per ADR-003 §5." ;;
  paused)     reason='kill-switch issue `ai:chain-paused` is open; refused per ADR-003 §4. Close it to lift the pause.' ;;
esac

rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT

awk \
  -v decision="$DECISION" \
  -v depth="$DEPTH" \
  -v max="$MAX_DEPTH" \
  -v closed="$CLOSED_ISSUE" \
  -v reason="$reason" \
  '{
    gsub(/\{\{DECISION\}\}/,     decision)
    gsub(/\{\{DEPTH\}\}/,        depth)
    gsub(/\{\{MAX_DEPTH\}\}/,    max)
    gsub(/\{\{CLOSED_ISSUE\}\}/, closed)
    gsub(/\{\{REASON\}\}/,       reason)
    print
  }' "$TEMPLATE_FILE" > "$rendered"

gh issue comment "$ISSUE_NUMBER" --repo "$REPO" --body-file "$rendered"
