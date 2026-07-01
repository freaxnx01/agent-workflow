#!/usr/bin/env bash
#
# classify-task.sh — Pick the model for an issue. Two-stage decision:
#
#   1. Explicit override via `model:<name>` label on the issue. This
#      always wins. Supported labels:
#        Claude:     model:opus / model:sonnet / model:haiku
#        OpenRouter: model:mistral-large / model:codestral /
#                    model:deepseek-v3 / model:qwen-coder /
#                    model:gemini-flash / model:deepseek-r1 /
#                    model:llama-4-maverick / model:qwen3-coder /
#                    model:gpt-oss-120b / model:glm-flash /
#                    model:minimax-m2 / model:deepseek-v32 /
#                    model:qwen3-27b
#      OpenRouter labels are only meaningful when `agent: opencode` runs;
#      if `AGENT != opencode` the script WARNS to stderr and falls
#      back to DEFAULT_MODEL (does not exit non-zero — per ADR-001
#      the agent step is what enforces auth/model compatibility).
#   2. Heuristic over the issue body — keyword-based for now. The
#      DESIGN target is a Haiku-powered classifier; that's a future
#      swap-in. Until then the heuristic + the override label are
#      good enough and cost nothing to run.
#
# Required environment variables:
#   ISSUE_NUMBER  GitHub issue number
#   REPO          owner/repo (default: $GITHUB_REPOSITORY)
#   GH_TOKEN      (or ambient gh auth)
#
# Optional environment variables:
#   DEFAULT_MODEL  Fallback when no override + no heuristic match.
#                  Default: claude-sonnet-5.
#   AGENT          `claude | opencode`. Used only to validate that a
#                  Mistral-flavored override label is compatible with
#                  the active agent. Default: claude.
#   ISSUE_LABELS   Newline- or space-separated labels. If set, skips the
#                  `gh issue view --json labels` call. Used by Layer-1 tests.
#   ISSUE_BODY     Free-form issue title+body string. If set, skips the
#                  `gh issue view --json title,body` call. Used by Layer-1 tests.
#
# Output:
#   Writes `model=<chosen>` and `reason=<text>` to $GITHUB_OUTPUT when set,
#   and prints a one-line `chosen: <model> (<reason>)` summary to stdout.
#
# Exit codes:
#   0  success
#   2  required env missing
set -euo pipefail
IFS=$'\n\t'

require_env() {
  if [[ -z "${!1:-}" ]]; then
    printf 'error: %s must be set\n' "$1" >&2
    exit 2
  fi
}

require_env ISSUE_NUMBER
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
if [[ -z "$REPO" ]]; then
  printf 'error: REPO or GITHUB_REPOSITORY must be set\n' >&2
  exit 2
fi

DEFAULT_MODEL="${DEFAULT_MODEL:-claude-sonnet-5}"
AGENT="${AGENT:-claude}"

# --- 1) explicit override label -------------------------------------------

if [[ -z "${ISSUE_LABELS:-}" ]]; then
  ISSUE_LABELS="$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json labels --jq '.labels[].name')"
fi

# Per-label compatibility: Claude labels run on `agent=claude`,
# Mistral labels run on `agent=opencode`. A mismatch warns + falls
# through (ADR-001 puts compatibility enforcement at the agent step,
# not here).
label_is_compatible() {
  local label="$1"
  case "$label" in
    model:opus|model:sonnet|model:haiku)
      [[ "$AGENT" == "claude" ]]
      ;;
    model:mistral-large|model:codestral|model:deepseek-v3|model:qwen-coder|model:gemini-flash|model:deepseek-r1|model:llama-4-maverick|model:qwen3-coder|model:gpt-oss-120b|model:glm-flash|model:minimax-m2|model:deepseek-v32|model:qwen3-27b)
      [[ "$AGENT" == "opencode" ]]
      ;;
    *)
      return 0
      ;;
  esac
}

chosen=''
reason=''
while IFS= read -r label; do
  case "$label" in
    model:opus|model:sonnet|model:haiku|model:mistral-large|model:codestral|model:deepseek-v3|model:qwen-coder|model:gemini-flash|model:deepseek-r1|model:llama-4-maverick|model:qwen3-coder|model:gpt-oss-120b|model:glm-flash|model:minimax-m2|model:deepseek-v32|model:qwen3-27b)
      if ! label_is_compatible "$label"; then
        printf 'warn: label %s incompatible with AGENT=%s; falling through to default\n' \
          "$label" "$AGENT" >&2
        continue
      fi
      ;;
  esac
  case "$label" in
    model:opus)           chosen=claude-opus-4-7;                 reason='label model:opus' ;;
    model:sonnet)         chosen=claude-sonnet-5;                 reason='label model:sonnet' ;;
    model:haiku)          chosen=claude-haiku-4-5;                reason='label model:haiku' ;;
    model:mistral-large)  chosen=mistralai/mistral-large;          reason='label model:mistral-large' ;;
    model:codestral)      chosen=mistralai/codestral-2508;         reason='label model:codestral' ;;
    model:deepseek-v3)    chosen=deepseek/deepseek-chat-v3-0324;   reason='label model:deepseek-v3' ;;
    model:qwen-coder)     chosen=qwen/qwen-2.5-coder-32b-instruct; reason='label model:qwen-coder' ;;
    model:gemini-flash)   chosen=google/gemini-2.5-flash;          reason='label model:gemini-flash' ;;
    model:deepseek-r1)    chosen=deepseek/deepseek-r1-0528;        reason='label model:deepseek-r1' ;;
    model:llama-4-maverick) chosen=meta-llama/llama-4-maverick;    reason='label model:llama-4-maverick' ;;
    model:qwen3-coder)    chosen=qwen/qwen3-coder-30b-a3b-instruct; reason='label model:qwen3-coder' ;;
    model:gpt-oss-120b)   chosen=openai/gpt-oss-120b;              reason='label model:gpt-oss-120b' ;;
    model:glm-flash)      chosen=z-ai/glm-4.7-flash;               reason='label model:glm-flash' ;;
    model:minimax-m2)     chosen=minimax/minimax-m2.5;             reason='label model:minimax-m2' ;;
    model:deepseek-v32)   chosen=deepseek/deepseek-v3.2;           reason='label model:deepseek-v32' ;;
    model:qwen3-27b)      chosen=qwen/qwen3.6-27b;                  reason='label model:qwen3-27b' ;;
  esac
done <<< "$ISSUE_LABELS"

# --- 2) heuristic over title+body -----------------------------------------

if [[ -z "$chosen" ]]; then
  if [[ -z "${ISSUE_BODY:-}" ]]; then
    ISSUE_BODY="$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json title,body --jq '.title + "\n" + .body')"
  fi

  if   printf '%s' "$ISSUE_BODY" | grep -qiE 'refactor|redesign|architecture|migrat[ei]|complex|cross-cutting'; then
    chosen=claude-opus-4-7
    reason='heuristic: refactor/architecture keywords'
  elif printf '%s' "$ISSUE_BODY" | grep -qiE 'typo|spelling|grammar|wording|rename|comment-only'; then
    chosen=claude-haiku-4-5
    reason='heuristic: trivial-edit keywords'
  else
    chosen="$DEFAULT_MODEL"
    reason='heuristic: default'
  fi
fi

printf 'chosen: %s (%s)\n' "$chosen" "$reason"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'model=%s\n'  "$chosen" >> "$GITHUB_OUTPUT"
  printf 'reason=%s\n' "$reason" >> "$GITHUB_OUTPUT"
fi
