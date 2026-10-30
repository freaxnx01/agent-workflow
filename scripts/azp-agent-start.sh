#!/usr/bin/env bash
#
# azp-agent-start.sh — Container entrypoint for a self-hosted Azure Pipelines
# agent: fetch the agent if absent, register it once, then hand over to run.sh.
#
# Required environment variables:
#   AZP_URL     Organization URL.
#   AZP_TOKEN   PAT with Agent Pools (read, manage). Never passed as an argument
#               (visible in `ps`): curl reads it from a config on stdin, and
#               config.sh reads it from VSTS_AGENT_INPUT_TOKEN.
#   AZP_POOL    Agent pool to register in.
#
# Optional environment variables:
#   AZP_AGENT_NAME  Agent name. Default: the hostname.
#   AZP_AGENT_DIR   Where the agent lives. Default: /azp/agent.
#
# Both token variables are unset before run.sh, so pipeline jobs never inherit
# the PAT.
#
# Exit codes:
#   0   run.sh exited cleanly (exec: this is run.sh's own status)
#   1   the agent download, URL check or unpack failed
#   2   a required environment variable is missing
set -euo pipefail
IFS=$'\n\t'

require_env() {
  local name
  for name in AZP_URL AZP_TOKEN AZP_POOL; do
    if [[ -z "${!name:-}" ]]; then
      printf 'azp-agent-start: %s must be set\n' "$name" >&2
      exit 2
    fi
  done
  # The token is written into a curl config line between double quotes.
  if [[ "$AZP_TOKEN" == *[\"\\]* || "$AZP_TOKEN" == *$'\n'* ]]; then
    printf 'azp-agent-start: AZP_TOKEN must not contain ", \\ or a newline\n' >&2
    exit 2
  fi
  AZP_URL="${AZP_URL%/}"
}

# fetch_download_url — asks the packages API (the ONLY authenticated request,
# and only to $AZP_URL) for the newest linux-x64 agent; prints its https URL.
# The PAT goes to curl as a config on stdin, never in argv.
fetch_download_url() {
  local api="$AZP_URL/_apis/distributedtask/packages/agent?platform=linux-x64&top=1&api-version=7.1"
  local url
  url="$(printf 'user = ":%s"\n' "$AZP_TOKEN" | curl -sS -fL -K - "$api" \
    | jq -er '.value[0].downloadUrl')" || return 1
  if [[ "$url" != https://* ]]; then
    printf 'azp-agent-start: refusing a non-https agent download URL\n' >&2
    return 1
  fi
  printf '%s' "$url"
}

# download_agent <dir> — unpacks the newest linux-x64 agent into <dir>. The
# tarball comes from a separate CDN host and is fetched WITHOUT credentials.
# Extracts into a scratch dir and moves into place only on success, so a failed
# download never leaves a half-populated <dir>/config.sh behind.
download_agent() {
  local dir="$1" scratch download_url
  scratch="$(mktemp -d)"
  trap 'rm -rf "$scratch"' EXIT

  download_url="$(fetch_download_url)" || return 1
  curl -sS -fL -o "$scratch/agent.tar.gz" "$download_url" || return 1
  mkdir "$scratch/agent"
  tar -xzf "$scratch/agent.tar.gz" -C "$scratch/agent" || return 1

  mkdir -p "$dir" || return 1
  cp -a "$scratch/agent/." "$dir/" || return 1
  rm -rf "$scratch"
  trap - EXIT
}

configure_agent() {
  VSTS_AGENT_INPUT_TOKEN="$AZP_TOKEN" ./config.sh --unattended \
    --url "$AZP_URL" --auth pat --pool "$AZP_POOL" --agent "$AZP_AGENT_NAME" \
    --replace --acceptTeeEula --work _work
}

main() {
  require_env
  AZP_AGENT_NAME="${AZP_AGENT_NAME:-$(hostname)}"
  local agent_dir="${AZP_AGENT_DIR:-/azp/agent}"

  if [[ ! -f "$agent_dir/config.sh" ]]; then
    download_agent "$agent_dir" || {
      printf 'azp-agent-start: agent download failed\n' >&2
      exit 1
    }
  fi
  cd "$agent_dir"
  [[ -e .agent ]] || configure_agent

  unset AZP_TOKEN VSTS_AGENT_INPUT_TOKEN
  exec ./run.sh
}

main "$@"
