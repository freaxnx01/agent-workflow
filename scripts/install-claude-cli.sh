#!/usr/bin/env bash
#
# install-claude-cli.sh — Put the Claude Code CLI on PATH for jobs that do not
# use anthropics/claude-code-base-action (the review and self-fix jobs).
#
# Uses the NATIVE installer, not npm. npm was the wrong shape here twice:
#   - `npm install -g` resolves to the shared `npm config get prefix`
#     (/usr/local), which on a PERSISTENT self-hosted runner is shared across
#     every job and run. Once written as root, a later install as the runner
#     user cannot rename the package dir and dies with EACCES (#302).
#   - A runner with no Node.js at all fails with a bare `npm: command not
#     found`, exit 127, naming no requirement (#384).
# The implement job never hit either, because claude-code-base-action installs
# the CLI itself. One dependency now has one mechanism.
#
# The installer is fetched and CHECKSUM-VERIFIED before it is executed. A bare
# `curl | bash` is forbidden by this repo's CI stack overlay, and the pin is
# what makes the fetch reviewable.
#
# Optional environment variables:
#   CLAUDE_CLI_VERSION  Version to install. Default below; keep it equal to the
#                       CLI the base action installs (agent-implement.yml:665).
#   INSTALLER_URL       Where to fetch install.sh. Default below.
#   INSTALLER_SHA256    Expected SHA-256 of install.sh. Default below.
#   CLAUDE_BIN_CANDIDATES
#                       Colon-separated dirs to search for the installed
#                       binary, ahead of the defaults. Exists for tests.
#   DRY_RUN             "1" → run the prerequisite guards, then stop. No
#                       network, no install. Used by Layer-1 tests.
#   GITHUB_PATH         When set, the dir holding `claude` is appended to it.
#   GITHUB_OUTPUT       When set, the exit code is published as `exit-code`
#                       before a non-zero exit, so the workflow's failure-path
#                       step can pass it to post-runner-block.sh.
#
# Exit codes:
#   0   claude on PATH at CLAUDE_CLI_VERSION
#   64  a prerequisite is absent — names it and the doc
#   65  installer checksum mismatch — refuses to execute
#   66  installer ran but `claude` is still not on PATH
set -euo pipefail
IFS=$'\n\t'

# Keep in lockstep with anthropics/claude-code-base-action in
# .github/workflows/agent-implement.yml:665 — the reviewer and the implementer
# should be running the same CLI. Bump both in the same commit.
CLAUDE_CLI_VERSION="${CLAUDE_CLI_VERSION:-2.1.270}"
INSTALLER_URL="${INSTALLER_URL:-https://claude.ai/install.sh}"

# SHA-256 of the installer as fetched on 2026-09-23. Refreshing this is a
# deliberate commit, reviewed like any other dependency bump: fetch the script,
# read the diff, then record the new hash here.
INSTALLER_SHA256="${INSTALLER_SHA256:-3a68d3406cf674e17bed1733a4dcf37805e2e47d87417700007d7e1aa766a944}"

DOC='docs/RUNNER-REQUIREMENTS.md'

# shellcheck source=lib/fetch-verified-installer.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fetch-verified-installer.sh"

# Kept as a thin alias: the exit paths below read as `die <code>`, and the
# helper owns publishing the step output.
die() {
  publish_exit_code "$1"
  exit "$1"
}

require_tool curl "install the Claude Code CLI for the review job"
require_tool sha256sum "install the Claude Code CLI for the review job"

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  printf 'prerequisites present; install skipped (DRY_RUN)\n'
  exit 0
fi

new_installer_workdir
installer="$(fetch_verified_installer "$INSTALLER_URL" "$INSTALLER_SHA256")"

printf 'installing Claude Code CLI %s\n' "$CLAUDE_CLI_VERSION"
bash "$installer" "$CLAUDE_CLI_VERSION"

# Locate the installed binary. The native installer targets ~/.local/bin; the
# candidates list keeps this from being a single hardcoded guess.
CANDIDATES="${CLAUDE_BIN_CANDIDATES:-}"
CANDIDATES="${CANDIDATES:+$CANDIDATES:}$HOME/.local/bin:$HOME/.claude/bin"

claude_dir=''
IFS=':' read -ra cand_dirs <<< "$CANDIDATES"
for d in "${cand_dirs[@]}"; do
  if [[ -n "$d" && -x "$d/claude" ]]; then
    claude_dir="$d"
    break
  fi
done

if [[ -z "$claude_dir" ]] && command -v claude >/dev/null 2>&1; then
  # Fall back to whatever the installer may already have put on PATH.
  claude_dir="$(dirname "$(command -v claude)")"
fi

if [[ -z "$claude_dir" ]]; then
  printf 'error: installer completed but no claude binary was found.\n' >&2
  printf '       Searched: %s\n' "$CANDIDATES" >&2
  printf '       Unmet runner requirement — see %s\n' "$DOC" >&2
  die 66
fi

if [[ -n "${GITHUB_PATH:-}" ]]; then
  printf '%s\n' "$claude_dir" >> "$GITHUB_PATH"
fi

PATH="$claude_dir:$PATH"
export PATH
printf 'claude installed at %s (version: %s)\n' \
  "$claude_dir/claude" "$("$claude_dir/claude" --version 2>/dev/null || printf 'unknown')"
