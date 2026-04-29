#!/usr/bin/env bash
#
# ensure-toolchain.sh — Ensure required CLI tools are present, installing via
# apt when any are missing. Idempotent and cheap on `ubuntu-latest` (where the
# defaults are pre-installed) — only triggers apt when something is actually
# missing.
#
# Optional environment variables:
#   TOOLS    Space-separated list of tools to check. Default: "rg jq gh".
#            Tools are checked with `command -v <tool>`. Defaults map to apt
#            packages via APT_PKG below; unknown tool names are assumed to
#            share their name with their apt package.
#   DRY_RUN  If "1", report missing tools but skip the apt install step.
#
# Exit codes:
#   0   all required tools present (with or without install)
#   1   apt install attempted but at least one tool is still missing
set -euo pipefail
IFS=$'\n\t'

if [[ -n "${TOOLS:-}" ]]; then
  # Force space-separated parsing — the prelude's IFS=$'\n\t' would collapse
  # "rg jq gh" into a single token otherwise.
  IFS=' ' read -ra TOOLS_LIST <<< "$TOOLS"
else
  TOOLS_LIST=(rg jq gh)
fi

declare -A APT_PKG=( [rg]=ripgrep [jq]=jq [gh]=gh )

MISSING=()
for t in "${TOOLS_LIST[@]}"; do
  command -v "$t" >/dev/null 2>&1 || MISSING+=("$t")
done

if [[ ${#MISSING[@]} -eq 0 ]]; then
  printf 'all required tools present: %s\n' "${TOOLS_LIST[*]}"
  exit 0
fi

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  printf 'missing (DRY_RUN, not installing): %s\n' "${MISSING[*]}"
  exit 0
fi

PKGS=()
for t in "${MISSING[@]}"; do
  PKGS+=("${APT_PKG[$t]:-$t}")
done

printf 'installing missing tools via apt: %s\n' "${PKGS[*]}"
sudo apt-get update -qq
sudo apt-get install -y -qq "${PKGS[@]}"

for t in "${MISSING[@]}"; do
  if ! command -v "$t" >/dev/null 2>&1; then
    printf 'error: %s still missing after install\n' "$t" >&2
    exit 1
  fi
done

printf 'installed: %s\n' "${MISSING[*]}"
