#!/usr/bin/env bash
#
# run-migrate-guard-tests.sh — Layer-1 tests for the backlog guard rollout
# (#653): scripts/lib/milestone-stub.sh, the milestone queries in
# scripts/lib/backlog-milestone.sh and
# `scripts/migrate-consumers.sh --add-milestone-guard`. gh is mocked; no
# network.
#
# Usage: tests/run-migrate-guard-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

unset GITHUB_REPOSITORY GITHUB_OUTPUT GITHUB_STEP_SUMMARY REPO

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
section() { printf '\n── %s ──\n' "$1"; }
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1" "missing: $3 | in: $2"; fi
}
assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1" "unexpected: $3 | in: $2"; fi
}

section "milestone stub — one source for onboarding and the rollout"

# shellcheck disable=SC1091
stub="$(source "$ROOT/scripts/lib/milestone-stub.sh"; build_milestone_yml freaxnx01/agent-workflow v2)"

assert_contains "calls the reusable workflow at the given ref" "$stub" \
  'uses: freaxnx01/agent-workflow/.github/workflows/backlog-milestone.yml@v2'
assert_contains "checks out the scripts at the same ref" "$stub" '      pipeline-ref: v2'
# shellcheck disable=SC2016  # `${{ }}` is Actions expression syntax, not shell
assert_contains "passes only the issue number, unexpanded" "$stub" \
  'issue-number: ${{ github.event.issue.number }}'
assert_contains "runs on opened and reopened" "$stub" 'types: [opened, reopened]'
assert_contains "the calling job may set the milestone" "$stub" '      issues: write'
assert_not_contains "never writes code" "$stub" 'contents: write'

# The ref is a parameter, not the sourcing script's environment: the rollout
# writes the stub at whatever ref the consumer already pins.
# shellcheck disable=SC1091
other="$(source "$ROOT/scripts/lib/milestone-stub.sh"; build_milestone_yml o/p v2.4.1)"
assert_contains "the pipeline repo is a parameter" "$other" 'uses: o/p/.github/workflows/backlog-milestone.yml@v2.4.1'
assert_contains "the ref is a parameter" "$other" '      pipeline-ref: v2.4.1'

if command -v actionlint >/dev/null 2>&1; then
  d="$(mktemp -d)"
  printf '%s\n' "$stub" > "$d/issue-milestone.yml"
  if actionlint "$d/issue-milestone.yml" >/dev/null 2>&1; then
    pass "actionlint accepts the generated stub"
  else
    fail "actionlint accepts the generated stub" "$(actionlint "$d/issue-milestone.yml" 2>&1 | head -5)"
  fi
  rm -rf "$d"
else
  printf '  - skipped actionlint (not installed)\n'
fi

if command -v yamllint >/dev/null 2>&1; then
  if printf '%s\n' "$stub" | yamllint -d '{extends: relaxed, rules: {line-length: disable, truthy: disable}}' - >/dev/null 2>&1; then
    pass "the generated stub is valid YAML"
  else
    fail "the generated stub is valid YAML" "yamllint rejected it"
  fi
fi

printf '\npassed: %d   failed: %d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf -- '  - %s\n' "$n"; done
  exit 1
fi
exit 0
