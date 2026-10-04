#!/usr/bin/env bash
#
# run-plan-coverage-tests.sh — Layer-1 tests for scripts/check-plan-coverage.sh
# and scripts/plan-coverage-step.sh (#457). No network; gh is mocked.
#
# Usage: tests/run-plan-coverage-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/scripts/check-plan-coverage.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0
FAIL_NAMES=()

section() { printf '\n── %s ──\n' "$1"; }
pass() { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
fail() {
  FAIL=$((FAIL + 1)); FAIL_NAMES+=("$1")
  printf '  ✗ %s\n' "$1"
  [[ $# -gt 1 ]] && printf '      %s\n' "$2"
  return 0
}
assert_eq() {
  if [[ "$3" == "$2" ]]; then pass "$1"; else fail "$1" "expected: $2 | actual: $3"; fi
}

# grade <body-file> <changed-file> → the script's three output lines
grade() { ISSUE_BODY_FILE="$1" CHANGED_FILES_FILE="$2" bash "$CHECK"; }
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

section "the #430 shape: 3 tasks planned, 1 landed"

cat > "$T/body-430.md" <<'EOF'
Some description.

## Implementation Plan

### Task 1: Parser

**Files:**
- Create: `scripts/parse.sh`
- Test: `tests/run-parse-tests.sh`

### Task 2: Workflow

**Files:**
- Modify: `.github/workflows/agent-implement.yml:120-140`

### Task 3: Docs

**Files:**
- Modify: `docs/DESIGN.md`

## Spec

[spec](docs/spec.md)
EOF
printf 'scripts/parse.sh\ntests/run-parse-tests.sh\n' > "$T/changed-430.txt"
out="$(grade "$T/body-430.md" "$T/changed-430.txt")"
assert_eq "#430 shape is partial" "partial" "$(field "$out" coverage)"
assert_eq "#430 shape names tasks 2 and 3" "2,3" "$(field "$out" missing-tasks)"
assert_eq "partial has no reason" "" "$(field "$out" reason)"
assert_eq "output is exactly three lines" "3" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"

section "every task landed"

printf 'scripts/parse.sh\n.github/workflows/agent-implement.yml\ndocs/DESIGN.md\n' > "$T/changed-all.txt"
out="$(grade "$T/body-430.md" "$T/changed-all.txt")"
assert_eq "all tasks landed is complete" "complete" "$(field "$out" coverage)"
assert_eq "complete has no missing tasks" "" "$(field "$out" missing-tasks)"

section "a PR with no changed files"

: > "$T/changed-none.txt"
out="$(grade "$T/body-430.md" "$T/changed-none.txt")"
assert_eq "no changed files is partial, not unverifiable" "partial" "$(field "$out" coverage)"
assert_eq "no changed files names every task" "1,2,3" "$(field "$out" missing-tasks)"

section "a task whose only file is shared with a landed task"

cat > "$T/body-shared.md" <<'EOF'
## Implementation Plan

### Task 1: Code

**Files:**
- Modify: `scripts/a.sh`
- Test: `tests/run-a-tests.sh`

### Task 2: More tests

**Files:**
- Test: `tests/run-a-tests.sh`
EOF
printf 'scripts/a.sh\ntests/run-a-tests.sh\n' > "$T/changed-shared.txt"
out="$(grade "$T/body-shared.md" "$T/changed-shared.txt")"
assert_eq "a shared-file task counts as landed" "complete" "$(field "$out" coverage)"

section "unverifiable plans"

printf 'Just a description, no plan.\n\n## Acceptance Criteria\n\n- [ ] works\n' > "$T/body-no-plan.md"
out="$(grade "$T/body-no-plan.md" "$T/changed-all.txt")"
assert_eq "no plan is unverifiable" "unverifiable" "$(field "$out" coverage)"
assert_eq "no plan reason" "no-plan" "$(field "$out" reason)"

printf '## Implementation Plan\n\nDo the thing in scripts/a.sh.\n' > "$T/body-no-tasks.md"
out="$(grade "$T/body-no-tasks.md" "$T/changed-all.txt")"
assert_eq "no task headings is unverifiable" "unverifiable" "$(field "$out" coverage)"
assert_eq "no task headings reason" "no-tasks" "$(field "$out" reason)"

cat > "$T/body-task-without-files.md" <<'EOF'
## Implementation Plan

### Task 1: Code

**Files:**
- Modify: `scripts/a.sh`

### Task 2: Think about it

Consider the options.
EOF
out="$(grade "$T/body-task-without-files.md" "$T/changed-shared.txt")"
assert_eq "a task with no files is unverifiable" "unverifiable" "$(field "$out" coverage)"
assert_eq "it names the task" "task-without-files:2" "$(field "$out" reason)"

section "format: h2 tasks, line ranges, fences, plan-level h2 headings"

cat > "$T/body-format.md" <<'EOF'
## Implementation Plan

# Some Feature Implementation Plan

## Global Constraints

- none

## Review Focus

1. fences

---

## Task 1: Edit b

**Files:**
- Modify: `scripts/b.sh:10-20` and `:30`

````markdown
```bash
echo inner fence
```
### Task 9: inside a fence, not a task
- Create: `scripts/ghost.sh`
````

```
[ full listing in the committed plan file — see the note at the top ]
```

### Task 2: Edit c

**Files:**
- Test: `tests/run-c-tests.sh:5`

## Spec

- Create: `docs/not-a-task-file.md`
EOF
printf 'scripts/b.sh\ntests/run-c-tests.sh\n' > "$T/changed-format.txt"
out="$(grade "$T/body-format.md" "$T/changed-format.txt")"
assert_eq "h2 tasks, line ranges and fences parse" "complete" "$(field "$out" coverage)"
printf 'scripts/b.sh\n' > "$T/changed-format-partial.txt"
out="$(grade "$T/body-format.md" "$T/changed-format-partial.txt")"
assert_eq "the fenced Task 9 is not counted" "2" "$(field "$out" missing-tasks)"

section "usage"

rc=0; ISSUE_BODY_FILE='' CHANGED_FILES_FILE="$T/changed-all.txt" bash "$CHECK" >/dev/null 2>&1 || rc=$?
assert_eq "unset ISSUE_BODY_FILE exits 2" "2" "$rc"
rc=0; ISSUE_BODY_FILE="$T/body-430.md" CHANGED_FILES_FILE="$T/nope.txt" bash "$CHECK" >/dev/null 2>&1 || rc=$?
assert_eq "unreadable CHANGED_FILES_FILE exits 2" "2" "$rc"

section "plan-coverage-step.sh (gh mocked)"

STEP="$ROOT/scripts/plan-coverage-step.sh"
export PATH="$ROOT/tests/mocks:$PATH"
export GH_MOCK_LOG="$T/gh.log"

# The mock ignores --jq and serves the fixture verbatim, so the files fixture is
# the post-jq shape: one path per line.
printf 'issue view\t%s\n' "$T/body-430.md" > "$T/step.map"
printf 'pulls/7/files\t%s\n' "$T/changed-430.txt" >> "$T/step.map"

: > "$GH_MOCK_LOG"
out="$(GH_MOCK_STDOUT_MAP="$T/step.map" GITHUB_OUTPUT="$T/out1" \
  REPO=o/r ISSUE_NUMBER=42 PR_NUMBER=7 bash "$STEP"; cat "$T/out1")"
assert_eq "the step writes the grade" "partial" "$(field "$out" coverage)"
assert_eq "the step writes the missing tasks" "2,3" "$(field "$out" missing-tasks)"
case "$(cat "$GH_MOCK_LOG")" in
  *"api --paginate repos/o/r/pulls/7/files"*"previous_filename"*)
    pass "changed files are paginated and include rename sources" ;;
  *) fail "changed files are paginated and include rename sources" "$(cat "$GH_MOCK_LOG")" ;;
esac

printf 'pulls/7/files\n' > "$T/step-fail.map"
rc=0
out="$(GH_MOCK_STDOUT_MAP="$T/step.map" GH_MOCK_FAIL_MAP="$T/step-fail.map" GITHUB_OUTPUT="$T/out2" \
  REPO=o/r ISSUE_NUMBER=42 PR_NUMBER=7 bash "$STEP")" || rc=$?
assert_eq "a failed fetch still exits 0" "0" "$rc"
out="$(cat "$T/out2")"
assert_eq "a failed fetch is unverifiable" "unverifiable" "$(field "$out" coverage)"
assert_eq "a failed fetch says why" "fetch-failed" "$(field "$out" reason)"

printf 'issue view\n' > "$T/step-fail-body.map"
out="$(GH_MOCK_STDOUT_MAP="$T/step.map" GH_MOCK_FAIL_MAP="$T/step-fail-body.map" GITHUB_OUTPUT="$T/out3" \
  REPO=o/r ISSUE_NUMBER=42 PR_NUMBER=7 bash "$STEP"; cat "$T/out3")"
assert_eq "a failed body fetch is unverifiable, never complete" "unverifiable" "$(field "$out" coverage)"

rc=0; REPO=o/r ISSUE_NUMBER=42 PR_NUMBER='' bash "$STEP" >/dev/null 2>&1 || rc=$?
assert_eq "missing PR_NUMBER exits 2" "2" "$rc"

section "workflow wiring"

WF="$ROOT/.github/workflows/agent-implement.yml"
if grep -q 'run: bash .claude-pipeline/scripts/plan-coverage-step.sh' "$WF"; then
  pass "the implement job runs the coverage step"
else
  fail "the implement job runs the coverage step"
fi
if grep -qE '^ +plan-coverage: +\$\{\{ steps\.plan_coverage\.outputs\.coverage \}\}' "$WF"; then
  pass "the implement job exports plan-coverage"
else
  fail "the implement job exports plan-coverage"
fi
if grep -qF "&& (inputs.dry-run || needs.implement.outputs.plan-coverage == 'complete')" "$WF"; then
  pass "AI-merge requires complete coverage outside dry-run"
else
  fail "AI-merge requires complete coverage outside dry-run"
fi
# shellcheck disable=SC2016  # the ${{ }} is GitHub Actions expression syntax
# being searched for literally in the workflow, not a shell expansion.
if grep -qF 'PLAN_COVERAGE: ${{ steps.plan_coverage.outputs.coverage }}' "$WF"; then
  pass "the run report receives the coverage grade"
else
  fail "the run report receives the coverage grade"
fi

printf '\npassed: %d   failed: %d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf -- '  - %s\n' "$n"; done
  exit 1
fi
exit 0
