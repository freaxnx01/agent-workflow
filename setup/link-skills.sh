#!/usr/bin/env bash
# setup/link-skills.sh
#
# Link (or copy) agent-workflow's USER-LEVEL agent skills into ~/.claude/skills/
# so they resolve from ANY repo. These are DISTINCT from the plugin skills
# published via freaxnx01/agent-skills (installed by /plugin into the plugin
# cache) — the skills here are personal and coupled to this repo's console
# commands, so they ship with the console rather than through the marketplace.
#
# A skill is a DIRECTORY containing SKILL.md (plus any references/ or scripts/),
# so the whole subtree is installed, not a single file.
#
# Default is COPY, deliberately — same reasoning as link-commands.sh: the symlink
# variant points into this repo's WORKING TREE, so a skill would silently follow
# whatever branch this checkout is on, and vanish on any branch predating it.
# Copies are pinned until an explicit re-run.
# Trade-off: `git pull` here no longer updates your skills; re-run this script.
# Pass --link to opt back into symlinks while actively editing a skill.
# Pass --no-sync to skip the clone/pull and just (re)install from the current
# working tree — used by tests and by config's linker once it has already synced.
#
# Idempotent: re-running refreshes the copies/links. Safe to run on every machine.
#
# Usage (existing machine, repo already cloned):
#   ~/repos/github/freaxnx01/public/agent-workflow/setup/link-skills.sh [--link] [--no-sync]
#
# Usage (new machine, nothing cloned yet — single-line bootstrap):
#   curl -fsSL https://raw.githubusercontent.com/freaxnx01/agent-workflow/main/setup/link-skills.sh | bash

set -euo pipefail

REPO_URL="https://github.com/freaxnx01/agent-workflow.git"
REPO_DIR="$HOME/repos/github/freaxnx01/public/agent-workflow"
# Source from THIS script's own checkout, not a $HOME-derived guess: with
# --no-sync the canonical path may not exist (tests, scratch HOME), and a find
# over a missing dir would copy nothing while still reporting success.
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../skills" && pwd)"
DEST_DIR="$HOME/.claude/skills"

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

# 2) Make sure ~/.claude/skills/ exists.
mkdir -p "$DEST_DIR"

# 3) Install each skill file, preserving the skill's directory structure.
#    Skip any README.md at the top level (a skill's own SKILL.md is the entry point).
echo "→ installing agent-workflow skills into $DEST_DIR ($mode)"
installed=0
while IFS= read -r f; do
  rel="${f#"$SRC_DIR"/}"
  case "$rel" in README.md) continue ;; esac
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
  installed=$((installed + 1))
done < <(find "$SRC_DIR" -type f | sort)

if [ "$installed" -eq 0 ]; then
  echo "✗ no skill files found in $SRC_DIR" >&2
  exit 1
fi

echo "✓ done — agent-workflow skills installed (e.g. processing-test-feedback, used by /process-feedback)"
