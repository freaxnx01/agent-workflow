#!/usr/bin/env bash
#
# check-opencode-model.sh — Preflight for the OpenCode agent path (#518): is
# the chosen model id one OpenRouter lists?
#
# The pipeline declares the run's model to opencode in config
# (opencode-model-config.sh), so opencode accepts ANY id — a typo included —
# and can no longer tell a new model from a wrong one. The authority on "does
# this id exist" is OpenRouter's public model list, so this asks it before the
# agent starts. A missing id is a configuration error, not a failure of the
# issue: instead of letting the run die opaquely, this synthesizes the opencode
# `error` event `opencode run` never got to write, so
# adapt-opencode-result.sh → classify-failure.sh (`model_not_found`) →
# post-run-report.sh degrade as for any other OpenCode failure.
#
# Fails OPEN: when the list cannot be read (after one retry) the run proceeds.
# The list being down says nothing about the model, and stopping there would
# turn an OpenRouter listing outage into a fleet-wide stop.
#
# Required environment variables:
#   OUTPUT_FILE  Path to write the synthesized event to. Must be the same
#                path the `Run OpenCode` step publishes as `execution_file`.
#   MODEL        OpenRouter model id, with or without a leading `openrouter/`.
#
# Optional environment variables:
#   OPENROUTER_MODELS_URL  Default https://openrouter.ai/api/v1/models. Public:
#                          the request carries no credential.
#
# Exit codes:
#   0   the id is listed, or the list could not be read; OUTPUT_FILE untouched
#   2   required env missing
#   65  the id is not listed; error event written to OUTPUT_FILE
set -euo pipefail
IFS=$'\n\t'

if [[ -z "${OUTPUT_FILE:-}" ]]; then
  printf 'error: OUTPUT_FILE must be set\n' >&2
  exit 2
fi
if [[ -z "${MODEL:-}" ]]; then
  printf 'error: MODEL must be set\n' >&2
  exit 2
fi

MODELS_URL="${OPENROUTER_MODELS_URL:-https://openrouter.ai/api/v1/models}"
model="${MODEL#openrouter/}"

# Prints one listed id per line. Non-zero when the request fails or the body is
# not a non-empty `{data: [...]}` — an empty list would otherwise reject every
# model there is.
fetch_model_ids() {
  curl -sS -f --max-time 15 "$MODELS_URL" 2>/dev/null \
    | jq -er '.data | if type == "array" and length > 0 then .[].id else error("not a model list") end' 2>/dev/null
}

ids=''
for _ in 1 2; do
  if ids="$(fetch_model_ids)"; then break; fi
  ids=''
done

if [[ -z "$ids" ]]; then
  printf '::warning::could not read the OpenRouter model list (%s) — model check skipped for %s\n' \
    "$MODELS_URL" "$model"
  exit 0
fi

# Whole-line, fixed-string match. A here-string, not a pipe: `grep -q` exits on
# the first match, and under pipefail the writer's SIGPIPE would read as "not
# listed".
is_listed() { grep -qxF -- "$1" <<< "$ids"; }

# `:nitro` / `:floor` / `:online` are routing shortcuts OpenRouter accepts on
# any id but does not list; `:free` variants are listed as their own ids. So an
# unlisted suffixed id passes when its base id is listed.
if is_listed "$model" || is_listed "${model%%:*}"; then
  printf 'ok: %s is on the OpenRouter model list\n' "$model"
  exit 0
fi

message="Model not found: \`${model}\` is not on OpenRouter's model list (https://openrouter.ai/models), so the run was stopped before the agent started. Fix the \`default-model\` input in the consumer workflow or the \`model:\` label on this issue, then re-dispatch."

# Same NDJSON `error` event shape opencode itself emits under `--format json`,
# so adapt-opencode-result.sh needs no special case.
jq -nc --arg msg "$message" \
  '{type:"error",timestamp:0,sessionID:"opencode-preflight",
    error:{name:"ModelNotFoundError",data:{message:$msg}}}' > "$OUTPUT_FILE"

printf '::error::%s\n' "$message"
exit 65
