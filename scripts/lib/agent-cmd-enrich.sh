#!/usr/bin/env bash
#
# agent-cmd-enrich.sh — autopilot.sh's default ENRICH_CMD wrapper.
#   Contract: ENRICH_CMD <issue-number>
#
# Runs ONE headless quick-mode enrichment of one issue in a nested Claude
# session. The caller (autopilot.sh) has already synced and cd'd into the target
# repo's managed clone, so this inherits the working directory — /enrich commits
# and pushes from there.
#
# Mirrors agent-cmd-claude-fix.sh: `claude --print` with a tool allowlist, the
# prompt on stdin, MODEL passed through the blocked-models denylist first. One
# nested session per issue, never one per run: a single long-lived session would
# share one context across every issue in the batch, and a mid-run context
# exhaustion would lose all of them. See ADR-015.
#
# CLAUDE_CODE_OAUTH_TOKEN must be in the environment (the CLI reads it
# directly). Under systemd that comes from the unit's EnvironmentFile, since a
# --user unit inherits nothing from an interactive shell.
#
# stdout/stderr go to $AUTOPILOT_LOG_DIR/enrich-<n>.log rather than being
# discarded, so a failed enrichment leaves a trace the driver's log line can
# point at. Diagnostics only — it does not change the exit-code contract.
#
# The prompt is fed via a here-string, not a pipe: a pipe under
# `set -o pipefail` reports the rightmost non-zero status, so if `claude`
# exited 0 without draining stdin and the feeding command took SIGPIPE, the
# pipeline would report that command's status instead of the session's.
# `claude` must stay the last command executed so its exit status is this
# script's exit status verbatim.
#
# Exits with the nested session's status; 2 on usage error.
set -euo pipefail
IFS=$'\n\t'

# shellcheck source=scripts/lib/blocked-models.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/blocked-models.sh"

issue="${1:-}"
if ! [[ "$issue" =~ ^[0-9]+$ ]]; then
  printf 'usage: %s <issue-number>\n' "$(basename "$0")" >&2
  exit 2
fi

MODEL="$(allowed_model_or_fallback "${MODEL:-}")"

args=(--print --allowedTools 'Edit,Write,Read,Glob,Grep,MultiEdit,TodoWrite,Bash')
[[ -n "${MODEL:-}" ]] && args+=(--model "$MODEL")

log_dir="${AUTOPILOT_LOG_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$log_dir"

claude "${args[@]}" <<< "/enrich $issue --quick --headless" > "$log_dir/enrich-$issue.log" 2>&1
