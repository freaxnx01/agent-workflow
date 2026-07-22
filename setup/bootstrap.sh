#!/usr/bin/env bash
# setup/bootstrap.sh — one-shot setup of every Claude surface this repo owns.
#
# Clones (or pulls) agent-workflow, then runs all four link steps in order:
#   link-partials  → @-imports into ~/.claude/CLAUDE.md
#   link-commands  → slash commands into ~/.claude/commands/
#   link-hooks     → handoff-resume SessionStart(clear) hook + settings.json wiring
#   link-skills    → personal agent skills into ~/.claude/skills/
#
# No other repo is cloned at any point: this repo owns all Claude content AND its
# provisioning (ADR-007).
#
# Idempotent — safe to re-run to update a machine after a `git pull`.
#
# New machine, nothing cloned yet (single line):
#   curl -fsSL https://raw.githubusercontent.com/freaxnx01/agent-workflow/main/setup/bootstrap.sh | bash
#
# Flags are forwarded verbatim to every step, e.g. --link to symlink commands
# while actively editing them:
#   curl -fsSL .../setup/bootstrap.sh | bash -s -- --link

set -euo pipefail

REPO_URL="https://github.com/freaxnx01/agent-workflow.git"
REPO_DIR="$HOME/repos/github/freaxnx01/public/agent-workflow"

sync=1
for arg in "$@"; do
  case "$arg" in
    --no-sync) sync=0 ;;
  esac
done

# Sync once here; each link step then runs with --no-sync so four consecutive
# pulls don't race the same checkout.
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

bash "$REPO_DIR/setup/link-partials.sh" --no-sync "$@"
bash "$REPO_DIR/setup/link-commands.sh" --no-sync "$@"
bash "$REPO_DIR/setup/link-hooks.sh"    --no-sync "$@"
bash "$REPO_DIR/setup/link-skills.sh"   --no-sync "$@"

echo
echo "✓ bootstrap complete — start a new Claude Code session, then run /commands and /memory to verify."
