#!/usr/bin/env bash
#
# run-azp-agent-start-tests.sh — Layer-1 tests for scripts/azp-agent-start.sh.
# AZP_AGENT_DIR is pre-populated with stub config.sh/run.sh/Agent.Listener that
# log their argv and environment, so nothing is downloaded and no agent is
# registered.
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
PIN_VERSION="5.281.1"
PIN_SHA="unset-until-the-fixture-tarball-exists"

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
printf '%s\n' "$*" > "$(dirname "$0")/run.argv"
STUB
  mkdir -p "$dir/bin"
  printf '#!/usr/bin/env bash\necho "  %s  "\n' "${2:-$PIN_VERSION}" > "$dir/bin/Agent.Listener"
  chmod +x "$dir/config.sh" "$dir/run.sh" "$dir/bin/Agent.Listener"
  printf '%s' "$dir"
}

# start <agent-dir> [env assignments...] — runs the script; echoes its exit code.
start() {
  local dir="$1"; shift
  local rc=0
  env -i PATH="$PATH" HOME="$WORK" "${PIN_ENV[@]}" "$@" AZP_AGENT_DIR="$dir" \
    bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}
# The pin is baked into the image as ENV, so every start has it.
PIN_ENV=(AZP_AGENT_VERSION="$PIN_VERSION" AZP_AGENT_SHA256="$PIN_SHA")
FULL_ENV=(AZP_URL=https://example.com/contoso AZP_TOKEN="$TOKEN" AZP_POOL=p AZP_AGENT_NAME=a)

section "required environment"

dir="$(new_agent_dir missing)"
assert_eq "start_missing_env_exits_64" "64" \
  "$(start "$dir" AZP_URL=https://example.com/contoso AZP_POOL=p)"

dir="$(new_agent_dir nopin)"
rc=0
env -i PATH="$PATH" HOME="$WORK" AZP_AGENT_SHA256=x "${FULL_ENV[@]}" AZP_AGENT_DIR="$dir" \
  bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
assert_eq "start_missing_pin_exits_64" "64" "$rc"
assert_eq "start_missing_pin_exits_64: run.sh not invoked" "no" \
  "$([[ -e "$dir/run.env" ]] && echo yes || echo no)"
rc=0
env -i PATH="$PATH" HOME="$WORK" AZP_AGENT_VERSION=5.281.1 "${FULL_ENV[@]}" AZP_AGENT_DIR="$dir" \
  bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
assert_eq "start_missing_sha_exits_64" "64" "$rc"
rc=0
touch "$dir/.agent"
env -i PATH="$PATH" HOME="$WORK" AZP_AGENT_VERSION= AZP_AGENT_SHA256=x AZP_AGENT_DIR="$dir" \
  bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
assert_eq "start_empty_pin_exits_64_even_when_registered" "64" "$rc"

section "configuration"

dir="$(new_agent_dir fresh)"
assert_eq "fresh start exits 0" "0" "$(start "$dir" "${FULL_ENV[@]}")"
assert_contains "start_configures_once" "--pool p --agent a --replace" \
  "$(cat "$dir/config.argv")"
assert_contains "config.sh is unattended with pat auth" "--unattended" \
  "$(cat "$dir/config.argv")"
assert_contains "start_work_folder_off_the_agent_volume" "--work /azp/work" \
  "$(cat "$dir/config.argv")"
assert_eq "start_runs_once" "--once" "$(cat "$dir/run.argv")"
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

dir="$(new_agent_dir configured-noenv)"
touch "$dir/.agent"
assert_eq "start_configured_needs_no_env" "0" "$(start "$dir")"
assert_eq "start_configured_needs_no_env: run.sh exec'd" "yes" \
  "$([[ -e "$dir/run.env" ]] && echo yes || echo no)"
assert_eq "start_configured_needs_no_env: config.sh not called" "no" \
  "$([[ -e "$dir/config.argv" ]] && echo yes || echo no)"

section "version check"

dir="$(new_agent_dir drift 5.280.0)"
touch "$dir/.agent"
assert_eq "start_version_drift_exits_66" "66" "$(start "$dir")"
assert_eq "start_version_drift_exits_66: run.sh not invoked" "no" \
  "$([[ -e "$dir/run.env" ]] && echo yes || echo no)"

dir="$(new_agent_dir drift-fresh 5.280.0)"
assert_eq "start_version_drift_after_registration_exits_66" "66" \
  "$(start "$dir" "${FULL_ENV[@]}")"

section "download (curl stubbed; fixture tarball built at test time)"

# Stub curl: logs argv and the byte count of stdin per call; a `-o <file>` call
# copies the fixture tarball there. Stdin is never logged.
STUBS="$WORK/stubs"
mkdir -p "$STUBS" "$WORK/fixture/bin"
# shellcheck disable=SC2016 # the stub's $ expansions are meant for run time
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$(dirname "$0")/config.argv"\ntouch "$(dirname "$0")/.agent"\n' > "$WORK/fixture/config.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/fixture/run.sh"
printf '#!/usr/bin/env bash\necho %s\n' "$PIN_VERSION" > "$WORK/fixture/bin/Agent.Listener"
chmod +x "$WORK/fixture/config.sh" "$WORK/fixture/run.sh" "$WORK/fixture/bin/Agent.Listener"
tar -czf "$WORK/agent.tar.gz" -C "$WORK/fixture" config.sh run.sh bin
PIN_SHA="$(sha256sum "$WORK/agent.tar.gz" | cut -d' ' -f1)"
PIN_ENV=(AZP_AGENT_VERSION="$PIN_VERSION" AZP_AGENT_SHA256="$PIN_SHA")
PIN_URL="https://download.agent.dev.azure.com/agent/$PIN_VERSION/vsts-agent-linux-x64-$PIN_VERSION.tar.gz"
cat > "$STUBS/curl" <<'STUB'
#!/usr/bin/env bash
argv="$*"
bytes=0
[[ "$argv" == *"-K -"* ]] && bytes=$(wc -c | tr -d ' ')
printf '%s\tstdin=%s\n' "$argv" "$bytes" >> "$CURL_STUB_LOG"
out=""
while (( $# )); do [[ "$1" == "-o" ]] && out="$2"; shift; done
if [[ -n "$out" ]]; then
  [[ -z "${CURL_STUB_FAIL_DOWNLOAD:-}" ]] || exit 22
  cp "$CURL_STUB_TARBALL" "$out"; exit 0
fi
exit 22
STUB
chmod +x "$STUBS/curl"

# download <name> [VAR=value ...] — runs the script against an empty agent dir
# with the stub curl and its own empty TMPDIR; sets DL_DIR, DL_LOG, DL_RC,
# DL_ERR (stderr) and DL_TMP. Later VAR=value pairs override the pin.
download() {
  local name="$1"; shift
  DL_DIR="$WORK/$name/agent"; DL_LOG="$WORK/$name.curl.log"; DL_TMP="$WORK/$name.tmp"
  mkdir -p "$WORK/$name" "$DL_TMP"; : > "$DL_LOG"; DL_RC=0
  env -i PATH="$STUBS:$PATH" HOME="$WORK" TMPDIR="$DL_TMP" "${FULL_ENV[@]}" "${PIN_ENV[@]}" \
    AZP_AGENT_DIR="$DL_DIR" CURL_STUB_LOG="$DL_LOG" CURL_STUB_TARBALL="$WORK/agent.tar.gz" \
    "$@" bash "$SCRIPT" >/dev/null 2>"$WORK/$name.err" || DL_RC=$?
  DL_ERR="$(cat "$WORK/$name.err")"
}

# assert_clean_failure <name> — a failed download leaves no scratch dir behind
# and no "unbound variable" from a trap that outlived its local.
assert_clean_failure() {
  assert_eq "$1: no leaked scratch dir" "" "$(ls -A "$DL_TMP")"
  assert_not_contains "$1: no unbound variable" "unbound variable" "$DL_ERR"
}

download ok
assert_eq "download_unpacks_and_starts" "0" "$DL_RC"
assert_eq "download_success_leaves_no_scratch_dir" "" "$(ls -A "$DL_TMP")"
assert_eq "download_populates_agent_dir" "yes" \
  "$([[ -x "$DL_DIR/config.sh" ]] && echo yes || echo no)"
assert_contains "start_download_url_from_pinned_version" "$PIN_URL" "$(cat "$DL_LOG")"
assert_eq "start_download_sends_no_credentials: the only curl call" "1" \
  "$(wc -l < "$DL_LOG" | tr -d ' ')"
for needle in ' -K' ' -u' 'Authorization'; do
  assert_not_contains "start_download_sends_no_credentials: no '$needle'" "$needle" "$(cat "$DL_LOG")"
done
assert_not_contains "download_token_not_in_any_argv" "$TOKEN" "$(cat "$DL_LOG")"

download shabad AZP_AGENT_SHA256=0000000000000000000000000000000000000000000000000000000000000000
assert_eq "start_sha_mismatch_exits_65" "65" "$DL_RC"
assert_eq "start_sha_mismatch_exits_65_leaves_dir_empty" "no" \
  "$([[ -e "$DL_DIR/config.sh" ]] && echo yes || echo no)"
assert_clean_failure "sha_mismatch"

download shaok
assert_eq "start_sha_match_configures" "0" "$DL_RC"
assert_contains "start_sha_match_configures: --work /azp/work" "--work /azp/work" \
  "$(cat "$DL_DIR/config.argv")"

download shaupper "AZP_AGENT_SHA256=${PIN_SHA^^}"
assert_eq "start_sha_uppercase_pin_accepted" "0" "$DL_RC"

download fetchfail CURL_STUB_FAIL_DOWNLOAD=1
assert_eq "download_fetch_failure_exits_1" "1" "$DL_RC"
assert_clean_failure "download_fetch_failure"

# A tarball that is not a tarball but whose hash matches: tar fails -> exit 1.
printf 'not a tarball' > "$WORK/bad.tar.gz"
download bad CURL_STUB_TARBALL="$WORK/bad.tar.gz" \
  AZP_AGENT_SHA256="$(sha256sum "$WORK/bad.tar.gz" | cut -d' ' -f1)"
assert_eq "download_unpack_failure_exits_1" "1" "$DL_RC"
assert_eq "failed_unpack_leaves_no_config" "no" \
  "$([[ -e "$DL_DIR/config.sh" ]] && echo yes || echo no)"
assert_clean_failure "download_unpack_failure"

# Unconfigured agent dir (no .agent, no config.sh), token unset: must refuse
# before any download.
mkdir -p "$WORK/notoken.tmp" "$WORK/notoken"
: > "$WORK/notoken.curl.log"
rc=0
env -i PATH="$STUBS:$PATH" HOME="$WORK" TMPDIR="$WORK/notoken.tmp" "${PIN_ENV[@]}" \
  AZP_URL=https://example.com/contoso AZP_POOL=p AZP_AGENT_DIR="$WORK/notoken/agent" \
  CURL_STUB_LOG="$WORK/notoken.curl.log" bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
assert_eq "start_unconfigured_without_token_exits_64" "64" "$rc"
assert_eq "start_unconfigured_without_token_exits_64: nothing downloaded" "0" \
  "$(wc -l < "$WORK/notoken.curl.log" | tr -d ' ')"

section "token validation"

dir="$(new_agent_dir badtoken)"
assert_eq "token_with_quote_exits_64" "64" \
  "$(start "$dir" AZP_URL=https://example.com/c AZP_TOKEN='a"b' AZP_POOL=p)"
assert_eq "token_with_backslash_exits_64" "64" \
  "$(start "$dir" AZP_URL=https://example.com/c AZP_TOKEN='a\b' AZP_POOL=p)"
assert_eq "token_with_newline_exits_64" "64" \
  "$(start "$dir" AZP_URL=https://example.com/c AZP_TOKEN=$'a\nb' AZP_POOL=p)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then printf 'Failed: %s\n' "${FAIL_NAMES[*]}"; exit 1; fi
