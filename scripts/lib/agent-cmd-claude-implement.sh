#!/usr/bin/env bash
#
# agent-cmd-claude-implement.sh — invoke Claude Code to IMPLEMENT, locally.
# Contract: AGENT_CMD <prompt-file> <result-file>.
#
# WHY THIS EXISTS, separately from agent-cmd-claude.sh. That one is
# review-pr.sh's wrapper: `claude --print` with no tool permissions, which is
# right for a review (read, answer) and useless for an implementation. Pointed at
# an implement prompt it reads the task, cannot write a file, and exits 0 having
# done nothing -- which is exactly what happened on the first real Azure DevOps
# run.
#
# The GitHub job does not use a wrapper at all: it runs the
# anthropics/claude-code-action Action, which owns permissions, tool access and
# the agent loop. There is no Action off GitHub, so this is the local equivalent.
#
# Required environment:
#   CLAUDE_CODE_OAUTH_TOKEN  or an authenticated CLI session
#
# Optional:
#   MODEL       passed as --model; a denylisted id is substituted first
#   MAX_TURNS   passed as --max-turns. Defaults to 80.
#
# PERMISSIONS. Implementation needs to write files and run git, so this passes
# --permission-mode bypassPermissions. That is a real grant: the agent can run
# any tool in the working directory without prompting. It is acceptable here
# because the caller is a human at a terminal in a repo they chose, which is not
# the same trust model as an unattended runner reacting to a public issue. Do not
# reuse this wrapper for anything triggered by untrusted input.
set -euo pipefail
IFS=$'\n\t'

# shellcheck source=scripts/lib/blocked-models.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/blocked-models.sh"

prompt="${1:?agent-cmd-claude-implement.sh requires a prompt file}"
out="${2:?agent-cmd-claude-implement.sh requires a result file}"

MODEL="$(allowed_model_or_fallback "${MODEL:-}")"

# --output-format json, not the default text. classify-failure.sh reads
# .is_error / .subtype / .num_turns off this file and rejects anything that is
# not JSON with exit 65 -- which is precisely how the first real run died, after
# the agent had already done its work.
args=(--print --output-format json
      --permission-mode bypassPermissions
      --max-turns "${MAX_TURNS:-80}")
[[ -n "${MODEL:-}" ]] && args+=(--model "$MODEL")

claude "${args[@]}" < "$prompt" > "$out"
