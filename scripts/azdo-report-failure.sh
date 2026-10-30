#!/usr/bin/env bash
#
# azdo-report-failure.sh — comment on the work item that its run failed.
#
# The trigger tag is consumed when the run starts (see azdo-tag-guard.sh), so
# the comment tells the reader to re-add it to retry.
#
# Env:
#   WORK_ITEM_ID  required
#   RUN_URL       required  link to the failed pipeline run
#   AZURE_DEVOPS_EXT_PAT  optional on a CI host: taken from the host identity
#                         token (lib/ci-host.sh) when unset. Never printed.
#
# Exit codes: 0 comment posted; 1 posting failed; 2 missing env.
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

if [[ -z "${AZURE_DEVOPS_EXT_PAT:-}" && "$(ci_host)" != "local" ]]; then
  AZURE_DEVOPS_EXT_PAT="$(ci_host_token)" || exit 2
  export AZURE_DEVOPS_EXT_PAT
fi

resolve_azdo_context || { echo "azdo-report-failure: origin is not an Azure DevOps remote" >&2; exit 1; }
REPO="${AZDO_PROJECT}/${AZDO_REPO}"   # forge_issue_comment requires it set

body="$(mktemp)"
trap 'rm -f "$body"' EXIT
printf 'ai-implement run failed: %s. The ai-implement tag was removed when the run started; re-add it to retry.\n' "$RUN_URL" > "$body"

forge_issue_comment "$WORK_ITEM_ID" "$body" >/dev/null || { echo "azdo-report-failure: could not post the comment" >&2; exit 1; }
