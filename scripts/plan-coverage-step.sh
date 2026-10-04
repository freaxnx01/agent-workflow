#!/usr/bin/env bash
#
# plan-coverage-step.sh — the implement job's "Check plan coverage" step (#457).
#
# Fetches the issue body and the PR's changed files, grades them with
# check-plan-coverage.sh, and appends the grade to $GITHUB_OUTPUT. Any fetch
# failure is graded `unverifiable` / `fetch-failed` — never `complete`, so a
# GitHub blip cannot wave a PR into the AI-merge job, and never `partial`, so it
# cannot fail a good run either. This step must never fail the job.
#
# Required env: REPO, ISSUE_NUMBER, PR_NUMBER. Optional: GITHUB_OUTPUT (default
# stdout), GH_TOKEN / ambient gh auth.
#
# Exit codes:
#   0  graded (any grade, including fetch-failed)
#   2  usage error: a required variable unset
set -euo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for var in REPO ISSUE_NUMBER PR_NUMBER; do
  [[ -n "${!var:-}" ]] || { printf 'error: %s must be set\n' "$var" >&2; exit 2; }
done

OUT="${GITHUB_OUTPUT:-/dev/stdout}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

emit_fetch_failed() {
  printf 'coverage=unverifiable\nmissing-tasks=\nreason=fetch-failed\n' >> "$OUT"
  exit 0
}

gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json body --jq .body \
  > "$work/body.md" 2>/dev/null || emit_fetch_failed
[[ -s "$work/body.md" ]] || emit_fetch_failed

gh api --paginate "repos/$REPO/pulls/$PR_NUMBER/files" \
  --jq '.[] | .filename, (.previous_filename // empty)' \
  > "$work/changed.txt" 2>/dev/null || emit_fetch_failed

ISSUE_BODY_FILE="$work/body.md" CHANGED_FILES_FILE="$work/changed.txt" \
  bash "$HERE/check-plan-coverage.sh" > "$work/grade.txt" || emit_fetch_failed
cat "$work/grade.txt" >> "$OUT"
