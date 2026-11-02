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
# A tagger's trust does not cover edits made after the tag: the agent reads the
# description and comments at run time, so anyone who changed the item since
# could steer it. Every revision after the tag-adding one must therefore be by
# an allowlisted identity too (spec D1a). That includes the build service: if
# it edits the item, its uniqueName must be on TAGGER_ALLOWLIST. There is one
# allowlist on purpose.
#
# Env:
#   WORK_ITEM_ID      required  the work item carrying the tag (digits only)
#   TAGGER_ALLOWLIST  required  comma-separated uniqueNames (case and
#                               surrounding spaces ignored)
#   TRIGGER_TAG       optional  default: ai-implement
#   AZURE_DEVOPS_EXT_PAT is needed by the tag write (see azdo_set_tags).
#
# The revisions are read twice: later editors FIRST, then the adder. Each read
# anchors on the latest tag-adding revision it sees, so if someone re-adds the
# tag between the two reads the adder read names THEM and their verdict
# applies. Read the other way round, the editors read could anchor on a
# stranger's re-add after an allowlisted adder was named, and nobody after it
# would be vetted.
#
# Known races: if someone else removes and re-adds the tag between the adder
# read and the removal, the removal consumes their tag on the earlier tagger's
# verdict -- a lost trigger, never an unauthorised run. An edit made after the
# revisions are read is not seen here at all; the window runs from those reads
# until the driver reads the item.
#
# Order: read tags -> absent: 64 -> list later editors -> find the adder ->
# allowlist (65) -> later editors allowlisted (66) -> remove the tag -> verify
# the removal -> comment (65/66 only). Every read happens before the one write.
#
# Exit codes (the dispatcher branches on these):
#   0   tag present, adder and every later editor allowlisted, tag removed and
#       the removal verified -> proceed. Nothing else ends in 0.
#   64  tag absent -> nothing done, nothing written
#   65  adder not allowlisted -> tag removed, one comment posted
#   66  adder allowlisted, but a later revision is by an identity that is not
#       -> tag removed, one comment posted
#   1   a read or write failed; the tag is left in place when the failure
#       precedes its removal. Also: the tag is present but its adder, or a later
#       editor, cannot be identified (fail closed, tag kept for a human to look
#       at), or the removal cannot be verified.
#   2   missing env, or WORK_ITEM_ID is not a number
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
if [[ ! "$WORK_ITEM_ID" =~ ^[0-9]+$ ]]; then
  echo "azdo-tag-guard: WORK_ITEM_ID must be a work item number" >&2
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

# first_stranger <identities>  echoes the first identity (one per line) that is
# not allowlisted; echoes nothing when every one is.
first_stranger() {
  local who
  while IFS= read -r who; do
    [[ -n "$who" ]] || continue
    if ! is_allowlisted "$who"; then
      printf '%s' "$who"
      return 0
    fi
  done <<<"$1"
}

# removed_tag_state <tags-the-write-returned>  exit 10 the tag is gone, 11 it is
# still there. Deliberately distinct from 0/1: an uncaught exception also exits
# 1, and that must never read as "gone". Anything but 10 or 11 is a failure.
removed_tag_state() {
  printf '%s' "$1" | python3 -c '
import sys
raw = sys.stdin.read()
if "\n" in raw:
    # A tags value never spans lines; this is not a response we understand.
    raise ValueError("the tag write returned a multi-line tags value")
want = sys.argv[1].strip().lower()
tags = {t.strip().lower() for t in raw.split(";") if t.strip()}
sys.exit(11 if want in tags else 10)' "$TRIGGER_TAG"
}

rc=0; has_tag || rc=$?
case $rc in
  0) ;;
  1) exit 64 ;;
  *) exit 1 ;;
esac

# Read before the adder (see the header) and before the removal, which is
# itself a revision. Acted on only once the adder is known to be allowlisted:
# a stranger's tag is refused (65) whatever this read returned.
editors_rc=0; editors=$(azdo_editors_since_tag "$WORK_ITEM_ID" "$TRIGGER_TAG") || editors_rc=$?

rc=0; adder=$(azdo_tag_adder "$WORK_ITEM_ID" "$TRIGGER_TAG") || rc=$?
if [[ $rc -ne 0 ]]; then
  # 64 here means the tag is present but nobody can be named as its adder:
  # fail closed and leave the tag for a human, same as a failed read.
  echo "azdo-tag-guard: cannot attribute the $TRIGGER_TAG tag on $WORK_ITEM_ID — leaving it in place" >&2
  exit 1
fi

allowed=0; is_allowlisted "$adder" && allowed=1

stranger=""
if [[ $allowed -eq 1 ]]; then
  if [[ $editors_rc -ne 0 ]]; then
    echo "azdo-tag-guard: cannot vet who changed $WORK_ITEM_ID after the $TRIGGER_TAG tag was added — leaving it in place" >&2
    exit 1
  fi
  stranger=$(first_stranger "$editors")
fi

# Trust the tags the write RETURNS, not the fact that it succeeded: a removal
# that left the tag on the item must never end in exit 0.
remaining=$(azdo_remove_tag "$WORK_ITEM_ID" "$TRIGGER_TAG") || {
  echo "azdo-tag-guard: could not remove the $TRIGGER_TAG tag" >&2
  exit 1
}
rc=0; removed_tag_state "$remaining" || rc=$?
case $rc in
  10) ;;
  11) echo "azdo-tag-guard: the $TRIGGER_TAG tag is still on $WORK_ITEM_ID after removal" >&2; exit 1 ;;
  *)  echo "azdo-tag-guard: could not verify that the $TRIGGER_TAG tag was removed from $WORK_ITEM_ID" >&2; exit 1 ;;
esac

if [[ $allowed -eq 0 ]]; then
  azdo_comment "$WORK_ITEM_ID" \
    "$TRIGGER_TAG ignored: the tag was added by $adder, who is not on this pipeline's allowlist." \
    || { echo "azdo-tag-guard: tag removed but the comment failed" >&2; exit 1; }
  exit 65
fi

if [[ -n "$stranger" ]]; then
  azdo_comment "$WORK_ITEM_ID" \
    "$TRIGGER_TAG ignored: the work item was changed by $stranger after the tag was added, and that identity is not on this pipeline's allowlist. Re-add the tag to run on the current content." \
    || { echo "azdo-tag-guard: tag removed but the comment failed" >&2; exit 1; }
  exit 66
fi

exit 0
