#!/usr/bin/env bash
#
# self-fix-pr.sh — self-fix-loop.sh's default FIX_CMD. Checks out the PR's
# head branch, runs the agent agentically against the prior review's
# concerns (scripts/lib/self-fix-prompt.md), then commits the fix. Part of
# the review flows' self-fix pass (#81 / ADR-004 follow-up).
#
# Contract: self-fix-pr.sh <pr-number> <concerns-json-file>
#
# Required environment variables:
#   REPO        owner/repo
#   HEAD_REF    PR head branch name — checked out and pushed to
#   ITERATION   integer, used in the commit message
#   GH_TOKEN    Required unless SKIP_CLONE=1. Injected into the clone's
#               remote URL so `git push` has credentials — `gh repo clone`
#               does not write a credential.helper into the fresh clone.
#
# Optional environment variables:
#   AGENT             claude | opencode — which agent implemented the
#                     issue (needs.implement.outputs.agent). Default:
#                     claude. Selects the default FIX_AGENT_CMD wrapper
#                     (ignored when FIX_AGENT_CMD is set explicitly).
#   FIX_AGENT_CMD     Override the agent invocation entirely. Contract:
#                       $FIX_AGENT_CMD <prompt-file>
#                     Agent edits files directly in the CWD. Takes
#                     precedence over AGENT-based resolution.
#   FIX_LIB_DIR       Directory the AGENT-based default resolves wrapper
#                     scripts from. Default: <script-dir>/lib. Test seam —
#                     lets Layer-1 tests point AGENT resolution at mock
#                     wrappers without touching the real lib/ scripts.
#   MODEL             Model id passed to FIX_AGENT_CMD.
#   PROMPT_TEMPLATE   Override path to lib/self-fix-prompt.md.
#   WORK_DIR          Directory to operate in. Default: mktemp -d, removed
#                     on exit. Caller-supplied WORK_DIR is never deleted
#                     (Layer-1 tests pass it explicitly and assert against
#                     it after the script returns).
#   SKIP_CLONE        "1" to skip `gh repo clone` / `git fetch` and operate
#                     directly in WORK_DIR (already a checked-out git repo
#                     on HEAD_REF). Used by Layer-1 tests.
#   SKIP_PUSH         "1" to skip `git push` (Layer-1 tests assert the
#                     local commit instead of a network push).
#
# Exit codes:
#   0  fix committed (and pushed, unless SKIP_PUSH=1)
#   1  checkout / agent / commit / push failure, or agent made no changes
#   2  required env or args missing, or AGENT invalid
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

require_env() {
  if [[ -z "${!1:-}" ]]; then
    printf 'error: %s must be set\n' "$1" >&2
    exit 2
  fi
}

PR_NUMBER="${1:-}"
CONCERNS_FILE="${2:-}"
if [[ -z "$PR_NUMBER" || -z "$CONCERNS_FILE" ]]; then
  printf 'error: usage: self-fix-pr.sh <pr-number> <concerns-json-file>\n' >&2
  exit 2
fi

require_env REPO
require_env HEAD_REF
require_env ITERATION

AGENT="${AGENT:-claude}"
# Only validated when it actually drives wrapper resolution below -- an
# explicit FIX_AGENT_CMD bypasses AGENT entirely (per the header comment),
# so an unrelated/nonstandard AGENT value must not block a caller who
# overrode the wrapper directly.
if [[ -z "${FIX_AGENT_CMD:-}" ]]; then
  case "$AGENT" in
    claude|opencode) ;;
    *)
      printf 'error: AGENT must be one of: claude | opencode (got %q)\n' "$AGENT" >&2
      exit 2
      ;;
  esac
fi

if [[ ! -r "$CONCERNS_FILE" ]]; then
  printf 'error: concerns file not readable: %s\n' "$CONCERNS_FILE" >&2
  exit 2
fi

PROMPT_TEMPLATE="${PROMPT_TEMPLATE:-$SCRIPT_DIR/lib/self-fix-prompt.md}"
if [[ ! -r "$PROMPT_TEMPLATE" ]]; then
  printf 'error: prompt template not readable: %s\n' "$PROMPT_TEMPLATE" >&2
  exit 2
fi

WORK_DIR_SUPPLIED=1
if [[ -z "${WORK_DIR:-}" ]]; then
  WORK_DIR_SUPPLIED=0
  WORK_DIR="$(mktemp -d)"
fi
PROMPT_FILE="$(mktemp)"

if [[ "$WORK_DIR_SUPPLIED" == "0" ]]; then
  trap 'rm -rf "$WORK_DIR"' EXIT
fi

if [[ "${SKIP_CLONE:-0}" != "1" ]]; then
  gh repo clone "$REPO" "$WORK_DIR" -- --quiet
  ( cd "$WORK_DIR" && git fetch --quiet origin "$HEAD_REF" && git checkout --quiet "$HEAD_REF" )
  # `gh repo clone` does not persist push credentials into the clone's
  # .git/config (no credential.helper entry) -- without this, `git push`
  # below has no credentials on a real runner. Inject the token into the
  # remote URL instead. Never log it (no set -x, no echoing the URL).
  : "${GH_TOKEN:?GH_TOKEN must be set to push (or GITHUB_TOKEN via gh env)}"
  ( cd "$WORK_DIR" && git remote set-url origin "https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git" )
fi

concerns_md="$(jq -r '.concerns[] | "- **\(.severity)**: \(.message)"' "$CONCERNS_FILE" 2>/dev/null || true)"
[[ -z "$concerns_md" ]] && concerns_md="(no concerns listed)"

awk -v repo="$REPO" -v pr="$PR_NUMBER" -v ref="$HEAD_REF" -v concerns="$concerns_md" '
  {
    gsub(/\{\{REPO\}\}/, repo)
    gsub(/\{\{PR_NUMBER\}\}/, pr)
    gsub(/\{\{HEAD_REF\}\}/, ref)
    if (index($0, "{{CONCERNS}}")) {
      print concerns
    } else {
      print
    }
  }
' "$PROMPT_TEMPLATE" > "$PROMPT_FILE"

if [[ -z "${FIX_AGENT_CMD:-}" ]]; then
  FIX_LIB_DIR="${FIX_LIB_DIR:-$SCRIPT_DIR/lib}"
  case "$AGENT" in
    claude)   FIX_AGENT_CMD="$FIX_LIB_DIR/agent-cmd-claude-fix.sh" ;;
    opencode) FIX_AGENT_CMD="$FIX_LIB_DIR/agent-cmd-opencode-fix.sh" ;;
  esac
fi

if ! ( cd "$WORK_DIR" && "$FIX_AGENT_CMD" "$PROMPT_FILE" ); then
  printf 'error: fix agent invocation failed\n' >&2
  rm -f "$PROMPT_FILE"
  exit 1
fi
rm -f "$PROMPT_FILE"

if [[ -z "$( cd "$WORK_DIR" && git status --porcelain )" ]]; then
  printf 'error: agent made no changes -- nothing to commit\n' >&2
  exit 1
fi

( cd "$WORK_DIR" && git add -A && git -c user.name='github-actions[bot]' -c user.email='github-actions[bot]@users.noreply.github.com' commit --quiet -m "address self-review (iteration $ITERATION)" )

if [[ "${SKIP_PUSH:-0}" != "1" ]]; then
  ( cd "$WORK_DIR" && git push --quiet origin "HEAD:$HEAD_REF" )
fi

printf 'fixed=true\n'
