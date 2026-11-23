#!/usr/bin/env bash
#
# run-azdo-plan-pointer-tests.sh — Layer-1 tests for scripts/lib/azdo-plan-pointer.sh
# (#651, Task 1), the plan-pointer extractor the ADO turn budget sizes from.
#
# The bodies here are raw HTML, because System.Description is an HTML field
# (ADR-017) and that is exactly what /enrich writes the pointer into.
#
# Usage: tests/run-azdo-plan-pointer-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib/azdo-plan-pointer.sh"

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

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CASE_N=0
RC=0; OUT=''

# pointer <body> — runs azdo_plan_pointer with the library sourced, in its own
# process; sets RC and OUT. No `set -e`: rc 1 is a documented answer here.
pointer() {
  CASE_N=$((CASE_N + 1))
  local script="$TMP/case-$CASE_N.sh"
  {
    printf '#!/usr/bin/env bash\nset -uo pipefail\nIFS=$'"'"'\\n\\t'"'"'\n'
    printf 'source %q\n' "$LIB"
    # shellcheck disable=SC2016  # $1 is the inner bash's argument, not this one's
    printf 'azdo_plan_pointer "$1"\n'
  } > "$script"
  RC=0
  OUT="$(bash "$script" "$1" 2>"$TMP/err-$CASE_N")" || RC=$?
}

section "azdo_plan_pointer"

pointer '<li><code>docs/superpowers/plans/2026-01-01-x.md</code></li>'
assert_eq "azdo_plan_pointer_ExtractsFromCodeTag: rc" "0" "$RC"
assert_eq "azdo_plan_pointer_ExtractsFromCodeTag: path" \
  "docs/superpowers/plans/2026-01-01-x.md" "$OUT"

# The same pointer written with the tags HTML-escaped, which is how an HTML
# field round-trips a pasted Markdown list. The bare path must still come out.
pointer '&lt;code&gt;docs/superpowers/plans/2026-01-01-x.md&lt;/code&gt;'
assert_eq "azdo_plan_pointer_ExtractsFromEscapedCodeTag: rc" "0" "$RC"
assert_eq "azdo_plan_pointer_ExtractsFromEscapedCodeTag: path" \
  "docs/superpowers/plans/2026-01-01-x.md" "$OUT"

# /enrich writes the spec pointer first. The spec is not the plan.
pointer '<p>Spec: <code>docs/superpowers/specs/2026-01-01-x-design.md</code></p>
<p>Plan: <code>docs/superpowers/plans/2026-01-01-x.md</code></p>'
assert_eq "azdo_plan_pointer_SkipsSpecPath: rc" "0" "$RC"
assert_eq "azdo_plan_pointer_SkipsSpecPath: path" \
  "docs/superpowers/plans/2026-01-01-x.md" "$OUT"

pointer '<p><code>docs/superpowers/plans/first.md</code></p>
<p><code>docs/superpowers/plans/second.md</code></p>'
assert_eq "azdo_plan_pointer_FirstOfTwo: rc" "0" "$RC"
assert_eq "azdo_plan_pointer_FirstOfTwo: path" "docs/superpowers/plans/first.md" "$OUT"

pointer '<p>Implement the thing. No pointers here, just <code>scripts/x.sh</code>.</p>'
assert_eq "azdo_plan_pointer_None: rc" "1" "$RC"
assert_eq "azdo_plan_pointer_None: prints nothing" "" "$OUT"

pointer ''
assert_eq "azdo_plan_pointer_EmptyBody: rc" "1" "$RC"
assert_eq "azdo_plan_pointer_EmptyBody: prints nothing" "" "$OUT"

pointer '<code>docs/../plans/x.md</code>'
assert_eq "azdo_plan_pointer_RejectsDotDot: rc" "1" "$RC"
assert_eq "azdo_plan_pointer_RejectsDotDot: prints nothing" "" "$OUT"

pointer '<code>docs/plans/../../etc/x.md</code>'
assert_eq "azdo_plan_pointer_RejectsDotDotEscape: rc" "1" "$RC"
assert_eq "azdo_plan_pointer_RejectsDotDotEscape: prints nothing" "" "$OUT"

pointer '<code>/docs/plans/x.md</code>'
assert_eq "azdo_plan_pointer_RejectsAbsolute: rc" "1" "$RC"
assert_eq "azdo_plan_pointer_RejectsAbsolute: prints nothing" "" "$OUT"

# A URL is an absolute path with a scheme in front of it, and reading it from
# the checkout would mean reading something the pointer never named.
pointer '<a href="https://example.invalid/docs/superpowers/plans/x.md">plan</a>'
assert_eq "azdo_plan_pointer_RejectsUrl: rc" "1" "$RC"
assert_eq "azdo_plan_pointer_RejectsUrl: prints nothing" "" "$OUT"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then printf 'Failed: %s\n' "${FAIL_NAMES[*]}"; exit 1; fi
