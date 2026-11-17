#!/usr/bin/env bash
#
# agent-cmd-claude-fix.sh — self-fix-pr.sh's default FIX_AGENT_CMD wrapper
# for the Claude Code CLI. Contract: FIX_AGENT_CMD <prompt-file>.
#
# Unlike agent-cmd-claude.sh (review-pr.sh's read-only, JSON-only wrapper),
# this one allows the agent to edit files directly in the current working
# directory — the caller (self-fix-pr.sh) has already checked out the PR
# branch, and commits/pushes afterward. Mirrors the tool allowlist the
# `implement` job already grants Claude for writing the PR in the first
# place (see .github/workflows/agent-implement.yml's "Run Claude Code" step).
#
# MODEL is optional; if set it becomes a `--model <value>` flag. A model on
# the blocked-models.sh denylist is substituted before the flag is built.
#
# stdout/stderr are captured to $RUNNER_TEMP/self-fix-agent-output.log
# (falls back to /tmp) instead of discarded, so a failed fix attempt
# leaves a trace the caller can inspect (#81 review finding 11) — this
# is diagnostics only, it does not change the exit-code contract.
set -euo pipefail
IFS=$'\n\t'

# shellcheck source=scripts/lib/blocked-models.sh disable=SC1091  # hook runs without -x; SC1091 is conventionally suppressed
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/blocked-models.sh"

prompt="$1"

# The chokepoint for FIX_MODEL, which self-fix-loop.sh defaults to the
# caller's review-model — a route that never sees classify-task.sh.
MODEL="$(allowed_model_or_fallback "${MODEL:-}")"

args=(--print --allowedTools 'Edit,Write,Read,Glob,Grep,MultiEdit,Bash')
[[ -n "${MODEL:-}" ]] && args+=(--model "$MODEL")

log="${RUNNER_TEMP:-/tmp}/self-fix-agent-output.log"

# AGENT_WORKSPACE is the driver saying "run this behind the user boundary"
# (#591): in an Azure Pipelines run the fix agent runs as awf-agent, in the
# workspace named here, with the same arguments and the same log.
if [[ -n "${AGENT_WORKSPACE:-}" ]]; then
  # shellcheck source=scripts/lib/agent-boundary.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/agent-boundary.sh"
  boundary_exec_claude "$AGENT_WORKSPACE" "${args[@]}" < "$prompt" > "$log" 2>&1
else
  claude "${args[@]}" < "$prompt" > "$log" 2>&1
fi
