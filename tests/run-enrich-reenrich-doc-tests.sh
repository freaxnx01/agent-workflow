#!/usr/bin/env bash
#
# run-enrich-reenrich-doc-tests.sh — Layer-1 checks that every write-back site in
# commands/enrich.md and commands/enrich-phased.md strips a previous enrichment
# before composing the new body (#499).
#
# Those sections are prompts, not scripts, so these assert the shape the fix
# depends on rather than running it:
#   - each site sources scripts/lib/enrich-body.sh and strips the re-read body;
#   - the strip sits between the guarded read and the write, never before the
#     read's own non-empty guard;
#   - on Azure DevOps the read and the strip stay two separate guarded
#     statements, so a failed read can never become a write.
#
# Usage: tests/run-enrich-reenrich-doc-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENRICH="$ROOT/commands/enrich.md"
PHASED="$ROOT/commands/enrich-phased.md"

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
  [[ $# -gt 1 ]] && printf '      %s\n' "$2"
  return 0
}

# slice <text> <start-regex> <stop-regex>  echoes the lines from the first line
# matching <start-regex> up to (not including) the next line matching
# <stop-regex>. Both headings repeat across the forge sections of these files —
# "### Step 6 — Update the issue body" appears under GitHub and under Forgejo —
# so every lookup slices the forge section first, then the step inside it.
slice() {
  printf '%s\n' "$1" | awk -v start="$2" -v stop="$3" \
    '$0 ~ start && !on { on = 1; print; next } on && $0 ~ stop { exit } on { print }'
}

# line_of <text> <regex>  echoes the 1-based number of the first matching line,
# or nothing. Ordering assertions compare these — "the strip is in the section"
# is not the property that matters; "the strip is after the read's guard and
# before the write" is.
line_of() {
  printf '%s\n' "$1" | grep -nE -- "$2" | head -1 | cut -d: -f1 || true
}

# assert_before <name> <text> <earlier-regex> <later-regex>
assert_before() {
  local name="$1" text="$2" earlier="$3" later="$4"
  local a b
  a="$(line_of "$text" "$earlier")"
  b="$(line_of "$text" "$later")"
  if [[ -n "$a" && -n "$b" ]] && (( a < b )); then
    pass "$name"
  else
    fail "$name" "earlier at ${a:-none}, later at ${b:-none}"
  fi
}

# assert_contains <name> <text> <fixed-string>
assert_contains() {
  local name="$1" text="$2" needle="$3"
  if printf '%s\n' "$text" | grep -qF -- "$needle"; then
    pass "$name"
  else
    fail "$name" "expected to find: $needle"
  fi
}

github="$(slice "$(cat "$ENRICH")" '^## GitHub$' '^## ')"
forgejo="$(slice "$(cat "$ENRICH")" '^## Forgejo$' '^## ')"
azdo="$(slice "$(cat "$ENRICH")" '^## Azure DevOps$' '^## ')"
[[ -n "$github" && -n "$forgejo" && -n "$azdo" ]] \
  || { printf 'could not slice the forge sections of %s\n' "$ENRICH" >&2; exit 1; }

gh_step6="$(slice "$github" '^### Step 6 — Update the issue body$' '^### ')"
fj_step6="$(slice "$forgejo" '^### Step 6 — Update the issue body$' '^### ')"
[[ -n "$gh_step6" && -n "$fj_step6" ]] \
  || { printf 'could not slice the Step 6 sections of %s\n' "$ENRICH" >&2; exit 1; }

section "enrich.md — GitHub Step 6"

assert_contains "GitHub Step 6 sources the strip library" "$gh_step6" 'enrich-body.sh'
assert_contains "GitHub Step 6 strips the re-read body" "$gh_step6" 'enrich_body_strip_markdown'
assert_before "GitHub Step 6 strips after the read's non-empty guard" "$gh_step6" \
  '\[ -s orig-body\.md \] \|\|' 'enrich_body_strip_markdown'
# shellcheck disable=SC2016  # the regexes are the doc's literal text, not expansions
assert_before "GitHub Step 6 strips before the write" "$gh_step6" \
  'enrich_body_strip_markdown' 'gh issue edit \$ISSUE --body-file'

# The pre-write assertion is what would otherwise still demand every image from
# a previous run's sections survive — it has to compare against the stripped
# prefix, not the raw original.
gh_assertion_paragraph="$(printf '%s\n' "$gh_step6" | awk 'BEGIN{RS=""} /user-attachments/')"
if [[ -n "$gh_assertion_paragraph" ]]; then
  assert_contains "GitHub assertion uses the stripped prefix" \
    "$gh_assertion_paragraph" 'kept-body.md'
else
  fail "GitHub assertion uses the stripped prefix" "no pre-write assertion paragraph found"
fi

section "enrich.md — Forgejo Step 6"

assert_contains "Forgejo Step 6 sources the strip library" "$fj_step6" 'enrich-body.sh'
assert_contains "Forgejo Step 6 strips the re-read body" "$fj_step6" 'enrich_body_strip_markdown'
assert_before "Forgejo Step 6 strips after the read's non-empty guard" "$fj_step6" \
  '\[ -s orig-body\.md \] \|\|' 'enrich_body_strip_markdown'
assert_before "Forgejo Step 6 strips before the write" "$fj_step6" \
  'enrich_body_strip_markdown' 'tea api -X PATCH'

section "enrich.md — Azure DevOps"

assert_contains "ADO block sources the strip library" "$azdo" 'enrich-body.sh'
assert_before "ADO read guard precedes the strip" "$azdo" \
  'orig="\$\(azdo_description.*\|\| \{' 'enrich_body_strip_html'
# shellcheck disable=SC2016  # the regexes are the doc's literal text, not expansions
assert_before "ADO strip precedes the write" "$azdo" \
  'enrich_body_strip_html' 'azdo_set_description "\$ISSUE"'

if printf '%s\n' "$azdo" | grep -E -- 'enrich_body_strip_html' | grep -qF -- '|| {'; then
  pass "ADO strip is guarded"
else
  fail "ADO strip is guarded" "no 'enrich_body_strip_html ... || {' line"
fi

# A pipeline would take the filter's exit status, so a failed read would compose
# an empty description and the write would destroy the stored body.
if printf '%s\n' "$azdo" | grep -qE -- 'azdo_description[^|]*\|[^|]'; then
  fail "ADO strip is not piped off the read" \
    "found an azdo_description pipeline — read and strip must be separate statements"
else
  pass "ADO strip is not piped off the read"
fi

section "enrich-phased.md — phase \`issue\`"

ph_github="$(slice "$(cat "$PHASED")" '^## GitHub$' '^## ')"
ph_forgejo="$(slice "$(cat "$PHASED")" '^## Forgejo$' '^## ')"
[[ -n "$ph_github" && -n "$ph_forgejo" ]] \
  || { printf 'could not slice the forge sections of %s\n' "$PHASED" >&2; exit 1; }

# shellcheck disable=SC2016  # the backticked markdown heading is doc text, not an expansion
ph_gh_issue="$(slice "$ph_github" '^### Phase `issue`$' '^### ')"
# shellcheck disable=SC2016  # the backticked markdown heading is doc text, not an expansion
ph_fj_issue="$(slice "$ph_forgejo" '^### Phase `issue`$' '^### ')"
# shellcheck disable=SC2016  # the backticked markdown heading is doc text, not an expansion
[[ -n "$ph_gh_issue" && -n "$ph_fj_issue" ]] \
  || { printf 'could not slice the `issue` phases of %s\n' "$PHASED" >&2; exit 1; }

assert_contains "GitHub issue phase strips" "$ph_gh_issue" 'enrich_body_strip_markdown'
assert_contains "Forgejo issue phase strips" "$ph_fj_issue" 'enrich_body_strip_markdown'

# The phase must point at the guarded fetch, not invite piping the read into
# the filter: `gh issue view … | enrich_body_strip_markdown` takes the filter's
# exit status and skips Step 6's retry and `[ -s orig-body.md ]` guard, so a
# failed read would write a body with no human description.
for forge in GitHub Forgejo; do
  if [[ $forge == GitHub ]]; then text="$ph_gh_issue"; else text="$ph_fj_issue"; fi
  assert_contains "$forge issue phase reads through the guarded fetch" "$text" 'kept-body.md'
  if printf '%s\n' "$text" | grep -qiE 'pipe[[:space:]]+the[[:space:]]+re-read'; then
    fail "$forge issue phase does not invite piping the read" "found 'pipe the re-read'"
  else
    pass "$forge issue phase does not invite piping the read"
  fi
done

printf '\npassed: %d   failed: %d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf -- '  - %s\n' "$n"; done
  exit 1
fi
exit 0
