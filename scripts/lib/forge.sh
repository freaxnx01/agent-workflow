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
    *)
      printf 'forge.sh: no read adapter for forge "%s" yet (see #253)\n' "$forge" >&2
      return 2
      ;;
  esac

  export ISSUE_LABELS ISSUE_BODY ISSUE_JSON ISSUE_COMMENTS_JSON
}
