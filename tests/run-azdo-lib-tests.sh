#!/usr/bin/env bash
#
# run-azdo-lib-tests.sh — Layer-1 fixture tests for scripts/lib/azdo.sh.
# `az` is mocked via tests/mocks/az; no network, no live organization.
#
# Usage: tests/run-azdo-lib-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib/azdo.sh"
MOCKS="$ROOT/tests/mocks"
FIXTURES="$ROOT/tests/fixtures"

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

# run_lib <fixture> <function> [args...] — sources the library with `az` mocked
# and the AZDO_* context pre-set, then calls one function.
# SC2030/SC2031: the exports below are deliberately local to the subshell -- that
# isolation is what keeps each case independent. shellcheck flags every one.
# shellcheck disable=SC2030,SC2031
run_lib() {
  local fixture="$1"; shift
  (
    export PATH="$MOCKS:$PATH"
    export AZ_MOCK_FIXTURE="$FIXTURES/$fixture"
    [[ -n "${AZ_MOCK_MAP:-}" ]] && export AZ_MOCK_MAP
    export AZDO_ORG=contoso AZDO_PROJECT=MyProject AZDO_REPO=my-repo
    # shellcheck disable=SC1090
    source "$LIB"
    "$@"
  )
}

# --- cases -------------------------------------------------------------

section "azdo_org_url"

assert_eq "builds the org url from AZDO_ORG" "https://dev.azure.com/contoso" \
  "$(run_lib azdo-wiql-rows.json azdo_org_url)"

section "azdo_closed_states — derived from metadata, never hardcoded"

# The two fixtures are real responses from two live projects on different
# process templates. Basic has a Done state; the Agile-derived one does not.
# That difference is the whole reason this is derived rather than written out:
# no fixed list is correct on both.
assert_eq "basic template includes Done" "'Closed','Completed','Done','Inactive','Removed'" \
  "$(run_lib azdo-workitemtypes-basic.json azdo_closed_states)"

assert_eq "agile-derived template omits Done" "'Closed','Completed','Inactive','Removed'" \
  "$(run_lib azdo-workitemtypes-agile.json azdo_closed_states)"

section "azdo_wiql — rows, empty and TF51011 are three outcomes"

assert_eq "returns ids one per line" "$(printf '1\n2\n4')" \
  "$(run_lib azdo-wiql-rows.json azdo_wiql 'SELECT [System.Id] FROM WorkItems')"

# A missing Area Path ERRORS rather than returning no rows, so it gets its own
# exit code: a caller must be able to tell "this repo has no area" from
# "nothing is open". Conflating them is how the wrong answer gets reported.
set +e
run_lib azdo-wiql-tf51011.txt azdo_wiql 'SELECT [System.Id] FROM WorkItems' >/dev/null 2>&1
rc=$?
set -e
assert_eq "TF51011 exits 2, distinct from empty" "2" "$rc"

# The query travels by stdin as a JSON body, crossing bash, python3, az, REST
# and the WIQL parser, and it carries BOTH single quotes and a backslash. That
# is the combination that breaks when the body is hand-quoted instead of encoded,
# so assert it arrives intact rather than mangled.
AZ_MOCK_STDIN_LOG="$(mktemp)"
export AZ_MOCK_STDIN_LOG
run_lib azdo-wiql-rows.json azdo_wiql \
  "SELECT [System.Id] FROM WorkItems WHERE [System.AreaPath] UNDER 'MyProject\\my-repo'" >/dev/null

# Decode the body the way the REST layer would, and compare to the query as written.
got="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["query"])' "$AZ_MOCK_STDIN_LOG" 2>/dev/null || echo PARSE-FAILED)"
assert_eq "the body is valid JSON and the query survives intact" \
  "SELECT [System.Id] FROM WorkItems WHERE [System.AreaPath] UNDER 'MyProject\\my-repo'" "$got"

rm -f "$AZ_MOCK_STDIN_LOG"
unset AZ_MOCK_STDIN_LOG

section "azdo_work_item_types — what /new offers and /triage orders by"

# ADO has no `bug` label, it has a Bug TYPE, so /triage's bugs-first ordering
# keys off this rather than a tag.
assert_eq "lists the project's types" "$(printf 'Issue\nEpic\nTask')" \
  "$(run_lib azdo-workitemtypes-basic.json azdo_work_item_types | head -3)"

section "azdo_fields — System.Tags is ABSENT, not empty, when unset"

# Work item 1 genuinely carries no tags, and the API omits the key entirely
# rather than returning null or "". Indexing it directly is the bug this guards.
assert_eq "absent tags default to empty string" "1||A linked to an active PR (section 7)" \
  "$(run_lib azdo-batch-fields.json azdo_fields 1,4 | head -1 \
     | python3 -c 'import sys,json; d=json.loads(sys.stdin.readline()); print("%s|%s|%s" % (d["id"], d["tags"], d["title"]))')"

assert_eq "present tags come through" "alpha; beta; unparked" \
  "$(run_lib azdo-batch-fields.json azdo_fields 1,4 | tail -1 \
     | python3 -c 'import sys,json; print(json.loads(sys.stdin.readline())["tags"])')"

section "azdo_areas / azdo_iterations — children[] and the null case"

# The response is a SINGLE OBJECT, so a top-level [] query silently returns
# nothing. And `children` is null on a childless project, which makes
# length(children) error rather than return 0 -- so a childless project must
# yield nothing quietly, not blow up.
assert_eq "childless project yields nothing, does not error" "" \
  "$(run_lib azdo-areas-childless.json azdo_areas)"

assert_eq "nested project lists its children" "$(printf 'MyProject\nempty-area')" \
  "$(run_lib azdo-areas-nested.json azdo_areas)"

section "azdo_active_pr_work_items — WIP is an ACTIVE pr, nothing else"

# These two calls run with `--output tsv --query ...`, so the fixture is what az
# PRINTS after that processing, not the raw JSON body. The .json siblings are
# kept alongside as documentation of the underlying shape -- both are top-level
# arrays, which is why their --query paths were the two that turned out correct.
az_map="$(mktemp)"
printf 'repos pr list\t%s/azdo-pr-list-active.tsv\n' "$FIXTURES" > "$az_map"
printf 'repos pr work-item list\t%s/azdo-pr-workitems.tsv\n' "$FIXTURES" >> "$az_map"
assert_eq "collects work items linked to active PRs" "1" \
  "$(AZ_MOCK_MAP="$az_map" run_lib azdo-pr-list-active.tsv azdo_active_pr_work_items)"

# No active PRs is a legitimate answer meaning "nothing is WIP", not a failure.
printf 'repos pr list\t%s/azdo-pr-list-empty.tsv\n' "$FIXTURES" > "$az_map"
assert_eq "no active PRs means nothing is WIP" "" \
  "$(AZ_MOCK_MAP="$az_map" run_lib azdo-pr-list-empty.tsv azdo_active_pr_work_items)"
rm -f "$az_map"

section "azdo_set_tags — REPLACES, which --fields cannot do"

# `az boards work-item update --fields "System.Tags=..."` appends and an empty
# value is a no-op, so an unpark verb cannot be built on it. These assert the
# behaviour that difference exists for: shrinking a list, and clearing it.
ct_dir="$(mktemp -d)"
# shellcheck disable=SC2030,SC2031
run_set_tags() {
  local fixture="$1"; shift
  (
    export PATH="$MOCKS:$PATH"
    export AZ_MOCK_FIXTURE="$FIXTURES/azdo-wiql-rows.json"
    export CURL_MOCK_FIXTURE="$FIXTURES/$fixture"
    export CURL_MOCK_BODY_LOG="$ct_dir/body.txt" CURL_MOCK_LOG="$ct_dir/argv.txt"
    export AZDO_ORG=contoso AZDO_PROJECT=MyProject AZDO_REPO=my-repo
    export AZURE_DEVOPS_EXT_PAT=not-a-real-token
    # shellcheck disable=SC1090
    source "$LIB"
    azdo_set_tags "$@"
  )
}

assert_eq "replacing shrinks the list" "alpha" \
  "$(run_set_tags azdo-set-tags-replaced.json 4 'alpha')"

assert_eq "an empty value CLEARS rather than no-ops" "" \
  "$(run_set_tags azdo-set-tags-cleared.json 4 '')"

# The request must be a json-patch `replace`, not an `add` -- `add` on this field
# is what appends, which is the behaviour being escaped.
assert_eq "sends a json-patch replace on System.Tags" "replace" \
  "$(python3 -c '
import json,sys
print(json.loads(open(sys.argv[1]).read().strip().splitlines()[0])[0]["op"])' "$ct_dir/body.txt")"

# The PAT travels by `curl -K -` on stdin, never argv, so it cannot leak into a
# process listing. Assert it is absent from the recorded command line.
if grep -q 'not-a-real-token' "$ct_dir/argv.txt"; then
  fail "the PAT never appears on curl's command line" "found it in argv"
else
  pass "the PAT never appears on curl's command line"
fi
rm -rf "$ct_dir"

# --- summary -------------------------------------------------------------

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
