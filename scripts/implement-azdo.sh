#!/usr/bin/env bash
#
# implement-azdo.sh — run the implement sequence against an Azure DevOps work
# item, locally. Step 4 of #253.
#
# The GitHub path is a workflow triggered by a label. Azure DevOps has no
# equivalent trigger in this design, so this is invoked explicitly. It composes
# the same pipeline scripts the GitHub job runs, through the forge adapter.
#
# WHAT THIS DOES NOT DO, and cannot:
#
#   * No retry. retry-dispatch.sh re-dispatches via `gh workflow run`, which has
#     no Azure DevOps equivalent. A transient failure ends the run -- there is no
#     recovery and no escalate-on-retry, so the cheap-model-then-escalate
#     strategy is GitHub-only.
#   * No AI review and no auto-merge. check-merge-envelope.sh is GitHub-specific
#     reasoning about required status checks and review decisions; Azure DevOps
#     expresses those as branch policies and reviewer votes, which is a different
#     model and its own design. The run opens a draft PR and stops.
#   * No label-and-walk-away. This is the cost the issue anticipated.
#
# So the shape is: invoke -> agent implements -> draft PR opens -> a human
# reviews and merges. That is less than the GitHub path and deliberately so;
# pretending otherwise would be the expensive mistake.
#
# Required environment:
#   ISSUE_NUMBER            the work item id
#   AZURE_DEVOPS_EXT_PAT    a PAT with work-item and code scopes
#   ANTHROPIC_API_KEY       or CLAUDE_CODE_OAUTH_TOKEN, for the agent
#
# Optional:
#   DRY_RUN=1   resolve, classify and report what WOULD run; invoke no agent
#               and write nothing. Use this first on any new project.
#
# Exit codes: 0 completed; 1 error; 2 required env missing or not an ADO remote.
set -euo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/detect-forge.sh
source "$HERE/lib/detect-forge.sh"
# shellcheck source=scripts/lib/forge.sh
source "$HERE/lib/forge.sh"
# shellcheck source=scripts/lib/azdo.sh
source "$HERE/lib/azdo.sh"

: "${ISSUE_NUMBER:?ISSUE_NUMBER must be set (the work item id)}"
DRY_RUN="${DRY_RUN:-0}"

forge="$(detect_forge | awk '{print $1}')"
if [[ "$forge" != "azdo" ]]; then
  printf 'error: this entry point is for Azure DevOps remotes; detected "%s".\n' "$forge" >&2
  printf '       On GitHub, label the issue ai-implement and let the pipeline run.\n' >&2
  exit 2
fi

: "${AZURE_DEVOPS_EXT_PAT:?AZURE_DEVOPS_EXT_PAT must be set — prefer an allowed .envrc reached with direnv exec}"
resolve_azdo_context || { printf 'error: could not resolve the ADO context from origin\n' >&2; exit 2; }

printf '== implement (Azure DevOps) ==\n'
printf '   org/project/repo : %s / %s / %s\n' "$AZDO_ORG" "$AZDO_PROJECT" "$AZDO_REPO"
printf '   work item        : #%s\n' "$ISSUE_NUMBER"
printf '   retry            : unavailable on this forge\n'
printf '   review / merge   : human, after the draft PR opens\n\n'

# --- read the work item through the adapter ---------------------------------
# Fills ISSUE_LABELS / ISSUE_BODY / ISSUE_JSON / ISSUE_COMMENTS_JSON, which is
# what lets the unchanged classifiers below run on this forge at all.
REPO="${AZDO_PROJECT}/${AZDO_REPO}"   # the classifiers want it set; unused on ADO
export REPO
forge_export_issue "$ISSUE_NUMBER" || { printf 'error: could not read work item #%s\n' "$ISSUE_NUMBER" >&2; exit 1; }

printf 'tags  : %s\n' "$(printf '%s' "$ISSUE_LABELS" | tr '\n' ' ')"
printf 'title : %s\n' "$(printf '%s' "$ISSUE_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin)["title"])')"

# --- classify ---------------------------------------------------------------
# These scripts are untouched. They take their injected path because
# forge_export_issue filled the variables they already prefer.
out="$(mktemp)"; trap 'rm -f "$out"' EXIT
GITHUB_OUTPUT="$out" bash "$HERE/classify-agent.sh" >/dev/null 2>&1 || true
GITHUB_OUTPUT="$out" bash "$HERE/classify-turns.sh" >/dev/null 2>&1 || true
agent="$(sed -n 's/^agent=//p' "$out" | tail -1)"
turns="$(sed -n 's/^turns=//p' "$out" | tail -1)"
printf 'agent : %s\nturns : %s\n\n' "${agent:-claude}" "${turns:-?}"

if [[ "$DRY_RUN" == "1" ]]; then
  printf 'DRY_RUN=1 — stopping before the agent runs. Nothing was written.\n'
  exit 0
fi

# --- build the prompt -------------------------------------------------------
# build-agent-prompt takes its injected ISSUE_JSON path, so it reads the work
# item's description and comments without ever calling gh.
PROMPT_FILE="$(mktemp --suffix=.md)"
RESULT_FILE="$(mktemp --suffix=.json)"
trap 'rm -f "$out" "$PROMPT_FILE" "$RESULT_FILE"' EXIT
PROMPT_FILE="$PROMPT_FILE" PROMPT_FORGE=azdo bash "$HERE/build-agent-prompt.sh" >/dev/null

# --- run the agent ----------------------------------------------------------
# Same wrapper the GitHub job uses, same contract: AGENT_CMD <prompt> <result>.
printf 'running the agent (max %s turns)...\n\n' "${turns:-80}"
agent_rc=0
MODEL="${MODEL:-claude-sonnet-5}" MAX_TURNS="${turns:-80}" \
  bash "$HERE/lib/agent-cmd-claude.sh" "$PROMPT_FILE" "$RESULT_FILE" || agent_rc=$?

# --- classify the outcome ---------------------------------------------------
# classify-failure.sh is the one pipeline script that was already forge-agnostic.
class="$(RESULT_FILE="$RESULT_FILE" IS_ERROR=false bash "$HERE/classify-failure.sh" 2>/dev/null \
         | sed -n 's/^class=//p' | tail -1)"
printf '\noutcome: %s (agent rc=%s)\n' "${class:-unknown}" "$agent_rc"

if [[ "$agent_rc" -ne 0 || "${class:-}" == "task_failure" ]]; then
  printf '\nThe run did not succeed, and there is no retry on this forge.\n' >&2
  printf 'Re-invoke by hand once the cause is addressed.\n' >&2
  exit 1
fi

# --- open the draft PR ------------------------------------------------------
# Through the adapter, so the work item and the PR are linked -- Azure DevOps
# has no "Closes #N" convention, the --work-items association IS the link.
head_branch="$(git rev-parse --abbrev-ref HEAD)"
default_branch="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
default_branch="${default_branch:-main}"

if [[ "$head_branch" == "$default_branch" ]]; then
  printf 'error: still on %s — the agent did not branch, so there is nothing to PR.\n' "$default_branch" >&2
  exit 1
fi

pr="$(forge_pr_create_draft "$head_branch" "$default_branch" \
        "Implement #${ISSUE_NUMBER}" "Implements work item #${ISSUE_NUMBER}." \
        "$ISSUE_NUMBER")" || {
  printf 'error: could not open the draft PR\n' >&2; exit 1; }
printf 'draft PR  : #%s (work item #%s linked)\n' "$pr" "$ISSUE_NUMBER"

# --- report back onto the work item -----------------------------------------
report="$(mktemp)"
{
  printf '## implement run (local, Azure DevOps)\n\n'
  printf -- '- outcome: %s\n' "${class:-success}"
  printf -- '- agent: %s, turns budget: %s\n' "${agent:-claude}" "${turns:-80}"
  printf -- '- draft PR: !%s\n\n' "$pr"
  printf 'Retry and auto-merge are unavailable on this forge; review and merge the PR by hand.\n'
} > "$report"
forge_issue_comment "$ISSUE_NUMBER" "$report" && printf 'reported  : comment posted on #%s\n' "$ISSUE_NUMBER"
rm -f "$report"

printf '\nDone. Review and merge !%s when ready.\n' "$pr"
