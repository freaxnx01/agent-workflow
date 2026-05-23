#!/usr/bin/env bash
#
# ensure-issue-labels.sh — Ensure the labels the pipeline reads or writes exist
# on the target repository.
#
# Three categories:
#   lifecycle  ai:running, ai:done, ai:failed, ctx:medium, ctx:high
#              — written by post-run-report.sh after each run
#   selectors  agent:claude, agent:opencode
#              — read by classify-agent.sh to override the workflow input
#                (see ADR-001 in docs/DECISIONS.md)
#   gates      ai-auto-review, ai-chain, ai:chain-paused
#              — read by future auto-review (epic #3) and chain-dispatch
#                (epic #4) workflows; user-applied opt-ins / kill switch
#
# Idempotent: existing labels are preserved unchanged (`gh label create` errors
# when the label exists; we ignore that error rather than passing `--force`, so
# consumers who customized colors aren't overridden).
#
# Required environment variables:
#   REPO      owner/repo (e.g. $GITHUB_REPOSITORY).
#   GH_TOKEN  (or ambient `gh auth`).
#
# Exit codes:
#   0   all 5 labels are present (created or pre-existing)
#   2   REPO unset
set -euo pipefail
IFS=$'\n\t'

if [[ -z "${REPO:-}" ]]; then
  printf 'error: REPO must be set\n' >&2
  exit 2
fi

create() {
  local name="$1" color="$2" desc="$3"
  if gh label create "$name" --repo "$REPO" --color "$color" --description "$desc" >/dev/null 2>&1; then
    printf 'created: %s\n' "$name"
  else
    printf 'present: %s\n' "$name"
  fi
}

create ai:running FBCA04 'Pipeline run in progress'
create ai:done    0E8A16 'Pipeline run completed successfully'
create ai:failed  D73A4A 'Pipeline run failed'
create ctx:medium FBCA04 'Peak context utilization 50-74%'
create ctx:high   D73A4A 'Peak context utilization 75%+ (consider trimming)'

create agent:claude    0075CA 'Force the Claude Code agent for this run'
create agent:opencode  0075CA 'Force the OpenCode (OpenRouter) agent for this run'

create ai-auto-review  0E8A16 'Run auto-review after PR opens; auto-merge on approve+green'
create ai-chain        0E8A16 'Eligible for chain-dispatch when blockers resolve'
create ai:chain-paused D73A4A 'Repo-wide kill switch for chain-dispatch'
