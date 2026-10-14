#!/usr/bin/env bash
#
# pipeline-pause.sh — Raise the pipeline alarm: one open, labelled issue per
# pause, plus one ntfy push.
#
# The alarm issue IS the pause state. There is no repo variable to write: the
# implement job's GITHUB_TOKEN carries `issues: write` and `actions: write` and
# nothing grants it the variables scope, so an open issue carrying
# $ALARM_LABEL is the one piece of state every job in every consumer repo can
# both read and write (ADR-018). check-pipeline-pause.sh gates new dispatches
# on it; closing it resumes the pipeline.
#
# The paused issues are tracked by label, not in the alarm body — the body is
# display-only, so untrusted error text cannot inject or alter the paused list
# (#521). Each paused issue gets the `ai:paused` label, and pipeline-resume.sh
# re-dispatches exactly the open issues carrying it.
#
# "One per pause" is enforced twice: an existing open alarm is updated rather
# than duplicated, and a creation that loses a race against a concurrent run
# closes its own issue as a duplicate of the lower-numbered winner. Only the
# run that actually created the surviving alarm pushes, so a repo with five
# issues failing in the same minute pages the maintainer once.
#
# Required environment variables:
#   REASON    Pause reason id from scripts/lib/pause-reasons.sh.
#   REPO      owner/repo.
#   GH_TOKEN  (or ambient gh auth) with `issues: write`.
#
# Optional environment variables:
#   ISSUE_NUMBER  The issue whose run hit the pause. Labelled `ai:paused` so the
#                 resume knows what to re-dispatch. Empty when the pause comes
#                 from the scheduled health check rather than a run.
#   ERROR_TEXT    The agent's error text. Redacted and quoted in the alarm.
#   ALARM_LABEL   Default "pipeline-paused".
#   NTFY_*        Passed through to notify-ntfy.sh. Missing config skips the
#                 push; a failed push never fails this script.
#
# Output (stdout + GITHUB_OUTPUT when set):
#   alarm-issue=<n>
#   created=true|false
#
# Exit codes:
#   0   an alarm is open for this pause (created, updated, or already there);
#       also when the forge has no adapter and the alarm is skipped
#   2   required env missing, or REASON is not a known pause reason
set -euo pipefail
IFS=$'\n\t'

_PP_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/detect-forge.sh
source "$_PP_HERE/lib/detect-forge.sh"
# shellcheck source=scripts/lib/forge.sh
source "$_PP_HERE/lib/forge.sh"
# shellcheck source=scripts/lib/pause-reasons.sh
source "$_PP_HERE/lib/pause-reasons.sh"
# shellcheck source=scripts/lib/paused-issues.sh
source "$_PP_HERE/lib/paused-issues.sh"

require_env() {
  if [[ -z "${!1:-}" ]]; then
    printf 'error: %s must be set\n' "$1" >&2
    exit 2
  fi
}

require_env REASON
require_env REPO

# shellcheck disable=SC2153  # REASON is the documented input env var, not a
# typo for the local `reason` inside pause-reasons.sh.
if ! is_pause_class "$REASON"; then
  printf 'error: %s is not a known pause reason (see scripts/lib/pause-reasons.sh)\n' "$REASON" >&2
  exit 2
fi

ALARM_LABEL="${ALARM_LABEL:-pipeline-paused}"
ISSUE_NUMBER="${ISSUE_NUMBER:-}"
ERROR_TEXT="${ERROR_TEXT:-}"

emit() {
  printf '%s=%s\n' "$1" "$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}

# The alarm, the push and the pin are all `gh`. Forgejo and Azure DevOps have
# no adapter for issue create/pin/close yet (#253), and a half-built alarm is
# worse than none: the run fails as it did before this feature existed.
forge="$(detect_forge | awk '{print $1}')"
if [[ "$forge" != "github" ]]; then
  printf 'pipeline-pause: no alarm adapter for forge %q — skipping the alarm\n' "$forge"
  exit 0
fi

# --- redaction --------------------------------------------------------------

# The error text is pasted verbatim into a public issue and a push body. A
# provider that echoes the offending key in its own error message — and some do
# — would publish it. Truncated too: an agent's error can be the whole
# transcript, and an alarm nobody reads is not an alarm.
redact() {
  sed -E 's/sk-or-[A-Za-z0-9_-]+/sk-or-***/g; s/sk-ant-[A-Za-z0-9_-]+/sk-ant-***/g' \
    | head -c 2000
}

# Untrusted text is neutralised before it reaches the body: backticks (they
# would close the code fence), HTML comment delimiters and the marker names (they
# would inject or hide entries in the paused-issues list pipeline-resume reads).
neutralise() {
  tr -d '`' | sed -E 's/<!--//g; s/-->//g; s#/?paused-issues##g'
}
SAFE_ERROR="$(printf '%s' "$ERROR_TEXT" | redact | neutralise)"

# ISSUE_NUMBER lands in the marker block: digits only.
if [[ -n "$ISSUE_NUMBER" && ! "$ISSUE_NUMBER" =~ ^[0-9]+$ ]]; then
  printf 'error: ISSUE_NUMBER must be digits only, got %q\n' "$ISSUE_NUMBER" >&2
  exit 2
fi

# The link the operator needs is usually in the error itself ("add credits at
# ...") and is more specific than any default we could hardcode.
KEY_LINK="$(printf '%s' "$SAFE_ERROR" \
  | grep -oE 'https://openrouter\.ai/[^ )"]+' | head -1 || true)"
KEY_LINK="${KEY_LINK:-https://openrouter.ai/settings/keys}"

# --- alarm body -------------------------------------------------------------

render_alarm_body() {
  cat <<EOF
The pipeline is **paused** in \`${REPO}\`: $(pause_title "$REASON").

No new agent run will start in this repository while this issue is open. The
paused issues keep their \`ai-implement\` label and are re-dispatched on resume —
nothing was lost and nothing counted as an attempt.

### Error

\`\`\`text
${SAFE_ERROR:-(no error text captured)}
\`\`\`

### How to resume

1. $(pause_hint "$REASON")
2. **Close this issue** — that is what clears the pause.
3. Re-dispatch the paused issues: \`REPO=${REPO} bash scripts/pipeline-resume.sh\`

[View paused issues](https://github.com/${REPO}/issues?q=is%3Aissue+is%3Aopen+label%3Aai%3Apaused)

Raised by \`pipeline-pause.sh\` (reason \`${REASON}\`). See \`docs/ALARMS.md\`.
EOF
}

bodyfile="$(mktemp)"
trap 'rm -f "$bodyfile"' EXIT

# --- an alarm may already be open -------------------------------------------

# --limit caps a pathological repo; sort_by(.number) makes "the oldest open
# alarm wins" deterministic rather than dependent on gh's ordering.
open_alarms="$(gh issue list --repo "$REPO" --label "$ALARM_LABEL" --state open \
  --json number --limit 20 2>/dev/null || printf '[]')"
alarm="$(jq -r 'sort_by(.number) | .[0].number // empty' <<<"$open_alarms")"

if [[ -n "$alarm" ]]; then
  # An existing alarm is not edited: the body belongs to the first racer and
  # may carry operator notes. The paused list is now label-based, not body-based.
  paused_issue_mark "$ISSUE_NUMBER"
  printf 'pipeline-pause: alarm #%s already open — labelled issue #%s\n' "$alarm" "$ISSUE_NUMBER"
  emit alarm-issue "$alarm"
  emit created false
  exit 0
fi

# --- raise a new alarm ------------------------------------------------------

forge_label_ensure "$ALARM_LABEL" B60205 \
  'Pipeline paused — an open issue with this label stops new dispatches' >/dev/null 2>&1 || true

render_alarm_body > "$bodyfile"
alarm_url="$(gh issue create --repo "$REPO" \
  --title "🚨 Pipeline paused: $(pause_title "$REASON")" \
  --label "$ALARM_LABEL" --body-file "$bodyfile")"
alarm="${alarm_url##*/}"

# Mark the paused issue with a label so pipeline-resume.sh can find it.
paused_issue_mark "$ISSUE_NUMBER"

# Two runs that fail in the same second both see no open alarm and both create
# one. Re-read and keep the lowest number: every racer reaches the same verdict
# from the same data, so exactly one alarm survives and exactly one push goes
# out — without a lock neither of them could take.
winner="$(gh issue list --repo "$REPO" --label "$ALARM_LABEL" --state open \
  --json number --limit 20 2>/dev/null \
  | jq -r 'sort_by(.number) | .[0].number // empty' || printf '')"
if [[ -n "$winner" && "$winner" != "$alarm" ]] && (( winner < alarm )); then
  gh issue close "$alarm" --repo "$REPO" --comment "duplicate of #${winner}" >/dev/null 2>&1 || true
  printf 'pipeline-pause: lost the race — closed #%s as a duplicate of #%s\n' "$alarm" "$winner"
  emit alarm-issue "$winner"
  emit created false
  exit 0
fi

# Best-effort: pinning needs a right the job's token may not have, and the
# label is what is authoritative anyway.
gh issue pin "$alarm" --repo "$REPO" >/dev/null 2>&1 || true

printf 'pipeline-pause: raised alarm #%s (%s)\n' "$alarm" "$REASON"
emit alarm-issue "$alarm"
emit created true

NTFY_TITLE="🚨 Pipeline paused: ${REPO}" \
NTFY_MESSAGE="$(pause_title "$REASON") — ${ISSUE_NUMBER:+issue #${ISSUE_NUMBER} and }new dispatches are stopped. See alarm #${alarm}." \
NTFY_PRIORITY=urgent \
NTFY_TAGS=rotating_light \
NTFY_CLICK="https://github.com/${REPO}/issues/${alarm}" \
  bash "$_PP_HERE/notify-ntfy.sh"
