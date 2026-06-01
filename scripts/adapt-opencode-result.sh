#!/usr/bin/env bash
#
# adapt-opencode-result.sh — Translate OpenCode's run output into the
# canonical `claude-result.json` shape per ADR-001 §2. Mirror role to
# the inline `Adapt execution_file -> result.json` step that handles
# the Claude path. Downstream scripts (classify-failure.sh,
# post-run-report.sh, retry-dispatch.sh) operate purely on the
# canonical shape — they never see "this came from OpenCode".
#
# Required environment variables:
#   EXECUTION_FILE  Path to OpenCode's raw output file.
#
# Optional environment variables:
#   MODEL           OpenRouter model id used for the run (e.g.
#                   `mistralai/mistral-large-latest`). Echoed into
#                   `result` on error so classify-failure.sh has
#                   provenance for bucketing.
#
# Output (stdout):
#   A single JSON object matching the keys ADR-001 §2 requires:
#     type, subtype, is_error, duration_ms, num_turns,
#     total_cost_usd, result, usage{input,output,cache_*}_tokens,
#     session_id
#
# Exit codes:
#   0   adapter ran (output JSON is on stdout even on error paths —
#       the canonical shape encodes success/failure via `is_error`,
#       not via the script's exit code)
#   2   required env missing
#   64  EXECUTION_FILE unreadable
#
# OpenCode output format (verified against opencode-ai@1.15.13 `run --format
# json`): an NDJSON stream of events, each `{type, timestamp, sessionID, ...}`:
#   - step_finish — carries .part.tokens.{input,output,reasoning,cache.{read,
#     write}} and .part.cost. Summed across steps for usage + cost; the count
#     is num_turns.
#   - text        — assistant output; the LAST one's .part.text is the result.
#   - error       — failure; .error.data.message becomes the result and flips
#     is_error. step_start / tool_use are informational.
# On a parse failure (opencode errored before emitting events and wrote plain
# text) we emit an error_during_execution result with the raw bytes inlined so
# classify-failure.sh can bucket it and an operator can diagnose.
set -euo pipefail
IFS=$'\n\t'

if [[ -z "${EXECUTION_FILE:-}" ]]; then
  printf 'error: EXECUTION_FILE must be set\n' >&2
  exit 2
fi
if [[ ! -r "$EXECUTION_FILE" ]]; then
  printf 'error: EXECUTION_FILE not readable: %s\n' "$EXECUTION_FILE" >&2
  exit 64
fi

MODEL="${MODEL:-unknown}"

# OpenCode `--format json` emits an NDJSON stream of events (verified against
# opencode-ai@1.15.13): step_start / tool_use / step_finish / text / error.
# Per-step token usage and cost live on `step_finish` events
# (.part.tokens.{input,output,cache.{read,write}}, .part.cost); the final
# assistant text is the last `text` event (.part.text); failures appear as
# `error` events (.error.data.message). We aggregate the whole stream into the
# canonical (Claude) result shape.
#
# If the file is neither JSON nor NDJSON (opencode errored before emitting any
# events and wrote a plain-text message), fall back to a bug-bucket result with
# the raw bytes inlined so classify-failure.sh can bucket it and an operator can
# diagnose.
if ! jq -e -s 'type == "array"' "$EXECUTION_FILE" >/dev/null 2>&1; then
  raw="$(head -c 4000 "$EXECUTION_FILE" | tr -d '\000')"
  jq -nc \
    --arg model "$MODEL" \
    --arg raw "$raw" \
    '{
      type: "result",
      subtype: "error_during_execution",
      is_error: true,
      duration_ms: 0,
      num_turns: 0,
      total_cost_usd: 0,
      session_id: "opencode-unparseable",
      result: ("OpenCode output was not parseable JSON. Model: " + $model + "\n\nFirst 4KB:\n" + $raw),
      usage: {
        input_tokens: 0,
        output_tokens: 0,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0
      }
    }'
  exit 0
fi

# Aggregate the event stream into the canonical result shape.
jq -s -c \
  --arg model "$MODEL" \
  '
  (map(select(.type == "error")))       as $errs  |
  (map(select(.type == "step_finish"))) as $steps |
  (map(select(.type == "text")))        as $texts |
  (map(.timestamp // empty))            as $ts    |
  {
    type: "result",
    subtype: (if ($errs | length) > 0 then "error_during_execution" else "success" end),
    is_error: (($errs | length) > 0),
    duration_ms: (if ($ts | length) > 0 then (($ts | max) - ($ts | min)) else 0 end),
    num_turns: ($steps | length),
    total_cost_usd: ([ $steps[] | (.part.cost // 0) ] | add // 0),
    session_id: ((.[0].sessionID // null) // ("opencode-" + ($model | gsub("/"; "-")))),
    result: (
      ($texts | last | .part.text)
      // ($errs  | last | .error.data.message)
      // ($errs  | last | .error.name)
      // ""
    ),
    usage: {
      input_tokens:  ([ $steps[] | (.part.tokens.input  // 0) ] | add // 0),
      output_tokens: ([ $steps[] | (.part.tokens.output // 0) ] | add // 0),
      cache_creation_input_tokens: ([ $steps[] | (.part.tokens.cache.write // 0) ] | add // 0),
      cache_read_input_tokens:     ([ $steps[] | (.part.tokens.cache.read  // 0) ] | add // 0)
    }
  }' "$EXECUTION_FILE"
