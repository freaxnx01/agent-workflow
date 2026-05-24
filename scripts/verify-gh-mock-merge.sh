#!/usr/bin/env bash
#
# verify-gh-mock-merge.sh — Inspect the gh-mock invocation log and emit
# `merge-attempted=true|false` to $GITHUB_OUTPUT. Called by the
# `auto_review` job's final step under stub-review-verdict mode (the
# issue-#16 act test's assertion surface).
#
# The mock log is written by tests/mocks/gh (one space-joined argv line
# per invocation, always exits 0). We grep for an invocation that starts
# with `pr merge ` — exact-match-at-line-start so `pr merge` in any
# other position (e.g. inside a body string) doesn't false-positive.
#
# Required environment variables:
#   GH_MOCK_LOG  Path to the mock log file.
#
# Exit codes:
#   0  evaluated cleanly (merge-attempted reflects the log)
set -euo pipefail
IFS=$'\n\t'

log="${GH_MOCK_LOG:-}"

if [[ -n "$log" && -r "$log" ]] && grep -qE '^pr merge ' "$log"; then
  attempted=true
else
  attempted=false
fi

printf 'merge-attempted=%s\n' "$attempted"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'merge-attempted=%s\n' "$attempted" >> "$GITHUB_OUTPUT"
fi

printf 'gh-mock log contents:\n'
if [[ -r "$log" ]]; then
  cat "$log"
else
  printf '(empty or unreadable)\n'
fi
