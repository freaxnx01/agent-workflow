#!/usr/bin/env bash
#
# post-run-report.sh — Render and post a metrics comment for a Claude Code run.
#
# Reads the run's result JSON (final SDK result message) and optionally the
# full execution log (NDJSON of all SDK messages), computes summary metrics,
# renders a Markdown comment, and posts it to a GitHub issue. Stamps
# observability labels: ai:done | ai:failed, plus ctx:medium / ctx:high when
# context utilization on any turn crosses a threshold.
#
# Required environment variables:
#   RESULT_FILE       Path to result JSON (final SDK result message).
#   ISSUE_NUMBER      GitHub issue number to comment on.
#   WORKFLOW_RUN_URL  Run URL, e.g. https://github.com/owner/repo/actions/runs/123.
#
# Optional environment variables:
#   EXECUTION_FILE      NDJSON of all SDK messages. Required for "Max context
#                       per turn"; otherwise that row reads 0.
#   REPO                owner/repo (default: $GITHUB_REPOSITORY).
#   CONTEXT_WINDOW_SIZE Token limit used as the % denominator. Default 200000.
#   RENDER_ONLY         If "1", print the rendered comment + label list to
#                       stdout and skip all GitHub API calls. Used by Layer-1
#                       fixture tests.
#
# Exit codes:
#   0   success
#   2   usage error (missing required env var; or missing REPO when posting)
#   64  RESULT_FILE missing or unreadable
#   65  RESULT_FILE not valid JSON
set -euo pipefail
IFS=$'\n\t'

require_env() {
  local var="$1"
  if [[ -z "${!var:-}" ]]; then
    printf 'error: %s must be set\n' "$var" >&2
    exit 2
  fi
}

require_env RESULT_FILE
require_env ISSUE_NUMBER
require_env WORKFLOW_RUN_URL

REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
CONTEXT_WINDOW_SIZE="${CONTEXT_WINDOW_SIZE:-200000}"
RENDER_ONLY="${RENDER_ONLY:-0}"
EXECUTION_FILE="${EXECUTION_FILE:-}"

[[ -r "$RESULT_FILE" ]] || {
  printf 'error: RESULT_FILE not readable: %s\n' "$RESULT_FILE" >&2
  exit 64
}
jq -e . "$RESULT_FILE" >/dev/null 2>&1 || {
  printf 'error: RESULT_FILE is not valid JSON: %s\n' "$RESULT_FILE" >&2
  exit 65
}

# --- formatters -------------------------------------------------------------

format_duration_ms() {
  local total_s=$(( ${1:-0} / 1000 ))
  local m=$(( total_s / 60 ))
  local s=$(( total_s % 60 ))
  if (( m > 0 )); then printf '%dm %ds' "$m" "$s"
  else printf '%ds' "$s"
  fi
}

format_int() {
  # 1234567 -> 1,234,567 (no LANG dependency)
  printf '%s' "$1" | sed -E ':a; s/^([-+]?[0-9]+)([0-9]{3})/\1,\2/; ta'
}

format_usd() {
  awk -v v="$1" 'BEGIN {
    if (v + 0 == 0)        printf "$0.00";
    else if (v + 0 < 0.01) printf "$%.4g", v;
    else                   printf "$%.2f", v;
  }'
}

pct() {
  # pct numerator denominator -> integer percent string ("42")
  awk -v n="$1" -v d="$2" 'BEGIN {
    if (d + 0 == 0) print 0;
    else            printf "%.0f", (n / d) * 100;
  }'
}

# --- read metrics from result JSON ------------------------------------------

read_result_metrics() {
  jq -r '
    .subtype // "unknown",
    (.is_error // false | tostring),
    (.duration_ms // 0 | tostring),
    (.num_turns // 0 | tostring),
    (.total_cost_usd // 0 | tostring),
    (.usage.input_tokens // 0 | tostring),
    (.usage.output_tokens // 0 | tostring),
    (.usage.cache_read_input_tokens // 0 | tostring),
    (.usage.cache_creation_input_tokens // 0 | tostring)
  ' "$RESULT_FILE"
}

{
  read -r SUBTYPE
  read -r IS_ERROR
  read -r DURATION_MS
  read -r NUM_TURNS
  read -r COST_USD
  read -r INPUT_TOKENS
  read -r OUTPUT_TOKENS
  read -r CACHE_READ
  read -r CACHE_CREATE
} < <(read_result_metrics)

# --- per-turn context utilization (optional) --------------------------------

HAS_EXECUTION_DATA=0
MAX_PROMPT_TOKENS=0
if [[ -n "$EXECUTION_FILE" && -r "$EXECUTION_FILE" ]]; then
  HAS_EXECUTION_DATA=1
  # Accept either a JSON array (claude-code-base-action's current shape) or
  # NDJSON (the SDK's --output-format stream-json). Detect and slurp only when
  # needed.
  if jq -e 'type == "array"' "$EXECUTION_FILE" >/dev/null 2>&1; then
    JQ_SLURP=()
  else
    JQ_SLURP=(-s)
  fi
  MAX_PROMPT_TOKENS="$(jq -r "${JQ_SLURP[@]}" '
    [ .[]
      | select(.type == "assistant")
      | (.message.usage // {})
      | ((.input_tokens // 0)
         + (.cache_read_input_tokens // 0)
         + (.cache_creation_input_tokens // 0))
    ] | (max // 0)
  ' "$EXECUTION_FILE")"
fi

# --- derived values ---------------------------------------------------------

CONTEXT_PCT="$(pct "$MAX_PROMPT_TOKENS" "$CONTEXT_WINDOW_SIZE")"
CACHE_DENOM=$(( CACHE_READ + INPUT_TOKENS + CACHE_CREATE ))
CACHE_HIT_PCT="$(pct "$CACHE_READ" "$CACHE_DENOM")"

if [[ "$IS_ERROR" == "true" ]]; then
  STATUS_EMOJI=':x:'
  STATUS_TEXT="failed: ${SUBTYPE}"
  STATUS_LABEL='ai:failed'
  STATUS_LABEL_OPPOSITE='ai:done'
else
  STATUS_EMOJI=':white_check_mark:'
  STATUS_TEXT='success'
  STATUS_LABEL='ai:done'
  STATUS_LABEL_OPPOSITE='ai:failed'
fi

CTX_LABEL=''
if (( HAS_EXECUTION_DATA )); then
  if   (( CONTEXT_PCT >= 75 )); then CTX_LABEL='ctx:high'
  elif (( CONTEXT_PCT >= 50 )); then CTX_LABEL='ctx:medium'
  fi
fi

if (( HAS_EXECUTION_DATA )); then
  CONTEXT_ROW="$(format_int "$MAX_PROMPT_TOKENS") / $(format_int "$CONTEXT_WINDOW_SIZE") (${CONTEXT_PCT}%)"
else
  CONTEXT_ROW="n/a (no execution log provided)"
fi

# --- render comment ---------------------------------------------------------

render_comment() {
  cat <<EOF
## ai-implement run

**Outcome:** ${STATUS_EMOJI} ${STATUS_TEXT}
**Duration:** $(format_duration_ms "$DURATION_MS") · **Turns:** ${NUM_TURNS} · **Cost:** $(format_usd "$COST_USD")

| Metric | Value |
|---|---|
| Input tokens | $(format_int "$INPUT_TOKENS") |
| Output tokens | $(format_int "$OUTPUT_TOKENS") |
| Cache read | $(format_int "$CACHE_READ") (${CACHE_HIT_PCT}% hit rate) |
| Cache create | $(format_int "$CACHE_CREATE") |
| Max context per turn | ${CONTEXT_ROW} |

[View workflow run](${WORKFLOW_RUN_URL})
EOF
}

labels_csv() {
  if [[ -n "$CTX_LABEL" ]]; then
    printf '%s,%s' "$STATUS_LABEL" "$CTX_LABEL"
  else
    printf '%s' "$STATUS_LABEL"
  fi
}

# --- output / post ----------------------------------------------------------

if [[ "$RENDER_ONLY" == "1" ]]; then
  render_comment
  printf '\n---\nLABELS: %s\n' "$(labels_csv)"
  exit 0
fi

[[ -n "$REPO" ]] || {
  printf 'error: REPO or GITHUB_REPOSITORY must be set when posting\n' >&2
  exit 2
}

tmpfile="$(mktemp)"
trap 'rm -f "$tmpfile"' EXIT
render_comment > "$tmpfile"

gh issue comment "$ISSUE_NUMBER" --repo "$REPO" --body-file "$tmpfile"
gh issue edit "$ISSUE_NUMBER" --repo "$REPO" --add-label "$(labels_csv)"
# Best-effort cleanup of stale lifecycle labels from prior runs. Each call
# errors when the label isn't present; that's expected and ignored.
gh issue edit "$ISSUE_NUMBER" --repo "$REPO" --remove-label 'ai:running'         2>/dev/null || true
gh issue edit "$ISSUE_NUMBER" --repo "$REPO" --remove-label "$STATUS_LABEL_OPPOSITE" 2>/dev/null || true
