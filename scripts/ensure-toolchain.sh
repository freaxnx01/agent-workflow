#!/usr/bin/env bash
#
# ensure-toolchain.sh — Ensure required CLI tools are present, installing via
# apt when any are missing. Idempotent and cheap on `ubuntu-latest` (where the
# defaults are pre-installed) — only triggers apt when something is actually
# missing.
#
# When `AGENT=opencode` is set in the environment, ALSO ensures the OpenCode
# CLI is on PATH at the version pinned in OPENCODE_VERSION below. The
# OpenCode install is gated to the opencode path so the Claude path stays
# zero-cost. See docs/RUNNER-REQUIREMENTS.md for the toolchain contract.
#
# Optional environment variables:
#   TOOLS    Space-separated list of tools to check. Default: "rg jq gh".
#            Tools are checked with `command -v <tool>`. Defaults map to apt
#            packages via APT_PKG below; unknown tool names are assumed to
#            share their name with their apt package.
#   DRY_RUN  If "1", report missing tools but skip the apt install step.
#            Also skips the OpenCode install probe (see OPENCODE_DRY_RUN).
#   AGENT    `claude | opencode`. When `opencode`, install OpenCode CLI
#            at OPENCODE_VERSION if it's not already present at that version.
#            Anything else: OpenCode install is skipped entirely.
#   OPENCODE_DRY_RUN
#            If "1", report whether OpenCode would be installed but skip
#            the actual network/install step. Used by Layer-1 tests.
#
# Exit codes:
#   0   all required tools present (with or without install)
#   1   apt install attempted but at least one tool is still missing
#   64/65/66
#       propagated from scripts/install-opencode.sh — prerequisite absent,
#       installer checksum mismatch, or installed-but-not-found respectively.
set -euo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Pinned OpenCode version. Bump in one place. The line is parsed by
# docs/RUNNER-REQUIREMENTS.md's CI check (when it exists) to keep the
# README and the script in sync.
OPENCODE_VERSION="${OPENCODE_VERSION:-1.15.13}"

if [[ -n "${TOOLS:-}" ]]; then
  # Force space-separated parsing — the prelude's IFS=$'\n\t' would collapse
  # "rg jq gh" into a single token otherwise.
  IFS=' ' read -ra TOOLS_LIST <<< "$TOOLS"
else
  TOOLS_LIST=(rg jq gh)
fi

declare -A APT_PKG=( [rg]=ripgrep [jq]=jq [gh]=gh )

# Fallback when apt is unreachable (#594): the runner's Ubuntu mirror failing
# DNS took every dispatch down at this step for hours while github.com stayed
# reachable. Pinned release binaries, verified by checksum; tools without an
# entry here have no fallback.
RG_VERSION="14.1.1"
declare -A RG_SHA256=(
  [x86_64]=4cf9f2741e6c465ffdb7c26f38056a59e2a2544b51f7cc128ef28337eeae4d8e
  [aarch64]=c827481c4ff4ea10c9dc7a4022c8de5db34a5737cb74484d62eb94a95841ab2f
)
declare -A RG_TARGET=( [x86_64]=x86_64-unknown-linux-musl [aarch64]=aarch64-unknown-linux-gnu )

install_release_binary() {
  local tool="$1" arch dir name
  [[ "$tool" == rg ]] || return 1
  arch="$(uname -m)"
  [[ -n "${RG_TARGET[$arch]:-}" ]] || return 1
  name="ripgrep-${RG_VERSION}-${RG_TARGET[$arch]}"
  dir="$(mktemp -d)"
  printf 'installing rg %s from the GitHub release\n' "$RG_VERSION"
  curl -fsSL --retry 3 -o "$dir/$name.tar.gz" \
    "https://github.com/BurntSushi/ripgrep/releases/download/${RG_VERSION}/${name}.tar.gz" || return 1
  echo "${RG_SHA256[$arch]}  $dir/$name.tar.gz" | sha256sum -c --quiet - || return 1
  tar -xzf "$dir/$name.tar.gz" -C "$dir" "$name/rg" || return 1
  sudo install -m 0755 "$dir/$name/rg" /usr/local/bin/rg
}

MISSING=()
MISSING=()
for t in "${TOOLS_LIST[@]}"; do
  command -v "$t" >/dev/null 2>&1 || MISSING+=("$t")
done

if [[ ${#MISSING[@]} -eq 0 ]]; then
  printf 'all required tools present: %s\n' "${TOOLS_LIST[*]}"
elif [[ "${DRY_RUN:-0}" == "1" ]]; then
  printf 'missing (DRY_RUN, not installing): %s\n' "${MISSING[*]}"
else
  PKGS=()
  for t in "${MISSING[@]}"; do
    PKGS+=("${APT_PKG[$t]:-$t}")
  done

  printf 'installing missing tools via apt: %s\n' "${PKGS[*]}"
  if ! { sudo apt-get update -qq && sudo apt-get install -y -qq "${PKGS[@]}"; }; then
    printf 'warning: apt install failed, trying release-binary fallbacks\n' >&2
    for t in "${MISSING[@]}"; do
      command -v "$t" >/dev/null 2>&1 || install_release_binary "$t" || true
    done
  fi

  for t in "${MISSING[@]}"; do
    if ! command -v "$t" >/dev/null 2>&1; then
      printf 'error: %s still missing after install\n' "$t" >&2
      exit 1
    fi
  done

  printf 'installed: %s\n' "${MISSING[*]}"
fi

# --- OpenCode CLI (only when AGENT=opencode) -----------------------------

ensure_opencode() {
  # Check if already installed at the pinned version.
  if command -v opencode >/dev/null 2>&1; then
    local current
    current="$(opencode --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    if [[ "$current" == "$OPENCODE_VERSION" ]]; then
      printf 'opencode already at pinned version %s\n' "$OPENCODE_VERSION"
      return 0
    fi
    printf 'opencode present but at %s; installing pinned version %s\n' \
      "${current:-unknown}" "$OPENCODE_VERSION"
  else
    printf 'opencode not present; installing pinned version %s\n' "$OPENCODE_VERSION"
  fi

  if [[ "${OPENCODE_DRY_RUN:-0}" == "1" || "${DRY_RUN:-0}" == "1" ]]; then
    printf 'opencode install skipped (DRY_RUN)\n'
    return 0
  fi

  # Native installer, checksum-pinned — not `npm install -g`, which resolves to
  # the shared global prefix and dies with EACCES on a persistent runner whose
  # prefix was ever written as root (#395, the same hazard #302 fixed for the
  # claude path). The contract downstream relies on is unchanged: binary
  # `opencode` on PATH, returning OPENCODE_VERSION from `--version`.
  #
  # install-opencode.sh owns the post-install verification and exits 66 if the
  # binary is not there, so there is no `command -v opencode` re-check here: it
  # would run in THIS shell, where $HOME/.opencode/bin is not on PATH yet — the
  # installer appends that dir to $GITHUB_PATH, which only reaches later steps.
  # The npm version got away with the re-check because /usr/local/bin was
  # already on PATH.
  OPENCODE_VERSION="$OPENCODE_VERSION" bash "$HERE/install-opencode.sh"

  printf 'opencode installed at version %s\n' "$OPENCODE_VERSION"
}

if [[ "${AGENT:-claude}" == 'opencode' ]]; then
  ensure_opencode
fi
