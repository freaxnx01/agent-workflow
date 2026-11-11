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

# Exactly one JSON value: `{..}{..}` would pass a plain `jq -e` on its last one.
is_canonical() {
  printf '%s' "$result_json" | jq -e -s 'length == 1 and (.[0]
    | type == "object" and .type == "result" and (.is_error | type) == "boolean")' >/dev/null 2>&1
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

if is_canonical; then
  printf '%s' "$result_json" | jq . > "$result_file"
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
