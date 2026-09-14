#!/usr/bin/env bash
#
# agent-cmd-claude.sh — review-pr.sh AGENT_CMD wrapper for the Claude
# Code CLI. Contract: AGENT_CMD <prompt-file> <result-file>.
#
# Invokes `claude` in headless print mode (`-p`) so the agent's final
# message lands on stdout, then redirects to the caller's result-file.
# CLAUDE_CODE_OAUTH_TOKEN must be in env (read by the CLI directly).
#
# MODEL is optional; if set it becomes a `--model <value>` flag. A model on
# the blocked-models.sh denylist is substituted before the flag is built.
set -euo pipefail
IFS=$'\n\t'

# shellcheck source=scripts/lib/blocked-models.sh disable=SC1091  # hook runs without -x; SC1091 is conventionally suppressed
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/blocked-models.sh"

prompt="$1"
out="$2"

# The chokepoint for `review-model`: it does not pass through
# classify-task.sh, so this is where a denylisted id gets substituted.
MODEL="$(allowed_model_or_fallback "${MODEL:-}")"

args=(--print)
[[ -n "${MODEL:-}" ]] && args+=(--model "$MODEL")

claude "${args[@]}" < "$prompt" > "$out"
