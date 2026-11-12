#!/usr/bin/env bash
#
# import-result-output.sh — the gate side of the evidence hand-over (#535,
# ADR-020). Writes the agent job's result back to a file for classify-failure.sh
# / post-run-report.sh, after checking its shape. Anything that is not a
# canonical result object — including an empty value, which is also what GitHub
# leaves when it drops an output it thinks holds a secret — becomes a synthetic
# failure, so a missing result is reported, never silently skipped.
#
# The values arrive as files, not env: the gate's raw-capture step writes them,
# and is the only step carrying the implement job's outputs. An oversized
# output fails that step before it starts (E2BIG), never this one, so a missing
# file is just a missing result (#571).
#
# The result is rebuilt from an allowlist, never copied (#571 N1): the agent can
# write export-result-output.sh, so every value is hostile until typed. Kept are
# only the fields the gate reads (classify-failure.sh, post-run-report.sh, the
# alarm and `Extract job outputs` steps); everything else is dropped. An absent
# or null field stays absent, so its consumer falls back to its own default. A
# present field of the wrong type makes the whole result invalid — a synthetic
# failure, never a nulled field — because a value that reaches `$(( ))` as
# `HOME[$(cmd)]` runs `cmd`, and one with a newline forges `$GITHUB_OUTPUT` lines:
#   type             "result"                  is_error        boolean (required)
#   duration_ms, num_turns, usage.{input,output,cache_read_input,
#     cache_creation_input}_tokens, api_error_status
#                    integer, 0 ≤ n ≤ 2^53 − 1
#   total_cost_usd   number, 0 ≤ n ≤ 2^53 − 1
#   subtype, result, session_id, api_error, api_error_host     string
#   subtype additionally ^[A-Za-z0-9_]{1,64}$: it is an enum and the run marker
#   (ADR-021) and the report read it back line by line.
#   usage            object; its other keys are dropped
#
# Optional env:
#   RESULT_JSON_FILE      file holding export-result-output.sh's result-json
#   EXECUTION_USAGE_FILE  file holding its execution-usage (a usage_aggregate)
#   OUT_DIR               where to write (default $RUNNER_TEMP, else mktemp -d)
#   A missing or unreadable file counts as an empty value.
# Outputs: result-file, execution-file (empty unless a valid usage_aggregate
#          with at least one event arrived), valid
# Exit: 0 always.
set -euo pipefail
IFS=$'\n\t'

OUT_DIR="${OUT_DIR:-${RUNNER_TEMP:-$(mktemp -d)}}"
mkdir -p "$OUT_DIR"
result_file="$OUT_DIR/claude-result.json"
usage_file="$OUT_DIR/execution-usage.json"

emit() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; fi
  printf '%s=%s\n' "$1" "$2"
}

# read_input <path> — the file's content, or nothing when unset or unreadable.
read_input() {
  [[ -n "$1" && -r "$1" ]] || return 0
  cat -- "$1"
}

result_json="$(read_input "${RESULT_JSON_FILE:-}")"
usage_json="$(read_input "${EXECUTION_USAGE_FILE:-}")"

# rebuilt_result — the result rebuilt from its allowlisted, typed fields (see
# the header); nothing unless it is exactly one JSON value (`{..}{..}` would
# pass a plain `jq -e` on its last one) and every kept field has its type.
rebuilt_result() {
  printf '%s' "$result_json" | jq -c -s '
    def count: type == "number" and . >= 0 and . == floor and . <= 9007199254740991;
    def amount: type == "number" and . >= 0 and . <= 9007199254740991;
    def ok(f): . == null or f;
    def present: with_entries(select(.value != null));
    select(length == 1) | .[0]
    | select(type == "object" and .type == "result" and (.is_error | type) == "boolean")
    | select(.usage | ok(type == "object"))
    | {type, subtype, is_error, duration_ms, num_turns, total_cost_usd, session_id,
       result, api_error, api_error_status, api_error_host,
       usage: (.usage | if . == null then null else
         {input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens}
         | present end)}
    | present
    | select(all(.duration_ms, .num_turns, .api_error_status, (.usage // {})[]; ok(count)))
    | select(.total_cost_usd | ok(amount))
    | select(all(.subtype, .result, .session_id, .api_error, .api_error_host; ok(type == "string")))
    | select(.subtype | ok(test("^[A-Za-z0-9_]{1,64}$")))' \
    2>/dev/null || true
}

# rebuilt_aggregate — the usage_aggregate rebuilt from its validated fields only
# (extra fields never pass through); nothing unless every count is a
# non-negative integer and there is at least one event.
rebuilt_aggregate() {
  printf '%s' "$usage_json" | jq -c -s '
    select(length == 1) | .[0]
    | select(type == "object" and .type == "usage_aggregate")
    | {type, events, max_prompt_tokens, input_tokens, output_tokens,
       cache_read_input_tokens, cache_creation_input_tokens}
    | select(all(del(.type)[]; type == "number" and . >= 0 and . == floor))
    | select(.events >= 1)' 2>/dev/null || true
}

write_synthetic() {
  jq -n '{type: "result", subtype: "error_invalid_evidence", is_error: true,
          duration_ms: 0, num_turns: 0, total_cost_usd: 0, session_id: "gate",
          result: "The gate received no valid result evidence from the implement job.",
          usage: {input_tokens: 0, output_tokens: 0,
                  cache_creation_input_tokens: 0, cache_read_input_tokens: 0}}' > "$result_file"
}

result="$(rebuilt_result)"
if [[ -n "$result" ]]; then
  printf '%s' "$result" | jq . > "$result_file"
  valid=true
else
  write_synthetic
  valid=false
  printf '::warning title=No valid result evidence::the implement job handed over no canonical result; reporting the run as failed\n'
fi

execution_file=''
aggregate="$(rebuilt_aggregate)"
if [[ -n "$aggregate" ]]; then
  printf '%s' "$aggregate" > "$usage_file"
  execution_file="$usage_file"
elif [[ -n "$usage_json" ]]; then
  printf '::warning title=Usage evidence dropped::the implement job handed over usage that is not a valid usage_aggregate; the run report falls back to the token counts in the result\n'
fi

emit result-file "$result_file"
emit execution-file "$execution_file"
emit valid "$valid"
