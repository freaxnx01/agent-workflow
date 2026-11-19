#!/usr/bin/env bash
#
# run-new-milestone-tests.sh -- Layer-1 tests for /new's milestone selection (#645).
# commands/new.md is a prompt, so the logic worth testing is the filter each
# section documents. This extracts those filters and RUNS them on fixtures:
#   - backlog is never an "active" milestone;
#   - active milestones keep the soonest-due-first, undated-last order;
#   - a missing backlog is detectable (so /new can report it, not create it);
#   - general-<month>-<year> handling is gone from /new.
#
# Usage: tests/run-new-milestone-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOC="$ROOT/commands/new.md"
PASS=0; FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [[ $# -gt 1 ]] && printf '       %s\n' "$2"; return 0; }
assert_eq() { # actual expected label
  if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3" "expected [$2] got [$1]"; fi
}

section_of() { # heading line -> body up to the next ### heading
  awk -v h="$1" '$0==h{on=1;next} on&&/^### /{exit} on{print}' "$DOC"
}

gh_sec="$(section_of '### Milestone selection (GitHub)')"
fj_sec="$(section_of '### Milestone selection (Forgejo)')"
[[ -n "$gh_sec" && -n "$fj_sec" ]] || { echo "milestone sections missing in $DOC" >&2; exit 1; }

# GitHub: the --jq expressions, in document order: [0] active list, [1] backlog count.
mapfile -t gh_jq < <(printf '%s\n' "$gh_sec" | sed -n "s/^ *--jq '\(.*\)'\$/\1/p")
if [[ ${#gh_jq[@]} -ne 2 ]]; then
  fail "GitHub section documents exactly two --jq filters" "found ${#gh_jq[@]}"
else
  pass "GitHub section documents exactly two --jq filters"
  fixture='[{"title":"backlog","due_on":null},{"title":"undated","due_on":null},{"title":"later","due_on":"2026-12-30T00:00:00Z"},{"title":"next","due_on":"2026-12-01T00:00:00Z"}]'
  assert_eq "$(printf '%s' "$fixture" | jq -r "${gh_jq[0]}" | cut -f1 | paste -sd,)" "next,later,undated" \
    "GitHub: active = sorted, undated last, backlog excluded, next kept"
  assert_eq "$(printf '%s' "$fixture" | jq -r "${gh_jq[1]}")" "1" "GitHub: backlog present -> 1"
  only='[{"title":"backlog","due_on":null}]'
  assert_eq "$(printf '%s' "$only" | jq -r "${gh_jq[0]}" | wc -l | tr -d ' ')" "0" \
    "GitHub: backlog alone -> zero active"
  none='[{"title":"a","due_on":null}]'
  assert_eq "$(printf '%s' "$none" | jq -r "${gh_jq[1]}")" "0" "GitHub: no backlog -> 0 (report, never create)"
  caps='[{"title":"Backlog","due_on":null}]'
  assert_eq "$(printf '%s' "$caps" | jq -r "${gh_jq[1]}")" "0" "GitHub: title match is exact and case-sensitive"
fi

# Forgejo: the python snippet, from "python3 -c '" to the line holding only "'".
fj_py="$(printf '%s\n' "$fj_sec" | awk '/python3 -c .$/{on=1;next} on&&/^.$/{exit} on{print}')"
if [[ -z "$fj_py" ]]; then
  fail "Forgejo section documents an extractable python3 -c snippet"
else
  pass "Forgejo section documents an extractable python3 -c snippet"
  fj_fixture='[{"title":"backlog","due_on":null},{"title":"undated","due_on":null},{"title":"later","due_on":"2026-12-30T00:00:00Z"}]'
  # `|| true`: a malformed snippet must FAIL an assertion, not kill the runner.
  out="$(printf '%s' "$fj_fixture" | python3 -I -c "$fj_py" 2>/dev/null || true)"
  assert_eq "$(printf '%s\n' "$out" | grep -c '^active')" "2" "Forgejo: two active rows, backlog excluded"
  assert_eq "$(printf '%s\n' "$out" | sed -n '1p' | cut -f2)" "later" "Forgejo: dated first"
  assert_eq "$(printf '%s\n' "$out" | grep '^backlog' | cut -f2)" "yes" "Forgejo: backlog present"
  out2="$(printf '%s' '[{"title":"a","due_on":null}]' | python3 -I -c "$fj_py" 2>/dev/null || true)"
  assert_eq "$(printf '%s\n' "$out2" | grep '^backlog' | cut -f2)" "no" "Forgejo: backlog missing"
fi

# Prose guards (secondary to the executed filters above).
assert_eq "$(grep -c 'general-' "$DOC" || true)" "0" "new.md no longer mentions general-<month>-<year>"
# shellcheck disable=SC2016  # the pattern is the literal markdown `none`, not an expansion
assert_eq "$(grep -c '`none`' "$DOC" || true)" "0" "new.md no longer offers a none option"
for sec in "$gh_sec" "$fj_sec"; do
  assert_eq "$(printf '%s\n' "$sec" | grep -q '/milestone new backlog' && echo yes || echo no)" "yes" \
    "a forge section points at /milestone new backlog"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
