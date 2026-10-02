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
#      not read from the consumer repo) exists, has at least one COMPLETED run
#      on the default branch, has at least one COMPLETED run for a
#      `pull_request`, and the default branch requires at least one status
#      check.
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
# #381 strengthened it: "has completed a run" was satisfied by a
# workflow_dispatch-only workflow in a repo with no branch protection at all.
# The gate must now also have completed a run for a pull_request, and the
# default branch must require at least one status check.
#
# NOT checked: that the named gate IS one of those required checks.
# `required_status_checks.contexts` holds job/check names while the gate is a
# filename, and mapping one to the other means matching a recent run's job
# names — which breaks on a rename, on a multi-job workflow, and when no recent
# run exists. See docs/AUTOPILOT.md.
#
# Query-only. Requires: gh (authenticated), jq.
set -euo pipefail
IFS=$'\n\t'

repo_eligible() {
  local repo="$1" gate="$2" yaml default_branch runs runs_json
  local pr_runs pr_runs_json prot_json contexts
  local agent_yml_err runs_err pr_runs_err prot_err
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

  # Errors are read the same way as the agent.yml check above: an exit code
  # alone cannot separate a genuine 404 from a `gh` outage, and reporting an
  # outage as "gate not found" sends an operator hunting for a workflow that
  # exists. Capture stderr and look for the 404 signature (#381).
  runs_err="$(mktemp)"
  # shellcheck disable=SC2064  # expand runs_err now, on function return
  trap "rm -f '$agent_yml_err' '$runs_err'" RETURN

  if ! runs_json="$(gh api \
        "repos/$repo/actions/workflows/$gate/runs?branch=$default_branch&status=completed&per_page=1" \
        2>"$runs_err")"; then
    if grep -qiE 'HTTP 404|Not Found' "$runs_err"; then
      printf 'test gate %s not found\n' "$gate"
      return 1
    fi
    printf 'eligibility check failed (gate runs)\n'
    return 1
  fi
  runs="$(printf '%s' "$runs_json" | jq -r '.total_count')"
  if [[ -z "$runs" || "$runs" == "null" ]]; then
    printf 'test gate %s not found\n' "$gate"
    return 1
  fi
  if (( runs == 0 )); then
    printf 'test gate %s has never completed a run on %s\n' "$gate" "$default_branch"
    return 1
  fi

  # #381: "has completed a run" is not "gates anything". A workflow_dispatch-only
  # workflow satisfies the check above while gating nothing — observed on
  # agent-action-sandbox, whose gate declared itself "Not part of the agent
  # pipeline". Ask for evidence instead: has this workflow ever completed a run
  # for a pull_request?
  #
  # NO branch= filter here. Pull-request runs happen on feature branches, so
  # filtering on the default branch returns zero for every repo and refuses all
  # of them.
  pr_runs_err="$(mktemp)"
  # shellcheck disable=SC2064  # expand pr_runs_err now, on function return
  trap "rm -f '$agent_yml_err' '$runs_err' '$pr_runs_err'" RETURN

  if ! pr_runs_json="$(gh api \
        "repos/$repo/actions/workflows/$gate/runs?event=pull_request&status=completed&per_page=1" \
        2>"$pr_runs_err")"; then
    # Same absent-vs-unreadable split as the two neighbouring calls. The query
    # above already proved the workflow exists, so a 404 here means it was
    # deleted in between — rare, but it is a missing gate, not a failed check.
    if grep -qiE 'HTTP 404|Not Found' "$pr_runs_err"; then
      printf 'test gate %s not found\n' "$gate"
      return 1
    fi
    printf 'eligibility check failed (gate pull-request runs)\n'
    return 1
  fi
  pr_runs="$(printf '%s' "$pr_runs_json" | jq -r '.total_count')"
  if [[ -z "$pr_runs" || "$pr_runs" == "null" || "$pr_runs" == 0 ]]; then
    printf 'test gate %s has never run on a pull request\n' "$gate"
    return 1
  fi

  # #381: and the branch must actually require a check. Without this the lane
  # would merge into a branch nothing blocks.
  #
  # This endpoint 404s BOTH when the branch is unprotected and when the token
  # lacks scope to read protection. Both refuse; the distinction is what the
  # operator reads. Same treatment as agent.yml above.
  prot_err="$(mktemp)"
  # shellcheck disable=SC2064  # expand prot_err now, on function return
  trap "rm -f '$agent_yml_err' '$runs_err' '$pr_runs_err' '$prot_err'" RETURN

  if ! prot_json="$(gh api "repos/$repo/branches/$default_branch/protection" \
        2>"$prot_err")"; then
    if grep -qiE 'HTTP 404|Not Found' "$prot_err"; then
      printf 'no branch protection on %s (or the token cannot read it)\n' \
        "$default_branch"
      return 1
    fi
    printf 'eligibility check failed (protection)\n'
    return 1
  fi
  contexts="$(printf '%s' "$prot_json" \
    | jq -r '(.required_status_checks.contexts // []) | length')"
  if [[ -z "$contexts" || "$contexts" == "null" ]] || (( contexts == 0 )); then
    printf '%s has no required status checks\n' "$default_branch"
    return 1
  fi

  printf 'eligible (gate %s ran on a pull request; %s requires %s check(s))\n' \
    "$gate" "$default_branch" "$contexts"
  return 0
}
