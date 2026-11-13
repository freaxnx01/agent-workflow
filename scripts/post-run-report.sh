#!/usr/bin/env bash
#
# post-run-report.sh — Render and post a metrics comment for a Claude Code run.
#
# Reads the run's result JSON (final SDK result message) and optionally the
# full execution log (NDJSON of all SDK messages), computes summary metrics,
# renders a Markdown comment, and posts it to a GitHub issue. Stamps
# observability labels: ai:done | ai:failed | ai:partial, plus ctx:medium / ctx:high when
# context utilization on any turn crosses a threshold.
#
# Required environment variables:
#   RESULT_FILE       Path to result JSON (final SDK result message).
#   ISSUE_NUMBER      GitHub issue number to comment on.
#   WORKFLOW_RUN_URL  Run URL, e.g. https://github.com/owner/repo/actions/runs/123.
#
# Optional environment variables:
#   EXECUTION_FILE      NDJSON of all SDK messages. Required for "Max context
#                       per turn"; otherwise that row reads 0. May instead
#                       hold one usage_aggregate object (export-result-output.sh,
#                       #571): its max and totals are used as-is.
#   MAX_TURNS           The configured turn budget for this run (e.g.
#                       steps.triage_turns.outputs.turns). When set, the
#                       Turns metric reads "N / cap M" instead of just "N" —
#                       note num_turns can exceed the configured cap and the
#                       run still succeed (the cap is not strictly enforced
#                       by the underlying action), so don't read "N > M" as
#                       a contradiction.
#   REPO                owner/repo (default: $GITHUB_REPOSITORY).
#   CONTEXT_WINDOW_SIZE Token limit used as the % denominator. Default 200000.
#   RENDER_ONLY         If "1", print the rendered comment + label list to
#                       stdout and skip all GitHub API calls. Used by Layer-1
#                       fixture tests.
#   CHECKS_RUNNABLE     "false" when check-pr-checks-runnable.sh determined the
#                       PR's required checks cannot run. Adds a warning block to
#                       the comment and the ai:checks-blocked label. Never
#                       changes the outcome — a blocked run is still a
#                       successful run (#364).
#   CHECKS_BLOCKED_REASON
#                       "no-app-token" | "rollup-empty". Selects the remedy
#                       wording. Only read when CHECKS_RUNNABLE is "false".
#   PLAN_COVERAGE       "complete" | "partial" | "unverifiable", from
#                       check-plan-coverage.sh (#457). "partial" grades the run
#                       ai:partial with :warning: — below an agent error and a
#                       missing PR, above salvaged. "unverifiable" keeps the
#                       grade and adds a "Plan coverage: not checked" line.
#   FAILURE_CLASS       From classify-failure.sh. When it names a class that
#                       pauses the whole pipeline (scripts/lib/pause-reasons.sh),
#                       the report is headed `## ai-implement paused` and no
#                       status label is stamped: the run did no work and the
#                       issue is still queued, so counting it as an attempt
#                       would spend the issue's budget on an empty key (#517).
#                       `model_not_found` (#518) renders `failed: model_not_found`
#                       plus a block naming the model and the fix.
#   MISSING_TASKS       Comma-separated plan task numbers; read when partial.
#   PLAN_COVERAGE_REASON
#                       Why coverage could not be checked; read when unverifiable.
#   ATTEMPT             The cap's lifetime attempt number for this run
#                       (steps.attempt_cap.outputs.attempt). Run marker only
#                       (#585); emitted as `attempt` when this run counts as an
#                       attempt, omitted otherwise — see ADR-021.
#   RETRY_ATTEMPT       Position in the automatic retry chain (inputs.attempt).
#                       Run marker only, as `retry_attempt`. Not the same number
#                       as ATTEMPT: a fresh label dispatch restarts the chain.
#   RETRY_DECISION      "retry" | "stop" from steps.retry.outputs.decision. Run
#                       marker only, as `decision`. Empty when Plan retry was
#                       skipped (no failure class, or success).
#   PR_NUMBER           The run's PR number (steps.verify_pr.outputs.pr-number).
#                       Run marker only, as `pr`.
#   PRE_AGENT_STEP      Name of the step that failed before the agent started
#                       (#597, implement_prefail). When set, the outcome reads
#                       `failed: before the agent started (step: <name>)` and
#                       the marker carries class `pre_agent`. Free text: it is
#                       sanitized and rendered in the visible comment only,
#                       never in the marker (ADR-021 item 4). With 0 turns and
#                       $0.00 in RESULT_FILE the run is a non-start, so it
#                       costs the issue no attempt.
#
# Exit codes:
#   0   success
#   2   usage error (missing required env var; or missing REPO when posting)
#   64  RESULT_FILE missing or unreadable
#   65  RESULT_FILE not valid JSON
set -euo pipefail
IFS=$'\n\t'

# The forge write verbs (#253). Same calls this script made directly; routing
# them through the adapter is what lets the read/write path stop naming a forge.
_PRR_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/detect-forge.sh
source "$_PRR_HERE/lib/detect-forge.sh"
# shellcheck source=scripts/lib/forge.sh
source "$_PRR_HERE/lib/forge.sh"
# The classes that pause the pipeline instead of failing the issue (#517).
# shellcheck source=scripts/lib/pause-reasons.sh
source "$_PRR_HERE/lib/pause-reasons.sh"

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
MAX_TURNS="${MAX_TURNS:-}"   # configured turn budget (steps.triage_turns.outputs.turns) — optional
SALVAGED="${SALVAGED:-}"     # "true" when the PR came from verify-or-recover-pr.sh salvage
HAS_PLAN="${HAS_PLAN:-}"     # "true"/"false": did the issue body carry an "## Implementation Plan"
PLAN_COVERAGE="${PLAN_COVERAGE:-}"                # complete | partial | unverifiable (#457)
MISSING_TASKS="${MISSING_TASKS:-}"                # comma-separated plan task numbers (partial)
PLAN_COVERAGE_REASON="${PLAN_COVERAGE_REASON:-}"  # why coverage was unverifiable
CHECKS_RUNNABLE="${CHECKS_RUNNABLE:-}"              # "false" → checks cannot run (#364)
CHECKS_BLOCKED_REASON="${CHECKS_BLOCKED_REASON:-}"  # no-app-token | rollup-empty
FAILURE_CLASS="${FAILURE_CLASS:-}"                  # classify-failure.sh class (#517)
# Run marker inputs (#585). Nothing visible reads these — see render_run_marker.
ATTEMPT="${ATTEMPT:-}"                 # the cap's lifetime attempt number
RETRY_ATTEMPT="${RETRY_ATTEMPT:-}"     # position in the automatic retry chain
RETRY_DECISION="${RETRY_DECISION:-}"   # retry | stop, from Plan retry
PR_NUMBER="${PR_NUMBER:-}"             # the run's PR number
PRE_AGENT_STEP="${PRE_AGENT_STEP:-}"   # failed step, when the agent never started (#597)

# Sanitized once, here: the name comes from the Actions jobs API, so it is
# workflow-authored rather than agent-authored, but it is still free text in a
# Markdown comment. One line, a conservative character set, 80 chars; a name
# that is nothing but stripped characters reads as `unknown` rather than
# rendering an empty parenthesis.
if [[ -n "$PRE_AGENT_STEP" ]]; then
  PRE_AGENT_STEP="$(printf '%s' "$PRE_AGENT_STEP" \
    | tr '\n\r\t' '   ' | tr -cd 'A-Za-z0-9 ._:()#/-' | cut -c1-80)"
  [[ -n "${PRE_AGENT_STEP// /}" ]] || PRE_AGENT_STEP='unknown'
fi

# Rendered into the comment, and gates the ai:checks-blocked label. Built here
# rather than inside render_comment so labels_csv can test one variable.
#
# Single-quoted and literally multi-line on purpose: backticks are markdown
# code spans, not command substitution, and `$(printf ...)` would strip the
# trailing newline the surrounding blank line needs. Empty renders as the one
# blank line that already separated the table from the run link.
CHECKS_BLOCKED_BLOCK=''
# shellcheck disable=SC2016  # the backticks are markdown code spans in the
# rendered comment, not command substitution — single quotes are the point.
if [[ "$CHECKS_RUNNABLE" == "false" ]]; then
  if [[ "$CHECKS_BLOCKED_REASON" == "rollup-empty" ]]; then
    CHECKS_BLOCKED_BLOCK='
> [!WARNING]
> **Required checks could not run on this PR.**
> A pipeline App token was minted, yet no checks appeared. This is not the
> usual cause — inspect the PR directly. See `docs/PIPELINE-APP-SETUP.md`.
'
  else
    CHECKS_BLOCKED_BLOCK='
> [!WARNING]
> **Required checks could not run on this PR.**
> No `PIPELINE_APP_ID` is configured, so the PR is authored by
> `github-actions` and its checks stall awaiting manual approval — the PR
> stays BLOCKED until someone approves them or pushes to the branch.
> The implementation itself is unaffected. Fix: `docs/PIPELINE-APP-SETUP.md`.
'
  fi
fi

[[ -r "$RESULT_FILE" ]] || {
  printf 'error: RESULT_FILE not readable: %s\n' "$RESULT_FILE" >&2
  exit 64
}
jq -e . "$RESULT_FILE" >/dev/null 2>&1 || {
  printf 'error: RESULT_FILE is not valid JSON: %s\n' "$RESULT_FILE" >&2
  exit 65
}

# #518: a run that stopped on its model gets the fix spelled out — the outcome
# line alone would send the reader to the logs. Same shape as
# CHECKS_BLOCKED_BLOCK (leading and trailing newline) so the two can share one
# line of the comment template and an empty one renders nothing. Reads
# RESULT_FILE, so it is built after the file is known to be valid JSON.
#
# The class has two origins and they need opposite advice: the model-list
# preflight (`check-opencode-model.sh`, session id `opencode-preflight`) means
# the id does not exist and the operator fixes the input or the label; opencode's
# own 0-turn error after that preflight passed means the id IS listed, so the
# injected config entry did not reach opencode and the input is already correct.
MODEL_FIX_BLOCK=''
if [[ "$FAILURE_CLASS" == "model_not_found" ]]; then
  if [[ "$(jq -r '.session_id // ""' "$RESULT_FILE")" == "opencode-preflight" ]]; then
    MODEL_FIX_BLOCK="
> [!WARNING]
> **Model \`${MODEL:-unknown}\` is not on OpenRouter's model list.**
> Set the \`default-model\` input in the consumer workflow, or the \`model:\` label
> on this issue, to an id from <https://openrouter.ai/models>, then re-dispatch.
> The run stopped before the agent started, so it does not count as an attempt.
"
  else
    MODEL_FIX_BLOCK="
> [!WARNING]
> **Model \`${MODEL:-unknown}\` could not be resolved by the agent.**
> The model-list preflight did not reject the id, so the \`default-model\` input
> and the \`model:\` label are likely fine — on the OpenCode path this means the
> model entry the pipeline declares in opencode's config did not take effect.
> Check the \`pipeline-ref\` the consumer workflow pins, then re-dispatch.
> The run did no turns and cost \$0.00, so it does not count as an attempt.
"
  fi
fi

# --- formatters -------------------------------------------------------------

# non_negative_int <value> — the value when it is a plain non-negative integer,
# else 0. Every value read from RESULT_FILE goes through this before shell
# arithmetic: bash evaluates array subscripts there, so `HOME[$(cmd)]` runs
# `cmd` (#571 N1). Valid input is unchanged.
non_negative_int() {
  if [[ "$1" =~ ^[0-9]+$ ]]; then printf '%s' "$1"; else printf '0'; fi
}

format_duration_ms() {
  local total_s=$(( $(non_negative_int "${1:-0}") / 1000 ))
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

# is_usage_aggregate — EXECUTION_FILE holds exactly one usage_aggregate object.
# Checked before the raw-stream detection: a single object is valid NDJSON too,
# and the raw path would sum its zero events into a table of zeros (#571 F3).
is_usage_aggregate() {
  jq -e -s 'length == 1 and (.[0] | type == "object" and .type == "usage_aggregate")' \
    "$EXECUTION_FILE" >/dev/null 2>&1
}

# read_usage_aggregate — "max in out cache_read cache_create", or nothing when
# any field is not a non-negative integer. The file can come from an
# agent-writable tree, so nothing that is not a plain integer may reach the
# shell arithmetic below.
read_usage_aggregate() {
  jq -r -s '
    .[0] as $a
    | [ "max_prompt_tokens", "input_tokens", "output_tokens",
        "cache_read_input_tokens", "cache_creation_input_tokens" ]
    | map($a[.])
    | select(all(.[]; type == "number" and . >= 0 and . == floor))
    | map(tostring) | join(" ")' "$EXECUTION_FILE" 2>/dev/null || true
}

if [[ -n "$EXECUTION_FILE" && -r "$EXECUTION_FILE" ]] && is_usage_aggregate; then
  AGGREGATE="$(read_usage_aggregate)"
  if [[ "$AGGREGATE" =~ ^[0-9]+( [0-9]+){4}$ ]]; then
    HAS_EXECUTION_DATA=1
    IFS=' ' read -r MAX_PROMPT_TOKENS INPUT_TOKENS OUTPUT_TOKENS CACHE_READ CACHE_CREATE <<< "$AGGREGATE"
  fi
elif [[ -n "$EXECUTION_FILE" && -r "$EXECUTION_FILE" ]]; then
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

# The token counts come from RESULT_FILE or the execution file, both
# agent-reachable; only plain integers may reach the arithmetic below (#571 N1).
INPUT_TOKENS="$(non_negative_int "$INPUT_TOKENS")"
OUTPUT_TOKENS="$(non_negative_int "$OUTPUT_TOKENS")"
CACHE_READ="$(non_negative_int "$CACHE_READ")"
CACHE_CREATE="$(non_negative_int "$CACHE_CREATE")"

CONTEXT_PCT="$(pct "$MAX_PROMPT_TOKENS" "$CONTEXT_WINDOW_SIZE")"
CACHE_DENOM=$(( CACHE_READ + INPUT_TOKENS + CACHE_CREATE ))
TOTAL_TOKENS=$(( INPUT_TOKENS + OUTPUT_TOKENS + CACHE_READ + CACHE_CREATE ))

# Optional "Model · Agent" line (#59). Empty when neither is provided.
# Plan is appended when known, so /ai-stats can correlate enrichment with
# shipping. Left off entirely when unset, keeping older reports parseable.
MODEL_AGENT_LINE=''
if [[ -n "$MODEL" || -n "$AGENT" ]]; then
  MODEL_AGENT_LINE="**Model:** ${MODEL:-n/a} · **Agent:** ${AGENT:-n/a}"
  case "$HAS_PLAN" in
    true)  MODEL_AGENT_LINE+=" · **Plan:** enriched" ;;
    false) MODEL_AGENT_LINE+=" · **Plan:** none" ;;
  esac
fi

# Header lines under the Outcome: the model/agent line, then — only when the
# plan could not be checked — a coverage note (#457). Built here so an empty
# coverage note adds no blank line to the comment.
META_LINES="$MODEL_AGENT_LINE"
if [[ "$PLAN_COVERAGE" == "unverifiable" ]]; then
  META_LINES+=$'\n'"**Plan coverage:** not checked — ${PLAN_COVERAGE_REASON:-unknown}"
fi
CACHE_HIT_PCT="$(pct "$CACHE_READ" "$CACHE_DENOM")"

TURNS_TEXT="$NUM_TURNS"
[[ -n "$MAX_TURNS" ]] && TURNS_TEXT="${NUM_TURNS} / cap ${MAX_TURNS}"

# A terminal `subtype` of error_* is authoritative even when is_error is false:
# the CLI reports `error_max_turns` with `"is_error": false`, so keying off the
# flag alone drops the one field that names the cause and falls through to the
# generic no-PR branch below (flowhub#20 run 32883249971 — three dispatches were
# spent reading raw logs for a reason the result JSON already carried).
#
# A pause class is checked first and outranks every grade below (#517): the run
# hit a repo-wide show-stopper — an exhausted API key — so it is not a verdict
# on this issue at all. Heading, outcome and the absent status label all say so,
# and check-attempt-cap.sh's `startswith("## ai-implement run")` then excludes
# the report from both the attempt and the non-start counters by construction.
HEADING='## ai-implement run'
if is_pause_class "$FAILURE_CLASS"; then
  HEADING='## ai-implement paused'
  STATUS_EMOJI=':warning:'
  STATUS_TEXT="paused: $(pause_title "$FAILURE_CLASS") — the issue stays queued"
  STATUS_LABEL=''
elif [[ -n "$PRE_AGENT_STEP" ]]; then
  # #597: the implement job died before the agent started — a toolchain
  # install, a checkout, the token mint. Still `## ai-implement run` + ai:failed
  # so the issue stops reading as "in flight", but RESULT_FILE carries 0 turns
  # and $0.00, which is check-attempt-cap.sh's own non-start rule: it costs the
  # issue no attempt, only one of its MAX_NON_STARTS.
  STATUS_EMOJI=':x:'
  STATUS_TEXT="failed: before the agent started (step: ${PRE_AGENT_STEP})"
  STATUS_LABEL='ai:failed'
elif [[ "$FAILURE_CLASS" == "model_not_found" ]]; then
  # #518: a wrong model id. Still `## ai-implement run` + ai:failed — the run
  # did fail — but it has 0 turns and $0.00, so check-attempt-cap.sh counts it
  # as a non-start, never as an attempt.
  STATUS_EMOJI=':x:'
  STATUS_TEXT='failed: model_not_found'
  STATUS_LABEL='ai:failed'
elif [[ "$IS_ERROR" == "true" || "$SUBTYPE" == error_* ]]; then
  STATUS_EMOJI=':x:'
  STATUS_TEXT="failed: ${SUBTYPE}"
  STATUS_LABEL='ai:failed'
elif [[ "${PR_PRESENT:-}" == "false" ]]; then
  # #100: run finished without error but no PR exists (and recovery, if any,
  # failed). Do not report success — the work is not reviewable.
  STATUS_EMOJI=':x:'
  STATUS_TEXT='failed: run completed but no PR was opened'
  STATUS_LABEL='ai:failed'
elif [[ "$PLAN_COVERAGE" == "partial" ]]; then
  # #457: the session ended cleanly but whole plan tasks have no file in the
  # PR (#430). Not a success — ai-stats counts only :white_check_mark: — and
  # the AI-merge job refuses it on plan-coverage != complete.
  STATUS_EMOJI=':warning:'
  STATUS_TEXT="partial: plan task(s) ${MISSING_TASKS//,/, } have no file in the PR"
  STATUS_LABEL='ai:partial'
elif [[ "${SALVAGED:-}" == "true" ]]; then
  # The run never opened a PR itself; verify-or-recover-pr.sh committed the work
  # it left behind and opened one. Reviewable, but not the same thing as a clean
  # success — say so, or the stats count it as one.
  STATUS_EMOJI=':white_check_mark:'
  STATUS_TEXT='success (salvaged: uncommitted work committed for review)'
  STATUS_LABEL='ai:done'
else
  STATUS_EMOJI=':white_check_mark:'
  STATUS_TEXT='success'
  STATUS_LABEL='ai:done'
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

# --- run marker (#585) ------------------------------------------------------

# One hidden HTML comment at the end of the report, carrying the facts a
# consumer (bridge) would otherwise have to regex out of the Markdown: the
# attempt number, the failure class, the retry decision, the PR. The visible
# report stays byte-identical — an HTML comment does not render, and every
# existing parser matches by prefix or by pattern within the body. Schema,
# versioning and the consumer trust rule: ADR-021 in docs/DECISIONS.md.

# Does check-attempt-cap.sh count this run as an attempt? Answering it here
# keeps consumers from re-implementing the cap's rule and disagreeing with the
# counter that actually parks issues.
run_counts() {
  if is_pause_class "$FAILURE_CLASS"; then
    printf 'false'
    return 0
  fi
  # The cap's non-start rule: no turns AND no cost. awk, not (( )), because
  # cost is a decimal.
  if awk -v t="$NUM_TURNS" -v c="$COST_USD" 'BEGIN { exit !(t + 0 == 0 && c + 0 == 0) }'; then
    printf 'false'
    return 0
  fi
  printf 'true'
}

# The marker object is accumulated as jq arguments plus object entries, so a
# field whose source is empty or malformed is left out of the JSON entirely —
# never emitted as null or 0. Insertion order is the field order in ADR-021.
MARKER_ARGS=()
MARKER_ENTRIES=()

marker_add_string() {  # <key> <value> — emitted when non-empty
  [[ -n "$2" ]] || return 0
  MARKER_ARGS+=(--arg "$1" "$2")
  MARKER_ENTRIES+=("\"$1\": \$$1")
}

marker_add_int() {  # <key> <value> — emitted only for a non-negative integer
  [[ "$2" =~ ^[0-9]+$ ]] || return 0
  MARKER_ARGS+=(--argjson "$1" "$2")
  MARKER_ENTRIES+=("\"$1\": \$$1")
}

marker_add_number() {  # <key> <value> — emitted only for a JSON number
  printf '%s' "$2" | jq -e 'type == "number"' >/dev/null 2>&1 || return 0
  MARKER_ARGS+=(--argjson "$1" "$2")
  MARKER_ENTRIES+=("\"$1\": \$$1")
}

marker_add_json() {  # <key> <literal> — for values that are their own JSON
  MARKER_ARGS+=(--argjson "$1" "$2")
  MARKER_ENTRIES+=("\"$1\": \$$1")
}

render_run_marker() {
  local counts class
  counts="$(run_counts)"
  # #597: a pre-agent failure has no classify-failure.sh class — the agent
  # never ran to produce one. `pre_agent` is an additive enum value, not
  # `transient`: a consumer's retry model must not read "safe to retry" into a
  # toolchain or checkout failure that may well be permanent.
  class="$FAILURE_CLASS"
  [[ -n "$PRE_AGENT_STEP" ]] && class='pre_agent'

  MARKER_ARGS=()
  MARKER_ENTRIES=()
  marker_add_json v 1
  # The cap computes its number before the agent runs, so a non-start or a
  # pause would carry the same number as the next real run. Omitting it means
  # every attempt number appears on exactly one marker.
  if [[ "$counts" == "true" ]]; then
    marker_add_int attempt "$ATTEMPT"
  fi
  marker_add_json counts "$counts"
  marker_add_int retry_attempt "$RETRY_ATTEMPT"
  marker_add_string class "$class"
  marker_add_string decision "$RETRY_DECISION"
  marker_add_string status "$STATUS_LABEL"
  marker_add_string subtype "$SUBTYPE"
  marker_add_string agent "$AGENT"
  marker_add_string model "$MODEL"
  marker_add_int turns "$NUM_TURNS"
  marker_add_int max_turns "$MAX_TURNS"
  marker_add_number cost_usd "$COST_USD"
  marker_add_int duration_ms "$DURATION_MS"
  marker_add_int pr "$PR_NUMBER"
  marker_add_string run_url "$WORKFLOW_RUN_URL"
  marker_add_string plan_coverage "$PLAN_COVERAGE"

  # jq escapes quotes and control characters but not `<` / `>`. Compact JSON
  # has neither outside string values, so replacing both with their JSON
  # escapes is lossless — and it is what makes a `-->` inside a model id
  # unable to close the HTML comment early (ADR-019: run text is never state).
  local json entries
  entries="$(IFS=,; printf '%s' "${MARKER_ENTRIES[*]}")"
  json="$(jq -nc "${MARKER_ARGS[@]}" "{$entries}" \
    | sed -e 's/</\\u003c/g' -e 's/>/\\u003e/g')"
  printf '<!-- ai-run: %s -->' "$json"
}

# --- render comment ---------------------------------------------------------

render_comment() {
  cat <<EOF
${HEADING}

**Outcome:** ${STATUS_EMOJI} ${STATUS_TEXT}
**Duration:** $(format_duration_ms "$DURATION_MS") · **Turns:** ${TURNS_TEXT} · **Cost:** $(format_usd "$COST_USD")
${META_LINES}

| Metric | Value |
|---|---|
| Input tokens | $(format_int "$INPUT_TOKENS") |
| Output tokens | $(format_int "$OUTPUT_TOKENS") |
| Cache read | $(format_int "$CACHE_READ") (${CACHE_HIT_PCT}% hit rate) |
| Cache create | $(format_int "$CACHE_CREATE") |
| Total tokens | $(format_int "$TOTAL_TOKENS") |
| Max context per turn | ${CONTEXT_ROW} |
${CHECKS_BLOCKED_BLOCK}${MODEL_FIX_BLOCK}
[View workflow run](${WORKFLOW_RUN_URL})
$(render_run_marker)
EOF
}

labels_csv() {
  # Built from a list, not by appending to $STATUS_LABEL: a paused run has no
  # status label, and appending would emit a leading comma — `gh issue edit
  # --add-label ,ctx:high` is a 422 (#517).
  local labels=() label
  [[ -n "$STATUS_LABEL" ]] && labels+=("$STATUS_LABEL")
  [[ -n "$CTX_LABEL" ]] && labels+=("$CTX_LABEL")
  # Additive only. A blocked run is still ai:done — the agent did its job and
  # the PR is reviewable; it is the repo that is misconfigured (#364).
  [[ -n "$CHECKS_BLOCKED_BLOCK" ]] && labels+=('ai:checks-blocked')
  local out=''
  for label in ${labels[@]+"${labels[@]}"}; do
    [[ -n "$out" ]] && out+=','
    out+="$label"
  done
  printf '%s' "$out"
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

forge_issue_comment "$ISSUE_NUMBER" "$tmpfile"

LABELS="$(labels_csv)"
[[ -n "$LABELS" ]] && forge_issue_label_add "$ISSUE_NUMBER" "$LABELS"
# Best-effort cleanup of stale lifecycle labels from prior runs. Each call
# errors when the label isn't present; that's expected and ignored.
forge_issue_label_remove "$ISSUE_NUMBER" 'ai:running'         2>/dev/null || true

# Exactly one status label survives: a re-run that changes the grade must not
# leave two grades on the issue (#457 added a third). A paused run has no grade
# to stamp and must not clear the previous one either — it did no work, so the
# last real run's verdict is still the truth about this issue (#517).
if [[ -n "$STATUS_LABEL" ]]; then
  for stale_label in ai:done ai:failed ai:partial; do
    [[ "$stale_label" == "$STATUS_LABEL" ]] && continue
    forge_issue_label_remove "$ISSUE_NUMBER" "$stale_label" 2>/dev/null || true
  done
fi
