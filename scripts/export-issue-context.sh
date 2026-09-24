#!/usr/bin/env bash
#
# export-issue-context.sh — read the issue once, per forge, and write the four
# variables the implement job's read paths already prefer into $GITHUB_ENV.
#
#   ISSUE_LABELS         classify-agent, classify-task, classify-turns
#   ISSUE_BODY           classify-turns
#   ISSUE_JSON           build-agent-prompt
#   ISSUE_COMMENTS_JSON  check-attempt-cap
#
# Each of those scripts checks its own variable first and falls back to `gh`
# only when unset, so filling them here makes the read path forge-agnostic
# without touching any of them. One forge call replaces five. See #253.
#
# Required environment:
#   ISSUE_NUMBER   the issue to read
#   REPO           owner/repo
#   GITHUB_ENV     file to append to (set by the runner)
#   GH_TOKEN       or ambient auth, for the GitHub path
#
# Exit codes:
#   0  written
#   1  the forge read failed
#   2  required env missing, or a forge with no read adapter yet
set -euo pipefail
IFS=$'\n\t'

: "${ISSUE_NUMBER:?ISSUE_NUMBER must be set}"
: "${REPO:?REPO must be set}"
: "${GITHUB_ENV:?GITHUB_ENV must be set}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/detect-forge.sh
source "$HERE/lib/detect-forge.sh"
# shellcheck source=scripts/lib/forge.sh
source "$HERE/lib/forge.sh"

forge_export_issue "$ISSUE_NUMBER"

# The delimiter is RANDOM PER RUN, never a fixed string.
#
# An issue body in a public repo is written by anyone. With a fixed delimiter, a
# body containing that delimiter followed by `KEY=value` closes the heredoc early
# and sets arbitrary environment variables for every later step in the job --
# including ones the agent then runs with. A random delimiter cannot be guessed
# by whoever wrote the issue.
delim="PIPELINE_EOF_$(openssl rand -hex 16 2>/dev/null || date +%s%N)"

{
  printf 'ISSUE_LABELS<<%s\n%s\n%s\n'        "$delim" "$ISSUE_LABELS"        "$delim"
  printf 'ISSUE_BODY<<%s\n%s\n%s\n'          "$delim" "$ISSUE_BODY"          "$delim"
  printf 'ISSUE_JSON<<%s\n%s\n%s\n'          "$delim" "$ISSUE_JSON"          "$delim"
  printf 'ISSUE_COMMENTS_JSON<<%s\n%s\n%s\n' "$delim" "$ISSUE_COMMENTS_JSON" "$delim"
} >> "$GITHUB_ENV"
