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
# Records the skill names this installer wrote, so a later run can prune the ones
# that disappear upstream without ever touching skills it didn't install.
MANIFEST="$DEST_DIR/.agent-workflow-skills"

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

# 3) Enumerate the skills this checkout ships. A skill is a top-level directory,
#    so a stray README.md beside them is ignored without a special case.
current=()
while IFS= read -r d; do
  current+=("$(basename "$d")")
done < <(find "$SRC_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

if [ "${#current[@]}" -eq 0 ]; then
  echo "✗ no skills found in $SRC_DIR" >&2
  exit 1
fi

# 4) Prune skills we previously installed that no longer exist upstream.
#
#    Unlike a stale slash command, which lies dormant until typed, a stale SKILL.md
#    keeps matching on its description and firing forever — with no upstream file
#    left to edit. So this installer removes what it orphans.
#
#    Only names recorded in OUR OWN manifest are ever removed. A skill you wrote by
#    hand, or one installed by anything else, is never in the manifest and so is
#    never touched.
if [ -f "$MANIFEST" ]; then
  while IFS= read -r name; do
    case "$name" in ''|.|..|*/*) continue ;; esac   # ignore junk; never traverse out
    for c in "${current[@]}"; do [ "$c" = "$name" ] && continue 2; done
    if [ -d "${DEST_DIR:?}/$name" ]; then
      rm -rf -- "${DEST_DIR:?}/$name"
      echo "  pruned  $name (gone upstream)"
    fi
  done < "$MANIFEST"
fi

# 5) Install each skill, refreshing its directory from scratch so a file dropped
#    upstream (a retired references/*.md) doesn't linger inside a surviving skill.
echo "→ installing agent-workflow skills into $DEST_DIR ($mode)"
for name in "${current[@]}"; do
  rm -rf -- "${DEST_DIR:?}/$name"
  while IFS= read -r f; do
    rel="${f#"$SRC_DIR"/}"
    dest="$DEST_DIR/$rel"
    mkdir -p "$(dirname "$dest")"
    if [ "$mode" = "copy" ]; then
      cp -f "$f" "$dest"
      echo "  copied  $rel"
    else
      ln -sfn "$f" "$dest"
      echo "  linked  $rel"
    fi
  done < <(find "$SRC_DIR/$name" -type f | sort)
done

# 6) Record what we installed, so the next run knows what it may prune.
printf '%s\n' "${current[@]}" > "$MANIFEST"

echo "✓ done — agent-workflow skills installed (e.g. processing-test-feedback, used by /process-feedback)"
