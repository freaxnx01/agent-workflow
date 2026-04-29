#!/usr/bin/env bash
#
# retry-dispatch.sh — Decide whether to retry a failed Claude run based on the
# failure class and prior attempt count. When a retry is warranted, sleep for
# the policy delay and re-dispatch the consumer workflow via
# `gh workflow run <consumer> -f issue-number=<N> -f attempt=<N+1>`.
#
# Required environment variables:
#   CLASS               From classify-failure.sh.
#   ATTEMPT             Current attempt number (1-based).
#   ISSUE_NUMBER        GitHub issue number.
#   REPO                owner/repo.
#   GH_TOKEN            (or ambient gh auth)
#
# Optional environment variables:
#   CONSUMER_WORKFLOW   Workflow filename to redispatch. Default: claude.yml.
#   MAX_RETRIES_RATE    Default 3.
#   MAX_RETRIES_TRANS   Default 3.
#   MAX_RETRIES_TASK    Default 1.
#   DELAY_OVERRIDE_SEC  Force a specific delay (skips policy computation).
#                       Used by tests to keep them fast.
#   DRY_RUN             If "1", print the decision and skip the actual sleep
#                       and `gh workflow run` call. Default 0.
#
# Output (stdout + GITHUB_OUTPUT when set):
#   decision=retry | stop
#   class=<CLASS>
#   attempt=<ATTEMPT>
#   delay-seconds=<N>   (0 when decision=stop)
#
# Exit codes:
#   0   decision produced (retry attempted/dispatched, or stop)
#   2   required env missing
set -euo pipefail
IFS=$'\n\t'

require_env() {
  if [[ -z "${!1:-}" ]]; then
    printf 'error: %s must be set\n' "$1" >&2
    exit 2
  fi
}

require_env CLASS
require_env ATTEMPT
require_env ISSUE_NUMBER
require_env REPO

CONSUMER_WORKFLOW="${CONSUMER_WORKFLOW:-claude.yml}"
MAX_RETRIES_RATE="${MAX_RETRIES_RATE:-3}"
MAX_RETRIES_TRANS="${MAX_RETRIES_TRANS:-3}"
MAX_RETRIES_TASK="${MAX_RETRIES_TASK:-1}"
DRY_RUN="${DRY_RUN:-0}"

# --- policy --------------------------------------------------------------

decision=stop
delay=0

case "$CLASS" in
  success)
    decision=stop
    ;;
  rate_limit)
    if (( ATTEMPT < MAX_RETRIES_RATE )); then
      decision=retry
      delay=300                  # 5 min — covers most per-minute resets
    fi
    ;;
  transient)
    if (( ATTEMPT < MAX_RETRIES_TRANS )); then
      decision=retry
      delay=$(( 10 * (1 << (ATTEMPT - 1)) ))  # 10, 20, 40, ...
    fi
    ;;
  task_failure)
    if (( ATTEMPT < MAX_RETRIES_TASK + 1 )); then  # ATTEMPT 1 → retry once
      decision=retry
      delay=10
    fi
    ;;
  api_auth|bug)
    decision=stop                # operator intervention
    ;;
  *)
    printf 'warn: unknown CLASS "%s" — defaulting to stop\n' "$CLASS" >&2
    decision=stop
    ;;
esac

if [[ -n "${DELAY_OVERRIDE_SEC:-}" ]]; then
  delay="$DELAY_OVERRIDE_SEC"
fi

# --- emit decision -------------------------------------------------------

emit() {
  printf '%s=%s\n' "$1" "$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}

emit decision      "$decision"
emit class         "$CLASS"
emit attempt       "$ATTEMPT"
emit delay-seconds "$delay"

# --- dispatch when decision=retry ---------------------------------------

if [[ "$decision" != "retry" ]]; then
  exit 0
fi

if [[ "$DRY_RUN" == "1" ]]; then
  printf 'DRY_RUN: would sleep %ds then dispatch %s on %s for issue #%s (attempt %d)\n' \
    "$delay" "$CONSUMER_WORKFLOW" "$REPO" "$ISSUE_NUMBER" "$((ATTEMPT + 1))"
  exit 0
fi

printf 'sleeping %ds before retrying (attempt %d → %d)\n' "$delay" "$ATTEMPT" "$((ATTEMPT + 1))"
sleep "$delay"

gh workflow run "$CONSUMER_WORKFLOW" \
  --repo "$REPO" \
  -f issue-number="$ISSUE_NUMBER" \
  -f attempt="$((ATTEMPT + 1))"
