#!/usr/bin/env bash
#
# run-azdo-cutover-doc-tests.sh — Layer-1 checks on docs/AZDO-CUTOVER.md (#643).
# The runbook is prose, not a script, so these assert the shape an operator
# depends on when cutting a consumer over to Azure DevOps:
#   - the ten steps exist, in the order that does not lose work;
#   - every step is checkable (a checklist plus a "Check:" line);
#   - the mirror warning is explicit;
#   - the backup fetches refs/pull/* before bundling;
#   - the archive comes after the migration write-back, and the close loop
#     keys on the migration marker rather than the script's --close;
#   - no organization, host or repository names leak into the doc.
#
# Usage: tests/run-azdo-cutover-doc-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOC="$ROOT/docs/AZDO-CUTOVER.md"
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

# section N — the body of "## N. ..." up to the next level-2 heading.
section() {
  awk -v n="^## $1\\\\. " '$0 ~ n {on=1; print; next} on && /^## /{exit} on{print}' "$DOC"
}

readonly HEADINGS=(
  '## 1. Preconditions'
  '## 2. Back up the GitHub repository'
  '## 3. Freeze on GitHub'
  '## 4. Last sync, then stop the mirror'
  '## 5. Disable the GitHub workflows'
  '## 6. Set up Azure DevOps'
  '## 7. Migrate the open issues'
  '## 8. Verify'
  '## 9. Close the GitHub issues and archive'
  '## 10. Rollback'
)

if [[ -f "$DOC" ]]; then
  pass "cutover_doc_Exists"
else
  fail "cutover_doc_Exists" "missing $DOC"
  printf '\npassed: %d   failed: %d\n' "$PASS" "$FAIL"
  printf 'failed:\n  - cutover_doc_Exists\n'
  exit 1
fi

# --- the ten headings, in order -------------------------------------------
mapfile -t found < <(grep -E '^## [0-9]+\. ' "$DOC" || true)
if [[ "${found[*]-}" == "${HEADINGS[*]}" ]]; then
  pass "cutover_doc_HeadingsInOrder"
else
  fail "cutover_doc_HeadingsInOrder" "got: ${found[*]-<none>}"
fi

# --- every step is checkable ----------------------------------------------
missing=()
for n in 1 2 3 4 5 6 7 8 9 10; do
  body="$(section "$n")"
  printf '%s\n' "$body" | grep -qE '^- \[ \]' || missing+=("$n: no '- [ ]' checklist")
  printf '%s\n' "$body" | grep -qE '^Check:' || missing+=("$n: no 'Check:' line")
done
if [[ ${#missing[@]} -eq 0 ]]; then
  pass "cutover_doc_EveryStepHasChecklistAndCheck"
else
  fail "cutover_doc_EveryStepHasChecklistAndCheck" "${missing[*]}"
fi

# --- the mirror warning ----------------------------------------------------
step4="$(section 4)"
if printf '%s\n' "$step4" | grep -q 'Never' \
  && printf '%s\n' "$step4" | grep -qF 'git push --mirror'; then
  pass "cutover_doc_MirrorWarning"
else
  fail "cutover_doc_MirrorWarning" "step 4 needs both 'Never' and 'git push --mirror'"
fi

# --- the backup: refs/pull/* is fetched before the bundle ------------------
step2="$(section 2)"
pull_line="$(printf '%s\n' "$step2" | grep -nF 'refs/pull' | head -1 | cut -d: -f1)"
bundle_line="$(printf '%s\n' "$step2" | grep -nF 'git bundle create' | head -1 | cut -d: -f1)"
if [[ -n "$pull_line" && -n "$bundle_line" && "$pull_line" -lt "$bundle_line" ]] \
  && printf '%s\n' "$step2" | grep -qF 'admin:org'; then
  pass "cutover_doc_BackupOrder"
else
  fail "cutover_doc_BackupOrder" \
    "need refs/pull (line ${pull_line:-none}) before git bundle create (line ${bundle_line:-none}), and admin:org"
fi

# --- step 9 closes by marker, not by --close -------------------------------
step9="$(section 9)"
if printf '%s\n' "$step9" | grep -qF 'awf-migrated-to:' \
  && printf '%s\n' "$step9" | grep -qF 'gh issue close'; then
  pass "cutover_doc_Step9UsesMarker"
else
  fail "cutover_doc_Step9UsesMarker" "step 9 needs 'awf-migrated-to:' and 'gh issue close'"
fi

# --- step 7's flags: --dry-run then --area, and no --close yet -------------
step7="$(section 7)"
if printf '%s\n' "$step7" | grep -qF -- '--dry-run' \
  && printf '%s\n' "$step7" | grep -qF -- '--area' \
  && ! printf '%s\n' "$step7" | grep -qF -- '--close'; then
  pass "cutover_doc_MigrateFlags"
else
  fail "cutover_doc_MigrateFlags" "step 7 needs --dry-run and --area, and must not use --close"
fi

# --- placeholders only -----------------------------------------------------
# check_host NAME HOST_REGEX ALLOWED_REGEX — every HOST occurrence in the doc
# must match ALLOWED_REGEX.
check_host() {
  local name="$1" host="$2" allowed="$3" bad=()
  local hit
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    [[ "$hit" =~ $allowed ]] || bad+=("$hit")
  done < <(grep -oE "$host" "$DOC" || true)
  if [[ ${#bad[@]} -eq 0 ]]; then
    pass "$name"
  else
    fail "$name" "real names: ${bad[*]}"
  fi
}

check_host "cutover_doc_PlaceholdersOnly_azdo" \
  'dev\.azure\.com/[^ )`"]*' '^dev\.azure\.com/(<org>|contoso)'
check_host "cutover_doc_PlaceholdersOnly_github" \
  'github\.com/[^ )`"]*' '^github\.com/(<owner>|freaxnx01/agent-workflow)'

# --- the setup doc links the runbook ---------------------------------------
if grep -qF '[cutover runbook](AZDO-CUTOVER.md)' "$SETUP_DOC"; then
  pass "cutover_doc_LinkedFromSetup"
else
  fail "cutover_doc_LinkedFromSetup" "no '[cutover runbook](AZDO-CUTOVER.md)' in $SETUP_DOC"
fi

printf '\npassed: %d   failed: %d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf -- '  - %s\n' "$n"; done
  exit 1
fi
exit 0
