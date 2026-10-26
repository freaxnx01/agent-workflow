#!/usr/bin/env bash
#
# export-result-output.sh — hands an agent job's canonical result to its gate
# job as job outputs (#535, ADR-020). Runs in the implement job AFTER the agent,
# so everything it emits is evidence, not a decision: the gate re-validates it.
#
# Required env:
#   RESULT_FILE       canonical result JSON (ADR-001 §2)
# Optional env:
#   EXECUTION_FILE    raw agent stream (Claude array/NDJSON or opencode NDJSON)
#   RESULT_TEXT_HALF  chars kept from each end of .result (default 4000)
# Outputs ($GITHUB_OUTPUT, else stdout), one line each:
#   result-json       compact result, .result elided; empty if not a JSON object
#   execution-usage   compact array of usage-bearing events only ([] if none)
#   is-error          true|false — a local hint for salvage, never a verdict
# Exit: 0; 2 RESULT_FILE unset.
set -euo pipefail
IFS=$'\n\t'

if [[ -z "${RESULT_FILE:-}" ]]; then
  printf 'error: RESULT_FILE must be set\n' >&2
  exit 2
fi
half="${RESULT_TEXT_HALF:-4000}"

emit() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  else
    printf '%s=%s\n' "$1" "$2"
  fi
}

compact_result() {
  jq -ce --argjson h "$half" '
    select(type == "object")
    | if (.result | type) == "string" and (.result | length) > ($h * 2)
      then .result = (.result[0:$h] + "\n[... elided by export-result-output.sh ...]\n" + .result[-$h:])
      else . end' "$RESULT_FILE" 2>/dev/null || true
}

usage_events() {
  [[ -n "${EXECUTION_FILE:-}" && -r "$EXECUTION_FILE" ]] || { printf '[]'; return; }
  jq -cs '
    (if length == 1 and (.[0] | type) == "array" then .[0] else . end) as $ev
    | [ $ev[] | select(type == "object" and .type == "assistant")
        | {type, message: {usage: (.message.usage // {})}} ]
    + [ $ev[] | select(type == "object" and .type == "step_finish")
        | {type, part: {tokens: (.part.tokens // {})}} ]' \
    "$EXECUTION_FILE" 2>/dev/null || printf '[]'
}

result_json="$(compact_result)"
is_error=true
if [[ -n "$result_json" ]]; then
  is_error="$(printf '%s' "$result_json" | jq -r '(.is_error == true) or ((.subtype // "") | startswith("error_"))')"
fi

emit result-json "$result_json"
emit execution-usage "$(usage_events)"
emit is-error "$is_error"
