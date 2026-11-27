#!/usr/bin/env bash
#
# run-azdo-validation-pool-tests.sh — Layer-1 checks that PR build validation is
# documented as running on its own agent pool (#703).
#
# The separation is operator setup enforced by Azure DevOps pool permissions,
# not code, so what there is to test is the shape of the instructions an
# operator follows:
#   - section 9 has a "Run validation on its own pool" subsection that names
#     the validation pool, says what is stolen without it
#     (`.credentials_rsaparams`), repeats the `--replace` warning, closes the
#     open-access trap, and is checkable;
#   - section 9.2 authorizes the validation pipeline on the validation pool,
#     and no subsection of 9 still says to authorize it on the implement pool;
#   - sections 10 and 13 point at the subsection;
#   - no organization name leaks into the doc.
#
# Usage: tests/run-azdo-validation-pool-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETUP_DOC="$ROOT/docs/AZDO-PIPELINE-SETUP.md"

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

# assert_has NAME NEEDLE TEXT — TEXT contains NEEDLE. Runs of whitespace in
# both collapse to one space first, so a needle that prose wraps over two lines
# still counts: these assertions are about what the doc says, not how it wraps.
assert_has() {
  local name="$1" needle="$2" text="$3"
  if printf '%s' "$text" | tr -s '[:space:]' ' ' \
    | grep -qF -- "$(printf '%s' "$needle" | tr -s '[:space:]' ' ')"; then
    pass "$name"
  else
    fail "$name" "missing: $needle"
  fi
}

# subsection REGEX — the body of the "### " heading matching REGEX, up to the
# next "### " or "## " heading.
subsection() {
  awk -v re="$1" '$0 ~ /^### / && $0 ~ re {on=1; print; next} on && /^#{2,3} /{exit} on{print}' "$SETUP_DOC"
}

# level2 N — the body of "## N. ..." up to the next level-2 heading.
level2() {
  awk -v n="^## $1\\\\. " '$0 ~ n {on=1; print; next} on && /^## /{exit} on{print}' "$SETUP_DOC"
}

printf '── the own-pool subsection ──\n'

if grep -qE '^### 9\.[0-9]+ Run validation on its own pool$' "$SETUP_DOC"; then
  pass "setup_doc_HasOwnPoolSubsection"
else
  fail "setup_doc_HasOwnPoolSubsection" \
    "no '### 9.N Run validation on its own pool' heading in $SETUP_DOC"
fi

OWN_POOL="$(subsection 'Run validation on its own pool$')"

assert_has "setup_doc_OwnPool_NamesValidationPool" '<validation-pool>' "$OWN_POOL"
if printf '%s\n' "$OWN_POOL" | grep -qF 'Pipeline permissions' \
  && printf '%s\n' "$OWN_POOL" | grep -qF 'ai-implement'; then
  pass "setup_doc_OwnPool_ImplementPoolOnlyAiImplement"
else
  fail "setup_doc_OwnPool_ImplementPoolOnlyAiImplement" \
    "the subsection needs both 'Pipeline permissions' and 'ai-implement'"
fi
assert_has "setup_doc_OwnPool_OpenAccessOff" \
  'Grant access permission to all pipelines' "$OWN_POOL"
assert_has "setup_doc_OwnPool_NamesTheft" '.credentials_rsaparams' "$OWN_POOL"
if printf '%s\n' "$OWN_POOL" | grep -qF -- '--replace' \
  || printf '%s\n' "$OWN_POOL" | grep -qF '10.1'; then
  pass "setup_doc_OwnPool_WarnsReplace"
else
  fail "setup_doc_OwnPool_WarnsReplace" \
    "the subsection needs '--replace' or a pointer to 10.1"
fi
if printf '%s\n' "$OWN_POOL" | grep -qE '^Check:'; then
  pass "setup_doc_OwnPool_HasCheck"
else
  fail "setup_doc_OwnPool_HasCheck" "the subsection needs a line starting 'Check:'"
fi

printf '\n── the rest of section 9, and the pointers ──\n'

assert_has "setup_doc_9_2_AuthorizesValidationPool" '<validation-pool>' \
  "$(subsection '^### 9[.]2 ')"

# No subsection of 9 may still send the validation pipeline to the implement
# pool: a reader following section 9 top to bottom would authorize it there.
# A subsection trips when it names both "Pipeline permissions" and the
# implement pool's Security page, on any of its lines. The own-pool subsection
# itself is exempt: it sends the operator to that page to *restrict* the pool.
mapfile -t bad_auth < <(awk '
  function flush() { if (in9 && has_permissions && has_pool) print number }
  /^#{2,3} / {
    flush(); in9 = 0; has_permissions = 0; has_pool = 0
    if ($0 ~ /^### 9[.][0-9]+ / && $0 !~ /Run validation on its own pool$/) {
      in9 = 1; number = $2
    }
    next
  }
  in9 {
    if (index($0, "Pipeline permissions")) has_permissions = 1
    if (index($0, "`<pool>` > Security")) has_pool = 1
  }
  END { flush() }
' "$SETUP_DOC")
if [[ ${#bad_auth[@]} -eq 0 ]]; then
  pass "setup_doc_9_NoImplementPoolAuthorization"
else
  fail "setup_doc_9_NoImplementPoolAuthorization" \
    "still authorizes on '<pool>': ${bad_auth[*]}"
fi

assert_has "setup_doc_10_PointsToOwnPool" 'Run validation on its own pool' "$(level2 10)"
assert_has "setup_doc_13_PointsToOwnPool" 'Run validation on its own pool' "$(level2 13)"

printf '\n── placeholders only ──\n'

leaks=()
while IFS= read -r hit; do
  [[ -z "$hit" ]] && continue
  [[ "$hit" == 'dev.azure.com/<org' ]] || leaks+=("$hit")
done < <(grep -oE 'dev\.azure\.com/[^ )>`"]*' "$SETUP_DOC" || true)
if [[ ${#leaks[@]} -eq 0 ]]; then
  pass "setup_doc_NoRealOrgUrl"
else
  fail "setup_doc_NoRealOrgUrl" "real names: ${leaks[*]}"
fi

printf '\npassed: %d   failed: %d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf -- '  - %s\n' "$n"; done
  exit 1
fi
exit 0
