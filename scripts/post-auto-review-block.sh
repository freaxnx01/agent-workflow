#!/usr/bin/env bash
#
# post-auto-review-block.sh — Surface that a review path refused
# to promote the PR and stamp the originating issue with
# `ai:review-blocked`. Called from the `ai_review_ai_merge` job in
# agent-implement.yml on every refusal path:
#
#   - self-modification guard fired (ADR-002 §"Self-modification")
#   - find-pipeline-pr.sh produced no allowlisted pipeline-opened PR
#   - review verdict != approve
#   - review verdict = approve but check-merge-envelope.sh returned fail
#
# Required environment variables:
#   REPO              owner/repo
#   ISSUE_NUMBER      Originating issue
#   GH_TOKEN          (or ambient gh auth)
#
# Optional environment variables (mostly the workflow's step outputs):
#   PR_NUMBER         If known, the refusal comment goes on the PR.
#                     Empty → comment on the issue instead.
#   SELF_MOD_BLOCKED  "true" iff the self-mod guard refused.
#   FOUND             "true" iff find-pipeline-pr.sh located a PR.
#   VERDICT           Review verdict (empty if review step was skipped).
#   ENVELOPE          Envelope outcome (empty if envelope step was skipped).
#   ENVELOPE_REASON   Human reason from check-merge-envelope.sh.
#   FAILED_GATES      Comma-separated gate IDs from check-merge-envelope.sh.
#   MODE              Operational mode (default: ai-merge).
#                     "human-merge" switches the comment prefix to "Review held"
#                     instead of "Auto-merge held" / "Auto-review held".
#   SELF_FIX_ITERATIONS  Iterations the self-fix loop actually used (#81).
#                        "0" or unset → unchanged wording.
#   SELF_FIX_MAX         The self-fix iteration cap, for the "exhausted"
#                        wording. Only read when SELF_FIX_ITERATIONS != "0".
#   REVIEW_REASON     review-pr.sh's reason output; used for the comment when
#                     VERDICT=review_failed and no self-fix ran (#490).
#   SELF_FIX_OUTCOME     The self-fix step's outcome (#474). "failure" means it
#                        timed out or crashed — the step is continue-on-error
#                        so this script still runs — and the reason says so.
#
# Exit codes:
#   0  success (refusal surfaced)
#   2  required env missing
set -euo pipefail
IFS=$'\n\t'

for var in REPO ISSUE_NUMBER; do
  if [[ -z "${!var:-}" ]]; then
    printf 'error: %s must be set\n' "$var" >&2
    exit 2
  fi
done

PR_NUMBER="${PR_NUMBER:-}"
SELF_MOD_BLOCKED="${SELF_MOD_BLOCKED:-false}"
FOUND="${FOUND:-false}"
VERDICT="${VERDICT:-}"
ENVELOPE="${ENVELOPE:-}"
ENVELOPE_REASON="${ENVELOPE_REASON:-}"
FAILED_GATES="${FAILED_GATES:-}"
SELF_FIX_ITERATIONS="${SELF_FIX_ITERATIONS:-0}"
SELF_FIX_MAX="${SELF_FIX_MAX:-}"
SELF_FIX_OUTCOME="${SELF_FIX_OUTCOME:-}"
MODE="${MODE:-ai-merge}"
REVIEW_REASON="${REVIEW_REASON:-}"

# Comment-prefix wording differs by mode; reason text is identical.
case "$MODE" in
  human-merge)
    pr_prefix='Review held'
    issue_prefix='Review held'
    ;;
  *)
    pr_prefix='Auto-merge held'
    issue_prefix='Auto-review held'
    ;;
esac

if [[ "$SELF_MOD_BLOCKED" == 'true' ]]; then
  reason='self-modification guard (ADR-002) refused promotion on agent-workflow itself'
elif [[ "$FOUND" != 'true' ]]; then
  reason='the review job could not find a pipeline-opened draft PR for this issue (expected "Closes #N" in PR body from an allowlisted author)'
elif [[ "$VERDICT" != 'approve' ]]; then
  if [[ "$SELF_FIX_ITERATIONS" != '0' ]]; then
    reason="self-fix exhausted after ${SELF_FIX_ITERATIONS}/${SELF_FIX_MAX} iteration(s) — last verdict: ${VERDICT:-<none>}"
  elif [[ "$VERDICT" == 'review_failed' ]]; then
    reason="review could not complete — ${REVIEW_REASON:-no usable verdict from the reviewer}"
  else
    reason="agent review verdict: ${VERDICT:-<none>} (gate 4)"
  fi
else
  gate_note=''
  [[ -n "$FAILED_GATES" ]] && gate_note=" (failed gates: $FAILED_GATES)"
  reason="merge-envelope failed: ${ENVELOPE_REASON:-unknown}${gate_note}"
fi

# #474: without this, a self-fix cut off by its timeout left the run a bare
# `cancelled` with no reason on the issue or PR.
if [[ "$SELF_FIX_OUTCOME" == 'failure' ]]; then
  reason="$reason; self-fix did not finish (timed out or crashed) — see the run"
fi

printf 'review: %s\n' "$reason"

if [[ -n "$PR_NUMBER" ]]; then
  gh pr comment "$PR_NUMBER" --repo "$REPO" \
    --body "$pr_prefix: $reason. PR stays draft for human review."
else
  gh issue comment "$ISSUE_NUMBER" --repo "$REPO" \
    --body "$issue_prefix: $reason."
fi

# Label the issue so a watcher can filter for review-blocked work.
# #490: a review that produced no usable verdict is a different signal from a
# refusal, so it gets its own label — but only when that is why we are here
# (self-mod guard and no-PR keep ai:review-blocked).
label='ai:review-blocked'
label_desc='Auto-review left the PR draft; human action required'
if [[ "$SELF_MOD_BLOCKED" != 'true' && "$FOUND" == 'true' && "$VERDICT" == 'review_failed' ]]; then
  label='ai:review-failed'
  label_desc='Review could not run to a verdict; human look needed'
fi

# ensure-issue-labels.sh runs earlier in the implement job under
# `always() && !dry-run`, so the label usually exists by the time we
# get here. Belt-and-suspenders: idempotently create it first so a
# manually-deleted label, or a future refactor that splits implement
# and ai_review_ai_merge across separate workflows, doesn't break the
# `--add-label` call.
gh label create "$label" --repo "$REPO" --color D73A4A \
  --description "$label_desc" \
  >/dev/null 2>&1 || true
gh issue edit "$ISSUE_NUMBER" --repo "$REPO" --add-label "$label"
