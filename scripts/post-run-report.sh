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
MODEL="${MODEL:-}"   # resolved model (steps.triage.outputs.model) — optional
AGENT="${AGENT:-}"   # resolved agent (steps.classify_agent.outputs.agent) — optional

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
  # Accept either a JSON array (claude-code-base-action's current shape) or
  # NDJSON (the SDK's --output-format stream-json). Detect the shape first; if
  # the file is neither valid JSON nor valid NDJSON, skip the context metric and
  # degrade to "n/a" rather than crashing the entire report. The OpenCode path
  # passes the raw opencode output as EXECUTION_FILE, which is plain text (not
  # JSON) whenever opencode itself errored — that unguarded jq is what failed
  # the whole run in #58.
  JQ_SLURP=()
  EXEC_PARSEABLE=0
  if jq -e 'type == "array"' "$EXECUTION_FILE" >/dev/null 2>&1; then
    JQ_SLURP=()
    EXEC_PARSEABLE=1
  elif jq -e -s '.' "$EXECUTION_FILE" >/dev/null 2>&1; then
    JQ_SLURP=(-s)
    EXEC_PARSEABLE=1
  fi
  if (( EXEC_PARSEABLE )); then
    HAS_EXECUTION_DATA=1
    MAX_PROMPT_TOKENS="$(jq -r "${JQ_SLURP[@]}" '
      (
        # Claude (claude-code-base-action): assistant messages carry usage.
        [ .[]
          | select(.type == "assistant")
          | (.message.usage // {})
          | ((.input_tokens // 0)
             + (.cache_read_input_tokens // 0)
             + (.cache_creation_input_tokens // 0))
        ]
        # OpenCode (--format json): step_finish events carry .part.tokens.
        + [ .[]
            | select(.type == "step_finish")
            | (.part.tokens // {})
            | ((.input // 0)
               + ((.cache.read) // 0)
               + ((.cache.write) // 0))
          ]
      ) | (max // 0)
    ' "$EXECUTION_FILE" 2>/dev/null || printf '0')"

    # Cumulative token totals across all turns (#53). result.json's usage is
    # only the LAST turn for the Claude path (claude-code-base-action), so the
    # raw values are misleading on multi-turn runs. Sum the execution stream for
    # true totals — handling both Claude (assistant/message.usage) and OpenCode
    # (step_finish/part.tokens) shapes — and override the last-turn values.
    CUM="$(jq -r "${JQ_SLURP[@]}" '
      def cl: [ .[] | select(.type == "assistant")    | (.message.usage // {}) ];
      def oc: [ .[] | select(.type == "step_finish")   | (.part.tokens  // {}) ];
        ( ([ cl[] | (.input_tokens // 0) ]               | add // 0)
        + ([ oc[] | (.input // 0) ]                       | add // 0) ) as $in
      | ( ([ cl[] | (.output_tokens // 0) ]              | add // 0)
        + ([ oc[] | (.output // 0) ]                      | add // 0) ) as $out
      | ( ([ cl[] | (.cache_read_input_tokens // 0) ]    | add // 0)
        + ([ oc[] | (.cache.read // 0) ]                  | add // 0) ) as $cr
      | ( ([ cl[] | (.cache_creation_input_tokens // 0) ]| add // 0)
        + ([ oc[] | (.cache.write // 0) ]                 | add // 0) ) as $cc
      | "\($in) \($out) \($cr) \($cc)"
    ' "$EXECUTION_FILE" 2>/dev/null || printf '')"
    if [[ -n "$CUM" ]]; then
      # Script-level IFS is $'\n\t'; CUM is space-separated, so split on space.
      IFS=' ' read -r INPUT_TOKENS OUTPUT_TOKENS CACHE_READ CACHE_CREATE <<< "$CUM"
    fi
  fi
fi

# --- derived values ---------------------------------------------------------

CONTEXT_PCT="$(pct "$MAX_PROMPT_TOKENS" "$CONTEXT_WINDOW_SIZE")"
CACHE_DENOM=$(( CACHE_READ + INPUT_TOKENS + CACHE_CREATE ))
TOTAL_TOKENS=$(( INPUT_TOKENS + OUTPUT_TOKENS + CACHE_READ + CACHE_CREATE ))

# Optional "Model · Agent" line (#59). Empty when neither is provided.
MODEL_AGENT_LINE=''
if [[ -n "$MODEL" || -n "$AGENT" ]]; then
  MODEL_AGENT_LINE="**Model:** ${MODEL:-n/a} · **Agent:** ${AGENT:-n/a}"
fi
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
${MODEL_AGENT_LINE}

| Metric | Value |
|---|---|
| Input tokens | $(format_int "$INPUT_TOKENS") |
| Output tokens | $(format_int "$OUTPUT_TOKENS") |
| Cache read | $(format_int "$CACHE_READ") (${CACHE_HIT_PCT}% hit rate) |
| Cache create | $(format_int "$CACHE_CREATE") |
| Total tokens | $(format_int "$TOTAL_TOKENS") |
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
