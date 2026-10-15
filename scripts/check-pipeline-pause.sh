#!/usr/bin/env bash
#
# check-pipeline-pause.sh — The circuit breaker. Decide whether this repo's
# pipeline is paused, before a single turn is spent on the agent.
#
# A pause is repo-wide: the key behind the agent is empty, so every dispatch
# fails the same way within minutes of the first (#517 — five runs, five
# "bug" verdicts, one dry key). While an alarm is open this step stops the run
# BEFORE the agent is invoked, labels the issue `ai:paused`, comments once on
# it, and leaves the dispatch label in place so the issue is still queued (the
# label is the list pipeline-resume.sh re-dispatches). Nothing is parked,
# nothing is graded, nothing counts as an attempt.
#
# Pause state, in precedence order:
#   1. An OPEN issue carrying $ALARM_LABEL, raised by pipeline-pause.sh. This
#      is the automatic state (ADR-018) and closing it resumes the pipeline.
#   2. A non-empty $AGENT_PAUSED_VAR (the repo variable `AGENT_PAUSED`). A
#      manual, read-only switch for an operator: the job's token cannot write
#      repo variables, so nothing in the pipeline can set or clear it.
#
# Required environment variables:
#   REPO          owner/repo (default: $GITHUB_REPOSITORY).
#   ISSUE_NUMBER  The issue being dispatched.
#   GH_TOKEN      (or ambient gh auth)
#
# Optional environment variables:
#   ALARM_LABEL          Default "pipeline-paused".
#   AGENT_PAUSED_VAR     Value of the repo variable AGENT_PAUSED.
#   ISSUE_COMMENTS_JSON  Seam (and the job-wide export from
#                        export-issue-context.sh): JSON array of {body}, used
#                        to suppress a duplicate pause notice.
#   DRY_RUN              If "1", decide but post nothing.
#
# Output (stdout + GITHUB_OUTPUT when set):
#   paused=true|false
#   alarm-issue=<n>   empty when the pause comes from the variable
#   reason=<id>       empty unless the alarm names a known reason id
#
# Exit codes:
#   0  decision produced (paused or not)
#   2  required env missing
set -euo pipefail
IFS=$'\n\t'

_CPP_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/detect-forge.sh
source "$_CPP_HERE/lib/detect-forge.sh"
# shellcheck source=scripts/lib/pause-reasons.sh
source "$_CPP_HERE/lib/pause-reasons.sh"
# shellcheck source=scripts/lib/paused-issues.sh
source "$_CPP_HERE/lib/paused-issues.sh"

require_env() {
  if [[ -z "${!1:-}" ]]; then
    printf 'error: %s must be set\n' "$1" >&2
    exit 2
  fi
}

require_env ISSUE_NUMBER
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
[[ -n "$REPO" ]] || { printf 'error: REPO or GITHUB_REPOSITORY must be set\n' >&2; exit 2; }

ALARM_LABEL="${ALARM_LABEL:-pipeline-paused}"
AGENT_PAUSED_VAR="${AGENT_PAUSED_VAR:-}"
DRY_RUN="${DRY_RUN:-0}"
NOTICE_MARKER='<!-- pipeline-pause-notice -->'

emit() {
  printf '%s=%s\n' "$1" "$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}

not_paused() {
  emit paused false
  emit alarm-issue ''
  emit reason ''
  exit 0
}

# Forgejo and Azure DevOps raise no alarm (pipeline-pause.sh skips them), so
# there is never one to find and the gate must not block them on a failed read.
if [[ "$(detect_forge | awk '{print $1}')" != "github" ]]; then
  printf 'check-pipeline-pause: no alarm adapter for this forge — not paused\n'
  not_paused
fi

alarm=''
reason=''
alarms="$(gh issue list --repo "$REPO" --label "$ALARM_LABEL" --state open \
  --json number,title,body --limit 20 2>/dev/null || printf '[]')"
alarm="$(jq -r 'sort_by(.number) | .[0].number // empty' <<<"$alarms")"

if [[ -n "$alarm" ]]; then
  # The reason id is in the alarm's own footer. Cosmetic: it names the cause in
  # the issue comment, so a missing one costs wording, not correctness.
  # shellcheck disable=SC2016  # the backticks are pipeline-pause.sh's markdown
  # code span in the alarm body, not command substitution.
  reason="$(jq -r 'sort_by(.number) | .[0].body // ""' <<<"$alarms" \
    | sed -n 's/.*reason `\([a-z_]*\)`.*/\1/p' | head -1 || true)"
  # The alarm body also quotes untrusted error text, so what was read is
  # accepted only when it is a reason id this pipeline knows (#521).
  is_pause_class "$reason" || reason=''
  notice="$(printf 'pipeline paused: %s, see #%s' "${reason:-see the alarm}" "$alarm")"
elif [[ -n "$AGENT_PAUSED_VAR" ]]; then
  alarm=''
  reason="$AGENT_PAUSED_VAR"
  notice="pipeline paused: the AGENT_PAUSED repo variable is set to \`${AGENT_PAUSED_VAR}\`"
else
  printf 'check-pipeline-pause: no open %s alarm and AGENT_PAUSED unset — proceeding\n' "$ALARM_LABEL"
  # A run that starts is not paused. Clears a label left behind when the alarm
  # was closed and the issue re-dispatched by hand, without pipeline-resume.sh.
  [[ "$DRY_RUN" == "1" ]] || paused_issue_clear "$ISSUE_NUMBER"
  not_paused
fi

emit paused true
emit alarm-issue "$alarm"
emit reason "$reason"
printf 'check-pipeline-pause: %s — no agent will be started for issue #%s\n' \
  "$notice" "$ISSUE_NUMBER"

[[ "$DRY_RUN" == "1" ]] && exit 0

# The paused list is this label. pipeline-resume.sh re-dispatches exactly the
# open issues that carry it, so a dispatch stopped here is not forgotten. A
# failed write is warned about and named in the step summary by the library;
# the gate's verdict stands either way.
paused_issue_mark "$ISSUE_NUMBER" || true

# --- notify the issue, once -------------------------------------------------

comments_json() {
  if [[ -n "${ISSUE_COMMENTS_JSON:-}" ]]; then
    printf '%s' "$ISSUE_COMMENTS_JSON"
    return
  fi
  gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json comments \
    --jq '.comments' 2>/dev/null || printf '[]'
}

# Dedup on the marker AND the notice line: a pause that outlives several
# dispatches of the same issue must say so once, but a SECOND, different pause
# later on is news again.
if jq -e --arg marker "$NOTICE_MARKER" --arg notice "$notice" \
     'any(.[]; (.body // "") | contains($marker) and contains($notice))' \
     <<<"$(comments_json)" >/dev/null 2>&1; then
  printf 'check-pipeline-pause: the pause notice is already on issue #%s — not repeating it\n' \
    "$ISSUE_NUMBER"
  exit 0
fi

bodyfile="$(mktemp)"
trap 'rm -f "$bodyfile"' EXIT
cat > "$bodyfile" <<EOF
${NOTICE_MARKER}
## ai-implement paused

**${notice}**

No agent was started, so this run spent nothing and counts as neither an
attempt nor a non-start. The \`ai-implement\` label is untouched: the issue is
still queued and is re-dispatched once the pause is cleared.
EOF

gh issue comment "$ISSUE_NUMBER" --repo "$REPO" --body-file "$bodyfile" >/dev/null 2>&1 || {
  printf 'warning: could not post the pause notice to issue #%s — continuing\n' "$ISSUE_NUMBER" >&2
}
exit 0
