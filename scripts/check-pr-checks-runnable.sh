#!/usr/bin/env bash
#
# check-pr-checks-runnable.sh — Determine whether a pipeline-opened PR's
# required status checks can actually run.
#
# A PR opened with the ambient GITHUB_TOKEN is authored by `github-actions`.
# Its `pull_request` workflow runs are created but stall at `action_required`
# awaiting manual approval, so `statusCheckRollup` stays empty and a repo with
# required checks leaves the PR permanently BLOCKED (#364, observed on #363).
# Nothing in the pipeline said so: a stalled PR looked exactly like a finished
# one. This probe is what makes the stall visible.
#
# DIAGNOSTIC ONLY. This script never fails the job — the calling step carries
# `continue-on-error: true`, and a blocked determination does not change the
# run's outcome label. The agent did its work; the repo is misconfigured.
#
# Polls for check PRESENCE, not completion. `gh pr checks --watch` is the wrong
# tool here: it waits for checks to finish, and the whole symptom is that none
# ever start.
#
# Required environment variables:
#   PR_NUMBER   The pull request to probe.
#
# Optional environment variables:
#   REPO                  owner/repo. Default: $GITHUB_REPOSITORY.
#   APP_TOKEN_CONFIGURED  "true" when a pipeline App token was minted. The
#                         workflow passes `${{ env.PIPELINE_APP_ID != '' }}`.
#                         Selects which blocked reason is reported.
#   POLL_INTERVAL         Seconds between polls. Default 10. Tests set 0.
#   POLL_TIMEOUT          Seconds to keep polling. Default 120.
#   GITHUB_OUTPUT         When set, both output keys are appended to it.
#
# Output (stdout, and $GITHUB_OUTPUT when set):
#   checks-runnable=true|false
#   checks-blocked-reason=|no-app-token|rollup-empty
#
# Exit codes:
#   0   determination made (runnable or not)
#   2   required env missing
set -euo pipefail
IFS=$'\n\t'

if [[ -z "${PR_NUMBER:-}" ]]; then
  printf 'error: PR_NUMBER must be set\n' >&2
  exit 2
fi

REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
APP_TOKEN_CONFIGURED="${APP_TOKEN_CONFIGURED:-false}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"
POLL_TIMEOUT="${POLL_TIMEOUT:-120}"

emit() {
  local runnable="$1" reason="$2"
  printf 'checks-runnable=%s\n' "$runnable"
  printf 'checks-blocked-reason=%s\n' "$reason"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      printf 'checks-runnable=%s\n' "$runnable"
      printf 'checks-blocked-reason=%s\n' "$reason"
    } >> "$GITHUB_OUTPUT"
  fi
}

# Count the checks attached to the PR. A `gh` failure is deliberately NOT
# fatal: an outage must not fail a diagnostic step, so it counts as zero and
# the poll simply carries on until the window closes.
rollup_count() {
  local args=(pr view "$PR_NUMBER" --json statusCheckRollup
              --jq '.statusCheckRollup | length')
  [[ -n "$REPO" ]] && args+=(--repo "$REPO")
  gh "${args[@]}" 2>/dev/null || printf '0'
}

deadline=$(( $(date +%s) + POLL_TIMEOUT ))
runnable=false

while :; do
  count="$(rollup_count | tr -d '[:space:]')"
  if [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 )); then
    runnable=true
    break
  fi
  (( $(date +%s) >= deadline )) && break
  sleep "$POLL_INTERVAL"
done

if [[ "$runnable" == "true" ]]; then
  printf 'checks are running on PR #%s\n' "$PR_NUMBER" >&2
  emit true ''
  exit 0
fi

# Two reasons, because they call for different operator actions.
if [[ "$APP_TOKEN_CONFIGURED" == "true" ]]; then
  reason='rollup-empty'
  printf 'PR #%s has no checks after %ss, and a pipeline App token WAS minted.\n' \
    "$PR_NUMBER" "$POLL_TIMEOUT" >&2
  printf 'This is not the usual cause — inspect the PR directly.\n' >&2
  printf 'See docs/PIPELINE-APP-SETUP.md\n' >&2
else
  reason='no-app-token'
  printf 'PR #%s has no checks after %ss; no pipeline App token was configured,\n' \
    "$PR_NUMBER" "$POLL_TIMEOUT" >&2
  printf 'so the PR is authored by github-actions and its checks need approval.\n' >&2
  printf 'See docs/PIPELINE-APP-SETUP.md\n' >&2
fi

emit false "$reason"
