#!/usr/bin/env bash
#
# run-enrich-batch-doc-tests.sh — Layer-1 checks on commands/enrich-batch.md
# (#453). The command is a prompt, not a script, so these assert the shape the
# batch session depends on:
#   - selection through autopilot-candidates.sh, narrowed by number or milestone;
#   - three groups, an interview before and after dispatch;
#   - one worktree subagent per issue under the enrich.md Cost rules;
#   - housekeeping of locks, drafts and worktrees;
#   - a scope boundary that never dispatches, reviews or merges.
#
# Usage: tests/run-enrich-batch-doc-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOC="$ROOT/commands/enrich-batch.md"

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

# check NAME TEXT PATTERN [grep flags] — assert PATTERN matches TEXT.
check() {
  local name="$1" text="$2" pattern="$3" flags="${4:--E}"
  if printf '%s\n' "$text" | grep -q "$flags" -- "$pattern"; then
    pass "$name"
  else
    fail "$name" "no match for: $pattern"
  fi
}

# section HEADING-REGEX — the lines from the first heading matching the regex
# up to the next heading of any level. Lines inside ``` fences are never
# headings: a `# comment` in a bash block must not end the section.
section() {
  [[ -f "$DOC" ]] || return 0
  awk -v re="$1" '
    /^```/{fence=!fence}
    !fence && on && /^#+ /{exit}
    !fence && /^#+ / && $0 ~ re {on=1}
    on{print}
  ' "$DOC"
}

if [[ -f "$DOC" ]]; then
  pass "commands/enrich-batch.md exists"
  doc="$(cat "$DOC")"
else
  fail "commands/enrich-batch.md exists" "missing: $DOC"
  doc=""
fi

# 1. Frontmatter.
frontmatter="$(awk 'NR==1 && /^---$/{on=1; next} on && /^---$/{exit} on{print}' "$DOC" 2>/dev/null || true)"
check "frontmatter has description:" "$frontmatter" '^description: '
check "frontmatter has argument-hint:" "$frontmatter" '^argument-hint: '

# 2. Forge detection; non-GitHub forges unsupported.
check "sources detect-forge.sh" "$doc" 'detect-forge\.sh'
check "has a Forgejo or Other forges heading" "$doc" '^## (Forgejo|Other forges)'
check "says other forges are not supported" "$doc" 'not supported|GitHub-only' -Ei

# 3. Selection.
check "sources autopilot-candidates.sh" "$doc" 'autopilot-candidates\.sh'
check "calls autopilot_candidates" "$doc" 'autopilot_candidates '
check "mentions --milestone" "$doc" '--milestone' -F

# 4. Grouping.
for group in 'quick and clear' 'needs decisions' 'cause-finding'; do
  check "names the '$group' group" "$doc" "$group" -Fi
done

# 5. Interview first.
first="$(section 'Interview first')"
check "has an Interview first heading" "$first" '^#+ .*Interview first'
check "interview first uses AskUserQuestion" "$first" 'AskUserQuestion' -F
check "interview first passes answers as [confirmed]" "$first" '[confirmed]' -F
check "interview first recommends an option" "$first" 'recommend' -Fi

# 6. Dispatch.
check "mentions isolation" "$doc" 'isolation' -F
check "mentions worktree" "$doc" 'worktree' -F
check "runs /enrich <n> --headless" "$doc" '--headless' -F
check "links enrich.md#cost-rules" "$doc" 'enrich.md#cost-rules' -F
check "states which model it picked" "$doc" 'which model' -Fi
check "every subagent prompt carries the confirmed answers" "$doc" 'every (subagent )?prompt.*confirmed' -Ei

# 7. Bugs.
check "bugs are reproduced" "$doc" 'reproduc' -Fi
check "unreproducible bugs go to needs-human" "$doc" 'needs-human' -F
bad_playwright="$(printf '%s\n' "$doc" | grep -F 'Playwright' | grep -Eiv 'e\.g\.|for example|such as' || true)"
if [[ -z "$bad_playwright" ]]; then
  pass "Playwright is only ever an example"
else
  fail "Playwright is only ever an example" "mandated on: $bad_playwright"
fi

# 8. Interview after.
after="$(section 'Interview after')"
check "has an Interview after heading" "$after" '^#+ .*Interview after'
check "interview after asks about [med] assumptions" "$after" '[med]' -F
check "interview after amends" "$after" 'amend' -Fi
check "interview after names the spec" "$after" 'spec' -Fi
check "interview after names the plan" "$after" 'plan' -Fi
check "interview after names the issue body" "$after" 'issue body' -Fi

# 9. Housekeeping.
house="$(section 'Housekeeping')"
check "has a Housekeeping heading" "$house" '^#+ .*Housekeeping'
check "releases enrichment-ongoing locks" "$house" '--remove-label enrichment-ongoing' -F
check "saves cut-off drafts to the scratchpad" "$house" 'scratchpad' -Fi
check "removes worktrees only when clean" "$house" 'clean' -F
# shellcheck disable=SC2016  # literal $wt: the doc text, not an expansion
check "tests cleanliness with status --porcelain" "$house" 'git( -C "\$wt")? status --porcelain' -E
check "removes worktrees only with nothing missing from main" "$house" 'missing from main|not on main' -Ei
check "checks commits against origin/main" "$house" 'origin/main..HEAD' -F
# shellcheck disable=SC2016  # literal $wt: the doc text, not an expansion
check "falls back to git cherry for rebased merges" "$house" 'git -C "$wt" cherry origin/main' -F
check "fetches origin before comparing" "$house" 'fetch origin' -F
check "records the landing order" "$house" 'landing order' -Fi

# 10. Scope boundary.
scope="$(section 'Scope boundary')"
check "has a Scope boundary heading" "$scope" '^#+ .*Scope boundary'
check "never applies ai-implement" "$scope" 'never.*ai-implement|ai-implement.*never' -Ei

# 11. Self-improvement closing line.
last="$(grep -v '^[[:space:]]*$' "$DOC" 2>/dev/null | tail -n 1 || true)"
if [[ "$last" == 'If you run into blockers, find a solution and update this command for the future.' ]]; then
  pass "ends with the self-improvement line"
else
  fail "ends with the self-improvement line" "last line: $last"
fi

# 12. Listed in the command docs.
for listing in commands/README.md docs/COMMAND-CHEATSHEET.md; do
  if grep -qF '/enrich-batch' "$ROOT/$listing"; then
    pass "$listing lists /enrich-batch"
  else
    fail "$listing lists /enrich-batch"
  fi
done

printf '\npassed: %d   failed: %d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf -- '  - %s\n' "$n"; done
  exit 1
fi
exit 0
