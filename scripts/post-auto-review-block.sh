#!/usr/bin/env bash
#
# post-auto-review-block.sh — Surface that the auto-review path refused
# to promote the PR and stamp the originating issue with
# `ai:review-blocked`. Called from the `auto_review` job in
# claude-implement.yml on every refusal path:
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

if [[ "$SELF_MOD_BLOCKED" == 'true' ]]; then
  reason='self-modification guard (ADR-002) refused promotion on agent-pipeline itself'
elif [[ "$FOUND" != 'true' ]]; then
  reason='auto-review could not find a pipeline-opened draft PR for this issue (expected "Closes #N" in PR body from an allowlisted author)'
elif [[ "$VERDICT" != 'approve' ]]; then
  reason="agent review verdict: ${VERDICT:-<none>} (gate 4)"
else
  gate_note=''
  [[ -n "$FAILED_GATES" ]] && gate_note=" (failed gates: $FAILED_GATES)"
  reason="merge-envelope failed: ${ENVELOPE_REASON:-unknown}${gate_note}"
fi

printf 'auto-review: %s\n' "$reason"

if [[ -n "$PR_NUMBER" ]]; then
  gh pr comment "$PR_NUMBER" --repo "$REPO" \
    --body "Auto-merge held: $reason. PR stays draft for human review."
else
  gh issue comment "$ISSUE_NUMBER" --repo "$REPO" \
    --body "Auto-review held: $reason."
fi

# Label the issue so a watcher can filter for review-blocked work.
# ensure-issue-labels.sh runs earlier in the implement job under
# `always() && !dry-run`, so the label usually exists by the time we
# get here. Belt-and-suspenders: idempotently create it first so a
# manually-deleted label, or a future refactor that splits implement
# and auto_review across separate workflows, doesn't break the
# `--add-label` call.
gh label create ai:review-blocked --repo "$REPO" --color D73A4A \
  --description 'Auto-review left the PR draft; human action required' \
  >/dev/null 2>&1 || true
gh issue edit "$ISSUE_NUMBER" --repo "$REPO" --add-label ai:review-blocked
