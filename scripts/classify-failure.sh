#!/usr/bin/env bash
#
# classify-failure.sh — Read a Claude run's result.json and classify the
# outcome into a retry-policy bucket. Mirrors the pattern from
# classify-task.sh (heuristic now; a Haiku classifier is a future swap-in).
#
# Required environment variables:
#   RESULT_FILE  Path to result.json from the Claude run.
#
# Optional environment variables:
#   OPENROUTER_API_KEY  Lets the classifier confirm a provider refusal
#                       against the budget's own state
#                       (check-openrouter-budget.sh). Unset means "not
#                       confirmed": never out_of_credits.
#
# Output (stdout one line; GITHUB_OUTPUT key=value when set):
#   class=success | out_of_credits | model_not_found | rate_limit | api_auth |
#         transient | task_failure | bug
#
#   - success      → no retry, post-run-report handles it
#   - out_of_credits → the provider refused its OWN call AND the budget check
#                    confirms it: a 402 when it reads exhausted or warn (key
#                    limit or account balance), a 403 only when it reads
#                    exhausted — pauses the whole pipeline
#                    (scripts/lib/pause-reasons.sh), no retry
#   - model_not_found → the model id is not on OpenRouter's list — operator
#                    fixes the id; no retry, not an attempt, one ntfy push
#   - rate_limit   → 429 / quota exceeded, or a provider 402 the budget check
#                    did not confirm — retry after delay
#   - api_auth     → 401 / invalid token, or a provider 403 the budget check
#                    did not confirm (a low budget does not) — operator
#                    intervention, no retry
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

_CF_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${RESULT_FILE:-}" ]]; then
  printf 'error: RESULT_FILE must be set\n' >&2
  exit 2
fi
[[ -r "$RESULT_FILE" ]] || { printf 'error: RESULT_FILE not readable: %s\n' "$RESULT_FILE" >&2; exit 64; }
jq -e . "$RESULT_FILE" >/dev/null 2>&1 || { printf 'error: RESULT_FILE not valid JSON\n' >&2; exit 65; }

is_error="$(jq -r '.is_error // false' "$RESULT_FILE")"
subtype="$(jq -r '.subtype // ""' "$RESULT_FILE")"
result_text="$(jq -r '.result // ""' "$RESULT_FILE")"
# The PROVIDER-CALL EVIDENCE, kept apart from every text channel: the HTTP
# status and the request host of the provider's own failed call, lifted by
# adapt-opencode-result.sh from opencode's `APIError` event. No message text is
# read for out_of_credits — `.result` and `.api_error` both carry words an
# issue author or a tool output can put there, and a pause stops the whole
# repo (#521).
api_status="$(jq -r '.api_error_status // ""' "$RESULT_FILE")"
api_host="$(jq -r '.api_error_host // ""' "$RESULT_FILE")"
# A constant, not derived from OPENROUTER_API_BASE: an env-derived allowlist is
# one more thing to get wrong, and no consumer sets another base (spec A10).
PROVIDER_HOST='openrouter.ai'
num_turns="$(jq -r '.num_turns // ""' "$RESULT_FILE")"

# provider_refused_payment — the provider's own call came back 402 or 403.
# OpenRouter reports an empty balance as 402 and a monthly key limit as 403.
provider_refused_payment() {
  [[ "$api_host" == "$PROVIDER_HOST" ]] || return 1
  [[ "$api_status" == "402" || "$api_status" == "403" ]]
}

# budget_confirms_refusal — the budget's own state backs the refusal
# (#521). One run's error is a claim; this is the check no run can reach.
#   402 → check-openrouter-budget.sh reads `exhausted` or `warn`, on the key
#         limit or the account balance: a forged 402 can only pause a repo
#         whose money is in fact nearly gone.
#   403 → it reads `exhausted`: the key limit is used up (only the key can
#         read `exhausted`). A moderation 403 in a low repo is not a pause.
# Fail safe: no key, an unreadable API, `ok` and `unknown` are all "not
# confirmed". GITHUB_OUTPUT is blanked so the budget script's outputs do not
# become this step's outputs.
budget_confirms_refusal() {
  [[ -n "${OPENROUTER_API_KEY:-}" ]] || return 1
  local verdict
  verdict="$(GITHUB_OUTPUT='' bash "$_CF_HERE/check-openrouter-budget.sh" 2>/dev/null \
    | sed -n 's/^verdict=//p' | head -1)" || return 1
  [[ "$verdict" == "exhausted" ]] && return 0
  [[ "$api_status" == "402" && "$verdict" == "warn" ]]
}

# A terminal `subtype` of error_* is authoritative even when is_error is false:
# the CLI reports `error_max_turns` with `"is_error": false`, so keying off
# is_error alone buckets a turn-budget exhaustion as a success and no retry is
# ever offered. Mirrors the same guard in post-run-report.sh. An error_* subtype
# the regexes below don't recognise falls through to `bug` — operator attention,
# which is the right default for an outcome we cannot name.
if [[ "$is_error" != "true" && "$subtype" != error_* ]]; then
  class=success
elif provider_refused_payment && ! budget_confirms_refusal; then
  # The provider refused its own call, but the budget does not confirm it.
  # Matched BEFORE rate_limit and api_auth, which would otherwise claim these
  # by their text. A 402 is a temporary refusal and retries, as before #517
  # (#514); a real exhaustion is confirmed by the check on the next run. A 403
  # — also one in a repo whose budget only reads low — keeps the pre-#517
  # behaviour: no retry, operator ping (#521).
  if [[ "$api_status" == "402" ]]; then
    class=rate_limit
  else
    class=api_auth
  fi
elif provider_refused_payment; then
  # Evidence AND confirmation: the provider refused its own call and the
  # budget backs it (a 402: exhausted or low; a 403: exhausted). The money
  # ran out (or nearly), so every
  # dispatch in the repo fails the same way until an operator tops up — a
  # pipeline pause, not a per-issue failure (#517, #521). The budget check ran
  # once, in the branch above.
  class=out_of_credits
elif [[ "$num_turns" == "0" ]] && printf '%s' "$result_text" | grep -qiE 'model not found|ProviderModelNotFoundError'; then
  # The model id is not one OpenRouter lists (check-opencode-model.sh's
  # preflight event), or opencode itself could not resolve it. A configuration
  # error on the workflow input or the issue's `model:` label — no retry can
  # fix it and it is not a verdict on the issue (#518, replacing the
  # `transient` bucket from #439: the pipeline now declares the model to
  # opencode, so the catalog miss that bucket retried cannot occur).
  # Matched BEFORE rate_limit, api_auth and transient: those match bare digit
  # runs and this message carries the model id — `mistral-small-2503` contains
  # `503`. The 0-turn guard keeps a mid-run model error in `bug`. The #164
  # missing-key preflight says nothing about a model not being found, so it
  # still reaches api_auth.
  class=model_not_found
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
elif [[ "$subtype" == "error_max_turns" ]]; then
  class=task_failure
else
  class=bug
fi

printf 'class=%s\n' "$class"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'class=%s\n' "$class" >> "$GITHUB_OUTPUT"
fi
