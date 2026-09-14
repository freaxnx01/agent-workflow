#!/usr/bin/env bash
#
# run-blocked-models-tests.sh — Layer-1 tests for scripts/lib/blocked-models.sh
# (no network). Sources the lib and asserts the pattern query plus the
# substitution helper every guarded call site uses. Which *routes* the guard
# applies to is covered in run-script-tests.sh, not here.
#
# Usage: tests/run-blocked-models-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib/blocked-models.sh"

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
  if [[ "$actual" == "$expected" ]]; then
    pass "$name"
  else
    fail "$name" "expected: $expected | actual: $actual"
  fi
}

# shellcheck source=scripts/lib/blocked-models.sh disable=SC1091  # hook runs without -x; SC1091 is conventionally suppressed
source "$LIB"

# is_blocked <model> — "yes" when the denylist matches, else "no"
is_blocked() { model_is_blocked "$1" && echo yes || echo no; }

# resolve <model> [substitute] — stdout only (stderr warning discarded)
resolve() { allowed_model_or_fallback "$@" 2>/dev/null; }

section "model_is_blocked — the guarded patterns"

assert_eq "the canonical Fable id is guarded"  yes "$(is_blocked claude-fable-5-1)"
assert_eq "a 1m-context Fable id is guarded"   yes "$(is_blocked 'claude-fable-5-1[1m]')"
assert_eq "a future Fable id is guarded"       yes "$(is_blocked claude-fable-6)"
assert_eq "a bare 'fable' is guarded"          yes "$(is_blocked fable)"

assert_eq "sonnet is allowed"                  no  "$(is_blocked claude-sonnet-5)"
assert_eq "opus is allowed"                    no  "$(is_blocked claude-opus-5)"
assert_eq "a dated haiku id is allowed"        no  "$(is_blocked claude-haiku-4-5-20251001)"
assert_eq "an OpenRouter id is allowed"        no  "$(is_blocked z-ai/glm-5.2)"
assert_eq "an empty model is allowed"          no  "$(is_blocked '')"

section "allowed_model_or_fallback — substitution"

assert_eq "an allowed model passes through untouched" \
  claude-opus-5 "$(resolve claude-opus-5 claude-sonnet-5)"

assert_eq "an empty model stays empty (keeps the no---model contract)" \
  '' "$(resolve '' claude-sonnet-5)"

assert_eq "a blocked model is replaced by the substitute" \
  claude-sonnet-5 "$(resolve claude-fable-5-1 claude-sonnet-5)"

assert_eq "a blocked model with no substitute uses the hardcoded fallback" \
  claude-sonnet-5 "$(resolve claude-fable-5-1)"

assert_eq "a blocked substitute cannot smuggle Fable back in" \
  claude-sonnet-5 "$(resolve claude-fable-5-1 claude-fable-6)"

assert_eq "the hardcoded fallback is itself unguarded" \
  no "$(is_blocked "$BLOCKED_MODEL_FALLBACK")"

section "allowed_model_or_fallback — operator feedback"

blocked_stderr="$(allowed_model_or_fallback claude-fable-5-1 claude-sonnet-5 2>&1 >/dev/null)"
case "$blocked_stderr" in
  *fable*) pass "a substitution names the guarded model on stderr" ;;
  *)       fail "a substitution names the guarded model on stderr" "stderr: $blocked_stderr" ;;
esac

case "$blocked_stderr" in
  *"model:*"*) pass "the warning points at the label as the deliberate route" ;;
  *)           fail "the warning points at the label as the deliberate route" "stderr: $blocked_stderr" ;;
esac

allowed_stderr="$(allowed_model_or_fallback claude-opus-5 claude-sonnet-5 2>&1 >/dev/null)"
assert_eq "an allowed model warns about nothing" '' "$allowed_stderr"

# --- summary ---------------------------------------------------------------

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
