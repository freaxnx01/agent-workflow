#!/usr/bin/env bash
#
# self-fix-loop.sh — the review flows' self-fix pass (#81 / ADR-004
# follow-up). On a `request_changes` verdict from the first review, runs
# up to MAX_ITERATIONS fix→re-review cycles: FIX_CMD applies and commits
# a fix, then REVIEW_SCRIPT re-reviews the new HEAD. Stops early on
# `approve` or `block`. Invoked by whichever review job runs
# (ai_review_ai_merge or ai_review_human_merge) only when the first
# verdict is `request_changes` and self-fix is enabled — a `block` or
# `approve` first verdict never reaches here.
#
# Required environment variables:
#   PR_NUMBER         PR number
#   REPO              owner/repo
#   HEAD_SHA          initial PR head SHA (from the first review)
#   HEAD_REF          PR head branch name (passed through to FIX_CMD)
#   INITIAL_VERDICT   verdict from the first review-pr.sh run
#   MAX_ITERATIONS    self-fix-max-iterations input (non-negative integer;
#                     0 means self-fix is trivially exhausted -- the loop
#                     never runs, verdict stays INITIAL_VERDICT)
#   CONCERNS_FILE     validated review JSON from the first review-pr.sh
#                     run. Not required when STUB_VERDICT_SEQUENCE is set.
#
# Optional environment variables:
#   FIX_CMD        Override for the fix invocation. Contract:
#                    $FIX_CMD <pr-number> <concerns-json-file>
#                  (ITERATION, REPO, HEAD_REF, AGENT, MODEL passed via env
#                  per call — AGENT/MODEL come from FIX_AGENT/FIX_MODEL
#                  below, not from this script's own inherited AGENT/MODEL,
#                  which the REVIEW_SCRIPT call below needs to stay at the
#                  fixed review-agent identity.) Default:
#                  <script-dir>/self-fix-pr.sh.
#   FIX_AGENT      claude | opencode — forwarded to FIX_CMD as AGENT.
#                  Default: claude.
#   FIX_MODEL      Forwarded to FIX_CMD as MODEL. Default: this script's own
#                  inherited MODEL (the caller's review-model), so a caller
#                  that only sets MODEL (not FIX_MODEL) keeps the fix call's
#                  --model flag unchanged from before FIX_MODEL existed.
#   REVIEW_SCRIPT  Override path to review-pr.sh (default: sibling
#                  script). Re-review calls reuse review-pr.sh's own env
#                  contract (AGENT, AGENT_CMD, MODEL, etc.) inherited
#                  unmodified from this script's own environment — the
#                  caller job sets those to the fixed review-agent
#                  identity (AGENT=claude), which is intentionally
#                  independent of FIX_AGENT.
#   NEW_HEAD_SHA   Skip the `gh pr view --json headRefOid` lookup after
#                  each fix and use this value instead. Used by Layer-1
#                  tests.
#   STUB_VERDICT_SEQUENCE
#                  Test-only. Comma-separated verdicts (e.g.
#                  "request_changes,approve") consumed one per iteration
#                  instead of really invoking FIX_CMD/REVIEW_SCRIPT. Used
#                  by Layer-2 act tests (real fix/review behavior is
#                  covered by Layer-1 tests of self-fix-pr.sh /
#                  review-pr.sh directly).
#
# Output ($GITHUB_OUTPUT):
#   verdict           final verdict (INITIAL_VERDICT unchanged if no
#                     iteration completed)
#   iterations-used   integer, 0 if no iteration completed
#   head-sha          final PR head SHA (unchanged if no iteration ran)
#
# Exit codes:
#   0   always — verdict/iterations-used/head-sha carry the outcome
#   2   required env missing or MAX_ITERATIONS not a non-negative integer
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

require_env() {
  if [[ -z "${!1:-}" ]]; then
    printf 'error: %s must be set\n' "$1" >&2
    exit 2
  fi
}

require_env PR_NUMBER
require_env REPO
require_env HEAD_SHA
require_env HEAD_REF
require_env INITIAL_VERDICT
require_env MAX_ITERATIONS

if ! [[ "$MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
  printf 'error: MAX_ITERATIONS must be a non-negative integer (got %q)\n' "$MAX_ITERATIONS" >&2
  exit 2
fi
# MAX_ITERATIONS=0 is not an error -- a misconfigured consumer (self-fix:
# true, self-fix-max-iterations: 0) should get self-fix trivially exhausted
# (loop never runs, verdict stays INITIAL_VERDICT, iterations-used=0, exit
# 0) rather than a red CI job (#81 review finding 12). The `for` loops
# below already no-op when MAX_ITERATIONS is 0 -- no further branching
# needed.

if [[ -z "${STUB_VERDICT_SEQUENCE:-}" ]]; then
  require_env CONCERNS_FILE
fi

emit_output() {
  local key="$1" value="$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
  fi
}

verdict="$INITIAL_VERDICT"
# shellcheck disable=SC2153 # HEAD_SHA (env) seeds local head_sha; not a typo
head_sha="$HEAD_SHA"
iterations_used=0

if [[ -n "${STUB_VERDICT_SEQUENCE:-}" ]]; then
  # Layer-2 test seam: bypass FIX_CMD/REVIEW_SCRIPT entirely and just
  # consume the stubbed sequence, one verdict per iteration.
  IFS=',' read -ra stub_verdicts <<< "$STUB_VERDICT_SEQUENCE"
  for (( i = 1; i <= MAX_ITERATIONS && i <= ${#stub_verdicts[@]}; i++ )); do
    verdict="${stub_verdicts[$((i - 1))]}"
    iterations_used=$i
    [[ "$verdict" == "approve" || "$verdict" == "block" ]] && break
  done
else
  FIX_CMD="${FIX_CMD:-$SCRIPT_DIR/self-fix-pr.sh}"
  REVIEW_SCRIPT="${REVIEW_SCRIPT:-$SCRIPT_DIR/review-pr.sh}"
  FIX_AGENT="${FIX_AGENT:-claude}"
  # Default to this script's own inherited MODEL (the caller's review-model,
  # e.g. the workflow's existing `MODEL: ${{ inputs.review-model }}` on the
  # self-fix step) rather than empty -- otherwise a caller that hasn't been
  # updated to set FIX_MODEL explicitly silently loses its --model flag on
  # the fix call (PR #232 review finding).
  FIX_MODEL="${FIX_MODEL:-${MODEL:-}}"
  # shellcheck disable=SC2153 # CONCERNS_FILE (env) seeds local concerns_file; not a typo
  concerns_file="$CONCERNS_FILE"

  abort_iteration() {
    # A fix or re-review failure under `set -e` would otherwise crash this
    # whole script before it writes anything to $GITHUB_OUTPUT — the
    # workflow's downstream promote/block steps key off find_pr's output
    # only, so a crash here silently skips ALL of them (no PR comment, no
    # ai:review-blocked label). Degrade instead: stop the loop, keep the
    # last known verdict, and annotate loudly so this doesn't look
    # identical to "self-fix simply wasn't configured" (#81 review
    # findings 4/5).
    printf 'self-fix-loop: %s (iteration %s) -- stopping\n' "$1" "$2" >&2
    printf '::warning::self-fix-loop: aborted due to a failed fix/review attempt (iteration %s)\n' "$2"
  }

  for (( i = 1; i <= MAX_ITERATIONS; i++ )); do
    if ! ITERATION="$i" REPO="$REPO" HEAD_REF="$HEAD_REF" AGENT="$FIX_AGENT" MODEL="$FIX_MODEL" \
         "$FIX_CMD" "$PR_NUMBER" "$concerns_file"; then
      abort_iteration "fix attempt failed" "$i"
      break
    fi
    iterations_used=$i

    if [[ -n "${NEW_HEAD_SHA:-}" ]]; then
      head_sha="$NEW_HEAD_SHA"
    elif ! head_sha="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json headRefOid --jq '.headRefOid')"; then
      abort_iteration "gh pr view failed after fix" "$i"
      break
    fi

    review_go="$(mktemp)"
    if ! GITHUB_OUTPUT="$review_go" ITERATION="$i" PR_NUMBER="$PR_NUMBER" REPO="$REPO" HEAD_SHA="$head_sha" \
         bash "$REVIEW_SCRIPT" >/dev/null; then
      abort_iteration "re-review failed" "$i"
      rm -f "$review_go"
      break
    fi
    verdict="$(grep '^verdict=' "$review_go" | tail -n1 | cut -d= -f2-)"
    new_concerns="$(grep '^summary-file=' "$review_go" | tail -n1 | cut -d= -f2-)"
    rm -f "$review_go"
    [[ -n "$new_concerns" && -r "$new_concerns" ]] && concerns_file="$new_concerns"

    if [[ "$verdict" == "approve" || "$verdict" == "block" ]]; then
      break
    fi
  done
fi

printf 'verdict=%s\n' "$verdict"
printf 'iterations-used=%s\n' "$iterations_used"
printf 'head-sha=%s\n' "$head_sha"

emit_output verdict "$verdict"
emit_output iterations-used "$iterations_used"
emit_output head-sha "$head_sha"
