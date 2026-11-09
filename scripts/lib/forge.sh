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
#   forge_pr_diff <pr>                  unified diff to stdout. azdo: the three-dot
#                                       diff of the checkout against
#                                       origin/$DEFAULT_BRANCH (must be set).
#   forge_pr_head_sha <pr>              the PR head SHA. azdo: HEAD of the checkout.
#   forge_pr_comment <pr> <body-file>   post the file as a PR comment (azdo: one
#                                       active thread).
#   forge_pr_comments_json <pr>         NOTE THE NAME: echoes every PR comment
#                                       body as TEXT, not JSON, because that is
#                                       what review-pr.sh's marker check reads.
#                                       The mismatch is deliberate.
#
# FORGE, when set, overrides detect_forge for the four PR verbs (see _forge_kind).
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
      # title + "\n" + body, NOT body alone. classify-turns.sh's own gh fallback
      # builds it that way, and its heuristic greps the result -- so a body-only
      # value would make the injected path score differently from the fallback
      # for any issue whose signal is in the title.
      ISSUE_BODY="$(printf '%s' "$json" | python3 -c '
import sys, json
d = json.load(sys.stdin)
print(d.get("title", "") + "\n" + d.get("body", ""))')"
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

      # Same shape as the GitHub branch: title + "\n" + description. On this
      # forge it also stops the value being EMPTY for a work item with no
      # description, which classify-turns would read as "not injected" and fall
      # back to gh for -- against a repo gh cannot reach.
      ISSUE_BODY="$(printf '%s' "$wi" | python3 -c '
import sys, json
f = json.load(sys.stdin).get("fields", {})
print(f.get("System.Title", "") + "\n" + f.get("System.Description", ""))')"

      # Normalise to gh's shape. An ADO comment's text is `.text`; a GitHub
      # comment's is `.body`, and build-agent-prompt reads `.body`. Without this
      # mapping every comment would render empty -- silently.
      #
      # Both documents go via temp files, not one stream: `az` pretty-prints
      # JSON across many lines, so any attempt to separate two responses on
      # stdin by a newline parses the first brace as the whole document.
      # Convert before mktemp: a failing helper must not leave temp files behind.
      ISSUE_COMMENTS_JSON="$(printf '%s' "$comments" | _forge_azdo_comments_text)" \
        || { printf 'forge.sh: cannot read the azdo comments document\n' >&2; return 1; }
      local _wf _cf
      _wf="$(mktemp)"; _cf="$(mktemp)"
      printf '%s' "$wi" > "$_wf"
      printf '%s' "$ISSUE_COMMENTS_JSON" > "$_cf"
      ISSUE_JSON="$(python3 -c '
import json, sys
wi = json.load(open(sys.argv[1]))
bodies = json.load(open(sys.argv[2]))
f = wi.get("fields", {})
print(json.dumps({
    "title": f.get("System.Title", ""),
    "body": f.get("System.Description", ""),
    "comments": bodies,
}))' "$_wf" "$_cf")"
      rm -f "$_wf" "$_cf"
      ;;
    *)
      printf 'forge.sh: no read adapter for forge "%s" yet (see #253)\n' "$forge" >&2
      return 2
      ;;
  esac

  export ISSUE_LABELS ISSUE_BODY ISSUE_JSON ISSUE_COMMENTS_JSON
}

# _forge_azdo_comments_text  reads an Azure DevOps comments document on stdin and
# prints a JSON array [{"body": <plain text>}] in API order.
# The comments API returns HTML (<div> wrappers, &nbsp;, entities), while
# check-attempt-cap.sh matches `startswith("## ai-implement run")`; without this
# conversion no report is ever counted. Tags are stripped BEFORE unescaping, so
# an escaped `&lt;b&gt;` stays the text `<b>`.
_forge_azdo_comments_text() {
  python3 -c '
import html, json, re, sys

def plain(text):
    text = re.sub(r"(?i)<br\s*/?>", "\n", text)
    text = re.sub(r"(?i)</(div|p)>", "\n", text)
    text = re.sub(r"<[^>]+>", "", text)
    return html.unescape(text).replace("\u00a0", " ").strip()

doc = json.load(sys.stdin)
print(json.dumps([{"body": plain(c.get("text") or "")}
                  for c in doc.get("comments") or []]))'
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

# forge_pr_create_draft <head-branch> <base-branch> <title> <body> [issue-number]
#
# Echoes the created PR's NUMBER on success. Draft, always: find-pipeline-pr.sh
# selects only drafts, so a ready-for-review PR gets no pipeline review at all
# (agent-workflow#322).
#
# The issue number is optional on GitHub -- the body carries the link -- but on
# Azure DevOps it is how the work item and the PR are associated at all, via
# --work-items. There is no "Closes #N" convention there.
forge_pr_create_draft() {
  local head="${1:?forge_pr_create_draft requires a head branch}"
  local base="${2:?forge_pr_create_draft requires a base branch}"
  local title="${3:?forge_pr_create_draft requires a title}"
  local body="${4-}" issue="${5-}"

  case "$(detect_forge | awk '{print $1}')" in
    github)
      : "${REPO:?REPO must be set}"
      # gh prints the PR URL; the last path segment is the number.
      local url
      url="$(gh pr create --repo "$REPO" --draft \
               --base "$base" --head "$head" \
               --title "$title" --body "$body")" || return 1
      printf '%s' "${url##*/}"
      ;;
    azdo)
      _forge_source_azdo; resolve_azdo_context || return 1
      local args=(repos pr create --org "$(azdo_org_url)"
                  --project "$AZDO_PROJECT" --repository "$AZDO_REPO"
                  --source-branch "$head" --target-branch "$base"
                  --title "$title" --draft
                  --output tsv --only-show-errors --query pullRequestId)
      [[ -n "$body" ]] && args+=(--description "$body")
      # Without this the work item and the PR are unrelated: ADO has no
      # "Closes #N" convention, so the link IS the association.
      [[ -n "$issue" ]] && args+=(--work-items "$issue")
      az "${args[@]}" || return 1
      ;;
    *)
      printf 'forge.sh: no PR adapter for this forge yet (#253)\n' >&2
      return 2
      ;;
  esac
}

# --- PR verbs ----------------------------------------------------------------
#
# What the shared review / self-fix scripts need from a pull request. The github
# branch of each is the gh call those scripts make today, character for
# character; azdo reads the job's own checkout where it can, since the pipeline
# agent has already checked the branch out.

# _forge_kind  echoes the forge: $FORGE when set and non-empty, otherwise the
# first word of detect_forge. The override lets a caller that already knows its
# forge skip the git-remote probe (and run outside a git repo).
_forge_kind() {
  if [[ -n "${FORGE:-}" ]]; then printf '%s\n' "$FORGE"; return 0; fi
  detect_forge | awk '{print $1}'
}

# _forge_no_pr_adapter  the refusal every PR verb gives an unknown forge.
_forge_no_pr_adapter() {
  printf 'forge.sh: no PR adapter for this forge yet (#253)\n' >&2
  return 2
}

# _forge_azdo_thread_bodies  reads an Azure DevOps pullRequestThreads document on
# stdin and prints the content of every comment of every thread, one after
# another. System threads carry comments without `content`; those are skipped,
# not printed as "None".
_forge_azdo_thread_bodies() {
  python3 -c '
import json, sys
for thread in json.load(sys.stdin).get("value") or []:
    for comment in thread.get("comments") or []:
        content = comment.get("content")
        if content:
            print(content)'
}

# _forge_azdo_threads <pr> [az args...]  the pullRequestThreads call shared by
# forge_pr_comment (POST) and forge_pr_comments_json (GET); the caller's extra
# arguments pick the method, the input and the output format.
_forge_azdo_threads() {
  local pr="$1"; shift
  _forge_source_azdo; resolve_azdo_context || return 1
  az devops invoke --org "$(azdo_org_url)" --area git \
    --resource pullRequestThreads \
    --route-parameters project="$AZDO_PROJECT" repositoryId="$AZDO_REPO" \
      pullRequestId="$pr" \
    --api-version 7.1 --only-show-errors "$@"
}

# forge_pr_diff <pr>
#
# Writes the unified diff to stdout. On azdo it is the three-dot diff of the
# checkout against origin/$DEFAULT_BRANCH, with the prefixes and external diff
# pinned so a user's diff.noprefix / diff.external cannot change its shape.
# DEFAULT_BRANCH is never guessed: a wrong base reviews the wrong change.
forge_pr_diff() {
  local pr="${1:?forge_pr_diff requires a PR number}"
  case "$(_forge_kind)" in
    github)
      : "${REPO:?REPO must be set}"
      gh pr diff "$pr" --repo "$REPO"
      ;;
    azdo)
      if [[ -z "${DEFAULT_BRANCH:-}" ]]; then
        printf 'forge_pr_diff: DEFAULT_BRANCH must be set on azdo\n' >&2
        return 1
      fi
      git diff --no-color --no-ext-diff --src-prefix=a/ --dst-prefix=b/ \
        "origin/${DEFAULT_BRANCH}...HEAD"
      ;;
    *) _forge_no_pr_adapter ;;
  esac
}

# forge_pr_head_sha <pr>
#
# Echoes the PR's head SHA. On azdo the job's checkout IS the PR branch, so HEAD
# is the answer, and it moves with a self-fix commit, which is what makes the
# re-review's marker differ from the first review's.
forge_pr_head_sha() {
  local pr="${1:?forge_pr_head_sha requires a PR number}"
  case "$(_forge_kind)" in
    github)
      : "${REPO:?REPO must be set}"
      gh pr view "$pr" --repo "$REPO" --json headRefOid --jq '.headRefOid'
      ;;
    azdo) git rev-parse HEAD ;;
    *) _forge_no_pr_adapter ;;
  esac
}

# forge_pr_comment <pr> <body-file>
#
# Takes a FILE, as forge_issue_comment does. On azdo a PR comment is a thread:
# one active thread holding the file's text. The body is built with jq so
# backticks, `$` and newlines reach the API untouched, and goes over stdin like
# the other plain-JSON calls (azdo_wiql / azdo_fields).
forge_pr_comment() {
  local pr="${1:?forge_pr_comment requires a PR number}"
  local f="${2:?forge_pr_comment requires a body file}"
  case "$(_forge_kind)" in
    github)
      : "${REPO:?REPO must be set}"
      gh pr comment "$pr" --repo "$REPO" --body-file "$f"
      ;;
    azdo)
      jq -n --rawfile c "$f" \
        '{comments: [{parentCommentId: 0, content: $c, commentType: 1}], status: "active"}' \
      | _forge_azdo_threads "$pr" --http-method POST --in-file /dev/stdin --output none
      ;;
    *) _forge_no_pr_adapter ;;
  esac
}

# forge_pr_comments_json <pr>
#
# Despite the name this echoes the comment BODIES AS TEXT, not JSON: that is
# what review-pr.sh's marker check greps. The name is kept from the spec; the
# contract is documented in the header. On azdo, every comment of every thread.
forge_pr_comments_json() {
  local pr="${1:?forge_pr_comments_json requires a PR number}"
  case "$(_forge_kind)" in
    github)
      : "${REPO:?REPO must be set}"
      gh pr view "$pr" --repo "$REPO" --json comments --jq '.comments[].body'
      ;;
    azdo)
      _forge_azdo_threads "$pr" --output json | _forge_azdo_thread_bodies
      ;;
    *) _forge_no_pr_adapter ;;
  esac
}
