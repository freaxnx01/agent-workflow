#!/usr/bin/env bash
#
# gh-retry.sh — backoff helper for flaky `gh` calls (e.g. `gh pr create`
# under secondary rate limits). Source it; do not execute.
#
#   with_backoff <cmd> [args...]   run cmd, retrying transient failures
#   gh_retryable "<stderr text>"   exit 0 if text is a transient signature
#
# Seams (env): GH_RETRY_MAX (3), GH_RETRY_BASE_SLEEP (2),
#              GH_RETRY_SLEEP_CMD (sleep), GH_RETRY_NO_JITTER (unset).
set -euo pipefail
IFS=$'\n\t'

# Transient signatures worth retrying.
_GH_RETRY_TRANSIENT='secondary rate limit|rate limit|was submitted too quickly|abuse detection|\b5[0-9][0-9]\b|server error|timed out|timeout|connection reset'
# Hard failures we must NOT retry (surface immediately).
_GH_RETRY_FATAL='not permitted to create or approve pull requests|must be a collaborator|authentication|bad credentials'

gh_retryable() {
  local text="$1"
  shopt -s nocasematch
  if [[ "$text" =~ $_GH_RETRY_FATAL ]]; then shopt -u nocasematch; return 1; fi
  if [[ "$text" =~ $_GH_RETRY_TRANSIENT ]]; then shopt -u nocasematch; return 0; fi
  shopt -u nocasematch
  return 1
}

with_backoff() {
  local max="${GH_RETRY_MAX:-3}"
  local base="${GH_RETRY_BASE_SLEEP:-2}"
  local sleep_cmd="${GH_RETRY_SLEEP_CMD:-sleep}"
  local attempt=1 ec errfile jitter
  errfile="$(mktemp)"
  # shellcheck disable=SC2064  # expand errfile now, on function return
  trap "rm -f '$errfile'" RETURN

  while :; do
    ec=0
    "$@" 2>"$errfile" || ec=$?
    cat "$errfile" >&2
    [[ "$ec" -eq 0 ]] && return 0
    if ! gh_retryable "$(cat "$errfile")"; then return "$ec"; fi
    if (( attempt >= max )); then return "$ec"; fi
    jitter=0
    [[ -z "${GH_RETRY_NO_JITTER:-}" ]] && jitter=$(( RANDOM % 2 ))
    "$sleep_cmd" "$(( base * attempt + jitter ))"
    attempt=$(( attempt + 1 ))
  done
}
