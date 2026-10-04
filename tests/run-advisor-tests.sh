#!/usr/bin/env bash
#
# run-advisor-tests.sh — Layer-1 contract tests for /factory-advisor (#459).
#
# /factory-advisor is a prompt plus a settings file, so there is no runtime to drive.
# What can drift is the contract: the command must read the canonical docs and
# ask for a topic, the deny-list must hold the rules that make "the advisor
# never merges" enforced rather than promised, ADVISOR-PROMPT.md must carry the
# rules that used to live only in claude.ai Project memory, and the command
# must be listed where the other commands are.
#
# Usage: tests/run-advisor-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMMAND="$ROOT/commands/factory-advisor.md"
SETTINGS="$ROOT/setup/advisor-settings.json"
PROMPT="$ROOT/docs/ADVISOR-PROMPT.md"

# The deny rules #459 §3 requires. Exact strings: a rule that is spelled
# differently is a rule Claude Code may not match. The approve rules wildcard
# both sides because the PR number usually comes first (`gh pr review 12
# --approve`), which a `gh pr review --approve` prefix would never see; the
# `gh api` merge endpoint is the same merge spelled another way.
REQUIRED_DENY=(
  'Bash(gh pr merge:*)'
  'Bash(gh pr review *--approve*)'
  'Bash(gh pr review * -a*)'
  'Bash(gh api *pulls/*/merge*)'
  'Bash(gh secret set:*)'
  'Bash(gh secret delete:*)'
)

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

# assert_contains <name> <file> <fixed-string>
assert_contains() {
  if [[ -f "$2" ]] && grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1" "no '$3' in ${2#"$ROOT"/}"; fi
}

section "commands/factory-advisor.md"
# Claude Code ships a built-in /advisor; a user command of the same name shows
# up twice in the / menu with no way to tell which one runs.
if [[ -e "$ROOT/commands/advisor.md" ]]; then
  fail "no commands/advisor.md (clashes with the built-in /advisor)"
else
  pass "no commands/advisor.md (clashes with the built-in /advisor)"
fi
if [[ -f "$COMMAND" ]] && [[ "$(head -n1 "$COMMAND")" == "---" ]] \
   && sed -n '2,/^---$/p' "$COMMAND" | grep -q '^description: '; then
  pass "has description front-matter"
else
  fail "has description front-matter" "missing file or front-matter"
fi
assert_contains "reads ADVISOR-PROMPT.md" "$COMMAND" "docs/ADVISOR-PROMPT.md"
assert_contains "reads FACTORY-MAP.md" "$COMMAND" "docs/FACTORY-MAP.md"
# shellcheck disable=SC2016  # literal $ARGUMENTS, not an expansion
assert_contains "takes the topic from \$ARGUMENTS" "$COMMAND" '$ARGUMENTS'
assert_contains "asks for a topic when given none" "$COMMAND" "ask for one"
assert_contains "names the auto-lane-v1 agenda" "$COMMAND" "--milestone auto-lane-v1"
assert_contains "reads run actors from the REST API" "$COMMAND" "triggering_actor"
# `gh run view --json` has no actor fields ("Unknown JSON field: actor") —
# found by the first real advisor run against #430.
if grep -qE '^gh run view .*--json[^|]*actor' "$COMMAND"; then
  fail "does not ask gh run view for actor fields" "gh run view --json has no actor/triggeringActor"
else
  pass "does not ask gh run view for actor fields"
fi
assert_contains "points at the guardrail settings" "$COMMAND" "setup/advisor-settings.json"

section "setup/advisor-settings.json"
if [[ -f "$SETTINGS" ]] && jq -e . "$SETTINGS" >/dev/null 2>&1; then
  pass "is valid JSON"
  for rule in "${REQUIRED_DENY[@]}"; do
    if jq -e --arg r "$rule" '.permissions.deny | index($r)' "$SETTINGS" >/dev/null; then
      pass "denies $rule"
    else
      fail "denies $rule"
    fi
  done
  if jq -e '[.permissions.deny[] | select(test("protection"))] | length > 0' "$SETTINGS" >/dev/null; then
    pass "denies branch-protection writes"
  else
    fail "denies branch-protection writes"
  fi
else
  fail "is valid JSON" "missing or unparseable: ${SETTINGS#"$ROOT"/}"
fi

section "docs/ADVISOR-PROMPT.md"
assert_contains "TL;DR rule" "$PROMPT" "TL;DR"
# shellcheck disable=SC2016  # literal backticks, not a command substitution
assert_contains "failure mode: trusting ai:done" "$PROMPT" 'Trusting `ai:done`'
assert_contains "failure mode: numbering gaps" "$PROMPT" "numbering gap"
assert_contains "failure mode: write without read-back" "$PROMPT" "Write without read-back"
assert_contains "bridge MCP limits (bridge#335)" "$PROMPT" "bridge#335"
assert_contains "Claude Code launch with the deny-list" "$PROMPT" "setup/advisor-settings.json"
assert_contains "names the command /factory-advisor" "$PROMPT" "/factory-advisor"

section "listings"
assert_contains "commands/README.md lists /factory-advisor" "$ROOT/commands/README.md" "/factory-advisor"
assert_contains "COMMAND-CHEATSHEET.md lists /factory-advisor" "$ROOT/docs/COMMAND-CHEATSHEET.md" "/factory-advisor"
assert_contains "README.md command block lists /factory-advisor" "$ROOT/README.md" "/factory-advisor"

# --- summary ---------------------------------------------------------------

printf '\n%s─────%s\n' "$C_DIM" "$C_OFF"
printf '  %s%d passed%s' "$C_GREEN" "$PASS" "$C_OFF"
[ "$FAIL" -gt 0 ] && printf ', %s%d failed%s' "$C_RED" "$FAIL" "$C_OFF"
printf '\n'
if [ "$FAIL" -gt 0 ]; then
  printf '\n  failed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf '    - %s\n' "$n"; done
  exit 1
fi
