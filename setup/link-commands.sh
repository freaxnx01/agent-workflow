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
# REPO_DIR is overridable purely as a test seam (tests/run-script-tests.sh drives
# this script against a scratch HOME); normal runs never set it.
REPO_DIR="${REPO_DIR:-$HOME/repos/github/freaxnx01/public/agent-workflow}"
SRC_DIR="$REPO_DIR/commands"
DEST_DIR="$HOME/.claude/commands"
LIB_SRC_DIR="$REPO_DIR/scripts/lib"
LIB_DEST_DIR="$HOME/.claude/scripts/lib"
MANIFEST="$HOME/.claude/.agent-workflow-commands-manifest"

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
declare -A current_rels=()
while IFS= read -r f; do
  rel="${f#"$SRC_DIR"/}"
  case "$rel" in README.md|*/README.md) continue ;; esac
  current_rels["$rel"]=1
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

# 3b) Prune commands THIS installer placed on a prior run that are no longer
#     in source (e.g. removed or merged elsewhere, like the gh:/fj: ->
#     forge-agnostic consolidation, #198/#199) — otherwise a superseded
#     command keeps working forever. Scoped to the manifest from the last run,
#     never to "any *.md under DEST_DIR" — that directory is Claude Code's
#     general user-commands location, not exclusively agent-workflow's, and a
#     file this installer never placed (hand-authored, or from another tool)
#     must never be touched.
if [ -f "$MANIFEST" ]; then
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    [ -n "${current_rels["$rel"]:-}" ] && continue
    rm -f "$DEST_DIR/$rel"
    echo "  removed $rel (no longer in source)"
  done < "$MANIFEST"
fi
printf '%s\n' "${!current_rels[@]}" | sort > "$MANIFEST"

# 4) Install the shared shell helpers that commands source (detect-forge.sh,
#    parse-enrich-args.sh, ...). Installs EVERY *.sh in scripts/lib rather than a
#    named list: a hardcoded single file is why parse-enrich-args.sh shipped in the
#    repo but never reached ~/.claude, breaking /enrich's argument parsing. Copying
#    a helper no command sources is harmless; missing one is not.
mkdir -p "$LIB_DEST_DIR"
for lib_src in "$LIB_SRC_DIR"/*.sh; do
  [ -e "$lib_src" ] || continue    # nullglob is not set; skip the literal pattern
  lib_name="$(basename "$lib_src")"
  lib_dest="$LIB_DEST_DIR/$lib_name"
  if [ "$mode" = "copy" ]; then
    rm -f "$lib_dest"      # dest may be a symlink from a prior install → cp would error
    cp -f "$lib_src" "$lib_dest"
    echo "  copied  scripts/lib/$lib_name"
  else
    ln -sfn "$lib_src" "$lib_dest"
    echo "  linked  scripts/lib/$lib_name"
  fi
done

echo "✓ done — agent-workflow console commands installed (e.g. /enrich, /route, /capture-idea)"
