#!/usr/bin/env bash
#
# run-azp-agent-dockerfile-tests.sh — Layer-1 guard for docker/azp-agent/Dockerfile.
# Parses the file with awk only (no Docker, no network) and pins the multi-stage
# contract: stages `base`, `dotnet`, `default`, where `default` is the last stage,
# is FROM base and adds nothing — so a bare `docker build` stays today's image —
# and the `dotnet` stage installs a SHA-512-verified SDK and ends as USER 1000.
# Each guard also has a negative case: a mutated copy of the Dockerfile must fail.
#
# Env:
#   DOCKERFILE  file under test. Defaults to docker/azp-agent/Dockerfile.
#
# Usage: tests/run-azp-agent-dockerfile-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCKERFILE="${DOCKERFILE:-$ROOT/docker/azp-agent/Dockerfile}"

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
assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then pass "$name"; else
    fail "$name" "expected: $expected | actual: $actual"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

BASE_FROM='FROM debian:13-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4 AS base'

# normalize <file> — logical Dockerfile instructions, one per line: comment lines
# dropped, `\`-continued lines joined, whitespace runs collapsed.
normalize() {
  awk '
    /^[[:space:]]*#/ { next }
    {
      line = $0
      cont = (line ~ /\\[[:space:]]*$/)
      sub(/\\[[:space:]]*$/, "", line)
      buf = buf " " line
      if (cont) next
      gsub(/[[:space:]]+/, " ", buf)
      sub(/^ /, "", buf); sub(/ $/, "", buf)
      if (buf != "") print buf
      buf = ""
    }
    END { gsub(/[[:space:]]+/, " ", buf); sub(/^ /, "", buf); if (buf != "") print buf }
  ' "$1"
}

# stage_lines <normalized-text> <stage> — the stage's instructions, FROM included.
stage_lines() {
  awk -v want="$2" '
    /^FROM / { cur = ($(NF - 1) == "AS") ? $NF : "" }
    cur == want { print }
  ' <<<"$1"
}

# Failures of the current run_checks call. EMIT=1 prints each result and counts
# it in PASS/FAIL; EMIT=0 only records, so a negative case stays silent.
CHECK_FAILS=0
CHECK_FAIL_NAMES=""
EMIT=1

check() { # check <name> <ok|bad> [detail]
  local name="$1" verdict="$2" detail="${3:-}"
  if [[ "$verdict" == ok ]]; then
    [[ "$EMIT" == 1 ]] && pass "$name"
    return 0
  fi
  CHECK_FAILS=$((CHECK_FAILS + 1))
  CHECK_FAIL_NAMES+=" $name "
  if [[ "$EMIT" == 1 ]]; then fail "$name" "$detail"; fi
  return 0
}

# verdict <condition-exit-status> — ok when 0, bad otherwise.
verdict() { if [[ "$1" -eq 0 ]]; then printf ok; else printf bad; fi; }

# run_checks <dockerfile> — runs every guard; failures land in CHECK_FAILS.
run_checks() {
  CHECK_FAILS=0
  CHECK_FAIL_NAMES=""
  local norm dotnet rc
  norm="$(normalize "$1")"
  dotnet="$(stage_lines "$norm" dotnet)"

  local names
  names="$(awk '/^FROM / { print $NF }' <<<"$norm" | tr '\n' ' ')"
  check dockerfile_has_three_named_stages \
    "$([[ "$names" == "base dotnet default " ]] && echo ok || echo bad)" "stages: $names"

  check dockerfile_base_is_the_pinned_debian \
    "$([[ "$(grep -m1 '^FROM ' <<<"$norm")" == "$BASE_FROM" ]] && echo ok || echo bad)" \
    "first FROM: $(grep -m1 '^FROM ' <<<"$norm")"

  check dockerfile_last_stage_is_default_from_base \
    "$([[ "$(grep '^FROM ' <<<"$norm" | tail -n1)" == "FROM base AS default" ]] && echo ok || echo bad)" \
    "last FROM: $(grep '^FROM ' <<<"$norm" | tail -n1)"

  local default_count
  default_count="$(stage_lines "$norm" default | wc -l | tr -d ' ')"
  check dockerfile_default_stage_has_no_instructions \
    "$([[ "$(grep '^FROM ' <<<"$norm" | tail -n1)" == "FROM base AS default" && "$default_count" == 1 ]] && echo ok || echo bad)" \
    "default stage has $default_count lines"

  check dockerfile_dotnet_stage_from_base \
    "$([[ "$(head -n1 <<<"$dotnet")" == "FROM base AS dotnet" ]] && echo ok || echo bad)" \
    "dotnet stage line: $(head -n1 <<<"$dotnet")"

  local sha
  sha="$(sed -n 's/^ARG DOTNET_SDK_SHA512=//p' <<<"$dotnet")"
  rc=1; [[ "$sha" =~ ^[0-9a-f]{128}$ ]] && rc=0
  check dockerfile_sha512_arg_is_128_hex "$(verdict "$rc")" "DOTNET_SDK_SHA512=$sha"

  local version
  version="$(sed -n 's/^ARG DOTNET_SDK_VERSION=//p' <<<"$dotnet")"
  rc=1; [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && rc=0
  check dockerfile_sdk_version_arg_set "$(verdict "$rc")" "DOTNET_SDK_VERSION=$version"

  check_install_run "$dotnet"
  check_toolchain_env "$norm" "$dotnet"
  check_dotnet_env_and_user "$dotnet"
  check_boundary "$norm"
}

# runs_under_user <norm> <needle> — the USER in effect for every RUN line that
# mentions <needle>, one per line.
runs_under_user() {
  awk -v needle="$2" '
    /^FROM / { user = "root" }
    /^USER / { user = $2 }
    /^RUN / && index($0, needle) > 0 { print user }
  ' <<<"$1"
}

# check_boundary <norm> — the agent user boundary of #591: the second user, the
# three entry points, the sudoers drop-in, and an `azp` home the agent cannot
# read.
check_boundary() {
  local norm="$1" rc entry copy useradd_line apt_line first_user_1000 copy_line
  local boundary_dir=/usr/local/libexec/awf-agent

  apt_line="$(grep -E '^RUN .*apt-get install' <<<"$(stage_lines "$norm" base)" | head -n1 || true)"
  rc=1; [[ "$apt_line" =~ (^|\ )sudo(\ |$) ]] && rc=0
  check dockerfile_base_installs_sudo "$(verdict "$rc")" "apt line: $apt_line"

  useradd_line="$(grep -E '^RUN .*useradd .*awf-agent' <<<"$norm" | head -n1 || true)"
  rc=0
  [[ -n "$useradd_line" ]] || rc=1
  [[ "$useradd_line" =~ --uid\ ([0-9]+) ]] || rc=1
  [[ "${BASH_REMATCH[1]:-1000}" != 1000 ]] || rc=1
  [[ "$useradd_line" != *" -G "* && "$useradd_line" != *"--groups"* ]] || rc=1
  check dockerfile_creates_awf_agent_user "$(verdict "$rc")" \
    "useradd: $useradd_line"

  rc=0
  first_user_1000="$(grep -n '^USER 1000$' <<<"$norm" | head -n1 | cut -d: -f1)"
  for entry in awf-agent-run awf-agent-git awf-agent-reap; do
    copy="$(grep -E "^COPY .*boundary/$entry $boundary_dir/$entry\$" <<<"$norm" | head -n1 || true)"
    [[ -n "$copy" ]] || { rc=1; continue; }
    [[ "$copy" == *"--chmod=0755"* ]] || rc=1
    copy_line="$(grep -n -F "$copy" <<<"$norm" | head -n1 | cut -d: -f1)"
    [[ -n "$first_user_1000" && "$copy_line" -lt "$first_user_1000" ]] || rc=1
  done
  check dockerfile_copies_boundary_entrypoints "$(verdict "$rc")" \
    "three mode-0755 COPYs into $boundary_dir, before USER 1000"

  copy="$(grep -E '^COPY .*sudoers-awf-agent /etc/sudoers\.d/awf-agent$' <<<"$norm" | head -n1 || true)"
  rc=0
  [[ -n "$copy" ]] || rc=1
  [[ "$copy" == *"--chmod=0440"* ]] || rc=1
  copy_line="$(grep -n -F "$copy" <<<"$norm" | head -n1 | cut -d: -f1)"
  [[ -n "$first_user_1000" && -n "$copy_line" && "$copy_line" -lt "$first_user_1000" ]] || rc=1
  check dockerfile_copies_sudoers_rule "$(verdict "$rc")" "COPY: $copy"

  local installs
  installs="$(runs_under_user "$norm" install-claude-cli.sh | grep -c '^1001$' || true)"
  check dockerfile_installs_claude_for_awf_agent \
    "$([[ "$installs" == 1 ]] && echo ok || echo bad)" \
    "install-claude-cli.sh RUNs under USER 1001 (awf-agent): $installs"

  rc=1; grep -qE '^RUN .*chmod 0700 /home/azp( |$)' <<<"$norm" && rc=0
  check dockerfile_azp_home_is_private "$(verdict "$rc")" \
    "no RUN sets /home/azp to 0700"
}

check_install_run() { # check_install_run <dotnet-stage>
  local run before_tar rc
  run="$(grep -E '^RUN .*tar .*/usr/share/dotnet' <<<"$1" | head -n1 || true)"

  # The checksum must gate extraction: verified first, same RUN, `&&`-chained,
  # not swallowed by `|| true` and not the tail of a pipe.
  rc=0
  [[ "$run" =~ sha512sum\ -c\ [^\&\|\;]+\&\& ]] || rc=1
  before_tar="${run%%tar *}"
  [[ "$before_tar" == *"sha512sum -c"* ]] || rc=1
  [[ "$run" != *"|| true"* ]] || rc=1
  [[ "$run" != *"| sha512sum"* ]] || rc=1
  check dockerfile_sha512_check_precedes_extract "$(verdict "$rc")" "install RUN: $run"

  # shellcheck disable=SC2016 # a literal Dockerfile ${...}, not a shell expansion
  local url version_ref='${DOTNET_SDK_VERSION}'
  url="$(grep -oE 'https://[^ "]+' <<<"$run" | head -n1 || true)"
  rc=0
  [[ "$url" == https://builds.dotnet.microsoft.com/* ]] || rc=1
  [[ "$url" == *"$version_ref"* ]] || rc=1
  check dockerfile_download_uses_version_arg "$(verdict "$rc")" "url: $url"
}

check_toolchain_env() { # check_toolchain_env <norm> <dotnet-stage>
  local env_in_dotnet outside rc
  env_in_dotnet="$(grep '^ENV ' <<<"$2" || true)"
  outside="$(stage_lines "$1" base; stage_lines "$1" default)"
  rc=0
  [[ "$env_in_dotnet" =~ (^|\ )AWF_TOOLCHAIN=dotnet(\ |$) ]] || rc=1
  [[ "$outside" != *AWF_TOOLCHAIN* ]] || rc=1
  ! grep -qE '^ARG .*AWF_TOOLCHAIN' <<<"$1" || rc=1
  check dockerfile_toolchain_env_only_in_dotnet "$(verdict "$rc")" \
    "AWF_TOOLCHAIN must be an ENV in dotnet only"
}

check_dotnet_env_and_user() { # check_dotnet_env_and_user <dotnet-stage>
  local env_lines rc=0 var
  env_lines="$(grep '^ENV ' <<<"$1" || true)"
  local wanted=(DOTNET_ROOT=/usr/share/dotnet DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1)
  for var in "${wanted[@]}"; do
    [[ "$env_lines" =~ (^|\ )"$var"(\ |$) ]] || rc=1
  done
  check dockerfile_dotnet_env_set "$(verdict "$rc")" "ENV: $env_lines"

  local last_user
  last_user="$(grep '^USER ' <<<"$1" | tail -n1 || true)"
  check dockerfile_dotnet_stage_ends_as_user_1000 \
    "$([[ "$last_user" == "USER 1000" ]] && echo ok || echo bad)" "last USER: $last_user"
}

# --- mutations: write a broken copy of the Dockerfile to $2 ------------------

# raw_stage <file> <name> — the raw lines of one stage (FROM to the next FROM).
raw_stage() {
  awk -v want="$2" '
    /^FROM / { cur = ($(NF - 1) == "AS") ? $NF : "" }
    cur == want { print }
  ' "$1"
}

mutate_swap_dotnet_and_default() {
  { raw_stage "$1" base; raw_stage "$1" default; raw_stage "$1" dotnet; } > "$2"
}
mutate_shorten_sha() {
  sed -E 's/(DOTNET_SDK_SHA512=[0-9a-f]{127})[0-9a-f]/\1/' "$1" > "$2"
}
mutate_drop_final_user() {
  { raw_stage "$1" base
    raw_stage "$1" dotnet | awk '
      { lines[NR] = $0; if ($0 ~ /^USER 1000[[:space:]]*$/) last = NR }
      END { for (i = 1; i <= NR; i++) if (i != last) print lines[i] }'
    raw_stage "$1" default; } > "$2"
}
mutate_toolchain_into_base() {
  awk 'BEGIN { done = 0 } { print } /^FROM / && !done { print "ENV AWF_TOOLCHAIN=dotnet"; done = 1 }' "$1" > "$2"
}
mutate_drop_sudo_package() {
  sed -E 's/^([[:space:]]*)bash ca-certificates curl git jq sudo /\1bash ca-certificates curl git jq /' "$1" > "$2"
}
mutate_awf_agent_into_azp_group() {
  sed -E 's/(useradd .*awf-agent)/\1 -G azp/' "$1" > "$2"
}
mutate_boundary_entrypoint_world_writable() {
  sed -E 's#(COPY --chmod=)0755( docker/azp-agent/boundary/awf-agent-run)#\10777\2#' "$1" > "$2"
}
mutate_sudoers_copy_mode() {
  sed -E 's#(COPY --chmod=)0440( docker/azp-agent/sudoers-awf-agent)#\10644\2#' "$1" > "$2"
}
mutate_drop_awf_agent_claude_install() {
  awk '
    /^USER 1001$/ { skipping = 1; next }
    skipping && /^RUN .*install-claude-cli\.sh/ { skipping = 0; next }
    { print }
  ' "$1" > "$2"
}
mutate_open_azp_home() {
  sed -E 's#chmod 0700 /home/azp#chmod 0755 /home/azp#' "$1" > "$2"
}

# negative <case-name> <mutator> <check-that-must-fail>
negative() {
  local name="$1" mutator="$2" expected="$3" mutated="$WORK/$1.Dockerfile"
  "$mutator" "$DOCKERFILE" "$mutated"
  if cmp -s "$DOCKERFILE" "$mutated"; then
    fail "$name" "mutation changed nothing — the case would pass vacuously"; return 0
  fi
  EMIT=0; run_checks "$mutated"; EMIT=1
  if (( CHECK_FAILS > 0 )) && [[ "$CHECK_FAIL_NAMES" == *" $expected "* ]]; then pass "$name"; else
    fail "$name" "expected $expected to fail | failed: ${CHECK_FAIL_NAMES:-none}"; fi
}

section "Dockerfile guards"
run_checks "$DOCKERFILE"

section "negative cases (a mutated Dockerfile must be caught)"
negative negative_dotnet_last_is_caught mutate_swap_dotnet_and_default \
  dockerfile_last_stage_is_default_from_base
negative negative_short_sha_is_caught mutate_shorten_sha dockerfile_sha512_arg_is_128_hex
negative negative_root_user_is_caught mutate_drop_final_user \
  dockerfile_dotnet_stage_ends_as_user_1000
negative negative_toolchain_in_base_is_caught mutate_toolchain_into_base \
  dockerfile_toolchain_env_only_in_dotnet
negative negative_missing_sudo_is_caught mutate_drop_sudo_package \
  dockerfile_base_installs_sudo
negative negative_agent_in_azp_group_is_caught mutate_awf_agent_into_azp_group \
  dockerfile_creates_awf_agent_user
negative negative_writable_entrypoint_is_caught mutate_boundary_entrypoint_world_writable \
  dockerfile_copies_boundary_entrypoints
negative negative_loose_sudoers_mode_is_caught mutate_sudoers_copy_mode \
  dockerfile_copies_sudoers_rule
negative negative_no_agent_cli_is_caught mutate_drop_awf_agent_claude_install \
  dockerfile_installs_claude_for_awf_agent
negative negative_readable_azp_home_is_caught mutate_open_azp_home \
  dockerfile_azp_home_is_private

# --- the sudoers drop-in ------------------------------------------------------

SUDOERS="${SUDOERS:-$ROOT/docker/azp-agent/sudoers-awf-agent}"
BOUNDARY_DIR=/usr/local/libexec/awf-agent
ENV_ALLOWLIST='CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY MODEL MAX_TURNS'

# run_sudoers_checks <file> — the grant must stay exactly three fixed commands,
# as one user, with no path to root and no credential in the kept environment.
run_sudoers_checks() {
  local file="$1" rule commands expected rc
  CHECK_FAILS=0
  CHECK_FAIL_NAMES=""

  rule="$(grep -E '^azp ' "$file" | head -n1 || true)"
  rc=0
  [[ "$rule" =~ ^azp\ ALL=\(awf-agent\)\ NOPASSWD:\ (.*)$ ]] || rc=1
  commands="${BASH_REMATCH[1]:-}"
  check sudoers_runas_is_awf_agent_only "$(verdict "$rc")" "rule: $rule"

  expected="$BOUNDARY_DIR/awf-agent-run, $BOUNDARY_DIR/awf-agent-git, $BOUNDARY_DIR/awf-agent-reap"
  rc=0
  [[ "$commands" == "$expected" ]] || rc=1
  check sudoers_names_exactly_the_three_entry_points "$(verdict "$rc")" \
    "commands: $commands"

  rc=0
  grep -qE '^Defaults:azp env_reset$' "$file" || rc=1
  grep -qF "Defaults:azp env_keep = \"$ENV_ALLOWLIST\"" "$file" || rc=1
  check sudoers_env_keep_is_the_allowlist "$(verdict "$rc")" \
    "env_reset plus env_keep = \"$ENV_ALLOWLIST\""

  rc=0
  grep -qE '\(root\)|ALL=\(ALL' "$file" && rc=1
  grep -qE 'NOPASSWD:[[:space:]]*ALL' "$file" && rc=1
  check sudoers_grants_nothing_as_root "$(verdict "$rc")" "no (root) and no ALL command"
}

mutate_sudoers_all_commands() {
  sed -E 's#NOPASSWD: .*#NOPASSWD: ALL#' "$1" > "$2"
}
mutate_sudoers_runas_root() {
  sed -E 's#\(awf-agent\)#(root)#' "$1" > "$2"
}
mutate_sudoers_env_keep_extra() {
  sed -E 's#(env_keep = "[^"]*)"#\1 AZURE_DEVOPS_EXT_PAT"#' "$1" > "$2"
}

negative_sudoers() {
  local name="$1" mutator="$2" expected="$3" mutated="$WORK/$1.sudoers"
  "$mutator" "$SUDOERS" "$mutated"
  if cmp -s "$SUDOERS" "$mutated"; then
    fail "$name" "mutation changed nothing — the case would pass vacuously"; return 0
  fi
  EMIT=0; run_sudoers_checks "$mutated"; EMIT=1
  if (( CHECK_FAILS > 0 )) && [[ "$CHECK_FAIL_NAMES" == *" $expected "* ]]; then pass "$name"; else
    fail "$name" "expected $expected to fail | failed: ${CHECK_FAIL_NAMES:-none}"; fi
}

section "sudoers drop-in"
run_sudoers_checks "$SUDOERS"

if command -v visudo >/dev/null 2>&1; then
  visudo_rc=0
  visudo -cf "$SUDOERS" >/dev/null 2>&1 || visudo_rc=$?
  assert_eq "sudoers_visudo_accepts_the_file" "0" "$visudo_rc"
else
  printf '  %s–%s sudoers_visudo_accepts_the_file (skipped: no visudo)%s\n' "$C_DIM" "$C_OFF" "$C_OFF"
fi

section "negative cases (a mutated sudoers file must be caught)"
negative_sudoers negative_sudoers_all_commands_is_caught mutate_sudoers_all_commands \
  sudoers_names_exactly_the_three_entry_points
negative_sudoers negative_sudoers_root_runas_is_caught mutate_sudoers_runas_root \
  sudoers_runas_is_awf_agent_only
negative_sudoers negative_sudoers_credential_in_env_keep_is_caught mutate_sudoers_env_keep_extra \
  sudoers_env_keep_is_the_allowlist

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then printf 'Failed: %s\n' "${FAIL_NAMES[*]}"; exit 1; fi
