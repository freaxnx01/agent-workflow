#!/usr/bin/env bash
#
# export-result-output-oversized.sh — stand-in for
# scripts/export-result-output.sh, copied over the workspace copy by
# agent-implement.yml's `evidence_oversized` stub fixture (#592 F9). It plays
# the agent that rewrote the export script, which is the #535 threat itself.
#
# It emits one canonical-looking result whose `result` string is 200000
# characters. The gate's raw-capture step then dies with E2BIG (Linux caps one
# env string at 128 KiB) and the import finds no file. `num_turns: 1` is what
# the payload claims; the gate must still report 0 turns.
#
# Vendored here rather than written from the workflow's YAML through a heredoc:
# a script a YAML step writes at run time is linted by nothing and runnable by
# no test (CLAUDE.md, CI stack: no inline bash over five lines in a YAML step).
#
# Outputs ($GITHUB_OUTPUT, else stdout — same fallback as the real script, so
# the Layer-1 suite can read it from stdout):
#   result-json   the oversized result
#   is-error      always false: the point is evidence that looks fine
# Exit: 0.
set -euo pipefail
IFS=$'\n\t'

emit() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  else
    printf '%s=%s\n' "$1" "$2"
  fi
}

emit result-json "$(jq -nc '{type:"result",subtype:"success",is_error:false,num_turns:1,total_cost_usd:0,usage:{input_tokens:0,output_tokens:0,cache_creation_input_tokens:0,cache_read_input_tokens:0},result:("x" * 200000)}')"
emit is-error false
