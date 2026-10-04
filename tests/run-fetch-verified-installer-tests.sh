#!/usr/bin/env bash
#
# run-fetch-verified-installer-tests.sh — Layer-1 tests for
# scripts/lib/fetch-verified-installer.sh.
#
# Hermetic: the helper runs with a PATH built of symlinks to exactly the tools a
# case should see, so "curl is missing" is a real absence rather than a mock.
# The curl stand-in writes a payload and the REAL sha256sum hashes it, so the
# checksum path is exercised for true rather than stubbed.
#
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../scripts/lib/fetch-verified-installer.sh"

PASS=0; FAIL=0; FAIL_NAMES=()

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
  [[ -n "${2:-}" ]] && printf '    %s%s%s\n' "$C_DIM" "$2" "$C_OFF"
}
assert_contains() {
  local hay="$1" needle="$2" name="$3"
  if [[ "$hay" == *"$needle"* ]]; then pass "$name"
  else fail "$name" "expected substring not found: $needle"; fi
}
assert_not_contains() {
  local hay="$1" needle="$2" name="$3"
  if [[ "$hay" != *"$needle"* ]]; then pass "$name"
  else fail "$name" "unexpected substring present: $needle"; fi
}
assert_equals() {
  if [[ "$1" == "$2" ]]; then pass "$3"
  else fail "$3" "expected '$2' got '$1'"; fi
}

PAYLOAD='#!/usr/bin/env bash
printf "payload ran\n"
'

# Build a PATH dir with symlinks to exactly $@; "curl" becomes a stand-in that
# writes $PAYLOAD to the -o target.
make_bin() {
  local dir="$1"; shift
  mkdir -p "$dir"
  local t
  for t in "$@"; do
    if [[ "$t" == "curl" ]]; then
      cat > "$dir/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s' "$PAYLOAD" > "$out"
CURL
      chmod +x "$dir/curl"
    else
      ln -sf "$(command -v "$t")" "$dir/$t"
    fi
  done
}

# Drive the helper from a tiny caller script, because it is sourced. The
# prelude is part of the contract, not scaffolding: `set -e` is what carries a
# mismatch out of the $(...) subshell, exactly as it does in the real
# installers. A caller without it would see exit 65 silently swallowed.
# shellcheck disable=SC2016  # $LIB/$WANT_SHA stay literal: expanded when the caller runs.
CALLER='
set -euo pipefail
. "$LIB"
require_tool curl "install the thing"
require_tool sha256sum "install the thing"
new_installer_workdir
p="$(fetch_verified_installer "https://example.invalid/install" "$WANT_SHA")"
printf "PATH_RETURNED=%s\n" "$p"
printf "CONTENT=%s\n" "$(cat "$p")"
'

run_caller() {
  local bindir="$1"; shift
  env PATH="$bindir" LIB="$LIB" PAYLOAD="$PAYLOAD" "$@" bash -c "$CALLER" 2>&1
}

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
GOOD_SHA="$(printf '%s' "$PAYLOAD" | sha256sum | cut -d' ' -f1)"
TOOLS=(mktemp cut rm sha256sum chmod mkdir bash cat curl)

section "prerequisite guards"

bin_nocurl="$tmp/bin-nocurl"
make_bin "$bin_nocurl" mktemp cut rm sha256sum chmod mkdir bash cat
ec=0
gho="$tmp/gho1"; : > "$gho"
out="$(run_caller "$bin_nocurl" WANT_SHA="$GOOD_SHA" GITHUB_OUTPUT="$gho")" || ec=$?
assert_equals "$ec" "64"                             "curl absent → exit 64"
assert_contains "$out" "curl"                        "curl absent → names curl"
assert_contains "$out" "install the thing"           "curl absent → names the purpose"
assert_contains "$out" "docs/RUNNER-REQUIREMENTS.md" "curl absent → names the doc"
assert_contains "$(cat "$gho")" "exit-code=64"       "curl absent → publishes exit-code"

bin_nosum="$tmp/bin-nosum"
make_bin "$bin_nosum" mktemp cut rm chmod mkdir bash cat curl
ec=0
out="$(run_caller "$bin_nosum" WANT_SHA="$GOOD_SHA")" || ec=$?
assert_equals "$ec" "64"           "sha256sum absent → exit 64"
assert_contains "$out" "sha256sum" "sha256sum absent → names sha256sum"

section "checksum verification"

bin_ok="$tmp/bin-ok"
make_bin "$bin_ok" "${TOOLS[@]}"

ec=0
gho="$tmp/gho2"; : > "$gho"
out="$(run_caller "$bin_ok" WANT_SHA=0000000000000000000000000000000000000000000000000000000000000000 GITHUB_OUTPUT="$gho")" || ec=$?
assert_equals "$ec" "65"                        "mismatch → exit 65"
assert_contains "$out" "checksum"               "mismatch → says checksum"
assert_not_contains "$out" "PATH_RETURNED"      "mismatch → caller never receives a path"
assert_contains "$(cat "$gho")" "exit-code=65"  "mismatch → publishes exit-code"

section "happy path"

ec=0
out="$(run_caller "$bin_ok" WANT_SHA="$GOOD_SHA")" || ec=$?
assert_equals "$ec" "0"                     "match → exit 0"
assert_contains "$out" "PATH_RETURNED=/"    "match → a path is returned"
assert_contains "$out" "CONTENT=#!"         "match → the path holds the payload"

section "stdout discipline"

# The returned path must be the ONLY thing on stdout, or $(...) captures noise.
path_line="$(run_caller "$bin_ok" WANT_SHA="$GOOD_SHA" 2>/dev/null | grep '^PATH_RETURNED=')"
assert_not_contains "$path_line" " "        "returned path contains no progress text"
assert_not_contains "$path_line" "fetching" "progress went to stderr, not stdout"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'; printf '  - %s\n' "${FAIL_NAMES[@]}"
  exit 1
fi
