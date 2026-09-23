#!/usr/bin/env bash
#
# fetch-verified-installer.sh — SOURCED helper. Fetch a third-party installer
# and verify its SHA-256 before anyone executes it.
#
# Extracted from install-claude-cli.sh (#302) when install-opencode.sh (#395)
# needed the same thing. The checksum comparison is the security-critical part
# of both; it should be fixable in one place.
#
# Sourced, not executed: `exit` here terminates the calling installer, which is
# intended — a failed fetch is terminal for both callers.
#
# Contract:
#   publish_exit_code <code>
#       Appends `exit-code=<code>` to $GITHUB_OUTPUT when set. The workflow's
#       failure-path step reads steps.install_cli.outputs.exit-code to pick a
#       reason in post-runner-block.sh; without it every failure gets the
#       generic wording (#302/#384).
#
#   require_tool <name> <purpose>
#       exits 64, naming the tool, the purpose and the doc.
#
#   new_installer_workdir
#       Sets INSTALLER_WORKDIR and registers its cleanup. Call it from the
#       caller's TOP LEVEL — see the note on the function itself.
#
#   fetch_verified_installer <url> <expected_sha256>
#       Echoes the verified file's path on STDOUT. Everything else it prints
#       goes to stderr — the caller reads the path with $(...), so a stray
#       stdout line would become part of the path.
#       exits 65 on mismatch, without executing anything.
#
# Callers run under `set -euo pipefail` (this repo's prelude), which is what
# carries a mismatch out of the command substitution: the function's `exit 65`
# ends the substitution subshell, and `set -e` then ends the caller with that
# same status, firing the cleanup trap on the way out.
#
# No `set -euo pipefail` and no IFS here: a sourced file inherits the caller's,
# and re-setting them would silently change the caller's shell options.

FETCH_VERIFIED_INSTALLER_DOC='docs/RUNNER-REQUIREMENTS.md'

publish_exit_code() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'exit-code=%s\n' "$1" >> "$GITHUB_OUTPUT"
  fi
}

require_tool() {
  local tool="$1" purpose="${2:-run the pipeline}"
  command -v "$tool" >/dev/null 2>&1 && return 0
  printf 'error: required tool %q is not present on this runner.\n' "$tool" >&2
  printf '       It is needed to %s.\n' "$purpose" >&2
  printf '       Unmet runner requirement — see %s\n' \
    "$FETCH_VERIFIED_INSTALLER_DOC" >&2
  publish_exit_code 64
  exit 64
}

# Create the scratch dir and register its cleanup.
#
# This MUST run at the caller's top level, not inside fetch_verified_installer:
# that function is invoked as `$(fetch_verified_installer ...)`, a subshell, so
# a trap registered there would fire the instant the substitution ends and
# delete the very file it had just returned. Registering here puts the trap in
# the caller's own shell, where it fires once, at the end of the run — on the
# mismatch path too, since `set -e` carries the exit 65 up to the caller.
new_installer_workdir() {
  INSTALLER_WORKDIR="$(mktemp -d)"
  trap 'rm -rf "${INSTALLER_WORKDIR:-}"' EXIT
}

fetch_verified_installer() {
  local url="$1" expected="$2"

  : "${INSTALLER_WORKDIR:?new_installer_workdir must be called before fetch_verified_installer}"
  local target="$INSTALLER_WORKDIR/installer.sh"

  printf 'fetching installer from %s\n' "$url" >&2
  curl -fsSL -o "$target" "$url"

  local actual
  actual="$(sha256sum "$target" | cut -d' ' -f1)"
  if [[ "$actual" != "$expected" ]]; then
    printf 'error: installer checksum mismatch — refusing to execute.\n' >&2
    printf '       expected %s\n' "$expected" >&2
    printf '       actual   %s\n' "$actual" >&2
    printf '       Either upstream changed the installer (bump the pin after\n' >&2
    printf '       reviewing the diff) or the download was tampered with.\n' >&2
    publish_exit_code 65
    exit 65
  fi

  printf '%s' "$target"
}
