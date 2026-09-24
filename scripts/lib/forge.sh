#!/usr/bin/env bash
#
# forge.sh — sourced, not executed.
#
# The forge-portable read path for the implement pipeline.
#
# The classifiers (classify-agent, classify-task, classify-turns) already prefer
# an injected ISSUE_LABELS / ISSUE_BODY and fall back to `gh` only when those are
# unset -- a seam built for their own Layer-1 tests. This does not rewrite their
# call sites; it fills the two variables they already look for, per forge, once
# per run. Five scripts stop needing the forge without any of them changing.
#
#   forge_export_issue <issue-number>   exports the four variables the implement
#                                       job's read paths already prefer, from a
#                                       SINGLE forge call:
#                                         ISSUE_LABELS        classify-agent/task/turns
#                                         ISSUE_BODY          classify-turns
#                                         ISSUE_JSON          build-agent-prompt
#                                         ISSUE_COMMENTS_JSON check-attempt-cap
#
# Requires: detect-forge.sh sourced first (for detect_forge), and REPO set.
#
# Exit codes:
#   0  success
#   1  the underlying forge call failed
#   2  the remote is on a forge this adapter does not implement yet
set -euo pipefail
IFS=$'\n\t'

# _forge_source_azdo  sources azdo.sh once, from beside this file.
_forge_source_azdo() {
  [[ -n "${_FORGE_AZDO_SOURCED:-}" ]] && return 0
  # shellcheck source=scripts/lib/azdo.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/azdo.sh"
  _FORGE_AZDO_SOURCED=1
}

# forge_export_issue <issue-number>
#
# ISSUE_LABELS is newline-separated, matching what `gh issue view --json labels
# --jq '.labels[].name'` produces today -- the classifiers split on lines, so the
# separator is part of the contract, not an implementation detail.
#
# Returns 2 rather than exporting empty values on an unknown forge. An empty
# ISSUE_LABELS is indistinguishable from "this issue carries no labels", which
# every classifier would act on: no agent override, no model override, default
# turn budget. Failing loudly is the only safe answer.
forge_export_issue() {
  local n="${1:?forge_export_issue requires an issue number}"
  local forge json
  : "${REPO:?REPO must be set}"

  forge="$(detect_forge | awk '{print $1}')"

  case "$forge" in
    github)
      # One call, four consumers. Fetching labels/title/body/comments together
      # replaces what were five separate `gh issue view` calls across the job.
      json="$(gh issue view "$n" --repo "$REPO" --json labels,title,body,comments)" || return 1
      ISSUE_LABELS="$(printf '%s' "$json" | python3 -c '
import sys, json
for l in json.load(sys.stdin).get("labels", []):
    print(l["name"])')"
      ISSUE_BODY="$(printf '%s' "$json" | python3 -c '
import sys, json
print(json.load(sys.stdin).get("body", ""))')"
      # build-agent-prompt wants title+body+comments in gh's own shape.
      ISSUE_JSON="$(printf '%s' "$json" | python3 -c '
import sys, json
d = json.load(sys.stdin)
print(json.dumps({"title": d.get("title", ""), "body": d.get("body", ""),
                  "comments": d.get("comments", [])}))')"
      ISSUE_COMMENTS_JSON="$(printf '%s' "$json" | python3 -c '
import sys, json
print(json.dumps(json.load(sys.stdin).get("comments", [])))')"
      ;;
    azdo)
      # Requires azdo.sh's context. resolve_azdo_context sets AZDO_ORG /
      # AZDO_PROJECT / AZDO_REPO from the remote.
      _forge_source_azdo
      resolve_azdo_context || return 1

      local wi comments
      wi="$(az boards work-item show --id "$n" --org "$(azdo_org_url)" \
              --output json --only-show-errors)" || return 1

      # Comments are NOT on the work item: they live at their own resource, and
      # at api-version 7.1-PREVIEW rather than 7.1.
      comments="$(az devops invoke --org "$(azdo_org_url)" \
                    --area wit --resource comments \
                    --route-parameters project="$AZDO_PROJECT" workItemId="$n" \
                    --api-version 7.1-preview --output json --only-show-errors)" || comments='{"comments":[]}'

      # Tags are this forge's labels. `; `-separated -- semicolon AND space --
      # so split on the semicolon and strip, never on the bare character.
      ISSUE_LABELS="$(printf '%s' "$wi" | python3 -c '
import sys, json
f = json.load(sys.stdin).get("fields", {})
for t in (f.get("System.Tags") or "").split(";"):
    t = t.strip()
    if t:
        print(t)')"

      ISSUE_BODY="$(printf '%s' "$wi" | python3 -c '
import sys, json
print(json.load(sys.stdin).get("fields", {}).get("System.Description", ""))')"

      # Normalise to gh's shape. An ADO comment's text is `.text`; a GitHub
      # comment's is `.body`, and build-agent-prompt reads `.body`. Without this
      # mapping every comment would render empty -- silently.
      #
      # Both documents go via temp files, not one stream: `az` pretty-prints
      # JSON across many lines, so any attempt to separate two responses on
      # stdin by a newline parses the first brace as the whole document.
      local _wf _cf
      _wf="$(mktemp)"; _cf="$(mktemp)"
      printf '%s' "$wi" > "$_wf"
      printf '%s' "$comments" > "$_cf"
      ISSUE_JSON="$(python3 -c '
import json, sys
wi = json.load(open(sys.argv[1]))
cm = json.load(open(sys.argv[2]))
f = wi.get("fields", {})
print(json.dumps({
    "title": f.get("System.Title", ""),
    "body": f.get("System.Description", ""),
    "comments": [{"body": c.get("text", "")} for c in cm.get("comments", [])],
}))' "$_wf" "$_cf")"
      rm -f "$_wf" "$_cf"

      ISSUE_COMMENTS_JSON="$(printf '%s' "$comments" | python3 -c '
import sys, json
print(json.dumps([{"body": c.get("text", "")}
                  for c in json.load(sys.stdin).get("comments", [])]))')"
      ;;
    *)
      printf 'forge.sh: no read adapter for forge "%s" yet (see #253)\n' "$forge" >&2
      return 2
      ;;
  esac

  export ISSUE_LABELS ISSUE_BODY ISSUE_JSON ISSUE_COMMENTS_JSON
}

# _forge_azdo_tags <work-item-id>  echoes the item's current tags, one per line.
# Every label write on this forge is read-modify-write: azdo_set_tags REPLACES
# the whole field, because the --fields form appends and cannot clear.
_forge_azdo_tags() {
  az boards work-item show --id "$1" --org "$(azdo_org_url)" \
    --output json --only-show-errors \
  | python3 -c '
import sys, json
f = json.load(sys.stdin).get("fields", {})
for t in (f.get("System.Tags") or "").split(";"):
    t = t.strip()
    if t:
        print(t)'
}

# _forge_azdo_retag <id> <add-csv> <remove-csv>  read-modify-write in one go.
_forge_azdo_retag() {
  local id="$1" add="${2-}" rm="${3-}" cur new
  cur="$(_forge_azdo_tags "$id")" || return 1
  new="$(printf '%s' "$cur" | python3 -c '
import sys
cur = [t.strip() for t in sys.stdin.read().splitlines() if t.strip()]
add = [t.strip() for t in sys.argv[1].split(",") if t.strip()]
rm  = {t.strip() for t in sys.argv[2].split(",") if t.strip()}
out = [t for t in cur if t not in rm]
for t in add:
    if t not in out:
        out.append(t)
print(";".join(out))' "$add" "$rm")" || return 1
  azdo_set_tags "$id" "$new" >/dev/null
}

# --- write verbs -------------------------------------------------------------
#
# Each mirrors one gh call the implement job already makes. They exist so the
# call sites stop naming a forge, not to add behaviour: same arguments, same
# exit codes, same idempotence as the gh form they replace.
#
# All four refuse an unsupported forge with exit 2 rather than doing nothing.
# A write that silently no-ops is worse than one that fails, because the caller
# reports success and the issue is left in a state nobody expects.

# forge_issue_comment <issue-number> <body-file>
#
# Takes a FILE, never a string. A run report is multi-line and long enough that
# passing it as an argument is a real risk; post-run-report.sh already uses
# --body-file for that reason and this must not regress it.
forge_issue_comment() {
  local n="${1:?forge_issue_comment requires an issue number}"
  local f="${2:?forge_issue_comment requires a body file}"
  : "${REPO:?REPO must be set}"
  case "$(detect_forge | awk '{print $1}')" in
    github) gh issue comment "$n" --repo "$REPO" --body-file "$f" ;;
    azdo)
      _forge_source_azdo; resolve_azdo_context || return 1
      # --discussion takes the text directly; read the file in.
      az boards work-item update --id "$n" --org "$(azdo_org_url)" \
        --discussion "$(cat "$f")" --output none --only-show-errors
      ;;
    *) printf 'forge.sh: no comment adapter for this forge yet (#253)\n' >&2; return 2 ;;
  esac
}

# forge_issue_label_add <issue-number> <comma-separated-names>
forge_issue_label_add() {
  local n="${1:?forge_issue_label_add requires an issue number}"
  local labels="${2:?forge_issue_label_add requires labels}"
  : "${REPO:?REPO must be set}"
  case "$(detect_forge | awk '{print $1}')" in
    github) gh issue edit "$n" --repo "$REPO" --add-label "$labels" ;;
    azdo) _forge_source_azdo; resolve_azdo_context || return 1; _forge_azdo_retag "$n" "$labels" "" ;;
    *) printf 'forge.sh: no label adapter for this forge yet (#253)\n' >&2; return 2 ;;
  esac
}

# forge_issue_label_remove <issue-number> <name>
forge_issue_label_remove() {
  local n="${1:?forge_issue_label_remove requires an issue number}"
  local label="${2:?forge_issue_label_remove requires a label}"
  : "${REPO:?REPO must be set}"
  case "$(detect_forge | awk '{print $1}')" in
    github) gh issue edit "$n" --repo "$REPO" --remove-label "$label" ;;
    azdo) _forge_source_azdo; resolve_azdo_context || return 1; _forge_azdo_retag "$n" "" "$label" ;;
    *) printf 'forge.sh: no label adapter for this forge yet (#253)\n' >&2; return 2 ;;
  esac
}

# forge_label_ensure <name> <color> <description>
#
# Idempotent by contract: an existing label is left exactly as it is, colour
# included. ensure-issue-labels.sh depends on that and documents it, so the
# caller keeps whatever error suppression it already has -- `gh label create`
# errors on an existing label and that is the expected, tolerated path.
forge_label_ensure() {
  local name="${1:?forge_label_ensure requires a name}"
  local color="${2:?forge_label_ensure requires a color}"
  local desc="${3:?forge_label_ensure requires a description}"
  : "${REPO:?REPO must be set}"
  case "$(detect_forge | awk '{print $1}')" in
    github) gh label create "$name" --repo "$REPO" --color "$color" --description "$desc" ;;
    azdo)
      # A no-op by design. Azure DevOps tags are created on first use -- there is
      # no label registry to seed, and no colour or description to carry. Verified
      # live: azdo_set_tags created a previously unseen tag with no prior step.
      return 0
      ;;
    *) printf 'forge.sh: no label adapter for this forge yet (#253)\n' >&2; return 2 ;;
  esac
}

# forge_issue_label_edit <issue-number> <add-csv> <remove-csv>
#
# Add and remove in ONE call. check-attempt-cap.sh parks an issue by adding the
# park label and removing the dispatch label together, and that atomicity
# matters: split into two calls, a failure between them leaves the issue parked
# but still carrying ai-implement, which invites a re-dispatch loop. Either
# argument may be empty.
forge_issue_label_edit() {
  local n="${1:?forge_issue_label_edit requires an issue number}"
  local add="${2-}" rm="${3-}"
  : "${REPO:?REPO must be set}"
  local args=(issue edit "$n" --repo "$REPO")
  [[ -n "$add" ]] && args+=(--add-label "$add")
  [[ -n "$rm" ]] && args+=(--remove-label "$rm")
  case "$(detect_forge | awk '{print $1}')" in
    github) gh "${args[@]}" ;;
    azdo) _forge_source_azdo; resolve_azdo_context || return 1; _forge_azdo_retag "$n" "$add" "$rm" ;;
    *) printf 'forge.sh: no label adapter for this forge yet (#253)\n' >&2; return 2 ;;
  esac
}
