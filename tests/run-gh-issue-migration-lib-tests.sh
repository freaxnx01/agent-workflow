#!/usr/bin/env bash
#
# run-gh-issue-migration-lib-tests.sh — Layer-1 tests for
# scripts/lib/gh-issue-migration.sh.
#
# Every function under test is pure: it reads its arguments (or a file) and
# prints. Nothing here needs a mock, a fixture or a network.
#
# Usage: tests/run-gh-issue-migration-lib-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib/gh-issue-migration.sh"

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

# run_lib <function> [args...] — sources the library in a subshell and calls one
# function, so a case cannot leak state into the next.
# shellcheck disable=SC2030,SC2031
run_lib() {
  (
    # shellcheck disable=SC1090
    source "$LIB"
    "$@"
  )
}

PROJECT_PATH='https://dev.azure.com/contoso/Contoso%20Project'

# --- cases -------------------------------------------------------------

section "migration_tags — pipeline state does not cross forges"

# ai:*, ai-implement and friends TRIGGER the pipeline. Carried over as tags they
# would either start a run on the new forge or confuse the guards, so they are
# dropped while every other label — needs-enrichment and roadmap included —
# survives.
assert_eq "migration_tags_DropsPipelineState" "enhancement; needs-enrichment" \
  "$(run_lib migration_tags \
      $'enhancement\nai-implement\nai:done\nctx:high\nturns:120\nenrichment-ongoing\nai-review-human-merge\nai-pre-preview\nneeds-enrichment')"

# The per-issue GATES are decisions taken for the old forge, so they stay with
# it — including the deprecated `ai-auto-review` spelling, which
# check-ai-merge-gate.sh still honours.
assert_eq "migration_tags_DropsGates" "enhancement" \
  "$(run_lib migration_tags \
      $'enhancement\nai-review-ai-merge\nai-auto-review\nai-chain\nai:chain-paused')"

# `agent:claude` / `agent:opencode` are read back out of System.Tags on the ADO
# side (forge_export_issue -> classify-agent.sh), so a carried one would force
# that agent on every future run of the work item.
assert_eq "migration_tags_DropsAgentOverride" "bug" \
  "$(run_lib migration_tags $'agent:opencode\nbug\nagent:claude')"

# Only the PREFIXES are dropped, not every label that starts with the letters.
assert_eq "migration_tags_KeepsLookalike" "aide; agentic" \
  "$(run_lib migration_tags $'aide\nagentic')"

# `;` is the tag separator Azure DevOps uses, so a label containing one would
# silently become two tags.
assert_eq "migration_tags_ReplacesSemicolon" "a,b" "$(run_lib migration_tags 'a;b')"

assert_eq "migration_tags_Empty" "" "$(run_lib migration_tags '')"

section "migration_type — the bug label picks the type"

assert_eq "migration_type_Bug" "Bug" \
  "$(run_lib migration_type $'bug\nx' 'Bug' 'User Story')"

assert_eq "migration_type_Story" "User Story" \
  "$(run_lib migration_type 'enhancement' 'Bug' 'User Story')"

assert_eq "migration_type_Override" "Issue" \
  "$(run_lib migration_type 'bug' 'Bug' 'User Story' 'Issue')"

section "migration_marker / migration_marker_id — the idempotency record"

assert_eq "migration_marker_Format" \
  '<!-- awf-migrated-to: https://dev.azure.com/contoso/Contoso%20Project#42 -->' \
  "$(run_lib migration_marker "$PROJECT_PATH" 42)"

mk_dir="$(mktemp -d)"
trap 'rm -rf "$mk_dir"' EXIT

{
  printf 'Some earlier comment.\n\n'
  printf 'Migrated to Azure DevOps work item [#42](%s/_workitems/edit/42).\n' "$PROJECT_PATH"
  run_lib migration_marker "$PROJECT_PATH" 42
  printf '\nA later comment.\n'
} > "$mk_dir/same-project.txt"

rc=0; out="$(run_lib migration_marker_id "$PROJECT_PATH" "$mk_dir/same-project.txt")" || rc=$?
assert_eq "migration_marker_id_SameProject: id" "42" "$out"
assert_eq "migration_marker_id_SameProject: exit" "0" "$rc"

# An issue migrated to a DIFFERENT project is not this run's work: skipping it
# would leave it out of the target backlog with nothing to say so.
run_lib migration_marker 'https://dev.azure.com/contoso/Other' 7 > "$mk_dir/other-project.txt"
rc=0; out="$(run_lib migration_marker_id "$PROJECT_PATH" "$mk_dir/other-project.txt")" || rc=$?
assert_eq "migration_marker_id_OtherProject: exit" "1" "$rc"
assert_eq "migration_marker_id_OtherProject: prints nothing" "" "$out"

: > "$mk_dir/none.txt"
rc=0; run_lib migration_marker_id "$PROJECT_PATH" "$mk_dir/none.txt" >/dev/null || rc=$?
assert_eq "migration_marker_id_NoComments: exit" "1" "$rc"

section "migration_comment_header — who said it, and when"

assert_eq "migration_comment_header_Login" '**octocat** on GitHub, 2026-03-04:' \
  "$(run_lib migration_comment_header 'octocat' '2026-03-04T23:59:00Z')"

# A deleted account comes back as a null author, which GitHub itself renders as
# `ghost`.
assert_eq "migration_comment_header_Ghost" '**ghost** on GitHub, 2026-03-04:' \
  "$(run_lib migration_comment_header '' '2026-03-04T00:00:00Z')"

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
