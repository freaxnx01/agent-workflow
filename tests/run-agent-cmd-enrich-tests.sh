#!/usr/bin/env bash
#
# run-agent-cmd-enrich-tests.sh — Layer-1 fixture tests for
# scripts/lib/agent-cmd-enrich.sh (no network; a stub `claude` on PATH
# stands in for the real CLI, so this is hermetic).
#
# Usage: tests/run-agent-cmd-enrich-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT

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

WRAPPER="$ROOT/scripts/lib/agent-cmd-enrich.sh"

# A `claude` stub on PATH: records argv and stdin, exits with $STUB_RC.
mkdir -p "$TMPDIR_T/bin"
cat > "$TMPDIR_T/bin/claude" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
( IFS=' '; printf '%s\n' "$*" > "$CLAUDE_STUB_ARGV" )
cat > "$CLAUDE_STUB_STDIN"
if [[ "${STUB_RC:-0}" -ne 0 ]]; then
  printf 'stub-diagnostic-line\n' >&2
fi
exit "${STUB_RC:-0}"
STUB
chmod +x "$TMPDIR_T/bin/claude"
export PATH="$TMPDIR_T/bin:$PATH"
export CLAUDE_STUB_ARGV="$TMPDIR_T/argv"
export CLAUDE_STUB_STDIN="$TMPDIR_T/stdin"
export AUTOPILOT_LOG_DIR="$TMPDIR_T/logs"
mkdir -p "$AUTOPILOT_LOG_DIR"

section "the prompt"

rc=0; "$WRAPPER" 373 || rc=$?
assert_eq "wrapper returns 0 when the session succeeds" "0" "$rc"
assert_eq "prompt is the headless enrich command" "/enrich 373 --quick --headless" "$(cat "$TMPDIR_T/stdin")"

section "the flags"

argv="$(cat "$TMPDIR_T/argv")"
case "$argv" in
  *--print*) pass "runs in print mode" ;;
  *) fail "runs in print mode" "argv was: $argv" ;;
esac
case "$argv" in
  *--allowedTools*) pass "passes a tool allowlist" ;;
  *) fail "passes a tool allowlist" "argv was: $argv" ;;
esac
case "$argv" in
  *Bash*) pass "allowlist includes Bash" ;;
  *) fail "allowlist includes Bash" "argv was: $argv" ;;
esac

section "MODEL"

rc=0; MODEL=claude-opus-5 "$WRAPPER" 42 || rc=$?
argv="$(cat "$TMPDIR_T/argv")"
case "$argv" in
  *"--model claude-opus-5"*) pass "MODEL becomes --model" ;;
  *) fail "MODEL becomes --model" "argv was: $argv" ;;
esac

rc=0; "$WRAPPER" 42 || rc=$?
argv="$(cat "$TMPDIR_T/argv")"
case "$argv" in
  *--model*) fail "no MODEL means no --model flag" "argv was: $argv" ;;
  *) pass "no MODEL means no --model flag" ;;
esac

section "exit status and diagnostics"

rc=0; STUB_RC=7 "$WRAPPER" 99 || rc=$?
assert_eq "session failure propagates" "7" "$rc"
if grep -qF 'stub-diagnostic-line' "$AUTOPILOT_LOG_DIR/enrich-99.log" 2>/dev/null; then
  pass "a failed session's log captures stderr diagnostics"
else
  fail "a failed session's log captures stderr diagnostics" "no stub-diagnostic-line in $AUTOPILOT_LOG_DIR/enrich-99.log"
fi

section "usage"

rc=0; "$WRAPPER" >/dev/null 2>&1 || rc=$?
assert_eq "missing issue number is a usage error" "2" "$rc"
rc=0; "$WRAPPER" not-a-number >/dev/null 2>&1 || rc=$?
assert_eq "non-numeric issue is a usage error" "2" "$rc"

printf '\n%s──────────%s\n' "$C_DIM" "$C_OFF"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf -- '  - %s\n' "$n"; done
  exit 1
fi
exit 0
