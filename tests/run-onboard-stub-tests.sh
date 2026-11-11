#!/usr/bin/env bash
#
# run-onboard-stub-tests.sh — Layer-1 tests for the consumer stub that
# scripts/onboard-consumer.sh generates.
#
# The script runs onboarding at top level, so it cannot simply be sourced. The
# generator functions are extracted from the real file instead — testing the
# shipped source rather than a copy that could drift.
#
# Usage: tests/run-onboard-stub-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/scripts/onboard-consumer.sh"

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
assert_contains() {
  if [[ "$2" == *"$1"* ]]; then pass "$3"; else fail "$3" "missing: $1"; fi
}
assert_not_contains() {
  if [[ "$2" != *"$1"* ]]; then pass "$3"; else fail "$3" "unexpectedly present: $1"; fi
}

# stub <agent> [model] — echoes the generated agent.yml for that agent choice.
# Extracts build_agent_yml from the shipped script so the test cannot drift from it.
stub() {
  local agent="$1" model="${2:-claude-sonnet-5}"
  # SC2034: the assignments below are the generator's inputs. It is sourced from
  # a sed extract of the real script, so shellcheck cannot see the uses and
  # reports every one as unused. Scoped to this subshell, not the whole file.
  # shellcheck disable=SC2034
  (
    AGENT="$agent"
    MODEL="$model"
    REF='v2'
    RUNNER_LABELS='["ubuntu-latest"]'
    PIPELINE_REPO='freaxnx01/agent-workflow'
    AI_MERGE=false
    HUMAN_MERGE=true
    # shellcheck disable=SC1090
    source <(sed -n '/^build_agent_yml()/,/^}/p' "$SRC")
    build_agent_yml
  )
}

# health_stub — echoes the generated pipeline-health.yml. Same extraction trick
# as stub(), for the same reason.
health_stub() {
  # shellcheck disable=SC2034
  (
    REF='v2'
    PIPELINE_REPO='freaxnx01/agent-workflow'
    # shellcheck disable=SC1090
    source <(sed -n '/^build_health_yml()/,/^}/p' "$SRC")
    build_health_yml
  )
}

# intake_stub — echoes the generated issue-intake.yml (#549). Same extraction
# trick as stub().
intake_stub() {
  # shellcheck disable=SC2034
  (
    REF='v2'
    PIPELINE_REPO='freaxnx01/agent-workflow'
    # shellcheck disable=SC1090
    source <(sed -n '/^build_intake_yml()/,/^}/p' "$SRC")
    build_intake_yml
  )
}

# --- cases -------------------------------------------------------------

section "consumer stub — permissions"

out="$(stub claude)"

# retry-dispatch.sh re-dispatches the consumer workflow with `gh workflow run`,
# which needs actions: write on the CALLING workflow. Without it every retry
# 403s and a transient failure the classifier decided to retry becomes hard.
assert_contains 'actions: write' "$out" "grants actions: write for retry-dispatch"
assert_contains 'contents: write' "$out" "still grants contents: write"
assert_contains 'pull-requests: write' "$out" "still grants pull-requests: write"
assert_contains 'issues: write' "$out" "still grants issues: write"

section "consumer stub — the agent is always declared"

# agent-implement.yml's `agent` input defaults to opencode. A stub that omits the
# line therefore runs the OPPOSITE of this script's documented default (claude).
# Worse, such a repo can appear to run Claude purely because no OPENROUTER_API_KEY
# is present — flipping the moment that secret is added for any reason.
assert_contains 'agent: claude' "$out" "claude is written out, not left implicit"

out_oc="$(stub opencode z-ai/glm-5.2)"
assert_contains 'agent: opencode' "$out_oc" "opencode is written out"
assert_contains 'OPENROUTER_API_KEY' "$out_oc" "opencode stub passes the OpenRouter key"
assert_not_contains 'OPENROUTER_API_KEY' "$out" "claude stub does not pass it"

section "consumer stub — the ntfy token is forwarded (#517)"

# This stub does not use `secrets: inherit`, so a secret set on the repo but not
# listed here never reaches the reusable workflow — the pause alarm would then
# raise its issue and silently never push.
# shellcheck disable=SC2016  # `${{ }}` is GitHub Actions expression syntax in
# the generated YAML, not shell expansion.
assert_contains 'NTFY_TOKEN: ${{ secrets.NTFY_TOKEN }}' "$out" \
  "the alarm's ntfy token reaches the reusable workflow"

section "health stub — the daily budget check (#517)"

health="$(health_stub)"
assert_contains 'uses: freaxnx01/agent-workflow/.github/workflows/pipeline-health.yml@v2' \
  "$health" "calls the health workflow at the pinned ref"
assert_contains 'schedule:' "$health" "runs on a schedule"
assert_contains 'workflow_dispatch:' "$health" "can also be run by hand"
# shellcheck disable=SC2016  # Actions expression syntax, as above.
assert_contains 'OPENROUTER_API_KEY: ${{ secrets.OPENROUTER_API_KEY }}' "$health" \
  "forwards the key whose budget is checked"
# shellcheck disable=SC2016  # Actions expression syntax, as above.
assert_contains 'NTFY_TOKEN: ${{ secrets.NTFY_TOKEN }}' "$health" "forwards the ntfy token"
assert_contains 'issues: write' "$health" "may raise and comment on the alarm"

if command -v yamllint >/dev/null 2>&1; then
  if printf '%s\n' "$health" | yamllint -d '{extends: relaxed, rules: {line-length: disable, truthy: disable}}' - >/dev/null 2>&1; then
    pass "generated health stub is valid YAML"
  else
    fail "generated health stub is valid YAML" "yamllint rejected it"
  fi
fi

section "intake stub — new issues enter the lane (#549)"

intake="$(intake_stub)"
assert_contains 'uses: freaxnx01/agent-workflow/.github/workflows/issue-intake.yml@v2' \
  "$intake" "calls the intake workflow at the pinned ref"
assert_contains 'types: [opened]' "$intake" "runs when an issue is opened"
# shellcheck disable=SC2016  # `${{ }}` is Actions expression syntax, not shell
assert_contains 'issue-number: ${{ github.event.issue.number }}' "$intake" "passes the new issue's number"
assert_contains 'pipeline-ref: v2' "$intake" "checks out scripts at the same ref"
assert_contains 'issues: write' "$intake" "may label the issue"
assert_not_contains 'contents: write' "$intake" "never writes code"
# shellcheck disable=SC2016  # `\$NO_STUB` is a sed pattern matching the literal
# text in the script under test, not a shell expansion.
writes="$(sed -n '/^if \[\[ "\$NO_STUB"/,/^fi/p' "$SRC" | grep -c 'put_file ".github/workflows/issue-intake.yml"' || true)"
if [[ "$writes" == 2 ]]; then
  pass "both onboarding paths write the intake stub"
else
  fail "both onboarding paths write the intake stub" "found $writes put_file calls, expected 2"
fi

if command -v yamllint >/dev/null 2>&1; then
  if printf '%s\n' "$intake" | yamllint -d '{extends: relaxed, rules: {line-length: disable, truthy: disable}}' - >/dev/null 2>&1; then
    pass "generated intake stub is valid YAML"
  else
    fail "generated intake stub is valid YAML" "yamllint rejected it"
  fi
fi

section "consumer stub — still well-formed"

assert_contains 'uses: freaxnx01/agent-workflow/.github/workflows/agent-implement.yml@v2' \
  "$out" "calls the reusable workflow at the pinned ref"
assert_contains "if: github.event.label.name == 'ai-implement'" "$out" "triggers on the ai-implement label"
assert_contains 'default-model: claude-sonnet-5' "$out" "carries the requested model"

if command -v yamllint >/dev/null 2>&1; then
  if printf '%s\n' "$out" | yamllint -d '{extends: relaxed, rules: {line-length: disable}}' - >/dev/null 2>&1; then
    pass "generated stub is valid YAML"
  else
    fail "generated stub is valid YAML" "yamllint rejected it"
  fi
else
  printf '  %s- skipped YAML validation (yamllint not installed)%s\n' "$C_DIM" "$C_OFF"
fi

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
