#!/usr/bin/env bash
#
# azp-agent-start.sh — Container entrypoint for a self-hosted Azure Pipelines
# agent: fetch the PINNED agent if absent (hash-verified, no credentials),
# register it once, check its version, then hand over to `run.sh --once`: one
# job per container, the supervisor restarts it for the next one.
#
# Required environment variables on EVERY start (baked into the image):
#   AZP_AGENT_VERSION  Agent version to run, e.g. 5.281.1.
#   AZP_AGENT_SHA256   SHA-256 of that version's linux-x64 tarball.
#
# Required environment variables, ONLY while the agent is not yet registered
# (no $AZP_AGENT_DIR/.agent); a configured agent needs no registration variable:
#   AZP_URL     Organization URL.
#   AZP_TOKEN   PAT with Agent Pools (read, manage). Never passed as an argument
#               (visible in `ps`): config.sh reads it from VSTS_AGENT_INPUT_TOKEN.
#   AZP_POOL    Agent pool to register in.
#
# Optional environment variables:
#   AZP_AGENT_NAME  Agent name. Default: the hostname.
#   AZP_AGENT_DIR   Where the agent lives. Default: /azp/agent.
#
# One-shot registration (PAT from a mode-600 env file, deleted afterwards):
# see docs/AZDO-PIPELINE-SETUP.md.
# Both token variables are unset before run.sh, so pipeline jobs never inherit
# the PAT. The work folder is /azp/work, off the agent volume.
#
# Exit codes:
#   0/other  run.sh's own status (exec). The agent uses 1-4 itself, 2 meaning
#            "retryable", so this script never reuses 2.
#   1   the agent download or unpack failed
#   64  a required variable is missing or invalid (the pin on every start, the
#       registration variables while unregistered, or a forbidden token
#       character)
#   65  the downloaded tarball's SHA-256 differs from AZP_AGENT_SHA256
#   66  the installed agent's version differs from AZP_AGENT_VERSION
# 64-66 are configuration errors: a restart cannot fix them, so the supervisor
# lists them in RestartPreventExitStatus.
set -euo pipefail
IFS=$'\n\t'

require_env() {
  local name
  for name in AZP_URL AZP_TOKEN AZP_POOL; do
    if [[ -z "${!name:-}" ]]; then
      printf 'azp-agent-start: %s must be set\n' "$name" >&2
      exit 64
    fi
  done
  # Kept from when the token was written into a quoted curl config line: such
  # characters are never valid in a PAT, so fail fast on a mangled secret.
  if [[ "$AZP_TOKEN" == *[\"\\]* || "$AZP_TOKEN" == *$'\n'* ]]; then
    printf 'azp-agent-start: AZP_TOKEN must not contain ", \\ or a newline\n' >&2
    exit 64
  fi
  AZP_URL="${AZP_URL%/}"
}

# require_pin — the version pin is needed on every start, registered or not.
require_pin() {
  local name
  for name in AZP_AGENT_VERSION AZP_AGENT_SHA256; do
    if [[ -z "${!name:-}" ]]; then
      printf 'azp-agent-start: %s must be set\n' "$name" >&2
      exit 64
    fi
  done
}

# download_agent <dir> — unpacks the pinned linux-x64 agent into <dir>. The
# tarball comes from a public CDN URL built from the pin and is fetched WITHOUT
# credentials, then checked against AZP_AGENT_SHA256 before tar sees it.
# Extracts into a scratch dir and moves into place only on success, so a failed
# download never leaves a half-populated <dir>/config.sh behind. The scratch
# dir is removed on every path, success or failure, before this returns -- no
# trap, since an EXIT trap would fire after the function's locals are gone.
download_agent() {
  local dir="$1" scratch rc=0
  scratch="$(mktemp -d)"
  fetch_agent_into "$scratch" "$dir" || rc=$?
  rm -rf "$scratch"
  return "$rc"
}

# fetch_agent_into <scratch> <dir> — the download, verify and unpack steps
# proper. Returns 1 on download/unpack failure, 65 on a hash mismatch.
fetch_agent_into() {
  local scratch="$1" dir="$2" actual
  local version="$AZP_AGENT_VERSION"
  curl -sS -fL -o "$scratch/agent.tar.gz" \
    "https://download.agent.dev.azure.com/agent/$version/vsts-agent-linux-x64-$version.tar.gz" \
    || return 1
  actual="$(sha256sum "$scratch/agent.tar.gz")" || return 1
  if [[ "${actual%% *}" != "${AZP_AGENT_SHA256,,}" ]]; then
    printf 'azp-agent-start: agent tarball SHA-256 mismatch\n' >&2
    return 65
  fi
  mkdir "$scratch/agent" || return 1
  tar -xzf "$scratch/agent.tar.gz" -C "$scratch/agent" || return 1
  mkdir -p "$dir" || return 1
  cp -a "$scratch/agent/." "$dir/" || return 1
}

configure_agent() {
  VSTS_AGENT_INPUT_TOKEN="$AZP_TOKEN" ./config.sh --unattended \
    --url "$AZP_URL" --auth pat --pool "$AZP_POOL" --agent "$AZP_AGENT_NAME" \
    --replace --acceptTeeEula --work /azp/work
}

# check_agent_version <dir> — the installed agent must be the pinned one.
check_agent_version() {
  local installed
  installed="$("$1/bin/Agent.Listener" --version)" || installed=""
  installed="${installed//[[:space:]]/}"
  if [[ "$installed" != "$AZP_AGENT_VERSION" ]]; then
    printf 'azp-agent-start: installed agent is "%s", expected %s\n' \
      "$installed" "$AZP_AGENT_VERSION" >&2
    exit 66
  fi
}

# register_agent <dir> — the only path that needs the registration environment:
# fetches the agent if absent, then configures it.
register_agent() {
  local agent_dir="$1"
  require_env
  AZP_AGENT_NAME="${AZP_AGENT_NAME:-$(hostname)}"
  if [[ ! -f "$agent_dir/config.sh" ]]; then
    local rc=0
    download_agent "$agent_dir" || rc=$?
    if (( rc != 0 )); then
      printf 'azp-agent-start: agent download failed\n' >&2
      exit "$rc"
    fi
  fi
  (cd "$agent_dir" && configure_agent)
}

main() {
  local agent_dir="${AZP_AGENT_DIR:-/azp/agent}"

  require_pin
  if [[ ! -e "$agent_dir/.agent" ]]; then
    register_agent "$agent_dir"
  fi
  check_agent_version "$agent_dir"
  cd "$agent_dir"

  unset AZP_TOKEN VSTS_AGENT_INPUT_TOKEN
  exec ./run.sh --once
}

main "$@"
