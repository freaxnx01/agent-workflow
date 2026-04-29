#!/usr/bin/env bash
#
# classify-failure.sh — Read a Claude run's result.json and classify the
# outcome into a retry-policy bucket. Mirrors the pattern from
# classify-task.sh (heuristic now; a Haiku classifier is a future swap-in).
#
# Required environment variables:
#   RESULT_FILE  Path to result.json from the Claude run.
#
# Output (stdout one line; GITHUB_OUTPUT key=value when set):
#   class=success | rate_limit | api_auth | transient | task_failure | bug
#
#   - success      → no retry, post-run-report handles it
#   - rate_limit   → 429 / quota exceeded — retry after delay
#   - api_auth     → 401 / invalid token — operator intervention, no retry
#   - transient    → 5xx / network / timeout — retry with exponential backoff
#   - task_failure → max-turns or similar Claude-side failure — at most one retry
#   - bug          → unclassified is_error=true — no retry, ping operator
#
# Exit codes:
#   0   classification produced (regardless of class)
#   2   RESULT_FILE unset
#   64  RESULT_FILE unreadable
#   65  RESULT_FILE not valid JSON
set -euo pipefail
IFS=$'\n\t'

if [[ -z "${RESULT_FILE:-}" ]]; then
  printf 'error: RESULT_FILE must be set\n' >&2
  exit 2
fi
[[ -r "$RESULT_FILE" ]] || { printf 'error: RESULT_FILE not readable: %s\n' "$RESULT_FILE" >&2; exit 64; }
jq -e . "$RESULT_FILE" >/dev/null 2>&1 || { printf 'error: RESULT_FILE not valid JSON\n' >&2; exit 65; }

is_error="$(jq -r '.is_error // false' "$RESULT_FILE")"
subtype="$(jq -r '.subtype // ""' "$RESULT_FILE")"
result_text="$(jq -r '.result // ""' "$RESULT_FILE")"

if [[ "$is_error" != "true" ]]; then
  class=success
elif printf '%s' "$result_text" | grep -qiE 'rate.?limit|"?429"?|too many requests|quota.?exceed'; then
  class=rate_limit
elif printf '%s' "$result_text" | grep -qiE '"?401"?|invalid.bearer|authentication.error|unauthorized'; then
  class=api_auth
elif printf '%s' "$result_text" | grep -qiE '"?5[0-9]{2}"?|service.unavailable|timeout|econn|network'; then
  class=transient
elif [[ "$subtype" == "error_max_turns" ]]; then
  class=task_failure
else
  class=bug
fi

printf 'class=%s\n' "$class"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'class=%s\n' "$class" >> "$GITHUB_OUTPUT"
fi
