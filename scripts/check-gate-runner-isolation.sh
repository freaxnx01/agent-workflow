#!/usr/bin/env bash
#
# check-gate-runner-isolation.sh — fail closed when the gate would share the
# agent's machine (#592 F7, follows #535 / ADR-020).
#
# `gate-runner-labels` defaults to `runner-labels`. On a persistent self-hosted
# runner that puts implement_gate on the machine the agent just had: same
# workspace, same $HOME. A planted git hook or a modified ~/.local/bin tool then
# runs inside the job that judges the run, which is the weakness the separate
# gate job exists to remove. So a self-hosted run must name a gate pool of its
# own — hosted runners, or an ephemeral self-hosted pool that starts clean per
# job — unless the consumer accepts the risk explicitly.
#
# This step is pre-agent and trusted: it runs in the implement job right after
# the pipeline checkout and before any agent step, so a refusal fails the job
# before `agent-eligible` and implement_prefail (ADR-023) reports it.
#
# Required environment variables:
#   RUNNER_LABELS  JSON array of the implement job's runner labels.
#
# Optional environment variables:
#   GATE_RUNNER_LABELS       JSON array for the gate jobs. Empty or `[]` counts
#                            as unset: the workflow expression treats '' as
#                            unset, and `[]` names no runner at all.
#   ALLOW_SHARED_GATE_RUNNER "true" accepts the risk and proceeds with a
#                            warning. Anything else is false.
#
# Exit codes:
#   0  the run is allowed (not self-hosted, a gate pool is named, or opted out)
#   1  refused: self-hosted with no gate pool and no opt-out
#   2  usage: RUNNER_LABELS is not a JSON array of strings
set -euo pipefail
IFS=$'\n\t'

: "${RUNNER_LABELS:?RUNNER_LABELS must be set}"
GATE_RUNNER_LABELS="${GATE_RUNNER_LABELS:-}"
ALLOW_SHARED_GATE_RUNNER="${ALLOW_SHARED_GATE_RUNNER:-false}"

if ! printf '%s' "$RUNNER_LABELS" \
  | jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null 2>&1; then
  printf '::error title=Malformed runner-labels::runner-labels must be a JSON array of strings, got: %s\n' \
    "$RUNNER_LABELS"
  exit 2
fi

# GitHub matches runner labels case-insensitively, so `Self-Hosted` is the same
# label as `self-hosted` and must not slip past the check.
if ! printf '%s' "$RUNNER_LABELS" \
  | jq -e 'any(.[]; ascii_downcase == "self-hosted")' >/dev/null 2>&1; then
  exit 0
fi

gate_named=false
if [[ -n "$GATE_RUNNER_LABELS" ]] \
  && ! printf '%s' "$GATE_RUNNER_LABELS" | jq -e 'type == "array" and length == 0' >/dev/null 2>&1; then
  gate_named=true
fi

if [[ "$gate_named" == true ]]; then
  exit 0
fi

if [[ "$ALLOW_SHARED_GATE_RUNNER" == true ]]; then
  printf "::warning title=Gate shares the agent's runner::allow-shared-gate-runner is set, so the gate jobs run on the same self-hosted pool as the agent; only safe on ephemeral runners that start clean per job (#592)\n"
  exit 0
fi

printf "::error title=Gate shares the agent's runner::runner-labels names a self-hosted pool and gate-runner-labels is empty, so the gate would judge this run on the machine the agent just used; set gate-runner-labels to a hosted or ephemeral pool, or set allow-shared-gate-runner: true to accept the risk (#592)\n"
exit 1
