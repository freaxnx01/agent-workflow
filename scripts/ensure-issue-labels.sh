#!/usr/bin/env bash
#
# ensure-issue-labels.sh — Ensure the labels the pipeline reads or writes exist
# on the target repository.
#
# Categories:
#   trigger    ai-implement
#              — the user-applied label the consumer `agent.yml` keys its
#                `if:` on to start a run; the pipeline reads it, so ensure it
#                exists (else the very first run can't be triggered)
#   lifecycle  ai:running, ai:done, ai:failed, ctx:medium, ctx:high
#              — written by post-run-report.sh after each run
#   selectors  agent:claude, agent:opencode
#              — read by classify-agent.sh to override the workflow input
#                (see ADR-001 in docs/DECISIONS.md)
#   gates      ai-review-ai-merge, ai-review-human-merge, ai-chain, ai:chain-paused
#              — read by the review flows (epic #3, ADR-009) and
#                chain-dispatch (epic #4) workflows; user-applied opt-ins /
#                kill switch. The pre-ADR-009 names ai-auto-review and
#                ai-pre-preview are still honoured by the gates until v3,
#                but are no longer created here.
#   budget     turns:50, turns:80, turns:120, turns:160
#              — read by classify-turns.sh as an explicit stage-1 override of
#                the task-count heuristic; `gh issue edit --add-label` fails
#                outright on a label that does not exist, so the documented
#                override is unusable until these are created
#   outcome    ai:review-blocked
#              — written by either review job (ADR-002, epic #3) when
#                the safety envelope or verdict leaves the PR draft
#   coordination enrichment-ongoing
#              — read/written by /enrich (Step 1.5 / 2.5 / 6) to prevent two
#                sessions from concurrently enriching the same issue
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
#   0   all required labels are present (created or pre-existing)
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

create ai-implement 1D76DB 'Trigger the agent-workflow to implement this issue'

create ai:running FBCA04 'Pipeline run in progress'
create ai:done    0E8A16 'Pipeline run completed successfully'
create ai:failed  D73A4A 'Pipeline run failed'
create ctx:medium FBCA04 'Peak context utilization 50-74%'
create ctx:high   D73A4A 'Peak context utilization 75%+ (consider trimming)'

create agent:claude    0075CA 'Force the Claude Code agent for this run'
create agent:opencode  0075CA 'Force the OpenCode (OpenRouter) agent for this run'

create ai-review-ai-merge     0E8A16 'AI reviews the PR and auto-merges on approve+green'
create ai-review-human-merge  1D76DB 'AI reviews the PR and promotes it to ready; a human merges'
create ai-chain        0E8A16 'Eligible for chain-dispatch when blockers resolve'
create ai:chain-paused D73A4A 'Repo-wide kill switch for chain-dispatch'

create '🧊 parked' BFD4F2 'Parked for a human — agent attempt cap reached'

create turns:50  5319E7 'Override the agent turn budget to 50 (classify-turns.sh stage 1)'
create turns:80  5319E7 'Override the agent turn budget to 80 (classify-turns.sh stage 1)'
create turns:120 5319E7 'Override the agent turn budget to 120 (classify-turns.sh stage 1)'
create turns:160 5319E7 'Override the agent turn budget to 160 (classify-turns.sh stage 1)'

create ai:review-blocked D73A4A 'Auto-review left the PR draft; human action required'

create enrichment-ongoing FBCA04 'Another /enrich session is actively enriching this issue — do not start a second one'
