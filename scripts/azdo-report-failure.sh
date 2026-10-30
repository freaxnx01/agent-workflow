#!/usr/bin/env bash
#
# azdo-report-failure.sh — comment on the work item that its run failed.
#
# The guard consumes the trigger tag on most paths but deliberately leaves it in
# place on some failures (see azdo-tag-guard.sh), so the comment makes no claim
# about the tag: it says to re-add it only if it is gone.
#
# Env:
#   WORK_ITEM_ID  required  digits only
#   RUN_URL       required  link to the failed pipeline run
#   AZURE_DEVOPS_EXT_PAT  optional on Azure Pipelines: taken from
#                         SYSTEM_ACCESSTOKEN when unset (lib/ci-host.sh,
#                         ci_host_export_azdo_pat). Never printed.
#
# Exit codes: 0 comment posted; 1 posting failed; 2 missing env, WORK_ITEM_ID
# not a number, or on Azure Pipelines with no token to use.
set -euo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/detect-forge.sh
source "$HERE/lib/detect-forge.sh"
# shellcheck source=scripts/lib/forge.sh
source "$HERE/lib/forge.sh"
# shellcheck source=scripts/lib/ci-host.sh
source "$HERE/lib/ci-host.sh"

if [[ -z "${WORK_ITEM_ID:-}" || -z "${RUN_URL:-}" ]]; then
  echo "azdo-report-failure: WORK_ITEM_ID and RUN_URL must be set" >&2
  exit 2
fi
if [[ ! "$WORK_ITEM_ID" =~ ^[0-9]+$ ]]; then
  echo "azdo-report-failure: WORK_ITEM_ID must be a work item number" >&2
  exit 2
fi

ci_host_export_azdo_pat || exit 2

resolve_azdo_context || { echo "azdo-report-failure: origin is not an Azure DevOps remote" >&2; exit 1; }
REPO="${AZDO_PROJECT}/${AZDO_REPO}"   # forge_issue_comment requires it set

body="$(mktemp)"
trap 'rm -f "$body"' EXIT
printf 'ai-implement run failed: %s. If the ai-implement tag is no longer on this work item, re-add it to retry.\n' "$RUN_URL" > "$body"

forge_issue_comment "$WORK_ITEM_ID" "$body" >/dev/null || { echo "azdo-report-failure: could not post the comment" >&2; exit 1; }
