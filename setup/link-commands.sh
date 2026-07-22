#!/usr/bin/env bash
# setup/link-commands.sh
#
# Link (or copy) agent-workflow's USER-LEVEL operator-console slash commands into
# ~/.claude/commands/ so they work from ANY repo. These are DISTINCT from this
# repo's PROJECT-SCOPED .claude/commands/ (commit, push), which are active
# only inside agent-workflow itself.
#
# Default is COPY, deliberately: the symlink variant points into this repo's
# WORKING TREE, so the console would silently follow whatever branch this checkout
# is on — and vanish entirely on any branch predating the console (see ADR-005's
# hazard note in docs/DECISIONS.md). Copies are pinned until an explicit re-run.
# Trade-off: `git pull` here no longer updates your commands; re-run this script.
# Pass --link to opt back into symlinks while actively editing commands.
# Pass --no-sync to skip the clone/pull and just (re)install from the current
# working tree — used by tests and by config's linker once it has already synced.
#
# Idempotent: re-running refreshes the copies/links. Safe to run on every machine.
#
# Usage (existing machine, repo already cloned):
#   ~/repos/github/freaxnx01/public/agent-workflow/setup/link-commands.sh [--link] [--no-sync]
#
# Usage (new machine, nothing cloned yet — single-line bootstrap):
#   curl -fsSL https://raw.githubusercontent.com/freaxnx01/agent-workflow/main/setup/link-commands.sh | bash

set -euo pipefail

# Transitional: agent-workflow doesn't exist on GitHub / locally until the
REPO_URL="https://github.com/freaxnx01/agent-workflow.git"
REPO_DIR="$HOME/repos/github/freaxnx01/public/agent-workflow"
SRC_DIR="$REPO_DIR/commands"
DEST_DIR="$HOME/.claude/commands"

mode="copy"
sync=1
for arg in "$@"; do
  case "$arg" in
    --copy)    mode="copy" ;;   # accepted for compatibility; already the default
    --link)    mode="link" ;;
    --no-sync) sync=0 ;;
  esac
done

# 1) Clone or fast-forward the agent-workflow repo at the canonical path (unless --no-sync).
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

# 2) Make sure ~/.claude/commands/ exists.
mkdir -p "$DEST_DIR"

# 3) Install each command .md, preserving subdirs (which become /namespace:cmd).
#    Skip any README.md at the top level or inside namespace dirs.
echo "→ installing agent-workflow console commands into $DEST_DIR ($mode)"
while IFS= read -r f; do
  rel="${f#"$SRC_DIR"/}"
  case "$rel" in README.md|*/README.md) continue ;; esac
  dest="$DEST_DIR/$rel"
  mkdir -p "$(dirname "$dest")"
  if [ "$mode" = "copy" ]; then
    rm -f "$dest"        # dest may be a symlink from a prior install → cp would error
    cp -f "$f" "$dest"
    echo "  copied  $rel"
  else
    ln -sfn "$f" "$dest"
    echo "  linked  $rel"
  fi
done < <(find "$SRC_DIR" -type f -name '*.md')

echo "✓ done — agent-workflow console commands installed (e.g. /gh:enrich, /route, /capture-idea)"
