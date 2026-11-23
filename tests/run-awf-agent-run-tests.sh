#!/usr/bin/env bash
#
# run-awf-agent-run-tests.sh — Layer-1 guard for the environment
# docker/azp-agent/boundary/awf-agent-run hands the agent (#591, #641).
#
# It runs the REAL entry point with a stub CLI that prints its own environment,
# so what the agent could read is observable as this user: no Docker, no sudo,
# no second Linux user. The three `dotnet` constants of #641 must be there, the
# caller must not be able to influence them, and nothing that looks like a
# credential may survive apart from the two model-auth names of the allowlist.
#
# Usage: tests/run-awf-agent-run-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/docker/azp-agent/boundary/awf-agent-run"
NUGET_CACHE_DIR=/var/cache/awf-nuget

PASS=0
FAIL=0
FAIL_NAMES=()

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_GREEN=''; C_RED=''; C_DIM=''; C_OFF=''
fi

section() { printf '\n%s── %s ──%s\n' "$C_DIM" "$1" "$C_OFF"; }
pass() { PASS=$((PASS + 1)); printf '  %s✓%s %s\n' "$C_GREEN" "$C_OFF" "$1"; }
fail() {
  FAIL=$((FAIL + 1)); FAIL_NAMES+=("$1")
  printf '  %s✗%s %s\n' "$C_RED" "$C_OFF" "$1"
  [ $# -gt 1 ] && printf '      %s\n' "$2"
  return 0
}
check() { # check <name> <condition-exit-status> [detail]
  local name="$1" rc="$2" detail="${3:-}"
  if [[ "$rc" -eq 0 ]]; then pass "$name"; else fail "$name" "$detail"; fi
  return 0
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STUB="$WORK/claude-stub"
printf '#!/usr/bin/env bash\nenv | sort\n' > "$STUB"
chmod +x "$STUB"
mkdir -p "$WORK/ws1"

# The one invocation every case reads: a caller that sets the fallback path
# itself and holds both Azure DevOps credentials.
OUT="$(NUGET_FALLBACK_PACKAGES=/evil AZURE_DEVOPS_EXT_PAT=x SYSTEM_ACCESSTOKEN=y MODEL=m \
  AWF_WS_ROOT="$WORK" AWF_AGENT_CLAUDE="$STUB" "$RUN" "$WORK/ws1" -- --print)"

section "the environment awf-agent-run builds"

rc=0; grep -qx "NUGET_FALLBACK_PACKAGES=$NUGET_CACHE_DIR" <<<"$OUT" || rc=1
check awf_agent_run_SetsFallbackConstant "$rc" \
  "no NUGET_FALLBACK_PACKAGES=$NUGET_CACHE_DIR in: $(grep NUGET <<<"$OUT" || true)"

rc=0; grep -q '/evil' <<<"$OUT" && rc=1
check awf_agent_run_IgnoresCallerFallback "$rc" "the caller's /evil reached the agent"

rc=0
grep -qx 'DOTNET_CLI_TELEMETRY_OPTOUT=1' <<<"$OUT" || rc=1
grep -qx 'DOTNET_NOLOGO=1' <<<"$OUT" || rc=1
check awf_agent_run_SetsDotnetConstants "$rc" "DOTNET_*: $(grep DOTNET <<<"$OUT" || true)"

rc=0; grep -qE '^(AZURE_DEVOPS_EXT_PAT|SYSTEM_ACCESSTOKEN)=' <<<"$OUT" && rc=1
check awf_agent_run_DropsCredentials "$rc" "a credential survived the rebuild"

# The guarantee of #641 as a property, not as a list: nothing credential-shaped
# in the agent's environment beyond the two model-auth names.
# `(^|_)PAT(_|$)`, not a bare `PAT`: PATH is not a credential.
suspicious="$(cut -d= -f1 <<<"$OUT" | grep -E 'TOKEN|ACCESSTOKEN|SECRET|PASSWORD|(^|_)PAT(_|$)' \
  | grep -vxE 'CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_API_KEY' || true)"
rc=0; [[ -z "$suspicious" ]] || rc=1
check awf_agent_run_NoCredentialNamesBeyondModelAuth "$rc" \
  "credential-shaped names: $(tr '\n' ' ' <<<"$suspicious")"

rc=0; [[ "$(MODEL=m "$RUN" --protocol)" == 2 ]] || rc=1
check awf_agent_run_ProtocolIsTwo "$rc" "--protocol said: $("$RUN" --protocol)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then printf 'Failed: %s\n' "${FAIL_NAMES[*]}"; exit 1; fi
