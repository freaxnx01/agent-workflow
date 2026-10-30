#!/usr/bin/env bash
#
# run-azp-agent-start-tests.sh — Layer-1 tests for scripts/azp-agent-start.sh.
# AZP_AGENT_DIR is pre-populated with stub config.sh/run.sh that log their argv
# and environment, so nothing is downloaded and no agent is registered.
#
# Usage: tests/run-azp-agent-start-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/azp-agent-start.sh"

PASS=0
FAIL=0
FAIL_NAMES=()
TOKEN="s3cr3t-pat-value"

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
assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then pass "$name"; else
    fail "$name" "expected: $expected | actual: $actual"; fi
}
assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$name"; else
    fail "$name" "missing: $needle | in: $haystack"; fi
}
assert_not_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then pass "$name"; else
    fail "$name" "unexpected: $needle"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# new_agent_dir <name> — an agent dir whose config.sh/run.sh only log.
new_agent_dir() {
  local dir="$WORK/$1"
  mkdir -p "$dir"
  cat > "$dir/config.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/config.argv"
env >> "$(dirname "$0")/config.env"
touch "$(dirname "$0")/.agent"
STUB
  cat > "$dir/run.sh" <<'STUB'
#!/usr/bin/env bash
env > "$(dirname "$0")/run.env"
STUB
  chmod +x "$dir/config.sh" "$dir/run.sh"
  printf '%s' "$dir"
}

# start <agent-dir> [env assignments...] — runs the script; echoes its exit code.
start() {
  local dir="$1"; shift
  local rc=0
  env -i PATH="$PATH" HOME="$WORK" "$@" AZP_AGENT_DIR="$dir" \
    bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}
FULL_ENV=(AZP_URL=https://example.com/contoso AZP_TOKEN="$TOKEN" AZP_POOL=p AZP_AGENT_NAME=a)

section "required environment"

dir="$(new_agent_dir missing)"
assert_eq "start_missing_env_exits_2" "2" \
  "$(start "$dir" AZP_URL=https://example.com/contoso AZP_POOL=p)"

section "configuration"

dir="$(new_agent_dir fresh)"
assert_eq "fresh start exits 0" "0" "$(start "$dir" "${FULL_ENV[@]}")"
assert_contains "start_configures_once" "--pool p --agent a --replace" \
  "$(cat "$dir/config.argv")"
assert_contains "config.sh is unattended with pat auth" "--unattended" \
  "$(cat "$dir/config.argv")"
assert_not_contains "start_token_not_in_argv" "$TOKEN" "$(cat "$dir/config.argv")"
assert_contains "config.sh receives the token via the environment" \
  "VSTS_AGENT_INPUT_TOKEN=$TOKEN" "$(cat "$dir/config.env")"
assert_not_contains "start_run_sees_no_token (AZP_TOKEN)" "AZP_TOKEN" "$(cat "$dir/run.env")"
assert_not_contains "start_run_sees_no_token (VSTS_AGENT_INPUT_TOKEN)" \
  "VSTS_AGENT_INPUT_TOKEN" "$(cat "$dir/run.env")"

section "already configured"

dir="$(new_agent_dir configured)"
touch "$dir/.agent"
assert_eq "configured start exits 0" "0" "$(start "$dir" "${FULL_ENV[@]}")"
assert_eq "start_skips_config_when_configured" "no" \
  "$([[ -e "$dir/config.argv" ]] && echo yes || echo no)"
assert_eq "run.sh still started" "yes" "$([[ -e "$dir/run.env" ]] && echo yes || echo no)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then printf 'Failed: %s\n' "${FAIL_NAMES[*]}"; exit 1; fi
