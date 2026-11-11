#!/usr/bin/env bash
#
# retry-policy.sh — the retry decision table: given a failure class and the
# current attempt number, should the run be retried, and after how long?
#
# One table, two callers: scripts/retry-dispatch.sh (GitHub path, re-dispatches
# the workflow) and the Azure DevOps ai-implement driver (in-job retry).
#
# Optional environment variables, read at call time:
#   MAX_RETRIES_RATE    Default 3.
#   MAX_RETRIES_TRANS   Default 3.
#   MAX_RETRIES_TASK    Default 1.
#   DELAY_OVERRIDE_SEC  When set and non-empty, replaces the delay on both
#                       decisions. Used by tests to keep them fast.
#
# Sourced, not executed. Only defines functions; does not touch shell options.
# Exposes:
#   retry_policy <class> <attempt>   prints two lines to stdout:
#                                      decision=<retry|stop>
#                                      delay=<seconds>
#                                    returns 0, or 2 when an argument is missing

retry_policy() {
  if [[ $# -lt 2 ]]; then
    printf 'usage: retry_policy <class> <attempt>\n' >&2
    return 2
  fi
  local class="$1" attempt="$2"
  local max_rate="${MAX_RETRIES_RATE:-3}"
  local max_trans="${MAX_RETRIES_TRANS:-3}"
  local max_task="${MAX_RETRIES_TASK:-1}"
  local decision=stop
  local delay=0

  case "$class" in
    success)
      decision=stop
      ;;
    rate_limit)
      if (( attempt < max_rate )); then
        decision=retry
        delay=300                  # 5 min — covers most per-minute resets
      fi
      ;;
    transient)
      if (( attempt < max_trans )); then
        decision=retry
        delay=$(( 10 * (1 << (attempt - 1)) ))  # 10, 20, 40, ...
      fi
      ;;
    task_failure)
      if (( attempt < max_task + 1 )); then  # attempt 1 → retry once
        decision=retry
        delay=10
      fi
      ;;
    out_of_credits|model_not_found|api_auth|bug)
      # operator intervention. out_of_credits is a pause class
      # (scripts/lib/pause-reasons.sh): retrying it cannot succeed until the key
      # is topped up, and pipeline-pause.sh re-dispatches the issue on resume.
      # model_not_found is a wrong model id (#518): the operator corrects
      # `default-model` or the `model:` label and re-dispatches. Not retrying is
      # also what keeps escalate-on-retry from moving the issue to Claude.
      decision=stop
      ;;
    *)
      printf 'warn: unknown CLASS "%s" — defaulting to stop\n' "$class" >&2
      decision=stop
      ;;
  esac

  if [[ -n "${DELAY_OVERRIDE_SEC:-}" ]]; then
    delay="$DELAY_OVERRIDE_SEC"
  fi

  printf 'decision=%s\n' "$decision"
  printf 'delay=%s\n' "$delay"
}
