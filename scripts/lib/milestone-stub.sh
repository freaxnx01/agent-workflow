#!/usr/bin/env bash
#
# milestone-stub.sh — the consumer-side caller stub for the backlog milestone
# guard (#646, freaxnx01/ai-instructions#61), in one place.
#
# Written by onboard-consumer.sh when a repo is onboarded and by
# `migrate-consumers.sh --add-milestone-guard` when an already-onboarded repo
# is caught up (#653). Two copies of this text could drift, and a consumer
# whose stub disagrees with the one onboarding writes is a difference nobody
# would look for.
#
# Sourced, not executed. Exposes:
#   build_milestone_yml <pipeline-repo> <ref>   query — prints the stub
set -euo pipefail
IFS=$'\n\t'

# build_milestone_yml <pipeline-repo> <ref> — the caller stub, on stdout.
#
# The stub never creates `backlog`: the guard warns per issue instead, and
# onboarding does not create it either. The rollout's --apply does, because
# that is an operator asking for it.
build_milestone_yml() {
  local pipeline_repo="$1" ref="$2"
  cat <<YAML
name: Issue milestone
on:
  issues:
    types: [opened, reopened]

permissions:
  contents: read

jobs:
  milestone:
    permissions:
      contents: read
      issues: write   # assigns the backlog milestone
    uses: $pipeline_repo/.github/workflows/backlog-milestone.yml@$ref
    with:
      issue-number: \${{ github.event.issue.number }}
      pipeline-ref: $ref
YAML
}
