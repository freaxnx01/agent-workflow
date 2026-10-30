#!/usr/bin/env bash
#
# azdo-pipeline-run.sh — the single step an Azure Pipelines run executes.
#
# Runs the tag guard, then (only if it passes) the implement driver. A skipped
# run (no tag, or a tagger who is not allowlisted) is a green run: nothing went
# wrong, so the pipeline must not report a failure.
#
# Env (same as the guard):
#   WORK_ITEM_ID      required  the work item carrying the trigger tag
#   TAGGER_ALLOWLIST  required  comma-separated uniqueNames
#   TRIGGER_TAG       optional  default: ai-implement
#   AZURE_DEVOPS_EXT_PAT  optional on a CI host: taken from the host identity
#                         token (lib/ci-host.sh) when unset. Never printed.
#   GUARD_CMD / DRIVER_CMD  override the script paths; for tests only.
#
# Exit codes:
#   0   run completed, or skipped (guard 64 no tag / 65 tagger not allowlisted)
#   N   any other guard code, or the driver's code, is propagated unchanged
set -euo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/ci-host.sh
source "$HERE/lib/ci-host.sh"

GUARD_CMD="${GUARD_CMD:-$HERE/azdo-tag-guard.sh}"
DRIVER_CMD="${DRIVER_CMD:-$HERE/implement-azdo.sh}"

if [[ -z "${AZURE_DEVOPS_EXT_PAT:-}" && "$(ci_host)" != "local" ]]; then
  AZURE_DEVOPS_EXT_PAT="$(ci_host_token)" || exit 2
  export AZURE_DEVOPS_EXT_PAT
fi

rc=0
"$GUARD_CMD" || rc=$?
case "$rc" in
  0) ;;
  64) printf 'azdo-pipeline-run: no trigger tag on work item %s; nothing to do.\n' "${WORK_ITEM_ID:-?}"; exit 0 ;;
  65) printf 'azdo-pipeline-run: tagger is not allowlisted; run skipped.\n'; exit 0 ;;
  *) exit "$rc" ;;
esac

ISSUE_NUMBER="$WORK_ITEM_ID" exec "$DRIVER_CMD"
