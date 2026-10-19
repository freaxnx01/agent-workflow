#!/usr/bin/env bash
#
# issue-intake.sh — label a newly opened issue needs-enrichment (#549).
#
# The autopilot lane only enriches issues carrying needs-enrichment. Issues
# filed through bridge (flowhub's path) or /new are born with it; one opened in
# the GitHub UI is not, and would be ignored without a trace. This applies the
# same intake stamp to that path. Removing the label stays a deliberate act.
#
# Skipped (never labelled): issues opened by a bot, issues that already carry
# it, issues carrying a pipeline label (see BLOCKING below, plus any ai:*), and
# issues whose body already has a `## Implementation Plan` heading. Category
# labels (bug, area:*, …) do not block it.
#
# Required env: REPO (owner/name), ISSUE_NUMBER, GH_TOKEN (or ambient gh auth
# on a runner). Optional: DRY_RUN=1 decides and prints, writes nothing.
#
# Output: one stdout line, `intake: #<n> labelled needs-enrichment` or
# `intake: #<n> skipped (<reason>)`; `decision=` and `reason=` appended to
# $GITHUB_OUTPUT when set.
#
# Exit codes:
#   0  labelled, or skipped by rule
#   1  the issue could not be read, or the label could not be applied
#   2  REPO or ISSUE_NUMBER missing or invalid
set -euo pipefail
IFS=$'\n\t'

INTAKE_LABEL='needs-enrichment'
INTAKE_LABEL_COLOR='d4c5f9'
INTAKE_LABEL_DESC='Needs a spec and plan before it can be implemented — /enrich or the autopilot lane'

# intake_decision — issue JSON ({labels, body, author}) on stdin. Prints
# `label`, or `skip <reason>`. Query only.
intake_decision() {
  jq -r '
    def blocking: ["ai-implement", "enrichment-ongoing", "needs-human",
                   "parked", "🧊 parked", "roadmap", "pipeline-paused"];
    def names: [.labels[]?.name];
    def blockers: [names[] | select(. as $n | (blocking | index($n)) != null
                                     or startswith("ai:"))];
    if (.author.is_bot // false) then "skip opened by a bot"
    elif (names | index("needs-enrichment")) != null then "skip already labelled"
    elif (blockers | length) > 0 then "skip pipeline label " + blockers[0]
    elif ((.body // "") | test("(^|\n)## Implementation Plan[ \t]*\r?(\n|$)"))
      then "skip already has an implementation plan"
    else "label" end'
}

usage_error() { printf 'error: %s\n' "$1" >&2; exit 2; }

# report <decision> <reason> — the stdout line plus $GITHUB_OUTPUT.
report() {
  local decision="$1" reason="$2"
  if [[ "$decision" == labelled ]]; then
    printf 'intake: #%s labelled %s\n' "$ISSUE_NUMBER" "$INTAKE_LABEL"
  else
    printf 'intake: #%s skipped (%s)\n' "$ISSUE_NUMBER" "$reason"
  fi
  [[ -n "${GITHUB_OUTPUT:-}" ]] || return 0
  printf 'decision=%s\nreason=%s\n' "$decision" "$reason" >> "$GITHUB_OUTPUT"
}

apply_label() {
  # Errors when the label exists — the expected, tolerated path.
  gh label create "$INTAKE_LABEL" --repo "$REPO" --color "$INTAKE_LABEL_COLOR" \
    --description "$INTAKE_LABEL_DESC" >/dev/null 2>&1 || true
  gh issue edit "$ISSUE_NUMBER" --repo "$REPO" --add-label "$INTAKE_LABEL" >/dev/null 2>&1
}

main() {
  [[ -n "${REPO:-}" ]] || usage_error 'REPO must be set'
  [[ "${ISSUE_NUMBER:-}" =~ ^[1-9][0-9]*$ ]] \
    || usage_error "ISSUE_NUMBER must be a positive integer (got: ${ISSUE_NUMBER:-})"

  local json decision
  if ! json="$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json number,labels,body,author 2>/dev/null)" \
     || ! decision="$(printf '%s' "$json" | intake_decision 2>/dev/null)"; then
    printf 'error: could not read issue #%s in %s — not labelled\n' "$ISSUE_NUMBER" "$REPO" >&2
    exit 1
  fi

  if [[ "$decision" != label ]]; then
    report skipped "${decision#skip }"
    return 0
  fi
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf 'DRY_RUN: would label #%s %s\n' "$ISSUE_NUMBER" "$INTAKE_LABEL"
    return 0
  fi
  if ! apply_label; then
    printf 'error: could not label issue #%s %s in %s\n' "$ISSUE_NUMBER" "$INTAKE_LABEL" "$REPO" >&2
    exit 1
  fi
  report labelled ''
}

# Sourced by tests/run-issue-intake-tests.sh to call intake_decision directly.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
