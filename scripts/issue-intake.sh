#!/usr/bin/env bash
#
# issue-intake.sh — label a newly opened issue needs-enrichment (#549).
#
# The autopilot lane only enriches issues carrying needs-enrichment. Issues
# filed through bridge (flowhub's path) or /new are born with it; one opened in
# the GitHub UI is not, and would be ignored without a trace. This applies the
# same intake stamp to that path. Removing the label stays a deliberate act.
#
# Skipped (never labelled): issues opened by a bot, issues opened by anyone
# without write access to the repo (see intake_decision), issues that already
# carry it, issues carrying a pipeline label (see BLOCKING below, plus any
# ai:*), and issues whose body already has a `## Implementation Plan` heading.
# Category labels (bug, area:*, …) do not block it.
#
# Required env: REPO (owner/name), ISSUE_NUMBER, GH_TOKEN (or ambient gh auth
# on a runner). Optional: DRY_RUN=1 decides and prints, writes nothing.
#
# Output: one stdout line, `intake: #<n> labelled needs-enrichment` or
# `intake: #<n> skipped (<reason>)`; `decision=` and `reason=` appended to
# $GITHUB_OUTPUT when set. DRY_RUN=1 is the exception: a run that would label
# prints only what it would do and writes neither the label nor $GITHUB_OUTPUT
# (a skip is a decision either way, so it still reports).
#
# Exit codes:
#   0  labelled, or skipped by rule
#   1  the issue could not be read, or the label could not be applied
#   2  REPO or ISSUE_NUMBER missing or invalid
set -euo pipefail
IFS=$'\n\t'

_II_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/intake-label.sh
source "$_II_HERE/lib/intake-label.sh"

# The file every gh call in this script sends stderr to, so a failure can quote
# gh's own message. Set by main; empty while only sourced.
GH_STDERR=''

# intake_decision — a REST issue object ({labels, body, user,
# author_association}) on stdin. Prints `label`, or `skip <reason>`. Query only.
#
# The author gate is fail-CLOSED, and deliberately more than the bot check:
# the label is the entry ticket to the unattended lane, which spends credits
# on enrichment and can end in an agent-written, auto-merged PR
# (scripts/autopilot.sh). Only someone who can already write to the repo may
# start that, so anything but OWNER/MEMBER/COLLABORATOR — an outside
# contributor, a first-time contributor, or an association gh did not report —
# is skipped. A human with triage rights can still label the issue by hand.
intake_decision() {
  jq -r '
    def blocking: ["ai-implement", "enrichment-ongoing", "needs-human",
                   "parked", "🧊 parked", "roadmap", "pipeline-paused"];
    def trusted: ["OWNER", "MEMBER", "COLLABORATOR"];
    def names: [.labels[]?.name];
    def blockers: [names[] | select(. as $n | (blocking | index($n)) != null
                                     or startswith("ai:"))];
    if ((.user.type // "") == "Bot") then "skip opened by a bot"
    elif (.author_association as $a | (trusted | index($a)) == null)
      then "skip author without write access ("
             + (.author_association // "unknown") + ")"
    elif (names | index("needs-enrichment")) != null then "skip already labelled"
    elif (blockers | length) > 0 then "skip pipeline label " + blockers[0]
    elif ((.body // "") | test("(^|\n)## Implementation Plan[ \t]*\r?(\n|$)"))
      then "skip already has an implementation plan"
    else "label" end'
}

usage_error() { printf 'error: %s\n' "$1" >&2; exit 2; }

# report_gh_stderr <what> — quote what the failed call wrote, so a permissions
# error is distinguishable from a transient one. Command.
report_gh_stderr() {
  if [[ -s "${GH_STDERR:-/dev/null}" ]]; then
    printf '  %s wrote:\n' "$1" >&2
    while IFS= read -r line; do printf '    %s\n' "$line" >&2; done < "$GH_STDERR"
  else
    printf '  %s failed without a message\n' "$1" >&2
  fi
}

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
  local create_err=''
  # `gh label create` errors when the label exists — the expected, tolerated
  # path (ensure-issue-labels.sh seeds it at onboarding), so its message is
  # kept back and only quoted if the edit then fails too.
  : > "$GH_STDERR"
  if ! gh label create "$INTAKE_LABEL" --repo "$REPO" --color "$INTAKE_LABEL_COLOR" \
         --description "$INTAKE_LABEL_DESC" >/dev/null 2>"$GH_STDERR"; then
    create_err="$(tr '\n' ' ' < "$GH_STDERR")"
  fi
  : > "$GH_STDERR"
  gh issue edit "$ISSUE_NUMBER" --repo "$REPO" --add-label "$INTAKE_LABEL" \
    >/dev/null 2>"$GH_STDERR" && return 0

  printf 'error: could not label issue #%s %s in %s\n' "$ISSUE_NUMBER" "$INTAKE_LABEL" "$REPO" >&2
  report_gh_stderr 'gh issue edit'
  [[ -z "$create_err" ]] || printf '  gh label create wrote: %s\n' "$create_err" >&2
  return 1
}

main() {
  # Shape-checked, not just non-empty: REPO lands in the REST path below, so a
  # malformed value would address some other endpoint rather than fail loudly.
  [[ "${REPO:-}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
    || usage_error "REPO must be owner/name (got: ${REPO:-})"
  [[ "${ISSUE_NUMBER:-}" =~ ^[1-9][0-9]*$ ]] \
    || usage_error "ISSUE_NUMBER must be a positive integer (got: ${ISSUE_NUMBER:-})"

  GH_STDERR="$(mktemp)"
  trap 'rm -f "$GH_STDERR"' EXIT

  # The REST issue object, not `gh issue view --json`: the author gate needs the
  # author's association with the repo, and that field is not among the ones
  # `gh issue view --json` can project (gh 2.102 answers `Unknown JSON field:
  # "authorAssociation"`). REST carries it as `author_association`, alongside
  # `user.type` for the bot check, so one call still answers every rule.
  local json decision
  if ! json="$(gh api "repos/$REPO/issues/$ISSUE_NUMBER" 2>"$GH_STDERR")"; then
    printf 'error: could not read issue #%s in %s — not labelled\n' "$ISSUE_NUMBER" "$REPO" >&2
    report_gh_stderr 'gh api'
    exit 1
  fi
  : > "$GH_STDERR"
  if ! decision="$(printf '%s' "$json" | intake_decision 2>"$GH_STDERR")"; then
    printf 'error: could not decide on issue #%s in %s — not labelled\n' "$ISSUE_NUMBER" "$REPO" >&2
    report_gh_stderr 'jq'
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
  apply_label || exit 1
  report labelled ''
}

# Sourced by tests/run-issue-intake-tests.sh to call intake_decision directly.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
