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
#   1   the agent download or unpack failed
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
}

# curl_authed <curl args...> — runs curl with the PAT on stdin, not in argv.
curl_authed() {
  printf 'user = ":%s"\n' "$AZP_TOKEN" | curl -sS -fL -K - "$@"
}

# download_agent <dir> — unpacks the newest linux-x64 agent into <dir>.
download_agent() {
  local dir="$1" package_url download_url tarball
  package_url="$AZP_URL/_apis/distributedtask/packages/agent?platform=linux-x64&top=1&api-version=7.1"
  mkdir -p "$dir"
  tarball="$(mktemp -p "$dir")"

  download_url="$(curl_authed "$package_url" | jq -er '.value[0].downloadUrl')"
  curl_authed -o "$tarball" "$download_url"
  tar -xzf "$tarball" -C "$dir"
  rm -f "$tarball"
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

  [[ -f "$agent_dir/config.sh" ]] || download_agent "$agent_dir"
  cd "$agent_dir"
  [[ -e .agent ]] || configure_agent

  unset AZP_TOKEN VSTS_AGENT_INPUT_TOKEN
  exec ./run.sh
}

main "$@"
