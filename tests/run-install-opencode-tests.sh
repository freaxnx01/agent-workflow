#!/usr/bin/env bash
#
# run-install-opencode-tests.sh — Layer-1 tests for scripts/install-opencode.sh.
#
# Mirrors the claude installer's suite: a PATH built of symlinks to exactly the
# tools a case should see, a curl stand-in writing a payload, and the REAL
# sha256sum hashing it. No network.
#
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/install-opencode.sh"

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

# The payload records the args it was given, so the --version pin is provable,
# and creates the binary so the success path is observable.
# shellcheck disable=SC2016  # $FAKE_* stay literal: expanded when the payload runs.
INSTALLER_PAYLOAD='#!/usr/bin/env bash
set -euo pipefail
printf "%s\n" "$*" > "$FAKE_ARGS_FILE"
mkdir -p "$FAKE_INSTALL_BIN"
printf "#!/usr/bin/env bash\necho 1.15.13\n" > "$FAKE_INSTALL_BIN/opencode"
chmod +x "$FAKE_INSTALL_BIN/opencode"
'

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
printf '%s' "$INSTALLER_PAYLOAD" > "$out"
CURL
      chmod +x "$dir/curl"
    else
      ln -sf "$(command -v "$t")" "$dir/$t"
    fi
  done
}

run_script() {
  local bindir="$1"; shift
  env -u OPENCODE_VERSION PATH="$bindir" INSTALLER_PAYLOAD="$INSTALLER_PAYLOAD" \
    "$@" bash "$SCRIPT" 2>&1
}

TOOLS=(mktemp cut rm sha256sum chmod mkdir bash dirname cat curl)
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
GOOD_SHA="$(printf '%s' "$INSTALLER_PAYLOAD" | sha256sum | cut -d' ' -f1)"

section "prerequisite guards"

bin_nocurl="$tmp/bin-nocurl"
make_bin "$bin_nocurl" mktemp cut rm sha256sum chmod mkdir bash dirname cat
ec=0
out="$(run_script "$bin_nocurl" HOME="$tmp/home")" || ec=$?
assert_equals "$ec" "64"                             "curl absent → exit 64"
assert_contains "$out" "curl"                        "curl absent → names curl"
assert_contains "$out" "opencode"                    "curl absent → names the purpose"
assert_contains "$out" "docs/RUNNER-REQUIREMENTS.md" "curl absent → names the doc"
assert_not_contains "$out" "command not found"       "curl absent → not a bare command-not-found"

section "checksum verification"

bin_ok="$tmp/bin-ok"
make_bin "$bin_ok" "${TOOLS[@]}"
marker="$tmp/should-not-exist"
ec=0
out="$(run_script "$bin_ok" HOME="$tmp/home" \
  FAKE_INSTALL_BIN="$marker" FAKE_ARGS_FILE="$tmp/args-bad" \
  INSTALLER_SHA256=0000000000000000000000000000000000000000000000000000000000000000)" || ec=$?
assert_equals "$ec" "65"          "checksum mismatch → exit 65"
assert_contains "$out" "checksum" "checksum mismatch → says checksum"
if [[ ! -e "$marker/opencode" ]]; then pass "checksum mismatch → installer not executed"
else fail "checksum mismatch → installer not executed" "marker was created"; fi

section "happy path"

gh_path="$tmp/github_path"; : > "$gh_path"
install_bin="$tmp/installed"
args_file="$tmp/args"
ec=0
out="$(run_script "$bin_ok" HOME="$tmp/home" \
  FAKE_INSTALL_BIN="$install_bin" FAKE_ARGS_FILE="$args_file" \
  INSTALLER_SHA256="$GOOD_SHA" \
  OPENCODE_BIN_CANDIDATES="$install_bin" \
  GITHUB_PATH="$gh_path")" || ec=$?
assert_equals "$ec" "0"                            "happy path → exit 0"
assert_contains "$(cat "$gh_path")" "$install_bin" "happy path → bin dir on GITHUB_PATH"
assert_contains "$(cat "$args_file")" "--version"  "happy path → installer pinned by --version"
assert_contains "$(cat "$args_file")" "1.15.13"    "happy path → pinned to OPENCODE_VERSION"

section "version override is honoured"

ec=0
run_script "$bin_ok" HOME="$tmp/home" \
  FAKE_INSTALL_BIN="$install_bin" FAKE_ARGS_FILE="$args_file" \
  INSTALLER_SHA256="$GOOD_SHA" OPENCODE_BIN_CANDIDATES="$install_bin" \
  OPENCODE_VERSION=9.9.9 >/dev/null || ec=$?
assert_contains "$(cat "$args_file")" "9.9.9" "OPENCODE_VERSION override reaches the installer"

section "installer ran but produced no binary"

ec=0
out="$(run_script "$bin_ok" HOME="$tmp/home" \
  FAKE_INSTALL_BIN="$tmp/elsewhere" FAKE_ARGS_FILE="$tmp/args2" \
  OPENCODE_BIN_CANDIDATES="$tmp/nowhere" \
  INSTALLER_SHA256="$GOOD_SHA")" || ec=$?
assert_equals "$ec" "66"                             "no binary → exit 66"
assert_contains "$out" "docs/RUNNER-REQUIREMENTS.md" "no binary → names the doc"

section "DRY_RUN"

ec=0
out="$(run_script "$bin_ok" HOME="$tmp/home" DRY_RUN=1)" || ec=$?
assert_equals "$ec" "0"               "DRY_RUN → exit 0"
assert_contains "$out" "DRY_RUN"      "DRY_RUN → says so"
assert_not_contains "$out" "fetching" "DRY_RUN → nothing fetched"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'; printf '  - %s\n' "${FAIL_NAMES[@]}"
  exit 1
fi
