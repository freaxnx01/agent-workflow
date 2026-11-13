#!/usr/bin/env bash
#
# find-failed-step.sh — name the step that failed in this run's implement job
# (#597). Used by implement_prefail to say *where* a run died before the agent
# started, instead of leaving the operator to open the Actions list.
#
# Deliberately total: the step name is a convenience, the report and the run
# URL are the substance. An API error, a renamed caller job, a payload that is
# not the shape expected — all print `unknown` and exit 0, so the report is
# posted either way.
#
# Optional env:
#   REPO              owner/repo (default: $GITHUB_REPOSITORY)
#   RUN_ID            the workflow run to inspect (default: $GITHUB_RUN_ID)
#   RUN_ATTEMPT       re-run attempt number (default: $GITHUB_RUN_ATTEMPT, else 1)
#   JOB_NAME_SUFFIX   match jobs whose name ENDS with this. A reusable
#                     workflow's job is named `<caller job> / <job name>`, so
#                     only the suffix is ours to predict.
#   JOBS_JSON         the jobs payload, bypassing the API call. The seam the
#                     Layer-1 tests drive: no network, no gh.
#
# Output: one line — the first failed step of the first matching failed job,
#         or `unknown`.
# Exit: always 0.
set -euo pipefail
IFS=$'\n\t'

JSON="${JOBS_JSON:-}"
if [[ -z "$JSON" ]]; then
  JSON="$(gh api "repos/${REPO:-${GITHUB_REPOSITORY:-}}/actions/runs/${RUN_ID:-${GITHUB_RUN_ID:-}}/attempts/${RUN_ATTEMPT:-${GITHUB_RUN_ATTEMPT:-1}}/jobs?per_page=100" \
    2>/dev/null)" || JSON=''
fi

step="$(jq -r --arg suffix "${JOB_NAME_SUFFIX:-}" '
  [ .jobs[]?
    | select(.conclusion == "failure")
    | select(.name | endswith($suffix))
    | .steps[]?
    | select(.conclusion == "failure")
    | .name
  ][0] // empty
' <<< "$JSON" 2>/dev/null)" || step=''

# One line, always: the caller writes this to $GITHUB_OUTPUT, where a second
# line would be a second `key=value` pair.
step="${step//[$'\n\r']/ }"
printf '%s\n' "${step:-unknown}"
