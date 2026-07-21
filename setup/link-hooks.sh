#!/usr/bin/env bash
# setup/link-hooks.sh
#
# Install agent-workflow's Claude Code hooks: copy each script to ~/.claude/hooks/
# AND wire it into ~/.claude/settings.json.
#
# Hooks are always COPIED, never symlinked. settings.json references the INSTALLED
# path ($HOME/.claude/hooks/<name>.sh), not this repo — so the copy is what runs,
# and a checkout on any branch cannot change hook behaviour underfoot. Same
# reasoning as link-commands.sh's --copy default (ADR-006 hazard note).
#
# Idempotent: re-running refreshes the scripts and is a no-op on settings.json if
# the hook is already wired. settings.json is backed up before any edit and left
# untouched if it is not valid JSON. Needs jq (also required by the hook at runtime).
#
# Usage (existing machine, repo already cloned):
#   ~/repos/github/freaxnx01/public/agent-workflow/setup/link-hooks.sh [--no-sync]
#
# Usage (new machine, nothing cloned yet — single-line bootstrap):
#   curl -fsSL https://raw.githubusercontent.com/freaxnx01/agent-workflow/main/setup/link-hooks.sh | bash

set -euo pipefail
IFS=$'\n\t'

REPO_URL="https://github.com/freaxnx01/agent-workflow.git"
REPO_DIR="$HOME/repos/github/freaxnx01/public/agent-workflow"
# Source from THIS script's own checkout, not a $HOME-derived guess: with
# --no-sync the canonical path may not exist (tests, scratch HOME), and a find
# over a missing dir would copy nothing while still reporting success.
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"
HOOK_DIR="$HOME/.claude/hooks"
SETTINGS="$HOME/.claude/settings.json"

sync=1
for arg in "$@"; do
  case "$arg" in
    --no-sync) sync=0 ;;
  esac
done

command -v jq >/dev/null 2>&1 || {
  echo "✗ jq is required (the handoff-resume hook needs it at runtime)" >&2
  exit 1
}

# 1) Clone or fast-forward at the canonical path (unless --no-sync).
if [ "$sync" = 1 ]; then
  if [ ! -d "$REPO_DIR/.git" ]; then
    echo "→ cloning agent-workflow repo to $REPO_DIR"
    mkdir -p "$(dirname "$REPO_DIR")"
    git clone "$REPO_URL" "$REPO_DIR"
  else
    echo "→ pulling latest at $REPO_DIR"
    git -C "$REPO_DIR" pull --ff-only
  fi
fi

mkdir -p "$HOOK_DIR"

# 2) Copy each hook script into place.
mapfile -t hook_files < <(find "$SRC_DIR" -type f -name '*.sh' | sort)
if [ ${#hook_files[@]} -eq 0 ]; then
  echo "✗ no hook scripts found in $SRC_DIR" >&2
  exit 1
fi

echo "→ installing hooks into $HOOK_DIR"
for src in "${hook_files[@]}"; do
  name="$(basename "$src")"
  cp -f "$src" "$HOOK_DIR/$name"
  chmod +x "$HOOK_DIR/$name"
  echo "  copied  $name"
done

# 3) Wire handoff-resume into settings.json as a SessionStart(clear) hook.
# shellcheck disable=SC2016  # literal $HOME is intended: settings.json stores the
# unexpanded path so the same file works across machines and users.
CMD='$HOME/.claude/hooks/handoff-resume.sh'

if [ ! -f "$SETTINGS" ]; then
  printf '{}\n' > "$SETTINGS"
fi

if ! jq empty "$SETTINGS" >/dev/null 2>&1; then
  echo "⚠ $SETTINGS is not valid JSON — leaving it untouched." >&2
  echo "  Wire the hook manually: SessionStart matcher \"clear\" → $CMD" >&2
  exit 0
fi

# Match by script BASENAME, not the exact command string: an existing entry
# written with an absolute path (or a different $HOME spelling) still counts as
# present. Exact-string matching would inject a near-duplicate and fire the
# resume hook twice. Ported from config's 02-claude-hooks.sh, which got this right.
present='([ (.hooks.SessionStart // [])[] | select(.matcher? == "clear") | .hooks[]? | .command? | select(. != null) | select(test("handoff-resume\\.sh")) ] | length) > 0'
if jq -e "$present" "$SETTINGS" >/dev/null 2>&1; then
  echo "  settings.json already wires the hook — no change"
else
  cp -f "$SETTINGS" "$SETTINGS.bak"
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  jq --arg cmd "$CMD" '
    .hooks //= {} |
    .hooks.SessionStart //= [] |
    .hooks.SessionStart += [{
      "matcher": "clear",
      "hooks": [{ "type": "command", "command": $cmd }]
    }]
  ' "$SETTINGS" > "$tmp"
  mv "$tmp" "$SETTINGS"
  trap - EXIT
  echo "  settings.json wired (backup: $SETTINGS.bak)"
fi

echo "✓ done — hooks installed (handoff-resume fires on SessionStart after /clear)"
