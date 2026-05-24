#!/usr/bin/env bash
#
# agent-cmd-claude.sh — review-pr.sh AGENT_CMD wrapper for the Claude
# Code CLI. Contract: AGENT_CMD <prompt-file> <result-file>.
#
# Invokes `claude` in headless print mode (`-p`) so the agent's final
# message lands on stdout, then redirects to the caller's result-file.
# CLAUDE_CODE_OAUTH_TOKEN must be in env (read by the CLI directly).
#
# MODEL is optional; if set it becomes a `--model <value>` flag.
set -euo pipefail
IFS=$'\n\t'

prompt="$1"
out="$2"

args=(--print)
[[ -n "${MODEL:-}" ]] && args+=(--model "$MODEL")

claude "${args[@]}" < "$prompt" > "$out"
