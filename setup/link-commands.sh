#!/usr/bin/env bash
# setup/link-commands.sh
#
# Link (or copy) agent-pipeline's USER-LEVEL operator-console slash commands into
# ~/.claude/commands/ so they work from ANY repo. These are DISTINCT from this
# repo's PROJECT-SCOPED .claude/commands/ (commit, push, ui-*), which are active
# only inside agent-pipeline itself.
#
# Default is symlink (a `git pull` here then updates every machine instantly);
# pass --copy where symlinks are awkward (native Windows). Pass --no-sync to skip
# the clone/pull and just (re)link from the current working tree — used by tests
# and by config's linker once it has already synced.
#
# Idempotent: re-running refreshes the links/copies. Safe to run on every machine.
#
# Usage (existing machine, repo already cloned):
#   ~/repos/github/freaxnx01/public/agent-pipeline/setup/link-commands.sh [--copy] [--no-sync]
#
# Usage (new machine, nothing cloned yet — single-line bootstrap):
#   curl -fsSL https://raw.githubusercontent.com/freaxnx01/agent-pipeline/main/setup/link-commands.sh | bash

set -euo pipefail

REPO_URL="https://github.com/freaxnx01/agent-pipeline.git"
REPO_DIR="$HOME/repos/github/freaxnx01/public/agent-pipeline"
SRC_DIR="$REPO_DIR/commands"
DEST_DIR="$HOME/.claude/commands"

mode="link"
sync=1
for arg in "$@"; do
  case "$arg" in
    --copy)    mode="copy" ;;
    --no-sync) sync=0 ;;
  esac
done

# 1) Clone or fast-forward the agent-pipeline repo at the canonical path (unless --no-sync).
if [ "$sync" = 1 ]; then
  if [ ! -d "$REPO_DIR/.git" ]; then
    echo "→ cloning agent-pipeline repo to $REPO_DIR"
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
echo "→ installing agent-pipeline console commands into $DEST_DIR ($mode)"
while IFS= read -r f; do
  rel="${f#"$SRC_DIR"/}"
  case "$rel" in README.md|*/README.md) continue ;; esac
  dest="$DEST_DIR/$rel"
  mkdir -p "$(dirname "$dest")"
  if [ "$mode" = "copy" ]; then
    cp -f "$f" "$dest"
    echo "  copied  $rel"
  else
    ln -sfn "$f" "$dest"
    echo "  linked  $rel"
  fi
done < <(find "$SRC_DIR" -type f -name '*.md')

echo "✓ done — agent-pipeline console commands installed (e.g. /gh:enrich, /route, /capture-idea)"
