#!/usr/bin/env bash
# setup/link-partials.sh
#
# Install agent-workflow's CLAUDE.md partials by @-importing them into the
# user-level ~/.claude/CLAUDE.md.
#
# Idempotent: re-running rewrites the marker block in place, byte-for-byte.
# All unrelated user content is preserved verbatim and in order.
#
# MIGRATION (remove once every machine has run this at least once): this script
# also sweeps the pre-consolidation block written by config's
# setup/00-claude-partials.sh, plus any free-floating @-line pointing into
# config/claude/. Without that sweep the old block survives -- the installer only
# strips markers it matches exactly -- and since the config clone remains on disk,
# BOTH sets of partials load. That failure is silent: no error, no missing file,
# just duplicated instructions.
#
# Usage (existing machine, repo already cloned):
#   ~/repos/github/freaxnx01/public/agent-workflow/setup/link-partials.sh [--no-sync]
#
# Usage (new machine, nothing cloned yet -- single-line bootstrap):
#   curl -fsSL https://raw.githubusercontent.com/freaxnx01/agent-workflow/main/setup/link-partials.sh | bash

set -euo pipefail

REPO_URL="https://github.com/freaxnx01/agent-workflow.git"
REPO_DIR="$HOME/repos/github/freaxnx01/public/agent-workflow"
CLAUDE_MD="$HOME/.claude/CLAUDE.md"

# Emitted with a literal ~ so Claude resolves it on whatever machine you're on
# (WSL2/Linux and Windows both expand ~ to the home dir). Never $HOME-expanded.
# shellcheck disable=SC2088  # the literal ~ is deliberate here — it is written
# verbatim into CLAUDE.md for Claude to expand per-machine, not a path we resolve.
CANON="~/repos/github/freaxnx01/public/agent-workflow/partials"

BEGIN="<!-- BEGIN provisioned:claude-partials (managed by setup/link-partials.sh) -->"
LEGACY_BEGIN="<!-- BEGIN provisioned:claude-partials (managed by setup/00-claude-partials.sh) -->"
END="<!-- END provisioned:claude-partials -->"

sync=1
for arg in "$@"; do
  case "$arg" in
    --no-sync) sync=0 ;;
  esac
done

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

# 2) Resolve the source dir AFTER any clone. Prefer this script's own checkout so
#    a scratch $HOME (tests) reads real partials rather than silently finding none.
#    Fall back to the canonical path because under `curl … | bash` BASH_SOURCE is
#    UNSET -- dirname yields "." and the relative guess would resolve against an
#    unrelated cwd. Verified on bash 5.2.
_src_guess="$(dirname "${BASH_SOURCE[0]:-$0}")/../partials"
if [ -d "$_src_guess" ]; then
  SRC_DIR="$(cd "$_src_guess" && pwd)"
else
  SRC_DIR="$REPO_DIR/partials"
fi

# 3) Enumerate the partials to import. README.md documents the surface and is not
#    an instruction fragment, so it is excluded -- same convention as
#    link-commands.sh. Sorted for a deterministic, byte-idempotent block.
mapfile -t partial_files < <(find "$SRC_DIR" -maxdepth 1 -type f -name '*.md' ! -name 'README.md' | sort)
if [ ${#partial_files[@]} -eq 0 ]; then
  echo "✗ no partials found in $SRC_DIR" >&2
  exit 1
fi

PARTIALS=()
for f in "${partial_files[@]}"; do
  PARTIALS+=("$CANON/$(basename "$f")")
done

# 4) Make sure ~/.claude/CLAUDE.md exists.
mkdir -p "$(dirname "$CLAUDE_MD")"
[ -f "$CLAUDE_MD" ] || : > "$CLAUDE_MD"

# 5) Compose the desired marker block.
block_file="$(mktemp)"
tmp="$(mktemp)"
trap 'rm -f "$block_file" "$tmp" "$tmp.trim"' EXIT
{
  printf '%s\n' "$BEGIN"
  for p in "${PARTIALS[@]}"; do printf '@%s\n' "$p"; done
  printf '%s\n' "$END"
} > "$block_file"

# 6) Normalize in a single awk pass: strip the current block (idempotency), the
#    legacy block (migration), and any stray @-line pointing at either partials
#    location. Everything else is passed through untouched.
echo "→ normalizing $CLAUDE_MD"
awk -v beg="$BEGIN" -v legacy="$LEGACY_BEGIN" -v end="$END" '
  $0 == beg || $0 == legacy { skip=1; next }
  $0 == end                 { skip=0; next }
  skip                      { next }
  /^@/ && (index($0, "/config/claude/") || index($0, "/agent-workflow/partials/")) { next }
  { print }
' "$CLAUDE_MD" > "$tmp"

# Trim trailing blank lines so re-runs are byte-idempotent (otherwise each run
# accumulates an extra blank line before the block).
awk 'BEGIN{n=0} {buf[++n]=$0} END{
  while (n>0 && buf[n]=="") n--
  for (i=1; i<=n; i++) print buf[i]
}' "$tmp" > "$tmp.trim" && mv "$tmp.trim" "$tmp"

# Append exactly one separating blank line + the managed block.
[ -s "$tmp" ] && printf '\n' >> "$tmp"
cat "$block_file" >> "$tmp"
mv "$tmp" "$CLAUDE_MD"

echo "✓ done — start a new Claude Code session to pick up the partials"
