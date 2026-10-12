#!/usr/bin/env bash
#
# check-openrouter-budget.sh — Read the OpenRouter key's own state and say
# whether the pipeline is about to run out of money.
#
# The alarm in pipeline-pause.sh is reactive: by the time it fires, runs have
# already failed. This is the early warning — scheduled daily
# (.github/workflows/pipeline-health.yml), it reports the key's remaining
# budget while there is still time to top it up (#517).
#
# Two budgets, because either can be the binding one:
#   GET /key      the key's own monthly limit (`limit`, `limit_remaining`).
#                 A key with no limit set is unlimited — nothing to warn about.
#   GET /credits  the account balance behind every key. Needs a management
#                 key; a plain inference key gets 403, which is the normal
#                 case and is tolerated rather than reported as a problem.
#
# Required environment variables:
#   OPENROUTER_API_KEY  The pipeline's key. Passed to curl through a `-K -`
#                       config on stdin, never on argv, and never printed.
#
# Optional environment variables:
#   WARN_KEY_PCT        Warn below this % of the key limit. Default 20.
#   WARN_KEY_USD        Warn below this many USD on the key. Default 3.
#   WARN_ACCOUNT_USD    Warn below this many USD on the account. Default 10.
#   OPENROUTER_API_BASE Default https://openrouter.ai/api/v1.
#
# Output (stdout + GITHUB_OUTPUT when set):
#   verdict=ok | warn | exhausted | unknown
#   message=<one line>
#
# Exit codes:
#   0   a verdict was produced (including `unknown`) — a monitoring check that
#       exits non-zero on an unreadable API just turns into a red daily job
#   2   OPENROUTER_API_KEY unset
set -euo pipefail
IFS=$'\n\t'

if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
  printf 'error: OPENROUTER_API_KEY must be set\n' >&2
  exit 2
fi

WARN_KEY_PCT="${WARN_KEY_PCT:-20}"
WARN_KEY_USD="${WARN_KEY_USD:-3}"
WARN_ACCOUNT_USD="${WARN_ACCOUNT_USD:-10}"
OPENROUTER_API_BASE="${OPENROUTER_API_BASE:-https://openrouter.ai/api/v1}"

cfgfile="$(mktemp)"
trap 'rm -f "$cfgfile"' EXIT
chmod 600 "$cfgfile"
printf 'header = "Authorization: Bearer %s"\n' "$OPENROUTER_API_KEY" > "$cfgfile"

emit() {
  printf '%s=%s\n' "$1" "$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}

# api_get <path> — the response body, or empty on any failure. stderr is
# dropped: curl's verbose errors are not worth the risk of echoing a header.
api_get() {
  curl -sS -f --max-time 15 -K - "${OPENROUTER_API_BASE%/}/$1" \
    < "$cfgfile" 2>/dev/null || printf ''
}

# All arithmetic is in jq: `bc` is not guaranteed on a hosted runner and bash
# cannot compare dollars and cents at all.
key_json="$(api_get key)"
if [[ -z "$key_json" ]] || ! jq -e '.data' <<<"$key_json" >/dev/null 2>&1; then
  emit verdict unknown
  emit message "could not read the OpenRouter key state — check the key and the API"
  exit 0
fi

key_verdict_line="$(jq -r \
  --argjson pct "$WARN_KEY_PCT" --argjson usd "$WARN_KEY_USD" '
  .data as $d
  | ($d.limit // null) as $limit
  | ($d.limit_remaining // null) as $rem
  | if $limit == null or $rem == null then
      "ok|key has no monthly limit (usage $\($d.usage // 0))"
    elif $rem <= 0 then
      "exhausted|key limit reached: $\($d.usage // 0) of $\($limit) used, $\($rem) left"
    elif ($rem * 100) < ($limit * $pct) or $rem < $usd then
      "warn|key budget low: $\($rem) of $\($limit) left"
    else
      "ok|key budget healthy: $\($rem) of $\($limit) left"
    end' <<<"$key_json")"

key_verdict="${key_verdict_line%%|*}"
key_message="${key_verdict_line#*|}"

# 403 here is expected for an inference-only key, so an empty body means "not
# checked", never "nothing left".
account_verdict=ok
account_message=''
credits_json="$(api_get credits)"
if [[ -n "$credits_json" ]] && jq -e '.data' <<<"$credits_json" >/dev/null 2>&1; then
  account_line="$(jq -r --argjson usd "$WARN_ACCOUNT_USD" '
    .data as $d
    | (($d.total_credits // 0) - ($d.total_usage // 0)) as $left
    | if $left < $usd then "warn|account balance low: $\($left) left"
      else "ok|account balance healthy: $\($left) left" end' <<<"$credits_json")"
  account_verdict="${account_line%%|*}"
  account_message="${account_line#*|}"
else
  account_message='account balance not checked (the key cannot read /credits)'
fi

# Worst verdict wins: `exhausted` is already a pause, and a warning on either
# budget is a warning for the pipeline.
verdict=ok
case "$key_verdict" in exhausted) verdict=exhausted ;; warn) verdict=warn ;; esac
[[ "$verdict" == "ok" && "$account_verdict" == "warn" ]] && verdict=warn

emit verdict "$verdict"
emit message "${key_message}; ${account_message}"
