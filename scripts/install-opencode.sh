#!/usr/bin/env bash
#
# install-opencode.sh — Put the OpenCode CLI on PATH via its native installer.
#
# Replaces `npm install -g "opencode-ai@$OPENCODE_VERSION"` (#395). `npm
# install -g` resolves to the shared `npm config get prefix` (/usr/local on a
# typical runner), which on a PERSISTENT self-hosted runner is shared across
# every job and every run. Once that prefix has been written as root, a later
# install as the runner user cannot rename the package directory and dies with
# `EACCES / syscall rename`. #302 fixed exactly this for the Claude CLI; this
# is the same fix for the last path that still had it.
#
# The native installer lands the binary in $HOME/.opencode/bin — per-user and
# per-runner, never shared — which is the point.
#
# Optional environment variables:
#   OPENCODE_VERSION  Version to install. Default below; ensure-toolchain.sh
#                     owns the canonical pin and passes it down.
#   INSTALLER_URL     Where to fetch the installer. Default below.
#   INSTALLER_SHA256  Expected SHA-256 of the installer. Default below.
#   OPENCODE_BIN_CANDIDATES
#                     Colon-separated dirs to search for the installed binary,
#                     ahead of the defaults. Exists for tests.
#   DRY_RUN           "1" → run the prerequisite guards, then stop.
#   GITHUB_PATH       When set, the dir holding `opencode` is appended to it.
#   GITHUB_OUTPUT     When set, the exit code is published as `exit-code`.
#
# Exit codes:
#   0   opencode on PATH at OPENCODE_VERSION
#   64  a prerequisite is absent — names it and the doc
#   65  installer checksum mismatch — refuses to execute
#   66  installer ran but `opencode` is still not on PATH
set -euo pipefail
IFS=$'\n\t'

# shellcheck source=lib/fetch-verified-installer.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fetch-verified-installer.sh"

# Canonical pin lives in scripts/ensure-toolchain.sh (OPENCODE_VERSION); this
# default exists only so the script can be run standalone.
OPENCODE_VERSION="${OPENCODE_VERSION:-1.15.13}"
INSTALLER_URL="${INSTALLER_URL:-https://opencode.ai/install}"

# SHA-256 of the installer as fetched on 2026-09-23. Refreshing this is a
# deliberate commit, reviewed like any other dependency bump.
INSTALLER_SHA256="${INSTALLER_SHA256:-fc3c1b2123f49b6df545a7622e5127d21cd794b15134fc3b66e1ca49f7fb297e}"

PURPOSE='install the OpenCode CLI for an AGENT=opencode run'

require_tool curl "$PURPOSE"
require_tool sha256sum "$PURPOSE"

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  printf 'prerequisites present; install skipped (DRY_RUN)\n'
  exit 0
fi

new_installer_workdir
installer="$(fetch_verified_installer "$INSTALLER_URL" "$INSTALLER_SHA256")"

printf 'installing OpenCode CLI %s\n' "$OPENCODE_VERSION"
bash "$installer" --version "$OPENCODE_VERSION"

# The native installer targets $HOME/.opencode/bin; the candidates list keeps
# this from being a single hardcoded guess.
CANDIDATES="${OPENCODE_BIN_CANDIDATES:-}"
CANDIDATES="${CANDIDATES:+$CANDIDATES:}$HOME/.opencode/bin:$HOME/.local/bin"

opencode_dir=''
IFS=':' read -ra cand_dirs <<< "$CANDIDATES"
for d in "${cand_dirs[@]}"; do
  if [[ -n "$d" && -x "$d/opencode" ]]; then
    opencode_dir="$d"
    break
  fi
done

if [[ -z "$opencode_dir" ]] && command -v opencode >/dev/null 2>&1; then
  opencode_dir="$(dirname "$(command -v opencode)")"
fi

if [[ -z "$opencode_dir" ]]; then
  printf 'error: installer completed but no opencode binary was found.\n' >&2
  printf '       Searched: %s\n' "$CANDIDATES" >&2
  printf '       Unmet runner requirement — see docs/RUNNER-REQUIREMENTS.md\n' >&2
  publish_exit_code 66
  exit 66
fi

if [[ -n "${GITHUB_PATH:-}" ]]; then
  printf '%s\n' "$opencode_dir" >> "$GITHUB_PATH"
fi

PATH="$opencode_dir:$PATH"
export PATH
printf 'opencode installed at %s (version: %s)\n' \
  "$opencode_dir/opencode" "$("$opencode_dir/opencode" --version 2>/dev/null || printf 'unknown')"
