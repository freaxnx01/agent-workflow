#!/usr/bin/env bash
#
# azdo-tag-guard.sh — the security gate in front of an unattended agent run.
#
# Anyone who can tag a work item can otherwise start a permission-bypassed
# agent, so the trigger tag only counts when the identity that ADDED it is on
# the pipeline's allowlist. The tag is consumed here, BEFORE the agent runs
# (spec D1): a tag left in place would re-trigger on the next poll, and an
# agent that fails midway must not leave a live trigger behind.
#
# Env:
#   WORK_ITEM_ID      required  the work item carrying the tag
#   TAGGER_ALLOWLIST  required  comma-separated uniqueNames (case and
#                               surrounding spaces ignored)
#   TRIGGER_TAG       optional  default: ai-implement
#   AZURE_DEVOPS_EXT_PAT is needed by the tag write (see azdo_set_tags).
#
# Known race: if someone else removes and re-adds the tag between the adder read
# and the removal, the removal consumes their tag on the earlier tagger's
# verdict. The window is a few API calls wide and the outcome is a lost
# trigger, never an unauthorised run.
#
# Order: read tags -> absent: 64 -> find the adder -> allowlist -> remove the
# tag -> comment (65 only).
#
# Exit codes (the dispatcher branches on these):
#   0   tag present, adder allowlisted, tag removed -> proceed
#   64  tag absent -> nothing done, nothing written
#   65  adder not allowlisted -> tag removed, one comment posted
#   1   a read or write failed; the tag is left in place when the failure
#       precedes its removal. Also: the tag is present but its adder cannot
#       be attributed (fail closed, tag kept for a human to look at).
#   2   missing env
set -euo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/detect-forge.sh
source "$HERE/lib/detect-forge.sh"
# shellcheck source=scripts/lib/azdo.sh
source "$HERE/lib/azdo.sh"

# A list with no real entry (only commas/whitespace) counts as unset.
allowlist_entries="${TAGGER_ALLOWLIST:-}"
allowlist_entries="${allowlist_entries//[,$' \t']/}"
if [[ -z "${WORK_ITEM_ID:-}" || -z "$allowlist_entries" ]]; then
  echo "azdo-tag-guard: WORK_ITEM_ID and TAGGER_ALLOWLIST must be set" >&2
  exit 2
fi
TRIGGER_TAG="${TRIGGER_TAG:-ai-implement}"

resolve_azdo_context || { echo "azdo-tag-guard: origin is not an Azure DevOps remote" >&2; exit 1; }

# has_tag  exit 0 present, 1 absent, 3 read failed.
has_tag() {
  local row rc=0
  row=$(azdo_fields "$WORK_ITEM_ID") || rc=$?
  if [[ $rc -ne 0 || -z "$row" ]]; then
    echo "azdo-tag-guard: could not read work item $WORK_ITEM_ID" >&2
    return 3
  fi
  printf '%s' "$row" | python3 -c '
import sys, json
try:
    row = json.loads(sys.stdin.readline())
    want = sys.argv[1].strip().lower()
    tags = {t.strip().lower() for t in row.get("tags", "").split(";") if t.strip()}
except Exception:
    sys.exit(3)   # unreadable is not "absent"
sys.exit(0 if want in tags else 1)' "$TRIGGER_TAG"
}

# is_allowlisted <uniqueName>
is_allowlisted() {
  python3 -c '
import sys
who = sys.argv[1].strip().lower()
allowed = {a.strip().lower() for a in sys.argv[2].split(",") if a.strip()}
sys.exit(0 if who in allowed else 1)' "$1" "$TAGGER_ALLOWLIST"
}

rc=0; has_tag || rc=$?
case $rc in
  0) ;;
  1) exit 64 ;;
  *) exit 1 ;;
esac

rc=0; adder=$(azdo_tag_adder "$WORK_ITEM_ID" "$TRIGGER_TAG") || rc=$?
if [[ $rc -ne 0 ]]; then
  # 64 here means the tag is present but nobody can be named as its adder:
  # fail closed and leave the tag for a human, same as a failed read.
  echo "azdo-tag-guard: cannot attribute the $TRIGGER_TAG tag on $WORK_ITEM_ID — leaving it in place" >&2
  exit 1
fi

allowed=0; is_allowlisted "$adder" && allowed=1

# Trust the tags the write RETURNS, not the fact that it succeeded: a removal
# that left the tag on the item must never end in exit 0.
remaining=$(azdo_remove_tag "$WORK_ITEM_ID" "$TRIGGER_TAG") || {
  echo "azdo-tag-guard: could not remove the $TRIGGER_TAG tag" >&2
  exit 1
}
if printf '%s' "$remaining" | python3 -c '
import sys
want = sys.argv[1].strip().lower()
tags = {t.strip().lower() for t in sys.stdin.read().split(";") if t.strip()}
sys.exit(0 if want in tags else 1)' "$TRIGGER_TAG"; then
  echo "azdo-tag-guard: the $TRIGGER_TAG tag is still on $WORK_ITEM_ID after removal" >&2
  exit 1
fi

if [[ $allowed -eq 1 ]]; then
  exit 0
fi

azdo_comment "$WORK_ITEM_ID" \
  "$TRIGGER_TAG ignored: the tag was added by $adder, who is not on this pipeline's allowlist." \
  || { echo "azdo-tag-guard: tag removed but the comment failed" >&2; exit 1; }
exit 65
