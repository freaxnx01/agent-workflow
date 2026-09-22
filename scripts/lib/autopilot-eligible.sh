#!/usr/bin/env bash
#
# autopilot-eligible.sh — sourced, not executed.
#   repo_eligible <owner/repo> <gate>
#
# Returns 0 if the repo may be auto-laned, 1 otherwise, and writes a one-line
# reason to stdout either way — the driver logs it verbatim, so the reason is
# the whole diagnostic.
#
# Two conditions, both required:
#   1. The consumer's .github/workflows/agent.yml declares
#      `ai-review-ai-merge: true`.
#   2. The <gate> workflow (passed in — named by the host's autopilot.conf,
#      not read from the consumer repo) exists and has at least one COMPLETED
#      run on the default branch.
#
# (The allowlist is the third condition, enforced by the driver before this is
# called — an outer gate that cannot be flipped from inside a consumer repo.
# The allowlist is also where <gate> comes from: see
# scripts/lib/autopilot-config.sh. It cannot live in the consumer's agent.yml
# — the reusable workflow does not declare that input, and workflow_call
# hard-fails on an undeclared one.)
#
# Condition 2 is #263: no auto-merge on a gate that has never run. The gate is
# named by the operator rather than this script guessing which workflow is
# "the tests" — a heuristic guarding auto-merge means a workflow rename
# silently changes eligibility.
#
# Query-only. Requires: gh (authenticated), jq.
set -euo pipefail
IFS=$'\n\t'

repo_eligible() {
  local repo="$1" gate="$2" yaml default_branch runs
  local agent_yml_err
  agent_yml_err="$(mktemp)"
  # shellcheck disable=SC2064  # expand agent_yml_err now, on function return
  trap "rm -f '$agent_yml_err'" RETURN

  # A failed `gh api` here is ambiguous by exit code alone: a genuine 404
  # (the repo really has no agent.yml) and a `gh` outage or auth failure both
  # exit non-zero. Reading only stdout and treating empty as "missing" (as
  # this used to) reports an outage as "no agent.yml" — indistinguishable
  # from a real absence in the log, and misleading to whoever reads it at
  # 3am. Check stderr for the 404 signature to tell the two apart.
  if ! yaml="$(gh api -H 'Accept: application/vnd.github.raw' \
            "repos/$repo/contents/.github/workflows/agent.yml" 2>"$agent_yml_err")"; then
    if grep -qiE 'HTTP 404|Not Found' "$agent_yml_err"; then
      printf 'no .github/workflows/agent.yml\n'
      return 1
    fi
    printf 'eligibility check failed (could not read agent.yml)\n'
    return 1
  fi
  if [[ -z "$yaml" ]]; then
    printf 'no .github/workflows/agent.yml\n'
    return 1
  fi

  if ! grep -Eq '^[[:space:]]*ai-review-ai-merge:[[:space:]]*true[[:space:]]*$' <<< "$yaml"; then
    printf 'agent.yml does not set ai-review-ai-merge: true\n'
    return 1
  fi

  # gh --jq is not applied by the test mock (it serves the whole fixture
  # regardless of --jq), so extract scalars with an explicit jq pipe instead
  # of the --jq flag — behaves identically against the real gh.
  default_branch="$(gh api "repos/$repo" 2>/dev/null | jq -r '.default_branch')" || default_branch=''
  if [[ -z "$default_branch" || "$default_branch" == "null" ]]; then
    printf 'could not read the default branch\n'
    return 1
  fi

  runs="$(gh api "repos/$repo/actions/workflows/$gate/runs?branch=$default_branch&status=completed&per_page=1" \
            2>/dev/null | jq -r '.total_count')" || runs=''
  if [[ -z "$runs" || "$runs" == "null" ]]; then
    printf 'test gate %s not found\n' "$gate"
    return 1
  fi
  if (( runs == 0 )); then
    printf 'test gate %s has never completed a run on %s\n' "$gate" "$default_branch"
    return 1
  fi

  printf 'eligible (gate %s, %s completed run(s) on %s)\n' "$gate" "$runs" "$default_branch"
  return 0
}
