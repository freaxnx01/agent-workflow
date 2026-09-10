#!/usr/bin/env bash
# SessionStart(clear) hook — pairs with the /handoff and /pickup commands.
#
# When you /clear, this looks for the cleared project's handoff and, if there is
# one, injects it as additionalContext so the resume prompt is already loaded
# (you just type /pickup or "go" — no clipboard paste needed).
#
# Handoffs are keyed by branch (.claude/handoff-<branch-slug>.md), because a repo
# with several worktrees checked out has one working copy per branch but a single
# shared file path. So resolve the branch first and read only that branch's file:
# injecting a sibling worktree's saved phase would resume the wrong task, which is
# the exact failure the slugged naming exists to prevent. The pre-slug
# .claude/handoff.md is read only as a fallback.
#
# Wire it up in ~/.claude/settings.json under hooks.SessionStart with
# matcher "clear":
#   { "type": "command", "command": "$HOME/.claude/hooks/handoff-resume.sh" }
#
# A command/skill CANNOT run /clear or auto-send a prompt itself — that's why this
# is a passive context injection, not an auto-trigger.
#
# Exit codes: always 0. A hook that fails blocks the session start, and a missing
# handoff is the normal case, not an error.
set -euo pipefail

input="$(cat)"
dir="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
[ -z "$dir" ] && dir="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -d "$dir" ] || exit 0

# The same slug /handoff writes: branch with "/" replaced by "-", or
# detached-<short sha> when HEAD is detached. No git (or no repo) leaves it empty
# and only the legacy fallback below applies.
slug="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null | tr '/' '-' || true)"
if [ "$slug" = "HEAD" ]; then
  slug="detached-$(git -C "$dir" rev-parse --short HEAD 2>/dev/null || true)"
fi

rel=""
[ -n "$slug" ] && [ -f "$dir/.claude/handoff-$slug.md" ] && rel=".claude/handoff-$slug.md"
[ -z "$rel" ] && [ -f "$dir/.claude/handoff.md" ] && rel=".claude/handoff.md"
[ -n "$rel" ] || exit 0

note="Resume context from a prior /handoff, read from $rel. Open the spec/plan it references and continue, subagent-driven:"
if [ -f "$dir/.claude/handoffs.md" ]; then
  note="$note (other branches' parked handoffs are listed in .claude/handoffs.md.)"
fi

jq -n --rawfile c "$dir/$rel" --arg note "$note" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: ($note + "\n\n" + $c)
  }
}'
