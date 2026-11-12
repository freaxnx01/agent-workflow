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
#   result-json       compact result, bounded (< 64 KiB): .result elided, the
#                     unread unbounded fields (permission_denials, modelUsage)
#                     dropped; empty if not a JSON object
#   execution-usage   one fixed-size usage_aggregate object (#571), the same
#                     max/sums post-run-report.sh computes from a raw stream;
#                     empty when the stream holds no usage events
#   is-error          true|false — .is_error only, a local hint for salvage, never
#                     a verdict; true too when the result is not a JSON object
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

# The gate gets every value through env:, and Linux caps one env string at
# 128 KiB (#571). Unknown fields can be any size, so past the cap the result is
# cut to the fields the gate's scripts read, each string truncated: .result and
# .api_error to $half characters, the rest to 256. At 4 bytes a character that
# stays near 41 KiB however the strings are encoded. Measured in bytes, since
# MAX_ARG_STRLEN is a byte limit.
max_result_bytes=65536

compact_result() {
  jq -ce --argjson h "$half" '
    select(type == "object")
    | del(.permission_denials, .modelUsage)
    | if (.result | type) == "string" and (.result | length) > ($h * 2)
      then .result = (.result[0:$h] + "\n[... elided by export-result-output.sh ...]\n" + .result[-$h:])
      else . end' "$RESULT_FILE" 2>/dev/null || true
}

essential_result() {
  printf '%s' "$1" | jq -c --argjson h "$half" '
    def cut($n): if type == "string" then .[0:$n] else . end;
    def num: if type == "number" then . else 0 end;
    (if (.usage | type) == "object" then .usage else {} end) as $u
    | { type, subtype, is_error, duration_ms, num_turns, total_cost_usd, session_id,
        result, api_error, api_error_status, api_error_host }
    | with_entries(select(.value != null)
        | (if .key == "result" or .key == "api_error" then $h else 256 end) as $n
        | .value |= cut($n))
    + { usage: { input_tokens: ($u.input_tokens | num), output_tokens: ($u.output_tokens | num),
                 cache_read_input_tokens: ($u.cache_read_input_tokens | num),
                 cache_creation_input_tokens: ($u.cache_creation_input_tokens | num) } }'
}

bounded_result() {
  local json
  json="$(compact_result)"
  if (( $(printf '%s' "$json" | wc -c) < max_result_bytes )); then printf '%s' "$json"; return; fi
  essential_result "$json"
}

# Same formulas as post-run-report.sh's raw-stream path: max per-event prompt
# (input + cache read + cache write) and cumulative totals, Claude
# (assistant/.message.usage) and opencode (step_finish/.part.tokens) alike.
usage_aggregate() {
  [[ -n "${EXECUTION_FILE:-}" && -r "$EXECUTION_FILE" ]] || return 0
  jq -cs '
    def n: if type == "number" then . else 0 end;
    (if length == 1 and (.[0] | type) == "array" then .[0] else . end) as $ev
    | ( [ $ev[] | select(type == "object" and .type == "assistant") | (.message.usage // {})
          | {i: (.input_tokens | n), o: (.output_tokens | n),
             r: (.cache_read_input_tokens | n), c: (.cache_creation_input_tokens | n)} ]
      + [ $ev[] | select(type == "object" and .type == "step_finish") | (.part.tokens // {})
          | {i: (.input | n), o: (.output | n), r: (.cache.read | n), c: (.cache.write | n)} ]
      ) as $u
    | select(($u | length) > 0)
    | {type: "usage_aggregate", events: ($u | length),
       max_prompt_tokens: ([ $u[] | .i + .r + .c ] | max),
       input_tokens: ([ $u[].i ] | add), output_tokens: ([ $u[].o ] | add),
       cache_read_input_tokens: ([ $u[].r ] | add),
       cache_creation_input_tokens: ([ $u[].c ] | add)}' \
    "$EXECUTION_FILE" 2>/dev/null || true
}

result_json="$(bounded_result)"
is_error=true
if [[ -n "$result_json" ]]; then
  is_error="$(printf '%s' "$result_json" | jq -r '.is_error == true')"
fi

emit result-json "$result_json"
emit execution-usage "$(usage_aggregate)"
emit is-error "$is_error"
