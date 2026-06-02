#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# onboard-consumer.sh — wire one repo up as an agent-pipeline consumer.
#
# Idempotent. Safe to re-run; each step checks current state first. Run it
# once per repo, or loop over a list to onboard them all (see footer).
#
# Does the four CONSUMER-SETUP.md onboarding steps, all via `gh`:
#   1. Enable "Actions can create and approve pull requests"
#   2. Set the CLAUDE_CODE_OAUTH_TOKEN secret (only if missing, or FORCE_SECRET=1)
#   3. Add .github/workflows/claude.yml on a branch + open a PR (if absent)
#   4. Pre-create the lifecycle issue labels (best-effort)
#
# Token hygiene: the OAuth token is read from $CLAUDE_CODE_OAUTH_TOKEN (or a
# command in $TOKEN_CMD, e.g. a passbolt fetch) and piped straight to
# `gh secret set` — never written to a file or echoed.
#
# Env:
#   REPO              <owner>/<repo>           (required)
#   PIPELINE_REF      ref to pin               (default: main)   ← see note
#   DEFAULT_MODEL     model input              (default: claude-opus-4-7)
#   RUNNER_LABELS     JSON array               (default: '["ubuntu-latest"]')
#   CLAUDE_CODE_OAUTH_TOKEN  token value       (optional; step 2 skipped if unset
#                                               and the secret already exists)
#   TOKEN_CMD         command printing token   (optional alt. to the var above)
#   FORCE_SECRET      "1" to overwrite secret  (default: unset)
#   STUB_BRANCH       branch for the stub PR   (default: chore/onboard-agent-pipeline)
#
# Note on PIPELINE_REF: pin a post-#68 ref. `@v1` still resolves to pre-rename
# code (override mandatory, self-mod guard off) until the v1 tag is advanced.
# `main` or a recent SHA are the safe choices today.
#
# Exit codes: 0 ok · 2 usage · 3 gh not authenticated · 4 repo not found

: "${REPO:?REPO must be set to <owner>/<repo>}"
PIPELINE_REF="${PIPELINE_REF:-main}"
DEFAULT_MODEL="${DEFAULT_MODEL:-claude-opus-4-7}"
RUNNER_LABELS="${RUNNER_LABELS:-[\"ubuntu-latest\"]}"   # raw JSON array; quoted in the template
STUB_BRANCH="${STUB_BRANCH:-chore/onboard-agent-pipeline}"
WORKFLOW_PATH=".github/workflows/claude.yml"

command -v gh >/dev/null || { printf 'error: gh CLI not found\n' >&2; exit 2; }
gh auth status >/dev/null 2>&1 || { printf 'error: gh not authenticated (run `gh auth login`)\n' >&2; exit 3; }
gh repo view "$REPO" >/dev/null 2>&1 || { printf 'error: repo %s not found / no access\n' "$REPO" >&2; exit 4; }

log() { printf '[%s] %s\n' "$REPO" "$1"; }

# ── Step 1: allow Actions to create PRs ──────────────────────────────────────
log 'step 1: enabling "Actions can create and approve pull requests"'
gh api -X PUT "repos/${REPO}/actions/permissions/workflow" \
  -F can_approve_pull_request_reviews=true >/dev/null
log '  ✓ enabled'

# ── Step 2: CLAUDE_CODE_OAUTH_TOKEN secret ───────────────────────────────────
secret_exists() {
  gh secret list -R "$REPO" --json name --jq '.[].name' 2>/dev/null \
    | grep -qx 'CLAUDE_CODE_OAUTH_TOKEN'
}
set_secret() {
  local token="$1"
  printf '%s' "$token" | gh secret set CLAUDE_CODE_OAUTH_TOKEN -R "$REPO"
}
resolve_token() {
  if [[ -n "${TOKEN_CMD:-}" ]]; then
    bash -c "$TOKEN_CMD"
  elif [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
    printf '%s' "$CLAUDE_CODE_OAUTH_TOKEN"
  fi
}
if secret_exists && [[ "${FORCE_SECRET:-}" != "1" ]]; then
  log 'step 2: CLAUDE_CODE_OAUTH_TOKEN already set — skipping (FORCE_SECRET=1 to overwrite)'
else
  token="$(resolve_token || true)"
  if [[ -z "${token:-}" ]]; then
    log 'step 2: ⚠ no token in $CLAUDE_CODE_OAUTH_TOKEN / $TOKEN_CMD and secret missing — set it manually:'
    log "        gh secret set CLAUDE_CODE_OAUTH_TOKEN -R ${REPO}"
  else
    set_secret "$token"
    unset token
    log '  ✓ secret set'
  fi
fi

# ── Step 3: consumer stub PR ─────────────────────────────────────────────────
if gh api "repos/${REPO}/contents/${WORKFLOW_PATH}" >/dev/null 2>&1; then
  log "step 3: ${WORKFLOW_PATH} already present — skipping stub PR"
else
  log "step 3: creating ${WORKFLOW_PATH} on ${STUB_BRANCH} and opening a PR"
  default_branch="$(gh repo view "$REPO" --json defaultBranchRef --jq .defaultBranchRef.name)"
  base_sha="$(gh api "repos/${REPO}/git/refs/heads/${default_branch}" --jq .object.sha)"

  # Create the branch (ignore "already exists").
  gh api -X POST "repos/${REPO}/git/refs" \
    -f ref="refs/heads/${STUB_BRANCH}" -f sha="$base_sha" >/dev/null 2>&1 || true

  stub="$(cat <<YAML
name: Claude
on:
  issues:
    types: [labeled]
  workflow_dispatch:
    inputs:
      issue-number:
        description: Issue to implement
        type: number
        required: true

permissions:
  contents: write
  pull-requests: write
  issues: write

jobs:
  claude:
    if: >-
      (github.event_name == 'issues' && github.event.label.name == 'ai-implement')
      || github.event_name == 'workflow_dispatch'
    uses: freaxnx01/agent-pipeline/.github/workflows/claude-implement.yml@${PIPELINE_REF}
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: \${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
    with:
      issue-number: \${{ github.event.issue.number || inputs.issue-number }}
      runner-labels: '${RUNNER_LABELS}'
      default-model: ${DEFAULT_MODEL}
      pipeline-repo: freaxnx01/agent-pipeline
      pipeline-ref: ${PIPELINE_REF}
YAML
)"

  gh api -X PUT "repos/${REPO}/contents/${WORKFLOW_PATH}" \
    -f message="ci: onboard agent-pipeline consumer stub" \
    -f branch="$STUB_BRANCH" \
    -f content="$(printf '%s' "$stub" | base64 -w0 2>/dev/null || printf '%s' "$stub" | base64)" \
    >/dev/null

  gh pr create -R "$REPO" \
    --base "$default_branch" --head "$STUB_BRANCH" \
    --title "ci: onboard agent-pipeline consumer stub" \
    --body "Adds the labeled-issue → draft-PR pipeline stub (pinned \`@${PIPELINE_REF}\`).

After merge: create an issue and label it \`ai-implement\` to trigger a run.
Enable auto-merge later per agent-pipeline docs/CONSUMER-SETUP.md §2." \
    >/dev/null
  log "  ✓ stub PR opened against ${default_branch}"
fi

# ── Step 4: lifecycle labels (best-effort) ───────────────────────────────────
log 'step 4: ensuring lifecycle labels (best-effort)'
for spec in \
  "ai-implement:1d76db:pipeline: implement this issue" \
  "ai:running:fbca04:pipeline run in progress" \
  "ai:done:0e8a16:pipeline run succeeded" \
  "ai:failed:b60205:pipeline run failed"; do
  name="${spec%%:*}"; rest="${spec#*:}"; color="${rest%%:*}"; desc="${rest#*:}"
  gh label create "$name" -R "$REPO" --color "$color" --description "$desc" >/dev/null 2>&1 \
    || gh label edit "$name" -R "$REPO" --color "$color" --description "$desc" >/dev/null 2>&1 \
    || true
done
log '  ✓ labels ensured'

log 'done.'
