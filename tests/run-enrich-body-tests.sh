#!/usr/bin/env bash
#
# run-enrich-body-tests.sh — Layer-1 fixture tests for scripts/lib/enrich-body.sh
# (no network). Sources the library and drives each filter against a fixture
# pair, comparing byte-for-byte with `cmp` so CRs and trailing newlines count.
#
# The filters strip a previous run's enrich-owned sections so a re-enrichment
# replaces them instead of appending a second copy (#499).
#
# Usage: tests/run-enrich-body-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib/enrich-body.sh"
FIXTURES="$ROOT/tests/fixtures/enrich-body"

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

if [[ ! -f "$LIB" ]]; then
  printf 'missing library: %s\n' "$LIB" >&2
  exit 1
fi
# shellcheck source=../scripts/lib/enrich-body.sh
source "$LIB"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# assert_strip_files <case-name> <filter> <input-file> <expected-file>
#   Runs <filter> over <input-file> and compares its stdout with
#   <expected-file>. `cmp` and not `diff`/`[[ == ]]`: a CR or a dropped trailing
#   newline is exactly the kind of difference these filters must not introduce,
#   and command substitution would eat it.
assert_strip_files() {
  local name="$1" filter="$2" in="$3" expected="$4"
  local actual="$TMP/$name.actual" status=0

  if [[ ! -f "$in" || ! -f "$expected" ]]; then
    fail "$name" "missing input or expectation ($in / $expected)"
    return 0
  fi

  "$filter" < "$in" > "$actual" || status=$?
  if (( status != 0 )); then
    fail "$name" "$filter exited $status"
    return 0
  fi
  if cmp -s "$actual" "$expected"; then
    pass "$name"
  else
    fail "$name" "output differs from $(basename "$expected")"
  fi
}

# assert_strip <case-name> <filter> <extension>
#   The fixture-pair form: <case>.in.<ext> through the filter, against
#   <case>.out.<ext>.
assert_strip() {
  local name="$1" filter="$2" ext="$3"
  assert_strip_files "$name" "$filter" \
    "$FIXTURES/$name.in.$ext" "$FIXTURES/$name.out.$ext"
}

# unterminate <fixture> <dest>  copies a fixture, dropping the single trailing
# newline it carries on disk.
#
# Every tracked fixture here ends with a newline because the repo's
# end-of-file-fixer hook rewrites files that don't — and these are compared with
# `cmp`, so a byte the hook adds is a byte the filter would be wrongly expected
# to emit. For the HTML cases that newline is storage, not data: an Azure DevOps
# System.Description is one value with no trailing newline, and the filter
# rstrips its output. Both sides drop it, so the comparison stays byte-exact on
# the bytes that are actually the filter's.
unterminate() {
  python3 -c '
import sys

data = open(sys.argv[1], "rb").read()
if data.endswith(b"\n"):
    data = data[:-1]
open(sys.argv[2], "wb").write(data)' "$1" "$2"
}

# assert_strip_html <case-name>  the HTML fixture-pair form, with the storage
# newline dropped from both the input and the expectation.
assert_strip_html() {
  local name="$1"
  unterminate "$FIXTURES/$name.in.html" "$TMP/$name.in.html"
  unterminate "$FIXTURES/$name.out.html" "$TMP/$name.out.html"
  assert_strip_files "$name" enrich_body_strip_html \
    "$TMP/$name.in.html" "$TMP/$name.out.html"
}

section "markdown — nothing to strip"

assert_strip fresh_body_unchanged      enrich_body_strip_markdown md
assert_strip crlf_body_unchanged       enrich_body_strip_markdown md
assert_strip inline_mention_not_cut    enrich_body_strip_markdown md
assert_strip fenced_heading_not_cut    enrich_body_strip_markdown md
assert_strip similar_heading_not_cut   enrich_body_strip_markdown md

section "markdown — a previous enrichment is cut"

assert_strip cuts_prior_enrichment          enrich_body_strip_markdown md
assert_strip cuts_headless_assumptions_only enrich_body_strip_markdown md
assert_strip cuts_forgejo_heading           enrich_body_strip_markdown md
assert_strip cuts_crlf_enrichment           enrich_body_strip_markdown md
assert_strip only_sections_strips_to_empty  enrich_body_strip_markdown md

# Built here rather than stored: the property under test is a heading with
# trailing spaces, and the repo's trailing-whitespace hook would strip exactly
# that out of a tracked fixture — silently turning the case into a duplicate of
# cuts_prior_enrichment.
printf 'The original human description.\n\n## Acceptance Criteria   \n\n- [ ] Trailing spaces on the heading.\n' \
  > "$TMP/trailing_spaces_heading_cut.in.md"
assert_strip_files trailing_spaces_heading_cut enrich_body_strip_markdown \
  "$TMP/trailing_spaces_heading_cut.in.md" "$FIXTURES/trailing_spaces_heading_cut.out.md"

section "markdown — idempotent across a re-compose"

# The re-run case: strip a previously enriched body, compose fresh sections onto
# the kept prefix, strip again. The second strip must return the same prefix —
# otherwise each run would shave a little more off the human's description.
kept="$TMP/kept.md"
recomposed="$TMP/recomposed.md"
restripped="$TMP/restripped.md"
if enrich_body_strip_markdown < "$FIXTURES/cuts_prior_enrichment.in.md" > "$kept" \
  && cat "$kept" "$FIXTURES/recompose-sections.md" > "$recomposed" \
  && enrich_body_strip_markdown < "$recomposed" > "$restripped"; then
  if cmp -s "$restripped" "$kept"; then
    pass "idempotent_after_recompose"
  else
    fail "idempotent_after_recompose" "strip(strip(x) + new sections) != strip(x)"
  fi
else
  fail "idempotent_after_recompose" "a filter invocation failed"
fi

section "html — nothing to strip"

assert_strip_html html_no_owned_heading_unchanged
assert_strip_html html_similar_heading_not_cut
assert_strip_html html_empty_input

section "html — a previous enrichment is cut"

assert_strip_html html_cuts_exact_write
assert_strip_html html_cuts_sanitized_shape
assert_strip_html html_cuts_spec_and_plan_first
assert_strip_html html_cuts_wrapped_heading
assert_strip_html html_only_sections_strips_to_empty

section "html — idempotent across a re-compose"

kept_html="$TMP/kept.html"
recomposed_html="$TMP/recomposed.html"
restripped_html="$TMP/restripped.html"
unterminate "$FIXTURES/recompose-sections.html" "$TMP/recompose-sections.html"
if enrich_body_strip_html < "$TMP/html_cuts_exact_write.in.html" > "$kept_html" \
  && cat "$kept_html" "$TMP/recompose-sections.html" > "$recomposed_html" \
  && enrich_body_strip_html < "$recomposed_html" > "$restripped_html"; then
  if cmp -s "$restripped_html" "$kept_html"; then
    pass "html_idempotent_after_recompose"
  else
    fail "html_idempotent_after_recompose" "strip(strip(x) + new sections) != strip(x)"
  fi
else
  fail "html_idempotent_after_recompose" "a filter invocation failed"
fi

printf '\npassed: %d   failed: %d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf -- '  - %s\n' "$n"; done
  exit 1
fi
exit 0
