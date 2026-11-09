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
  sed 's/AWF_TOOLCHAIN=dotnet/AWF_TOOLCHAIN_MOVED=1/' "$1" \
    | awk 'BEGIN { done = 0 } { print } /^FROM / && !done { print "ENV AWF_TOOLCHAIN=dotnet"; done = 1 }' > "$2"
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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then printf 'Failed: %s\n' "${FAIL_NAMES[*]}"; exit 1; fi
