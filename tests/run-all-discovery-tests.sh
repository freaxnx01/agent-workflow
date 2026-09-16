#!/usr/bin/env bash
#
# run-all-discovery-tests.sh — Layer-1 tests for tests/run-all.sh.
#
# Drives run-all.sh against fixture directories via TESTS_DIR, never the real
# tests/ dir — that one holds this file, and this file invokes run-all.sh, so
# pointing it there would recurse.
#
# Usage: tests/run-all-discovery-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_ALL="$ROOT/tests/run-all.sh"

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
  if [[ "$actual" == "$expected" ]]; then pass "$name"
  else fail "$name" "expected: $expected | actual: $actual"; fi
}
assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$name"
  else fail "$name" "missing: $needle"; fi
}
assert_not_contains() {
  local haystack="$1" needle="$2" name="$3"
  if [[ "$haystack" != *"$needle"* ]]; then pass "$name"
  else fail "$name" "unexpectedly present: $needle"; fi
}

# make_fixture_dir <name:exitcode>... — a dir of fake runners
make_fixture_dir() {
  local dir spec name code
  dir="$(mktemp -d)"
  for spec in "$@"; do
    name="${spec%%:*}"; code="${spec##*:}"
    printf '#!/usr/bin/env bash\nexit %s\n' "$code" > "$dir/$name"
    chmod +x "$dir/$name"
  done
  printf '%s' "$dir"
}

run_ec()  { TESTS_DIR="$1" bash "$RUN_ALL" >/dev/null 2>&1 && echo 0 || echo $?; }
run_out() { TESTS_DIR="$1" bash "$RUN_ALL" 2>&1 || true; }

section "discovery and exit codes"

d="$(make_fixture_dir 'run-a-tests.sh:0' 'run-b-tests.sh:0')"
assert_eq "all runners pass → exit 0" 0 "$(run_ec "$d")"
out="$(run_out "$d")"
assert_contains "$out" 'run-a-tests.sh' "names each runner it ran"
assert_contains "$out" 'run-b-tests.sh' "names the second runner"
assert_contains "$out" 'runners: 2' "reports how many it found"
rm -rf "$d"

d="$(make_fixture_dir 'run-a-tests.sh:0' 'run-b-tests.sh:1')"
assert_eq "one runner fails → exit 1" 1 "$(run_ec "$d")"
out="$(run_out "$d")"
assert_contains "$out" 'run-b-tests.sh' "names the failing runner"
assert_contains "$out" 'failed: 1' "counts the failure"
rm -rf "$d"

# A failure must not abort the sweep — one break should not hide later results.
d="$(make_fixture_dir 'run-a-tests.sh:1' 'run-b-tests.sh:0')"
out="$(run_out "$d")"
assert_contains "$out" 'run-b-tests.sh' "keeps going after a failure"
rm -rf "$d"

section "what is and is not a runner"

d="$(make_fixture_dir 'run-a-tests.sh:0')"
printf '#!/usr/bin/env bash\nexit 1\n' > "$d/helper.sh";      chmod +x "$d/helper.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$d/run-all.sh";     chmod +x "$d/run-all.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$d/run-tests.sh";   chmod +x "$d/run-tests.sh"
printf 'not a script\n' > "$d/fixture.json"
assert_eq "ignores helper.sh, run-all.sh, run-tests.sh and non-scripts" 0 "$(run_ec "$d")"
assert_not_contains "$(run_out "$d")" 'helper.sh' "does not run a plain helper"
rm -rf "$d"

# Nested dirs are fixtures/mocks, not runners — discovery is one level deep.
d="$(make_fixture_dir 'run-a-tests.sh:0')"
mkdir -p "$d/mocks"
printf '#!/usr/bin/env bash\nexit 1\n' > "$d/mocks/run-nested-tests.sh"
chmod +x "$d/mocks/run-nested-tests.sh"
assert_eq "does not descend into subdirectories" 0 "$(run_ec "$d")"
rm -rf "$d"

section "a broken discovery is an error, not a pass"

d="$(mktemp -d)"
assert_eq "no runners found → exit 2" 2 "$(run_ec "$d")"
rm -rf "$d"

assert_eq "missing TESTS_DIR → exit 2" 2 "$(run_ec /nonexistent-dir-xyz)"

section "the real tests/ directory"

# Guards the recursion trap and the two runners the old justfile list omitted.
mapfile -t real < <(find "$ROOT/tests" -maxdepth 1 -type f -name 'run-*-tests.sh' | sort)
listed="$(printf '%s\n' "${real[@]}")"
assert_contains "$listed" 'run-script-tests.sh'            "discovers the main suite"
assert_contains "$listed" 'run-parse-enrich-args-tests.sh' "discovers a runner the old list omitted"
assert_contains "$listed" 'run-link-skills-tests.sh'       "discovers the other omitted runner"
assert_not_contains "$listed" '/run-all.sh'                "run-all.sh is not itself a runner"

printf '\n%s─────%s\n' "$C_DIM" "$C_OFF"
printf '  %s%d passed%s' "$C_GREEN" "$PASS" "$C_OFF"
if [ "$FAIL" -gt 0 ]; then
  printf ', %s%d failed%s\n' "$C_RED" "$FAIL" "$C_OFF"
  printf '\nFailed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf '  - %s\n' "$n"; done
  exit 1
fi
printf '\n'
exit 0
