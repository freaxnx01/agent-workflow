#!/usr/bin/env bash
#
# azdo-pipeline-run.sh — the single step an Azure Pipelines run executes.
#
# Runs the tag guard, then (only if it passes) the implement driver. A skipped
# run (no tag, a tagger who is not allowlisted, or a later edit by someone who
# is not) is a green run: nothing went wrong, so the pipeline must not report a
# failure.
#
# Both scripts are resolved ONLY next to this one. There is deliberately no
# environment override: Azure Pipelines exposes every pipeline variable as an
# environment variable, so an override would let a variable skip the guard.
#
# Env (same as the guard):
#   WORK_ITEM_ID      required  the work item carrying the trigger tag (digits)
#   TAGGER_ALLOWLIST  required  comma-separated uniqueNames
#   TRIGGER_TAG       optional  default: ai-implement
#   AZURE_DEVOPS_EXT_PAT  optional on Azure Pipelines: taken from
#                         SYSTEM_ACCESSTOKEN when unset (lib/ci-host.sh,
#                         ci_host_export_azdo_pat). Never printed.
#
# Exit codes:
#   0   run completed, or skipped (guard 64 no tag / 65 tagger not allowlisted /
#       66 a later editor not allowlisted)
#   2   WORK_ITEM_ID missing or not a number, or on Azure Pipelines with no
#       token to use; the guard is not run
#   N   any other guard code, or the driver's code, is propagated unchanged
set -euo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/ci-host.sh
source "$HERE/lib/ci-host.sh"

if [[ ! "${WORK_ITEM_ID:-}" =~ ^[0-9]+$ ]]; then
  echo "azdo-pipeline-run: WORK_ITEM_ID must be set to a work item number" >&2
  exit 2
fi

ci_host_export_azdo_pat || exit 2

rc=0
"$HERE/azdo-tag-guard.sh" || rc=$?
case "$rc" in
  0) ;;
  64) printf 'azdo-pipeline-run: no trigger tag on work item %s; nothing to do.\n' "$WORK_ITEM_ID"; exit 0 ;;
  65) printf 'azdo-pipeline-run: tagger is not allowlisted; run skipped.\n'; exit 0 ;;
  66) printf 'azdo-pipeline-run: changed by an identity that is not allowlisted after the tag was added; run skipped.\n'; exit 0 ;;
  *) exit "$rc" ;;
esac

ISSUE_NUMBER="$WORK_ITEM_ID" exec "$HERE/implement-azdo.sh"
