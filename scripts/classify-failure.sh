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
#   class=success | out_of_credits | rate_limit | api_auth | transient |
#         task_failure | bug
#
#   - success      → no retry, post-run-report handles it
#   - out_of_credits → key limit / credit balance exhausted — pauses the whole
#                    pipeline (scripts/lib/pause-reasons.sh), no retry
#   - rate_limit   → 429 / quota exceeded — retry after delay
#   - api_auth     → 401 / invalid token — operator intervention, no retry
#   - transient    → 5xx / network / timeout / 0-turn model-not-found — retry with exponential backoff
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
num_turns="$(jq -r '.num_turns // ""' "$RESULT_FILE")"

# A terminal `subtype` of error_* is authoritative even when is_error is false:
# the CLI reports `error_max_turns` with `"is_error": false`, so keying off
# is_error alone buckets a turn-budget exhaustion as a success and no retry is
# ever offered. Mirrors the same guard in post-run-report.sh. An error_* subtype
# the regexes below don't recognise falls through to `bug` — operator attention,
# which is the right default for an outcome we cannot name.
if [[ "$is_error" != "true" && "$subtype" != error_* ]]; then
  class=success
elif printf '%s' "$result_text" | grep -qiE 'key limit exceeded|exceeds? your available credits|insufficient credits|requires more credits, or fewer max_tokens'; then
  # Only the provider's own full phrases: this text is the agent's whole result,
  # so loose patterns (`add.credits`, `payment required`) match task prose and
  # would pause a whole consumer repo.
  # Matched BEFORE rate_limit and api_auth, both of which would otherwise claim
  # these texts — OpenRouter reports a monthly key limit as HTTP 403 and an
  # empty balance as 402. Neither is retryable and neither is about this issue:
  # the money ran out, so every dispatch in the repo fails the same way until
  # an operator tops up. That is a pipeline pause, not a per-issue failure
  # (#517, superseding the rate_limit bucketing from #514).
  class=out_of_credits
elif printf '%s' "$result_text" | grep -qiE 'rate.?limit|"?429"?|too many requests|quota.?exceed'; then
  class=rate_limit
elif printf '%s' "$result_text" | grep -qiE '"?401"?|"?403"?|invalid.bearer|authentication.error|unauthorized|invalid.api.key|forbidden|api.key.is.not.set'; then
  # `403` / `forbidden` / `invalid api key` cover OpenRouter auth-fail
  # variants alongside Claude's `401` / `invalid bearer`;
  # `api.key.is.not.set` catches the missing-secret preflight (#164) —
  # an unset key is operator intervention, same as a rejected one.
  class=api_auth
elif printf '%s' "$result_text" | grep -qiE '"?5[0-9]{2}"?|service.unavailable|timeout|econn|network|upstream.error|provider.error'; then
  # `upstream.error` / `provider.error` cover OpenRouter's pass-through
  # failures from the underlying model provider.
  class=transient
elif [[ "$num_turns" == "0" ]] && printf '%s' "$result_text" | grep -qiE 'model not found|ProviderModelNotFoundError'; then
  # opencode resolves the model against a catalog it fetches at startup; when
  # that fetch fails it falls back to a bundled snapshot that may not know a
  # newer model, and dies before the first step (#439). Transient: retry, and
  # escalate-on-retry moves attempt 2 to Claude. The 0-turn guard keeps a
  # mid-run model error in `bug`; api_auth is matched first, so the #164
  # missing-key preflight never lands here.
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
