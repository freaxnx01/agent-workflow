#!/usr/bin/env bash
#
# run-enrich-headless-doc-tests.sh — Layer-1 checks on commands/enrich.md's
# "## Headless mode" section (#458). The section is a prompt, not a script, so
# these assert the shape the headless escalation depends on:
#   - needs-human is created before the escalation edit applies it, with the
#     color and description scripts/ensure-issue-labels.sh registers;
#   - the create swallows "already exists";
#   - the escalation is read back;
#   - the never-wait rule is stated, and says label state is the contract.
#
# Usage: tests/run-enrich-headless-doc-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOC="$ROOT/commands/enrich.md"
LABELS="$ROOT/scripts/ensure-issue-labels.sh"

PASS=0
FAIL=0
FAIL_NAMES=()

pass() { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
fail() {
  FAIL=$((FAIL + 1)); FAIL_NAMES+=("$1")
  printf '  ✗ %s\n' "$1"
  [[ $# -gt 1 ]] && printf '      %s\n' "$2"
  return 0
}

# The headless section: from its heading up to the next level-2 heading.
section="$(awk '/^## Headless mode$/{on=1; print; next} on && /^## /{exit} on{print}' "$DOC")"
[[ -n "$section" ]] || { printf 'no "## Headless mode" section in %s\n' "$DOC" >&2; exit 1; }

# needs-human's registered color and description, from the label registry.
registry_line="$(grep -E "^create needs-human " "$LABELS")"
color="$(printf '%s\n' "$registry_line" | awk '{print $3}')"
description="$(printf '%s\n' "$registry_line" | sed -E "s/^create needs-human [0-9A-Fa-f]{6} '(.*)'$/\1/")"

create_line="$(printf '%s\n' "$section" | grep -n 'gh label create needs-human' | head -1 | cut -d: -f1 || true)"
edit_line="$(printf '%s\n' "$section" | grep -n 'gh issue edit .*--add-label needs-human' | head -1 | cut -d: -f1 || true)"

if [[ -n "$create_line" ]]; then
  pass "headless mode creates needs-human"
else
  fail "headless mode creates needs-human" "no 'gh label create needs-human' in the section"
fi

if [[ -n "$create_line" && -n "$edit_line" ]] && (( create_line < edit_line )); then
  pass "the create precedes the escalation edit"
else
  fail "the create precedes the escalation edit" "create at ${create_line:-none}, edit at ${edit_line:-none}"
fi

if printf '%s\n' "$section" | grep -q -- "--color $color"; then
  pass "the create uses the registry color ($color)"
else
  fail "the create uses the registry color ($color)"
fi

if printf '%s\n' "$section" | grep -qF -- "$description"; then
  pass "the create uses the registry description"
else
  fail "the create uses the registry description" "expected: $description"
fi

if printf '%s\n' "$section" | grep -A3 'gh label create needs-human' | grep -qF '|| true'; then
  pass "the create swallows 'already exists'"
else
  fail "the create swallows 'already exists'"
fi

if printf '%s\n' "$section" | grep -qF 'index("needs-human")'; then
  pass "the escalation is read back"
else
  fail "the escalation is read back"
fi

if printf '%s\n' "$section" | grep -q '^### Never wait$'; then
  pass "the never-wait rule has its own heading"
else
  fail "the never-wait rule has its own heading"
fi

if printf '%s\n' "$section" | grep -qi 'label state'; then
  pass "the rule names label state as the contract"
else
  fail "the rule names label state as the contract"
fi

printf '\npassed: %d   failed: %d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf -- '  - %s\n' "$n"; done
  exit 1
fi
exit 0
