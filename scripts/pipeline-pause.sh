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
# The alarm body is DISPLAY ONLY (ADR-019). Which issues are paused is a label
# on each of them (scripts/lib/paused-issues.sh), never text in this body: the
# body quotes the agent's error, and that text is untrusted.
#
# "One per pause" is enforced twice: an existing open alarm is left as it is
# rather than duplicated, and a creation that loses a race against a concurrent
# run closes its own issue as a duplicate of the lower-numbered winner. Only
# the run that actually created the surviving alarm pushes, so a repo with five
# issues failing in the same minute pages the maintainer once.
#
# Required environment variables:
#   REASON    Pause reason id from scripts/lib/pause-reasons.sh.
#   REPO      owner/repo.
#   GH_TOKEN  (or ambient gh auth) with `issues: write`.
#
# Optional environment variables:
#   ISSUE_NUMBER  The issue whose run hit the pause. It is labelled so the
#                 resume knows what to re-dispatch. Empty when the pause comes
#                 from the scheduled health check rather than a run.
#   ERROR_TEXT    The agent's error text. Untrusted: redacted, truncated and
#                 shown inside one fenced block at the end of the alarm.
#   ALARM_LABEL   Default "pipeline-paused".
#   NTFY_*        Passed through to notify-ntfy.sh. Missing config skips the
#                 push; a failed push never fails this script.
#
# Output (stdout + GITHUB_OUTPUT when set):
#   alarm-issue=<n>
#   created=true|false
#
# Exit codes:
#   0   an alarm is open for this pause (created or already there); also when
#       the forge has no adapter and the alarm is skipped
#   2   required env missing, REASON is not a known pause reason, or
#       ISSUE_NUMBER is not a number
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

# ISSUE_NUMBER is handed to gh as an argument and named in the body: digits only.
if [[ -n "$ISSUE_NUMBER" && ! "$ISSUE_NUMBER" =~ ^[0-9]+$ ]]; then
  printf 'error: ISSUE_NUMBER must be digits only, got %q\n' "$ISSUE_NUMBER" >&2
  exit 2
fi

# --- the error text ---------------------------------------------------------

# The error text is pasted into a public issue. A provider that echoes the
# offending key in its own error message — and some do — would publish it.
# Truncated too: an agent's error can be the whole transcript, and an alarm
# nobody reads is not an alarm.
redact() {
  sed -E 's/sk-or-[A-Za-z0-9_-]+/sk-or-***/g; s/sk-ant-[A-Za-z0-9_-]+/sk-ant-***/g' \
    | head -c 2000
}

# Untrusted, and rendered in exactly one place: the fenced block that ends the
# body. Backticks are the only characters that can close that fence, so they
# are dropped. Nothing is extracted from this text and nothing after it exists
# for it to imitate.
SAFE_ERROR="$(printf '%s' "$ERROR_TEXT" | redact | tr -d '`')"

# --- the paused issue -------------------------------------------------------

# Before anything else, so the issue is on the paused list on every path below.
# A failed write leaves it on no list at all; UNLABELLED then names it in the
# alarm body (digits only, validated above — trusted).
UNLABELLED=''
if [[ -n "$ISSUE_NUMBER" ]]; then
  paused_issue_mark "$ISSUE_NUMBER" || UNLABELLED="$ISSUE_NUMBER"
fi

# --- alarm body -------------------------------------------------------------

# unlabelled_note — one line for an issue that could not be labelled, or nothing.
unlabelled_note() {
  [[ -n "$UNLABELLED" ]] || return 0
  # shellcheck disable=SC2016  # markdown code spans, not command substitution
  printf '\n**Issue #%s could not be labelled `%s`** — the resume will not find it; re-dispatch it by hand.\n' \
    "$UNLABELLED" "$PAUSED_ISSUE_LABEL"
}

# Every value above the error block is trusted: the repo, the reason table,
# a validated issue number and fixed URLs.
render_alarm_body() {
  cat <<EOF
The pipeline is **paused** in \`${REPO}\`: $(pause_title "$REASON").

No new agent run will start in this repository while this issue is open. Every
issue a run or a dispatch was stopped on carries the \`${PAUSED_ISSUE_LABEL}\`
label, keeps its \`ai-implement\` label and is re-dispatched on resume —
nothing was lost and nothing counted as an attempt.

### Paused issues

https://github.com/${REPO}/issues?q=is%3Aissue+is%3Aopen+label%3A${PAUSED_ISSUE_LABEL/:/%3A}
$(unlabelled_note)

### Key management

https://openrouter.ai/settings/keys

### How to resume

1. $(pause_hint "$REASON")
2. **Close this issue** — that is what clears the pause.
3. Re-dispatch the paused issues: \`REPO=${REPO} bash scripts/pipeline-resume.sh\`

Raised by \`pipeline-pause.sh\` (reason \`${REASON}\`). See \`docs/ALARMS.md\`.

### Error (as reported — untrusted text, shown for diagnosis only)

\`\`\`text
${SAFE_ERROR:-(no error text captured)}
\`\`\`
EOF
}

# lowest_open_alarm — the number of the oldest open alarm, or nothing.
# --limit caps a pathological repo; sort_by(.number) makes "the oldest open
# alarm wins" deterministic rather than dependent on gh's ordering.
lowest_open_alarm() {
  gh issue list --repo "$REPO" --label "$ALARM_LABEL" --state open \
    --json number --limit 20 2>/dev/null \
    | jq -r 'sort_by(.number) | .[0].number // empty' || printf ''
}

# --- an alarm may already be open -------------------------------------------

alarm="$(lowest_open_alarm)"
if [[ -n "$alarm" ]]; then
  printf 'pipeline-pause: alarm #%s already open — not raising another\n' "$alarm"
  emit alarm-issue "$alarm"
  emit created false
  exit 0
fi

# --- raise a new alarm ------------------------------------------------------

forge_label_ensure "$ALARM_LABEL" B60205 \
  'Pipeline paused — an open issue with this label stops new dispatches' >/dev/null 2>&1 || true

bodyfile="$(mktemp)"
trap 'rm -f "$bodyfile"' EXIT
render_alarm_body > "$bodyfile"
alarm_url="$(gh issue create --repo "$REPO" \
  --title "🚨 Pipeline paused: $(pause_title "$REASON")" \
  --label "$ALARM_LABEL" --body-file "$bodyfile")"
alarm="${alarm_url##*/}"

# Two runs that fail in the same second both see no open alarm and both create
# one. Re-read and keep the lowest number: every racer reaches the same verdict
# from the same data, so exactly one alarm survives and exactly one push goes
# out — without a lock neither of them could take.
winner="$(lowest_open_alarm)"
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
