#!/usr/bin/env bash
#
# notify-ntfy.sh — publish one push notification to an ntfy topic.
#
# The alarm this carries (#517) is only useful if it arrives within minutes —
# the failure it reports went unnoticed for 15 hours. But a push is strictly an
# addition to the alarm issue, so it must never be the reason a run goes red:
# every path here exits 0, including a missing configuration and a dead server.
#
# Required environment variables (both, or the push is skipped):
#   NTFY_URL     Base URL of the ntfy server, e.g. https://ntfy.sh
#   NTFY_TOPIC   Topic to publish to.
#
# Optional environment variables:
#   NTFY_TOKEN     Bearer token for a write-restricted topic. Passed to curl
#                  through a `-K -` config on stdin, never on argv: argv is
#                  world-readable in /proc and lands in any `ps` output.
#   NTFY_TITLE     Notification title. Default "pipeline".
#   NTFY_MESSAGE   Notification body.
#   NTFY_PRIORITY  urgent | high | default | low | min. Default "default".
#   NTFY_CLICK     URL opened when the notification is tapped.
#   NTFY_TAGS      Comma-separated ntfy tags, e.g. "rotating_light".
#
# Exit codes:
#   0   always — sent, skipped, or failed
#
# Deliberately NOT `set -e`: an `exit 0` contract and a shell that exits on the
# first unexpected non-zero are the same mistake twice. -u and pipefail stay.
set -uo pipefail
IFS=$'\n\t'

NTFY_URL="${NTFY_URL:-}"
NTFY_TOPIC="${NTFY_TOPIC:-}"

if [[ -z "$NTFY_URL" || -z "$NTFY_TOPIC" ]]; then
  printf 'ntfy: not configured (NTFY_URL / NTFY_TOPIC unset) — skipping push\n'
  exit 0
fi

case "${NTFY_PRIORITY:-default}" in
  urgent) priority=5 ;;
  high)   priority=4 ;;
  low)    priority=2 ;;
  min)    priority=1 ;;
  *)      priority=3 ;;
esac

body="$(jq -n \
  --arg topic "$NTFY_TOPIC" \
  --arg title "${NTFY_TITLE:-pipeline}" \
  --arg message "${NTFY_MESSAGE:-}" \
  --arg click "${NTFY_CLICK:-}" \
  --arg tags "${NTFY_TAGS:-}" \
  --argjson priority "$priority" \
  '{topic: $topic, title: $title, message: $message, priority: $priority}
   + (if $click != "" then {click: $click} else {} end)
   + (if $tags  != "" then {tags: ($tags | split(","))} else {} end)')"

errfile="$(mktemp)"
cfgfile="$(mktemp)"
trap 'rm -f "$errfile" "$cfgfile"' EXIT
chmod 600 "$cfgfile"

# Only the token goes through the config. The URL stays on argv: argv is local
# to the runner, and NTFY_URL is a GitHub secret, so a run log masks it anyway.
if [[ -n "${NTFY_TOKEN:-}" ]]; then
  printf 'header = "Authorization: Bearer %s"\n' "$NTFY_TOKEN" > "$cfgfile"
fi

if curl -sS -f --max-time 10 -K - -X POST \
     -H 'Content-Type: application/json' -d "$body" "${NTFY_URL%/}/" \
     < "$cfgfile" >/dev/null 2>"$errfile"; then
  printf 'ntfy: sent %s to topic %s\n' "${NTFY_PRIORITY:-default}" "$NTFY_TOPIC"
  exit 0
fi

# curl's own diagnostics never echo a request header, but they do name the
# bare host ("Could not resolve host: <host>"), which GitHub's masking of the
# full NTFY_URL secret does not catch. Redact it before truncating: the warning
# is the one thing from this script that reaches a public run log.
host="${NTFY_URL#*://}"
host="${host%%/*}"
detail="$(tr -d '\n' < "$errfile")"
detail="${detail//"$host"/<ntfy-host>}"
printf 'warning: ntfy push to topic %s failed (%s) — continuing\n' \
  "$NTFY_TOPIC" "${detail:0:200}" >&2
exit 0
