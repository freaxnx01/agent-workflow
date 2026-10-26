#!/usr/bin/env bash
#
# import-result-output.sh — the gate side of the evidence hand-over (#535,
# ADR-020). Writes the agent job's result back to a file for classify-failure.sh
# / post-run-report.sh, after checking its shape. Anything that is not a
# canonical result object — including an empty value, which is also what GitHub
# leaves when it drops an output it thinks holds a secret — becomes a synthetic
# failure, so a missing result is reported, never silently skipped.
#
# Optional env:
#   RESULT_JSON      compact result from export-result-output.sh
#   EXECUTION_USAGE  compact usage array from export-result-output.sh
#   OUT_DIR          where to write (default $RUNNER_TEMP, else mktemp -d)
# Outputs: result-file, execution-file (empty when no usable array), valid
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

is_canonical() {
  printf '%s' "${RESULT_JSON:-}" \
    | jq -e 'type == "object" and .type == "result" and (.is_error | type) == "boolean"' >/dev/null 2>&1
}

write_synthetic() {
  jq -n '{type: "result", subtype: "error_invalid_evidence", is_error: true,
          duration_ms: 0, num_turns: 0, total_cost_usd: 0, session_id: "gate",
          result: "The gate received no valid result evidence from the implement job.",
          usage: {input_tokens: 0, output_tokens: 0,
                  cache_creation_input_tokens: 0, cache_read_input_tokens: 0}}' > "$result_file"
}

if is_canonical; then
  printf '%s' "$RESULT_JSON" | jq . > "$result_file"
  valid=true
else
  write_synthetic
  valid=false
  printf '::warning title=No valid result evidence::the implement job handed over no canonical result; reporting the run as failed\n'
fi

execution_file=''
if printf '%s' "${EXECUTION_USAGE:-}" | jq -e 'type == "array"' >/dev/null 2>&1; then
  printf '%s' "$EXECUTION_USAGE" > "$usage_file"
  execution_file="$usage_file"
fi

emit result-file "$result_file"
emit execution-file "$execution_file"
emit valid "$valid"
