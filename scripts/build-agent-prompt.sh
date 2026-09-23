#!/usr/bin/env bash
#
# build-agent-prompt.sh — Assemble the prompt handed to the implementing agent.
#
# WHY THIS EXISTS (#393). The prompt was built inline in agent-implement.yml as:
#
#     gh issue view "$N" --json title,body
#
# Comments were never fetched — and the implementation contract that
# /gh:implement posts (TDD discipline, "commit and push after every task",
# "open the draft PR after the first task passes") is a COMMENT. So the
# contract reached no agent, in any run, ever. Two measured consequences:
#
#   - A run exhausted its budget having pushed nothing and lost $7.28 of work,
#     because the push-per-task rule lives only in that comment.
#   - A re-dispatch told, by comment, to resume on an existing branch instead
#     opened a second PR and redid finished work.
#
# The plan was always followed closely, because /enrich inlines the plan into
# the issue BODY. Two channels; only one of them worked.
#
# Not every comment belongs in the prompt. Pipeline-generated chatter — run
# reports, enrichment locks, review-held notices — costs context and, in the
# case of a prior run's failure report, invites the agent to re-litigate a past
# run instead of doing this one. Those are dropped by pattern; everything a
# human wrote is kept.
#
# Required environment variables:
#   ISSUE_NUMBER  GitHub issue number.
#
# Optional environment variables:
#   REPO         owner/repo. Default: $GITHUB_REPOSITORY.
#   PROMPT_FILE  Where to write. Default: $RUNNER_TEMP/claude-prompt.md.
#   GH_TOKEN     (or ambient gh auth)
#
# Output (to $GITHUB_OUTPUT when set):
#   prompt-file=<path>
#   has-plan=true|false   — whether the body carries an "## Implementation
#                           Plan" heading. /ai-stats correlates enrichment with
#                           whether a run ships, so it is derived here, from the
#                           same body the prompt is built from.
#
# Exit codes:
#   0  prompt written
#   2  required env missing
set -euo pipefail
IFS=$'\n\t'

if [[ -z "${ISSUE_NUMBER:-}" ]]; then
  printf 'error: ISSUE_NUMBER must be set\n' >&2
  exit 2
fi

REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
PROMPT_FILE="${PROMPT_FILE:-${RUNNER_TEMP:-/tmp}/claude-prompt.md}"

# shellcheck disable=SC2054  # the commas belong to gh's --json field list,
# which is one argument; they are not array element separators.
gh_args=(issue view "$ISSUE_NUMBER" --json title,body,comments)
[[ -n "$REPO" ]] && gh_args+=(--repo "$REPO")
issue_json="$(gh "${gh_args[@]}")"

title="$(printf '%s' "$issue_json" | jq -r '.title // ""')"
body="$(printf '%s' "$issue_json" | jq -r '.body // ""')"

# Comments the agent should not see. Anchored at the start of the comment so a
# human quoting one of these phrases mid-discussion is not silently dropped.
#   ## ai-implement run     — a prior run's metrics report
#   ## ai-implement parked  — the attempt-cap notice
#   🔒 / 🔓 Enrichment lock — /enrich's mutual-exclusion bookkeeping
#   Review held / Auto-*    — post-auto-review-block.sh refusals
#   **Review did not run**  — post-runner-block.sh toolchain blocks
DROP_RE='^(## ai-implement (run|parked)|🔒|🔓|Review held|Auto-merge held|Auto-review held|\*\*Review did not run\*\*)'

comments="$(printf '%s' "$issue_json" \
  | jq -r --arg re "$DROP_RE" '
      (.comments // [])
      | map(.body // "")
      | map(select((. | test($re)) | not))
      | map(select(. != ""))
      | join("\n\n---\n\n")
    ')"

{
  printf '# Issue #%s\n\n# %s\n\n%s\n\n' "$ISSUE_NUMBER" "$title" "$body"

  if [[ -n "$comments" ]]; then
    # Framed as instructions rather than as a thread transcript: the contract
    # lives here, and it is binding, not commentary.
    printf -- '---\n\n## Issue comments — read these as part of the task\n\n'
    printf 'These were added after the issue was written. Where one of them\n'
    printf 'states how the work must be carried out, it governs.\n\n'
    printf '%s\n\n' "$comments"
  fi

  printf -- '---\n\n'
  printf 'Read CLAUDE.md and follow the house rules.\n'
  printf 'Implement the change on a new branch and open a DRAFT pull request.\n'
  printf 'The PR body MUST include "Closes #%s" on its own line so the\n' "$ISSUE_NUMBER"
  printf 'pipeline can link the PR back to this issue (find-pipeline-pr.sh\n'
  printf 'searches for that exact phrase).\n'
} > "$PROMPT_FILE"

# Enrichment marker, read by /ai-stats. Derived from the body alone: a plan
# quoted in a comment is not an enriched issue.
has_plan=false
if printf '%s' "$body" | grep -qi '^## Implementation Plan'; then
  has_plan=true
fi

printf 'prompt written to %s (%s bytes, has-plan=%s)\n' \
  "$PROMPT_FILE" "$(wc -c < "$PROMPT_FILE" | tr -d ' ')" "$has_plan"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'prompt-file=%s\n' "$PROMPT_FILE" >> "$GITHUB_OUTPUT"
  printf 'has-plan=%s\n' "$has_plan" >> "$GITHUB_OUTPUT"
fi
