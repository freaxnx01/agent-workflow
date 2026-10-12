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
#   ISSUE_NUMBER  The issue whose run hit the pause. Listed in the alarm so the
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
MARKER_OPEN='<!-- paused-issues -->'
MARKER_CLOSE='<!-- /paused-issues -->'

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

# --- the paused-issues marker block -----------------------------------------

# paused_list <existing-list> — the existing space-separated "#12 #34" list
# with $ISSUE_NUMBER appended unless it is already there. Token comparison, not
# substring: `#1` is a substring of `#12` and dedup on that would drop issues.
paused_list() {
  local existing="$1" token entry out="" entries=()
  # IFS is newline/tab script-wide, so split on spaces explicitly.
  IFS=' ' read -ra entries <<<"$existing"
  [[ -n "$ISSUE_NUMBER" ]] && token="#${ISSUE_NUMBER}" || token=""
  for entry in "${entries[@]}"; do
    [[ "$entry" =~ ^#[0-9]+$ ]] || continue
    [[ -n "$out" ]] && out+=' '
    out+="$entry"
    [[ "$entry" == "$token" ]] && token=""
  done
  if [[ -n "$token" ]]; then
    [[ -n "$out" ]] && out+=' '
    out+="$token"
  fi
  printf '%s' "$out"
}

extract_list() {
  sed -n "s|.*${MARKER_OPEN}\(.*\)${MARKER_CLOSE}.*|\1|p" <<<"$1" | head -1
}

# --- alarm body -------------------------------------------------------------

render_alarm_body() {
  local list="$1"
  cat <<EOF
The pipeline is **paused** in \`${REPO}\`: $(pause_title "$REASON").

No new agent run will start in this repository while this issue is open. The
issues below keep their \`ai-implement\` label and are re-dispatched on resume —
nothing was lost and nothing counted as an attempt.

### Error

\`\`\`text
${SAFE_ERROR:-(no error text captured)}
\`\`\`

### Key management

${KEY_LINK}

### Paused issues

${MARKER_OPEN}${list}${MARKER_CLOSE}

### How to resume

1. $(pause_hint "$REASON")
2. **Close this issue** — that is what clears the pause.
3. Re-dispatch the paused issues: \`REPO=${REPO} bash scripts/pipeline-resume.sh\`

Raised by \`pipeline-pause.sh\` (reason \`${REASON}\`). See \`docs/ALARMS.md\`.
EOF
}

bodyfile="$(mktemp)"
trap 'rm -f "$bodyfile"' EXIT

# --- an alarm may already be open -------------------------------------------

# --limit caps a pathological repo; sort_by(.number) makes "the oldest open
# alarm wins" deterministic rather than dependent on gh's ordering.
open_alarms="$(gh issue list --repo "$REPO" --label "$ALARM_LABEL" --state open \
  --json number,body --limit 20 2>/dev/null || printf '[]')"
alarm="$(jq -r 'sort_by(.number) | .[0].number // empty' <<<"$open_alarms")"

if [[ -n "$alarm" ]]; then
  old_body="$(jq -r --argjson n "$alarm" \
    'map(select(.number == $n)) | .[0].body // ""' <<<"$open_alarms")"
  new_list="$(paused_list "$(extract_list "$old_body")")"
  if [[ "$old_body" == *"$MARKER_OPEN"* ]]; then
    # Only the marker block changes: the rest of the body may carry an
    # operator's own notes, and overwriting those would lose them.
    printf '%s\n' "$old_body" \
      | sed "s|${MARKER_OPEN}.*${MARKER_CLOSE}|${MARKER_OPEN}${new_list}${MARKER_CLOSE}|" \
      > "$bodyfile"
  else
    # A hand-written alarm, or one from an older version: give it a block so
    # pipeline-resume.sh can read the list back.
    { printf '%s\n\n### Paused issues\n\n%s%s%s\n' \
        "$old_body" "$MARKER_OPEN" "$new_list" "$MARKER_CLOSE"; } > "$bodyfile"
  fi
  gh issue edit "$alarm" --repo "$REPO" --body-file "$bodyfile" >/dev/null
  printf 'pipeline-pause: alarm #%s already open — added issue(s) %s\n' "$alarm" "$new_list"
  emit alarm-issue "$alarm"
  emit created false
  exit 0
fi

# --- raise a new alarm ------------------------------------------------------

forge_label_ensure "$ALARM_LABEL" B60205 \
  'Pipeline paused — an open issue with this label stops new dispatches' >/dev/null 2>&1 || true

render_alarm_body "$(paused_list '')" > "$bodyfile"
alarm_url="$(gh issue create --repo "$REPO" \
  --title "🚨 Pipeline paused: $(pause_title "$REASON")" \
  --label "$ALARM_LABEL" --body-file "$bodyfile")"
alarm="${alarm_url##*/}"

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
