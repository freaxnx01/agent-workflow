#!/usr/bin/env bash
#
# post-runner-block.sh — Surface that the review never STARTED because the
# runner's toolchain is unmet, and stamp the issue with `ai:runner-blocked`.
#
# This is the sibling of post-auto-review-block.sh, and the distinction is the
# point (#384): `ai:review-blocked` means the reviewer ran and refused to
# promote; `ai:runner-blocked` means the reviewer never got to run. Before this
# existed the second case posted nothing at all — the job aborted and the
# "Mark issue blocked" step, which inherits the default `success()`, never
# fired. From the issue the two were indistinguishable.
#
# Required environment variables:
#   REPO          owner/repo
#   ISSUE_NUMBER  Originating issue
#
# Optional environment variables:
#   PR_NUMBER   If known, the comment goes on the PR; else on the issue.
#   EXIT_CODE   install-claude-cli.sh's exit code, used to pick the reason.
#   JOB_NAME    Job that failed, for the comment. Default: "review".
#   GH_TOKEN    (or ambient gh auth)
#
# Exit codes:
#   0  failure surfaced
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
EXIT_CODE="${EXIT_CODE:-}"
JOB_NAME="${JOB_NAME:-review}"

# Map the installer's documented exit codes to a human reason. An unrecognised
# or absent code gets the generic line rather than a wrong specific one.
case "$EXIT_CODE" in
  64) reason='a required tool is not present on this runner' ;;
  65) reason='the installer checksum did not match the pinned value, so it was not executed' ;;
  66) reason='the installer ran but no claude binary was found afterwards' ;;
  *)  reason='the Claude Code CLI could not be installed' ;;
esac

# The doc is referenced as a plain path, NOT a relative markdown link: this
# comment renders in the CONSUMER repo, where a relative link would resolve
# against the wrong tree.
body="$(cat <<BLOCKED_MD
**Review did not run** — the ${JOB_NAME} job could not start.

Reason: ${reason}.

This is a runner-toolchain problem, not a review verdict: the reviewer never
examined the code, so nothing here says anything about the change itself.
See \`docs/RUNNER-REQUIREMENTS.md\` in the agent-workflow repo for the toolchain
contract, and the job log for the named diagnostic.
BLOCKED_MD
)"

if [[ -n "$PR_NUMBER" ]]; then
  gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$body"
else
  gh issue comment "$ISSUE_NUMBER" --repo "$REPO" --body "$body"
fi

# Label the issue so a watcher — and the autopilot lane — can route this to an
# operator rather than to a re-review. Created idempotently first, mirroring
# post-auto-review-block.sh: ensure-issue-labels.sh usually got there already,
# but a manually-deleted label must not break the --add-label call.
gh label create ai:runner-blocked --repo "$REPO" --color D73A4A \
  --description 'Review never started — runner toolchain unmet' \
  >/dev/null 2>&1 || true
gh issue edit "$ISSUE_NUMBER" --repo "$REPO" --add-label ai:runner-blocked
