#!/usr/bin/env bash
#
# migrate-gh-issues-to-azdo.sh — move a consumer's OPEN GitHub issues to Azure
# DevOps work items, once (#642).
#
# Run by an operator on the cutover day, from a checkout of the consumer
# repository whose `origin` is the target Azure DevOps project (or with AZDO_ORG
# and AZDO_PROJECT set). Closed issues, pull requests, milestones, assignees and
# reactions are out of scope.
#
# Each open issue becomes ONE work item whose System.Description is MARKDOWN, so
# the body — fenced blocks, task lists, an inlined plan — survives verbatim with
# only a `_Migrated from <url>._` line appended. Its comments follow as Markdown
# work item comments, each headed with who wrote it on GitHub and when.
#
# Usage:
#   migrate-gh-issues-to-azdo.sh --repo <owner/name> --area <path> \
#     [--type <t>] [--bug-type <t>] [--story-type <t>] \
#     [--close] [--dry-run] [--limit <n>]
#
#   --repo        required  the GitHub source, e.g. contoso/consumer-repo
#   --area        required  System.AreaPath for every item. The ADO service hook
#                           filters on it, so an item outside it is invisible to
#                           the pipeline — there is no default.
#   --type        every issue gets this type, overriding the two below
#   --bug-type    type for an issue labelled `bug` (default: Bug)
#   --story-type  type for every other issue (default: User Story)
#   --close       also close each migrated GitHub issue
#   --dry-run     read everything, write nothing, report per issue
#   --limit <n>   migrate the first n issues only, for a trial run (n > 0)
#
# Env: AZURE_DEVOPS_EXT_PAT is required — by the WRITES, and by the up-front
# validation reads, so a dry run needs it too. `gh` reads GitHub with its own
# login. AZDO_ORG / AZDO_PROJECT override what `origin` says.
#
# IDEMPOTENCY. A migrated issue gets a link comment carrying an invisible marker
# naming this project and the new id, and a re-run skips any issue that has one.
# The marker is matched on the whole project path: an issue migrated to a
# DIFFERENT project is not this backlog's, so it is migrated rather than skipped.
#
# FAILURE. The run stops at the first failed write. A work item created without
# its GitHub write-back is an ORPHAN: it carries no marker, so a re-run would
# create a second item for the same issue. There is no resume mode and nothing
# is guessed — the id is printed and the operator deletes it or adds the marker
# by hand. The run is one-off and small, and an honest stop is easier to recover
# from than a half-resume.
#
# Exit codes:
#   0  done, including a dry run
#   1  a write failed, or an orphan was left
#   2  a usage or validation error — nothing was read or written
set -euo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/detect-forge.sh
source "$HERE/lib/detect-forge.sh"
# shellcheck source=scripts/lib/azdo.sh
source "$HERE/lib/azdo.sh"
# shellcheck source=scripts/lib/gh-issue-migration.sh
source "$HERE/lib/gh-issue-migration.sh"

SELF="migrate-gh-issues-to-azdo"

# usage  prints the header comment — the whole of it, exit codes included — on
# stdout, so `--help` is readable output and not an error stream.
usage() {
  sed -n '3,51p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die_usage() {
  printf '%s: %s\n\n' "$SELF" "$1" >&2
  usage >&2
  exit 2
}

# --- arguments ----------------------------------------------------------

REPO=""
AREA=""
TYPE_OVERRIDE=""
BUG_TYPE="Bug"
STORY_TYPE="User Story"
CLOSE=0
DRY_RUN=0
# Unset, not 0: 0 is explode_issues' sentinel for "no limit", so it must not
# double as a value an operator can pass — see the check below.
LIMIT=""

need_value() { [[ $2 -ge 2 ]] || die_usage "$1 requires a value"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)       need_value "$1" $#; REPO="$2"; shift 2 ;;
    --area)       need_value "$1" $#; AREA="$2"; shift 2 ;;
    --type)       need_value "$1" $#; TYPE_OVERRIDE="$2"; shift 2 ;;
    --bug-type)   need_value "$1" $#; BUG_TYPE="$2"; shift 2 ;;
    --story-type) need_value "$1" $#; STORY_TYPE="$2"; shift 2 ;;
    --limit)      need_value "$1" $#; LIMIT="$2"; shift 2 ;;
    --close)      CLOSE=1; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            die_usage "unknown argument '$1'" ;;
  esac
done

[[ -n "$REPO" ]] || die_usage "--repo <owner/name> is required"
[[ "$REPO" == */* ]] || die_usage "--repo must be <owner>/<name>, got '$REPO'"
[[ -n "$AREA" ]] || die_usage "--area <path> is required — the ADO service hook filters on it"
if [[ -n "$LIMIT" ]]; then
  [[ "$LIMIT" =~ ^[0-9]+$ ]] || die_usage "--limit must be a number, got '$LIMIT'"
  # Zero is refused rather than accepted: it is explode_issues' sentinel for
  # "no limit", so `--limit 0` on a flag whose whole purpose is a cautious
  # trial run would quietly migrate the entire backlog. The value is known to
  # be digits by now, so "carries a non-zero one" is the whole test.
  [[ "$LIMIT" =~ [1-9] ]] || die_usage "--limit must be greater than 0, got '$LIMIT'"
fi

# --- validation, before a single issue is read --------------------------

if [[ -z "${AZURE_DEVOPS_EXT_PAT:-}" ]]; then
  printf '%s: AZURE_DEVOPS_EXT_PAT must be set — a dry run needs it for the validation reads too\n' "$SELF" >&2
  exit 2
fi

if [[ -z "${AZDO_ORG:-}" || -z "${AZDO_PROJECT:-}" ]]; then
  resolve_azdo_context || {
    printf '%s: origin is not an Azure DevOps remote — run this from the consumer checkout, or set AZDO_ORG and AZDO_PROJECT\n' "$SELF" >&2
    exit 2
  }
fi

# The type names belong to the project's process template, not to this script: a
# Basic project has Issue and neither Bug nor User Story. Checking 20 creates in
# is no use, so check here — and report EVERY missing type at once, so an
# operator makes one correction rather than three.
project_types="$(azdo_work_item_types)" || {
  printf '%s: could not read the work item types of %s\n' "$SELF" "$AZDO_PROJECT" >&2
  exit 2
}

missing_type() { # <name> <flag>
  printf '%s\n' "$project_types" | grep -qxF -- "$1" && return 1
  printf "%s: work item type '%s' does not exist in '%s' — override it with %s\n" \
    "$SELF" "$1" "$AZDO_PROJECT" "$2" >&2
  return 0
}

types_ok=1
if [[ -n "$TYPE_OVERRIDE" ]]; then
  missing_type "$TYPE_OVERRIDE" --type && types_ok=0
else
  missing_type "$BUG_TYPE" --bug-type && types_ok=0
  missing_type "$STORY_TYPE" --story-type && types_ok=0
fi
(( types_ok )) || exit 2

# azdo_areas lists the project's FIRST-LEVEL area nodes, so what can be verified
# is the first component of --area below the project — enough to catch the typo
# this guards against, and it never rejects a legitimately deeper path.
area_node="${AREA#"$AZDO_PROJECT"\\}"
area_node="${area_node%%\\*}"
if [[ -n "$area_node" && "$area_node" != "$AZDO_PROJECT" ]]; then
  project_areas="$(azdo_areas)" || {
    printf '%s: could not read the areas of %s\n' "$SELF" "$AZDO_PROJECT" >&2
    exit 2
  }
  if ! printf '%s\n' "$project_areas" | grep -qxF -- "$area_node"; then
    printf "%s: --area '%s' does not exist — '%s' is not an area of '%s'\n" \
      "$SELF" "$AREA" "$area_node" "$AZDO_PROJECT" >&2
    exit 2
  fi
fi

PROJECT_PATH="$(azdo_project_url_path)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- reading GitHub -----------------------------------------------------

# explode_issues <out-dir> <limit>  reads the issue list on stdin and writes one
# directory per open issue, numbered in list order, then echoes how many.
#
# A file per field rather than one line per issue: a body runs to tens of
# kilobytes and carries newlines, quotes and backslashes, so it must never
# become a shell variable or a delimited field.
explode_issues() {
  # SC2016: the python program below is deliberately single-quoted — nothing in
  # it is a shell expansion, and the two arguments arrive as argv.
  # shellcheck disable=SC2016
  python3 -c '
import json, os, sys

def issues(text):
    """One array per page, concatenated: `gh api --paginate` emits several JSON
    documents rather than one."""
    decoder, at, out = json.JSONDecoder(), 0, []
    while True:
        while at < len(text) and text[at].isspace():
            at += 1
        if at >= len(text):
            return out
        page, at = decoder.raw_decode(text, at)
        out.extend(page)

out_dir, limit = sys.argv[1], int(sys.argv[2])
seq = 0
for issue in issues(sys.stdin.read()):
    # The issues endpoint returns pull requests too; they are not issues.
    if "pull_request" in issue:
        continue
    if limit and seq >= limit:
        break
    seq += 1
    d = os.path.join(out_dir, "%04d" % seq)
    os.makedirs(d)

    def write(name, text):
        with open(os.path.join(d, name), "w", encoding="utf-8") as fh:
            fh.write(text)

    body = issue.get("body") or ""
    write("number", str(issue["number"]))
    write("title", issue["title"])
    write("labels", "\n".join(l["name"] for l in issue.get("labels") or []))
    write("body-bytes", str(len(body.encode("utf-8"))))
    # Trailing blank lines are trimmed so the migrated-from line sits exactly one
    # blank line below the body, whatever the issue ended with.
    write("description", body.rstrip("\r\n") + "\n\n_Migrated from %s._" % issue["html_url"])
print(seq)' "$1" "$2"
}

# explode_comments <out-dir>  reads an issue's comments on stdin, oldest first,
# and writes <NNNN>.body plus an index of <NNNN>\t<created-at>\t<login>. Also
# writes bodies.txt, the concatenation the marker check reads.
#
# The LOGIN COMES LAST because a deleted account has none: bash's `read` treats
# a run of tabs as one delimiter, so an empty field in the middle shifts every
# field after it, while an empty trailing one simply reads as empty.
explode_comments() {
  python3 -c '
import json, os, sys

def comments(text):
    decoder, at, out = json.JSONDecoder(), 0, []
    while True:
        while at < len(text) and text[at].isspace():
            at += 1
        if at >= len(text):
            return out
        page, at = decoder.raw_decode(text, at)
        out.extend(page)

out_dir = sys.argv[1]
items = comments(sys.stdin.read())
items.sort(key=lambda c: (c.get("created_at", ""), c.get("id", 0)))
index, bodies = [], []
for seq, comment in enumerate(items, start=1):
    body = (comment.get("body") or "").rstrip("\r\n") + "\n"
    with open(os.path.join(out_dir, "%04d.body" % seq), "w", encoding="utf-8") as fh:
        fh.write(body)
    author = comment.get("user") or {}
    index.append("%04d\t%s\t%s" % (seq, comment.get("created_at", ""), author.get("login", "")))
    bodies.append(body)
with open(os.path.join(out_dir, "index.tsv"), "w", encoding="utf-8") as fh:
    fh.write("".join(line + "\n" for line in index))
with open(os.path.join(out_dir, "bodies.txt"), "w", encoding="utf-8") as fh:
    fh.write("".join(bodies))
print(len(items))' "$1"
}

# read_comments <issue-number> <comment-dir>  echoes how many there were.
#
# `gh issue view` caps the comments it returns, so the REST endpoint is read
# with --paginate instead.
read_comments() {
  local number="$1" dir="$2" raw
  mkdir -p "$dir"
  raw="$(gh api --paginate "repos/$REPO/issues/$number/comments?per_page=100")" || {
    printf '%s: #%s: could not read the comments\n' "$SELF" "$number" >&2
    return 1
  }
  printf '%s' "$raw" | explode_comments "$dir"
}

# --- the migration ------------------------------------------------------

report_orphan() { # <work-item-id> <issue-number>
  printf 'orphan work item %s for #%s: delete it, or add the marker to the issue by hand\n' \
    "$1" "$2" >&2
}

# copy_comments <work-item-id> <issue-number> <comment-dir>  posts every comment
# in order. Returns 1 at the first failure, having reported the orphan.
copy_comments() {
  local id="$1" number="$2" dir="$3" seq created login
  [[ -s "$dir/index.tsv" ]] || return 0
  while IFS=$'\t' read -r seq created login; do
    [[ -n "$seq" ]] || continue
    {
      migration_comment_header "$login" "$created"
      printf '\n'
      cat "$dir/$seq.body"
    } > "$dir/$seq.md"
    azdo_comment_markdown "$id" "$dir/$seq.md" || {
      printf '%s: #%s: copying comment %s to work item %s failed\n' "$SELF" "$number" "$seq" "$id" >&2
      report_orphan "$id" "$number"
      return 1
    }
  done < "$dir/index.tsv"
}

# write_back <work-item-id> <issue-number> <note-file>  comments the link and the
# marker on the GitHub issue, and closes it with --close. Returns 1 at the first
# failure, having reported the orphan where one was left.
write_back() {
  local id="$1" number="$2" note="$3"
  {
    printf 'Migrated to Azure DevOps work item [#%s](%s/_workitems/edit/%s).\n' \
      "$id" "$PROJECT_PATH" "$id"
    migration_marker "$PROJECT_PATH" "$id"
  } > "$note"

  gh issue comment "$number" --repo "$REPO" --body-file "$note" >/dev/null || {
    printf '%s: #%s: the GitHub link comment failed\n' "$SELF" "$number" >&2
    report_orphan "$id" "$number"
    return 1
  }

  (( CLOSE )) || return 0
  # The marker is on the issue by now, so a re-run skips it — a failed close
  # leaves no orphan, just work for the operator.
  gh issue close "$number" --repo "$REPO" >/dev/null || {
    printf '%s: #%s: work item %s is created and linked, but closing the issue failed\n' \
      "$SELF" "$number" "$id" >&2
    return 1
  }
}

MIGRATED=0
SKIPPED=0

# migrate_one <issue-dir>  the whole per-issue sequence. Returns 1 on the first
# failed read or write.
migrate_one() {
  local dir="$1" number title labels comments marker_rc=0 existing type tags id
  number="$(cat "$dir/number")"
  title="$(cat "$dir/title")"
  labels="$(cat "$dir/labels")"

  comments="$(read_comments "$number" "$dir/comments")" || return 1

  existing="$(migration_marker_id "$PROJECT_PATH" "$dir/comments/bodies.txt")" || marker_rc=$?
  if [[ $marker_rc -eq 0 ]]; then
    printf 'skip #%s (already work item %s)\n' "$number" "$existing"
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi

  type="$(migration_type "$labels" "$BUG_TYPE" "$STORY_TYPE" "$TYPE_OVERRIDE")"
  tags="$(migration_tags "$labels")"

  if (( DRY_RUN )); then
    printf 'would create %s "%s" tags=[%s] comments=%s body=%sB\n' \
      "$type" "$title" "$tags" "$comments" "$(cat "$dir/body-bytes")"
    MIGRATED=$((MIGRATED + 1))
    return 0
  fi

  id="$(azdo_create_markdown_item "$type" "$title" "$AREA" "$tags" "$dir/description")" || {
    printf '%s: #%s: creating the work item failed — nothing was written, so a re-run is safe\n' \
      "$SELF" "$number" >&2
    return 1
  }

  copy_comments "$id" "$number" "$dir/comments" || return 1
  write_back "$id" "$number" "$dir/write-back.md" || return 1

  printf '#%s -> work item %s (%s, %s comments)\n' "$number" "$id" "$type" "$comments"
  MIGRATED=$((MIGRATED + 1))
}

issues_raw="$(gh api --paginate "repos/$REPO/issues?state=open&per_page=100&direction=asc&sort=created")" || {
  printf '%s: could not list the open issues of %s\n' "$SELF" "$REPO" >&2
  exit 1
}

mkdir -p "$WORK/issues"
open_count="$(printf '%s' "$issues_raw" | explode_issues "$WORK/issues" "${LIMIT:-0}")"
printf '%s open issue(s) to migrate from %s to %s\n' "$open_count" "$REPO" "$AZDO_PROJECT"

for issue_dir in "$WORK/issues"/*; do
  [[ -d "$issue_dir" ]] || continue
  migrate_one "$issue_dir" || exit 1
done

if (( DRY_RUN )); then
  printf 'dry run: %s issue(s) would be migrated, %s skipped — nothing was written\n' \
    "$MIGRATED" "$SKIPPED"
else
  printf 'done: %s issue(s) migrated, %s skipped\n' "$MIGRATED" "$SKIPPED"
fi
