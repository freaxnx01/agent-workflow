#!/usr/bin/env bash
#
# gh-issue-migration.sh — sourced, not executed.
#
# The pure mapping decisions behind scripts/migrate-gh-issues-to-azdo.sh (#642):
# which labels become tags, which work item type an issue gets, how the
# already-migrated marker is written and recognised, and how a copied comment is
# headed. None of it talks to a forge, so all of it is testable without a mock
# — which is the reason it is not inlined in the migration script.
#
#   migration_tags <labels>                echoes the System.Tags string
#   migration_type <labels> <bug-type> <story-type> [override]
#                                          echoes the work item type name
#   migration_marker <project-url-path> <id>
#                                          echoes the marker comment line
#   migration_marker_id <project-url-path> <bodies-file>
#                                          echoes the id a marker names (exit 1
#                                          when the file carries none for this
#                                          project)
#   migration_comment_header <login> <created-at>
#                                          echoes the copied comment's first line
#
# <labels> is always one argument holding the labels NEWLINE-separated. A label
# may legitimately contain a space or a comma, so neither can be the separator.
#
# Exit codes: 0 success; 1 migration_marker_id only — no marker for this project.
set -euo pipefail
IFS=$'\n\t'

# The labels that drive the GitHub pipeline. Carried across as tags they would
# either start a run on the new forge or confuse its guards, so they stay
# behind. The GATES go with them: `ai-review-ai-merge` (and `ai-auto-review`,
# its pre-ADR-009 alias) is the per-issue auto-merge opt-in and `ai-chain` the
# per-issue chain-dispatch opt-in, so an item arriving with one would carry a
# decision taken for the old forge — the more so because autopilot.sh applies
# `ai-implement,ai-review-ai-merge` as a pair, and only one half of it can be
# dropped. Everything else — needs-enrichment, roadmap, bug — is backlog
# information and travels.
MIGRATION_DROPPED_LABELS='ai-implement
ai-review-ai-merge
ai-review-human-merge
ai-auto-review
ai-pre-preview
ai-chain
enrichment-ongoing'

# ...and the prefixed families of the same kind: ai:*, agent:*, ctx:* and
# turns:*. `agent:*` is dropped for the same reason as the gates and more
# literally: the ADO side reads System.Tags back into ISSUE_LABELS
# (forge_export_issue) and classify-agent.sh honours `agent:opencode` there, so
# a carried one would force that agent on every future run of the work item.
MIGRATION_DROPPED_PREFIXES='ai:
agent:
ctx:
turns:'

# migration_tags <labels>  echoes the labels that survive, joined with "; ",
# or nothing when none do.
#
# `;` is Azure DevOps' own tag separator, so a label containing one would
# silently arrive as two tags. It becomes `,`.
migration_tags() {
  local labels="${1?migration_tags requires a newline-separated label list}"
  printf '%s' "$labels" | python3 -c '
import sys
dropped = set(sys.argv[1].split("\n"))
prefixes = tuple(sys.argv[2].split("\n"))
tags = []
for raw in sys.stdin.read().split("\n"):
    label = raw.strip()
    if not label:
        continue
    folded = label.lower()
    if folded in dropped or folded.startswith(prefixes):
        continue
    tags.append(label.replace(";", ","))
print("; ".join(tags))' "$MIGRATION_DROPPED_LABELS" "$MIGRATION_DROPPED_PREFIXES"
}

# migration_type <labels> <bug-type> <story-type> [override]  echoes the work
# item type name for an issue.
#
# Azure DevOps has no `bug` label, it has a Bug TYPE, so the label is what picks
# it. The two type names are arguments rather than constants because they are
# set by the project's process template: a Basic project has neither Bug nor
# User Story, it has Issue.
migration_type() {
  local labels="${1?migration_type requires a newline-separated label list}"
  local bug_type="${2:?migration_type requires a bug type name}"
  local story_type="${3:?migration_type requires a story type name}"
  local override="${4-}"

  if [[ -n "$override" ]]; then
    printf '%s\n' "$override"
    return 0
  fi

  local label
  while IFS= read -r label; do
    if [[ "${label,,}" == "bug" ]]; then
      printf '%s\n' "$bug_type"
      return 0
    fi
  done <<< "$labels"

  printf '%s\n' "$story_type"
}

# migration_marker <project-url-path> <id>  echoes the HTML comment that marks a
# GitHub issue as migrated.
#
# It is invisible in the rendered issue and carries the PROJECT, not just the
# id: ids are allocated per organization, so without the project the marker
# cannot say whether an issue belongs to the backlog being migrated now.
migration_marker() {
  local project_path="${1:?migration_marker requires a project url path}"
  local id="${2:?migration_marker requires a work item id}"
  printf '<!-- awf-migrated-to: %s#%s -->\n' "$project_path" "$id"
}

# migration_marker_id <project-url-path> <bodies-file>  echoes the work item id
# a marker in <bodies-file> names, or exits 1 when it carries none for THIS
# project.
#
# <bodies-file> is the concatenated text of an issue's comments. Matching is
# anchored on the whole project path, so an issue migrated to a different
# project is reported as not migrated and gets an item in this one.
migration_marker_id() {
  local project_path="${1:?migration_marker_id requires a project url path}"
  local bodies_file="${2:?migration_marker_id requires a comment bodies file}"
  python3 -c '
import re, sys
pattern = re.compile(r"<!--\s*awf-migrated-to:\s*" + re.escape(sys.argv[1]) + r"#(\d+)\s*-->")
with open(sys.argv[2], encoding="utf-8", errors="replace") as fh:
    match = pattern.search(fh.read())
if not match:
    sys.exit(1)
print(match.group(1))' "$project_path" "$bodies_file"
}

# migration_comment_header <login> <created-at>  echoes the first line of a
# copied comment: who wrote it on GitHub, and on which day.
#
# An empty login means a deleted account — the REST API returns a null author —
# which GitHub itself renders as `ghost`. <created-at> is the API's ISO-8601 UTC
# timestamp, so its date part is already the UTC date.
migration_comment_header() {
  local login="${1-}"
  local created_at="${2:?migration_comment_header requires a created-at timestamp}"
  printf '**%s** on GitHub, %s:\n' "${login:-ghost}" "${created_at%%T*}"
}
