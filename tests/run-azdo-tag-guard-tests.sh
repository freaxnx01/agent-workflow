#!/usr/bin/env bash
#
# run-azdo-tag-guard-tests.sh — Layer-1 tests for scripts/azdo-tag-guard.sh.
# `az` and `curl` are mocked (tag writes go through curl); no network.
#
# Usage: tests/run-azdo-tag-guard-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$ROOT/scripts/azdo-tag-guard.sh"
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
  if [[ "$3" == "$2" ]]; then pass "$1"; else fail "$1" "expected: $2 | actual: $3"; fi
}
assert_file_empty() {
  if [[ -s "$2" ]]; then fail "$1" "unexpected content: $(head -c 200 "$2")"; else pass "$1"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A throwaway repo gives resolve_azdo_context a real Azure DevOps origin.
REPO="$WORK/repo"
git init -q "$REPO"
git -C "$REPO" remote add origin https://dev.azure.com/contoso/MyProject/_git/my-repo

AZ_LOG="$WORK/az.log"; CURL_LOG="$WORK/curl.log"; BODY_LOG="$WORK/body.log"

# run_guard <fields-fixture> <revisions-fixture> — runs the guard, sets $rc.
# Extra env (WORK_ITEM_ID, TAGGER_ALLOWLIST) comes from the caller's environment.
run_guard() {
  local fields="$1" revisions="$2"
  local update="${UPDATE_FIXTURE:-azdo-set-tags-replaced.json}"
  local write="${WRITE_FIXTURE:-azdo-set-tags-replaced.json}"
  : > "$AZ_LOG"; : > "$CURL_LOG"; : > "$BODY_LOG"
  printf 'workitemsbatch\t%s\nrevisions\t%s\nwork-item update\t%s\n' \
    "$FIXTURES/$fields" "$FIXTURES/$revisions" "$FIXTURES/$update" > "$WORK/az.map"
  printf 'workitems/\t%s\n' "$FIXTURES/$write" > "$WORK/curl.map"
  rc=0
  (
    cd "$REPO"
    export PATH="$MOCKS:$PATH"
    export AZ_MOCK_MAP="$WORK/az.map" AZ_MOCK_LOG="$AZ_LOG"
    export CURL_MOCK_FIXTURE_MAP="$WORK/curl.map" CURL_MOCK_LOG="$CURL_LOG" CURL_MOCK_BODY_LOG="$BODY_LOG"
    export AZURE_DEVOPS_EXT_PAT=not-a-real-token
    "$GUARD"
  ) >/dev/null 2>&1 || rc=$?
}

sent_value() {
  python3 -c '
import json,sys
print(json.loads(open(sys.argv[1]).read().strip().splitlines()[0])[0]["value"])' "$BODY_LOG"
}

assert_no_writes() {
  assert_file_empty "$1: no tag write" "$BODY_LOG"
  if grep -q 'work-item update' "$AZ_LOG" || grep -q 'PATCH' "$CURL_LOG"; then
    fail "$1: no comment or PATCH" "a write was logged"
  else
    pass "$1: no comment or PATCH"
  fi
}

export WORK_ITEM_ID=7

section "tag present, adder allowlisted"
TAGGER_ALLOWLIST="owner@example.com" run_guard azdo-fields-ai-implement.json azdo-revisions-tag-added-clean.json
assert_eq "guard_allowlisted_exits_0_and_removes_tag: exit" 0 "$rc"
assert_eq "guard_allowlisted_exits_0_and_removes_tag: tag removed" "parked" "$(sent_value)"
if grep -q 'work-item update' "$AZ_LOG"; then fail "allowlisted posts no comment" "comment logged"; else pass "allowlisted posts no comment"; fi

TAGGER_ALLOWLIST=" Owner@Example.com ,x@y" run_guard azdo-fields-ai-implement.json azdo-revisions-tag-added-clean.json
assert_eq "guard_allowlist_case_and_space_insensitive" 0 "$rc"

section "tag absent"
TAGGER_ALLOWLIST="owner@example.com" run_guard azdo-fields-tagged.json azdo-revisions-tag-added.json
assert_eq "guard_no_tag_exits_64" 64 "$rc"
assert_no_writes "guard_no_tag_exits_64"

section "adder not allowlisted"
TAGGER_ALLOWLIST="someone@example.com" run_guard azdo-fields-ai-implement.json azdo-revisions-tag-added.json
assert_eq "guard_not_allowlisted_exits_65: exit" 65 "$rc"
assert_eq "guard_not_allowlisted_exits_65: tag removed" "parked" "$(sent_value)"
assert_eq "guard_not_allowlisted_exits_65: exactly one comment" 1 "$(grep -c 'work-item update' "$AZ_LOG")"
if grep -q -- "--discussion ai-implement ignored: the tag was added by owner@example.com, who is not on this pipeline's allowlist." "$AZ_LOG"; then
  pass "guard_not_allowlisted_exits_65_removes_tag_and_comments: comment text"
else
  fail "guard_not_allowlisted_exits_65_removes_tag_and_comments: comment text" "$(cat "$AZ_LOG")"
fi

section "changed after the tag was added (D1a)"
TAGGER_ALLOWLIST="owner@example.com" run_guard azdo-fields-ai-implement.json azdo-revisions-later-stranger-comment.json
assert_eq "guard_later_stranger_comment_exits_66: exit" 66 "$rc"
assert_eq "guard_later_stranger_comment_exits_66: tag removed" "parked" "$(sent_value)"
assert_eq "guard_later_stranger_comment_exits_66: exactly one comment" 1 "$(grep -c 'work-item update' "$AZ_LOG")"
if grep -q -- "--discussion ai-implement ignored: the work item was changed by mallory@example.com after the tag was added, and that identity is not on this pipeline's allowlist. Re-add the tag to run on the current content." "$AZ_LOG"; then
  pass "guard_later_stranger_comment_exits_66: comment text"
else
  fail "guard_later_stranger_comment_exits_66: comment text" "$(cat "$AZ_LOG")"
fi

TAGGER_ALLOWLIST="owner@example.com" run_guard azdo-fields-ai-implement.json azdo-revisions-tag-added.json
assert_eq "guard_later_stranger_edit_exits_66" 66 "$rc"
if grep -q -- "changed by bob@example.com after" "$AZ_LOG"; then pass "guard_later_stranger_edit_names_editor"; else fail "guard_later_stranger_edit_names_editor" "$(cat "$AZ_LOG")"; fi

TAGGER_ALLOWLIST="owner@example.com,mallory@example.com" run_guard azdo-fields-ai-implement.json azdo-revisions-later-stranger-comment.json
assert_eq "guard_later_editors_all_allowlisted_exits_0" 0 "$rc"
if grep -q 'work-item update' "$AZ_LOG"; then fail "guard_later_editors_all_allowlisted_posts_no_comment" "comment logged"; else pass "guard_later_editors_all_allowlisted_posts_no_comment"; fi

TAGGER_ALLOWLIST="owner@example.com" run_guard azdo-fields-ai-implement.json azdo-revisions-tag-added-clean.json
assert_eq "guard_later_edit_by_allowlisted_tagger_proceeds" 0 "$rc"

TAGGER_ALLOWLIST="owner@example.com" run_guard azdo-fields-ai-implement.json azdo-revisions-later-unidentified.json
assert_eq "guard_later_editor_unreadable_exits_1_keeps_tag: exit" 1 "$rc"
assert_no_writes "guard_later_editor_unreadable_exits_1_keeps_tag"

section "failures keep the tag"
TAGGER_ALLOWLIST="owner@example.com" run_guard azdo-fields-ai-implement.json azdo-wiql-tf51011.txt
assert_eq "guard_revision_read_failure_exits_1_keeps_tag: exit" 1 "$rc"
assert_no_writes "guard_revision_read_failure_exits_1_keeps_tag"

TAGGER_ALLOWLIST="owner@example.com" run_guard azdo-fields-ai-implement.json azdo-revisions-no-tag.json
assert_eq "guard_unattributable_tag_exits_1_keeps_tag: exit" 1 "$rc"
assert_no_writes "guard_unattributable_tag_exits_1_keeps_tag"

TAGGER_ALLOWLIST="owner@example.com" run_guard azdo-wiql-tf51011.txt azdo-revisions-tag-added.json
assert_eq "guard_tag_read_failure_exits_1" 1 "$rc"
assert_no_writes "guard_tag_read_failure_exits_1"

section "removal must really remove the tag"
TAGGER_ALLOWLIST="owner@example.com" run_guard azdo-fields-ai-implement-mixedcase.json azdo-revisions-tag-added-clean.json
assert_eq "guard_mixed_case_tag_exits_0: exit" 0 "$rc"
assert_eq "guard_mixed_case_tag_exits_0: tag removed" "parked" "$(sent_value)"

TAGGER_ALLOWLIST="owner@example.com" WRITE_FIXTURE=azdo-set-tags-still-tagged.json \
  run_guard azdo-fields-ai-implement.json azdo-revisions-tag-added-clean.json
assert_eq "guard_removal_leaves_tag_exits_1" 1 "$rc"

TAGGER_ALLOWLIST="owner@example.com" WRITE_FIXTURE=azdo-set-tags-multiline.json \
  run_guard azdo-fields-ai-implement.json azdo-revisions-tag-added-clean.json
assert_eq "guard_removal_check_crash_exits_1_never_0" 1 "$rc"

TAGGER_ALLOWLIST="owner@example.com" WRITE_FIXTURE=azdo-set-tags-not-text.json \
  run_guard azdo-fields-ai-implement.json azdo-revisions-tag-added-clean.json
assert_eq "guard_non_string_tags_in_write_response_exits_1" 1 "$rc"

TAGGER_ALLOWLIST="owner@example.com" CURL_MOCK_FAIL=1 \
  run_guard azdo-fields-ai-implement.json azdo-revisions-tag-added-clean.json
assert_eq "guard_tag_write_failure_exits_1" 1 "$rc"

TAGGER_ALLOWLIST="someone@example.com" UPDATE_FIXTURE=azdo-wiql-tf51011.txt \
  run_guard azdo-fields-ai-implement.json azdo-revisions-tag-added.json
assert_eq "guard_comment_failure_after_removal_exits_1" 1 "$rc"
assert_eq "guard_comment_failure_after_removal: tag was removed first" "parked" "$(sent_value)"

TAGGER_ALLOWLIST="owner@example.com" run_guard azdo-fields-tags-not-text.json azdo-revisions-tag-added-clean.json
assert_eq "guard_unparseable_tag_read_exits_1" 1 "$rc"
assert_no_writes "guard_unparseable_tag_read_exits_1"

section "missing env"
for bad in "7; rm -rf /" "-1" "7 " "0x7" "abc"; do
  rc=0; (cd "$REPO"; WORK_ITEM_ID="$bad" TAGGER_ALLOWLIST=owner@example.com "$GUARD") >/dev/null 2>&1 || rc=$?
  assert_eq "guard_non_numeric_work_item_exits_2: '$bad'" 2 "$rc"
done
rc=0; (cd "$REPO"; WORK_ITEM_ID=7 TAGGER_ALLOWLIST=" , ,$(printf '\t')" "$GUARD") >/dev/null 2>&1 || rc=$?
assert_eq "guard_blank_allowlist_exits_2" 2 "$rc"
rc=0; (cd "$REPO"; unset TAGGER_ALLOWLIST; WORK_ITEM_ID=7 "$GUARD") >/dev/null 2>&1 || rc=$?
assert_eq "guard_missing_env_exits_2: allowlist" 2 "$rc"
rc=0; (cd "$REPO"; unset WORK_ITEM_ID; TAGGER_ALLOWLIST=a@b "$GUARD") >/dev/null 2>&1 || rc=$?
assert_eq "guard_missing_env_exits_2: work item" 2 "$rc"

printf '\n%s─────%s\n' "$C_DIM" "$C_OFF"
printf '  %s%d passed%s' "$C_GREEN" "$PASS" "$C_OFF"
if [ "$FAIL" -gt 0 ]; then
  printf ', %s%d failed%s\n\nFailed:\n' "$C_RED" "$FAIL" "$C_OFF"
  for n in "${FAIL_NAMES[@]}"; do printf '  - %s\n' "$n"; done
  exit 1
fi
printf '\n'
exit 0
