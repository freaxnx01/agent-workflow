#!/usr/bin/env bash
#
# run-enrich-cost-rules-doc-tests.sh — Layer-1 checks on commands/enrich.md's
# "## Cost rules" section (#456). The section is a prompt, not a script, so
# these assert the shape the cost rules depend on:
#   - model by issue size, picked by the caller at launch;
#   - no dry runs, with bug reproduction kept mandatory;
#   - a concurrency cap of four;
#   - both Step 3 sections point at the section.
#
# Usage: tests/run-enrich-cost-rules-doc-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOC="$ROOT/commands/enrich.md"

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

# check NAME PATTERN [grep flags] — assert PATTERN matches the section.
check() {
  local name="$1" pattern="$2" flags="${3:--E}"
  if printf '%s\n' "$section" | grep -q "$flags" -- "$pattern"; then
    pass "$name"
  else
    fail "$name" "no match for: $pattern"
  fi
}

# The cost rules section: from its heading up to the next level-2 heading.
section="$(awk '/^## Cost rules$/{on=1; print; next} on && /^## /{exit} on{print}' "$DOC")"

if [[ -n "$section" ]]; then
  pass "the Cost rules section exists"
else
  fail "the Cost rules section exists" "no '## Cost rules' in $DOC"
  section=""
fi

for heading in 'Model by issue size' 'No dry runs' 'Concurrency'; do
  check "has the '### $heading' subheading" "^### $heading\$"
done

model_section="$(printf '%s\n' "$section" | awk '/^### Model by issue size$/{on=1; next} on && /^### /{exit} on{print}')"
for name in Sonnet Opus Fable; do
  if printf '%s\n' "$model_section" | grep -q "$name"; then
    pass "the model subsection names $name"
  else
    fail "the model subsection names $name"
  fi
done

check "the caller picks the model at launch" 'caller'
check "names the Agent tool model parameter" "\`model\`"
check "names the --model flag" '--model' -F
check "the batch caller states which model it picked" 'states? which' -Ei
check "names the lane's MODEL limit" "\`MODEL\`"
check "names blocked-models.sh" 'blocked-models\.sh'
check "no-dry-runs keeps reproduction" 'reproduc'
check "reproduction is mandatory" 'mandatory'
check "data probes stay allowed" 'probe'
check "concurrency caps at four" 'at most (4|four)' -Ei

linked="$(awk '/^### Step 3 — Brainstorm spec/{on=1; next} /^##/{on=0} on && /\(#cost-rules\)/{n++; on=0} END{print n+0}' "$DOC")"
if [[ "$linked" -eq 2 ]]; then
  pass "both Step 3 sections link (#cost-rules)"
else
  fail "both Step 3 sections link (#cost-rules)" "found $linked, expected 2"
fi

printf '\npassed: %d   failed: %d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf -- '  - %s\n' "$n"; done
  exit 1
fi
exit 0
