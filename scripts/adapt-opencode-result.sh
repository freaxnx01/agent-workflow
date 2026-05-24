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
# Assumptions about OpenCode's output (best-effort first cut):
#   - If the file is a single JSON object, treat it as the final
#     result and read the documented fields directly.
#   - If the file is an array, pick the LAST element (mirrors how the
#     Claude path's `select(.type == "result")` works).
#   - If the file is NDJSON, parse the last non-empty line.
#   - On any parse failure, emit a `bug`-bucket result with the raw
#     content as `result` so the operator can diagnose.
#
# When OpenCode's real output format is verified end-to-end (probably
# in #11's sandbox dogfood), the field-name guesses below will need
# updating. Each guess is named in a comment so the swap is local.
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

# Try to coerce the input into a single JSON object regardless of
# whether the file is an object, an array, or NDJSON. The result is
# captured in $payload; if every coercion fails, we emit a bug-class
# result with the raw bytes inlined for debugging.
payload=''
if jq -e 'type == "object"' "$EXECUTION_FILE" >/dev/null 2>&1; then
  payload="$(cat "$EXECUTION_FILE")"
elif jq -e 'type == "array"' "$EXECUTION_FILE" >/dev/null 2>&1; then
  payload="$(jq 'last // {}' "$EXECUTION_FILE")"
else
  # NDJSON: pick the last non-empty line as the canonical result.
  last_line="$(grep -v '^[[:space:]]*$' "$EXECUTION_FILE" | tail -1 || true)"
  if [[ -n "$last_line" ]] && printf '%s' "$last_line" | jq -e . >/dev/null 2>&1; then
    payload="$last_line"
  fi
fi

if [[ -z "$payload" ]]; then
  # Couldn't parse — surface the raw content so classify-failure.sh
  # can bucket and the operator can see what OpenCode produced.
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

# Extract fields from $payload via jq with documented fallbacks.
# Names on the left are the canonical (Claude) keys; names on the
# right are OpenCode's guessed field names (commented). Adjust here
# when OpenCode's actual output is verified.
#
#   subtype        ← .subtype // (.error.type if is_error else "success")
#   is_error       ← .error != null  OR  .is_error  OR  default false
#   duration_ms    ← .duration_ms // (.duration_s * 1000) // 0
#   num_turns      ← .turns // .num_turns // (.messages | length) // 0
#   total_cost_usd ← .cost_usd // .total_cost_usd // 0
#   result         ← .result // .output // (.error.message)
#   usage.*        ← .usage.{prompt,completion,total}_tokens, etc.
#   session_id     ← .session_id // .id // generated placeholder

printf '%s' "$payload" | jq -c \
  --arg model "$MODEL" \
  '{
    type: "result",
    subtype: (
      if (.subtype // null) != null then .subtype
      elif (.is_error // false) or (.error // null) != null then
        ((.error.type // "error_during_execution") | tostring)
      else "success"
      end
    ),
    is_error: ((.is_error // false) or ((.error // null) != null)),
    duration_ms: (
      .duration_ms //
      (if (.duration_s // null) != null then (.duration_s * 1000 | floor) else 0 end)
    ),
    num_turns: (.turns // .num_turns // (.messages // [] | length)),
    total_cost_usd: (.cost_usd // .total_cost_usd // 0),
    session_id: (.session_id // .id // ("opencode-" + ($model | gsub("/"; "-")))),
    result: (
      .result //
      .output //
      (.error.message // null) //
      ""
    ),
    usage: {
      input_tokens:
        (.usage.input_tokens // .usage.prompt_tokens // 0),
      output_tokens:
        (.usage.output_tokens // .usage.completion_tokens // 0),
      cache_creation_input_tokens:
        (.usage.cache_creation_input_tokens // 0),
      cache_read_input_tokens:
        (.usage.cache_read_input_tokens // 0)
    }
  }'
