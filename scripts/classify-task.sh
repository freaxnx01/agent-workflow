#!/usr/bin/env bash
#
# classify-task.sh — Pick the model for an issue. Three-stage decision:
#
#   1. Explicit override via `model:<name>` label on the issue. This
#      always wins. Supported labels:
#        Claude:     model:opus / model:sonnet / model:haiku
#        OpenRouter: model:mistral-large / model:codestral /
#                    model:deepseek-v3 / model:qwen-coder /
#                    model:gemini-flash / model:deepseek-r1 /
#                    model:llama-4-maverick / model:qwen3-coder /
#                    model:glm / model:glm-flash /
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
#      The keyword escalation targets (claude-opus-5 / claude-haiku-4-5)
#      are Claude-family model ids, so escalation only fires when
#      `AGENT == claude`; any other agent stays on DEFAULT_MODEL
#      (escalating would hand e.g. opencode/OpenRouter an unresolvable
#      model id and fail the run at zero tokens). Use an explicit
#      `model:*` override label to pick a specific OpenRouter model.
#   3. Cost guard (`lib/blocked-models.sh`) over the routes where nobody
#      decided per issue: DEFAULT_MODEL and ESCALATE_MODEL are checked as
#      they are read, and the resolved model is checked again on a retry
#      (ATTEMPT > 1). An explicit `model:*` label on attempt 1 is never
#      second-guessed — a human chose that one issue's model, which is what
#      `model:fable` is for (#330). The heuristic never picks a guarded
#      model on its own.
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
#   ATTEMPT        1-based attempt number for this issue (same value
#                  classify-agent.sh reads). Default 1. From attempt 2 the
#                  cost guard also applies to a model an explicit label
#                  chose: the first Fable attempt was a decision, the
#                  automatic repeat is not.
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

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/blocked-models.sh disable=SC1091  # hook runs without -x; SC1091 is conventionally suppressed
source "$HERE/lib/blocked-models.sh"

require_env ISSUE_NUMBER
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
if [[ -z "$REPO" ]]; then
  printf 'error: REPO or GITHUB_REPOSITORY must be set\n' >&2
  exit 2
fi

DEFAULT_MODEL="${DEFAULT_MODEL:-claude-sonnet-5}"
AGENT="${AGENT:-claude}"
ESCALATE_MODEL="${ESCALATE_MODEL:-claude-sonnet-5}"
ATTEMPT="${ATTEMPT:-1}"

# Cost guard on the repo-level knobs. Neither carries a per-issue decision —
# they are whatever a consumer's agent.yml says for every issue it dispatches —
# and the `claude-*` prefix test below would wave a Fable id straight through,
# since it only separates Claude ids from OpenRouter ids. Checked here rather
# than at the end so an explicit `model:*` label stays untouched.
ESCALATE_MODEL="$(allowed_model_or_fallback "$ESCALATE_MODEL")"
DEFAULT_MODEL="$(allowed_model_or_fallback "$DEFAULT_MODEL" "$ESCALATE_MODEL")"

# A repo whose default-model is an OpenRouter id (the fleet default is
# z-ai/glm-5.2) still resolves to AGENT=claude whenever a retry escalates, or
# when OPENROUTER_API_KEY is unavailable. Handing an OpenRouter id to the Claude
# CLI is fatal, so the Claude path substitutes the Claude-family escalation
# model. Claude model ids are exactly those starting `claude-`.
if [[ "$AGENT" == "claude" && "$DEFAULT_MODEL" != claude-* ]]; then
  printf 'note: DEFAULT_MODEL %q is not a Claude model; using %q on the claude agent\n' \
    "$DEFAULT_MODEL" "$ESCALATE_MODEL" >&2
  DEFAULT_MODEL="$ESCALATE_MODEL"
fi

# The mirror case: OpenRouter cannot resolve a Claude id. A consumer that pinned
# only `default-model` and inherited the flipped `agent: opencode` default would
# otherwise fail every run.
OPENROUTER_FALLBACK_MODEL="${OPENROUTER_FALLBACK_MODEL:-z-ai/glm-5.2}"
if [[ "$AGENT" != "claude" && "$DEFAULT_MODEL" == claude-* ]]; then
  printf 'note: DEFAULT_MODEL %q is a Claude model; using %q on the %s agent\n' \
    "$DEFAULT_MODEL" "$OPENROUTER_FALLBACK_MODEL" "$AGENT" >&2
  DEFAULT_MODEL="$OPENROUTER_FALLBACK_MODEL"
fi

# --- 1) explicit override label -------------------------------------------

# `+x` tests whether the variable is SET, not whether it is non-empty.
# An issue with no labels -- or an Azure DevOps work item with no tags or
# description -- yields an empty but injected value, and `-z` would treat
# that as "not injected" and fall back to a forge call. On GitHub that is a
# wasted round trip; on a forge gh cannot reach it is fatal. See #253.
if [[ -z "${ISSUE_LABELS+x}" ]]; then
  ISSUE_LABELS="$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json labels --jq '.labels[].name')"
fi

# Per-label compatibility: Claude labels run on `agent=claude`,
# Mistral labels run on `agent=opencode`. A mismatch warns + falls
# through (ADR-001 puts compatibility enforcement at the agent step,
# not here).
label_is_compatible() {
  local label="$1"
  case "$label" in
    model:opus|model:sonnet|model:haiku|model:fable)
      [[ "$AGENT" == "claude" ]]
      ;;
    model:mistral-large|model:codestral|model:deepseek-v3|model:qwen-coder|model:gemini-flash|model:deepseek-r1|model:llama-4-maverick|model:qwen3-coder|model:glm|model:glm-flash|model:minimax-m2|model:deepseek-v32|model:qwen3-27b)
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
    model:opus|model:sonnet|model:haiku|model:fable|model:mistral-large|model:codestral|model:deepseek-v3|model:qwen-coder|model:gemini-flash|model:deepseek-r1|model:llama-4-maverick|model:qwen3-coder|model:glm|model:glm-flash|model:minimax-m2|model:deepseek-v32|model:qwen3-27b)
      if ! label_is_compatible "$label"; then
        printf 'warn: label %s incompatible with AGENT=%s; falling through to default\n' \
          "$label" "$AGENT" >&2
        continue
      fi
      ;;
  esac
  # Retired models: recognised so the operator gets a reason, never selected.
  # gpt-oss-120b shipped 2 of 10 runs across the fleet — the worst measured
  # rate of any model with a real sample. See docs/model-comparison.md.
  if [[ "$label" == "model:gpt-oss-120b" ]]; then
    printf 'warn: label %s names a retired model (2/10 successful runs measured); falling through to default\n' \
      "$label" >&2
    continue
  fi

  case "$label" in
    model:opus)           chosen=claude-opus-5;                 reason='label model:opus' ;;
    model:sonnet)         chosen=claude-sonnet-5;                 reason='label model:sonnet' ;;
    model:haiku)          chosen=claude-haiku-4-5;                reason='label model:haiku' ;;
    model:fable)          chosen=claude-fable-5-1;                reason='label model:fable' ;;
    model:mistral-large)  chosen=mistralai/mistral-large;          reason='label model:mistral-large' ;;
    model:codestral)      chosen=mistralai/codestral-2508;         reason='label model:codestral' ;;
    model:deepseek-v3)    chosen=deepseek/deepseek-chat-v3-0324;   reason='label model:deepseek-v3' ;;
    model:qwen-coder)     chosen=qwen/qwen-2.5-coder-32b-instruct; reason='label model:qwen-coder' ;;
    model:gemini-flash)   chosen=google/gemini-2.5-flash;          reason='label model:gemini-flash' ;;
    model:deepseek-r1)    chosen=deepseek/deepseek-r1-0528;        reason='label model:deepseek-r1' ;;
    model:llama-4-maverick) chosen=meta-llama/llama-4-maverick;    reason='label model:llama-4-maverick' ;;
    model:qwen3-coder)    chosen=qwen/qwen3-coder-30b-a3b-instruct; reason='label model:qwen3-coder' ;;
    model:glm)            chosen=z-ai/glm-5.2;                     reason='label model:glm' ;;
    model:glm-flash)      chosen=z-ai/glm-4.7-flash;               reason='label model:glm-flash' ;;
    model:minimax-m2)     chosen=minimax/minimax-m2.5;             reason='label model:minimax-m2' ;;
    model:deepseek-v32)   chosen=deepseek/deepseek-v3.2;           reason='label model:deepseek-v32' ;;
    model:qwen3-27b)      chosen=qwen/qwen3.6-27b;                  reason='label model:qwen3-27b' ;;
    # Anything else shaped like a model label is a typo (model:opsu) or a
    # model this pipeline does not offer. Warn rather than fall through
    # silently — a silent fall-through is indistinguishable from a label that
    # worked, which is the failure shape #330 removed for model:fable.
    model:*)
      printf 'warn: %s is not a recognised model label; falling through to default\n' \
        "$label" >&2
      ;;
  esac
done <<< "$ISSUE_LABELS"

# --- 2) heuristic over title+body -----------------------------------------

if [[ -z "$chosen" ]]; then
  # `+x` tests whether the variable is SET, not whether it is non-empty.
  # An issue with no labels -- or an Azure DevOps work item with no tags or
  # description -- yields an empty but injected value, and `-z` would treat
  # that as "not injected" and fall back to a forge call. On GitHub that is a
  # wasted round trip; on a forge gh cannot reach it is fatal. See #253.
  if [[ -z "${ISSUE_BODY+x}" ]]; then
    ISSUE_BODY="$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json title,body --jq '.title + "\n" + .body')"
  fi

  # The two escalation targets below (claude-opus-5 / claude-haiku-4-5) are
  # Claude-family model ids with no established OpenRouter equivalent. On a
  # non-Claude agent they're not just wrong, they're fatal: opencode dies at
  # zero tokens trying to resolve them via OpenRouter. Only AGENT=claude may
  # escalate off keywords; every other agent stays on DEFAULT_MODEL, same as
  # the no-match branch. An explicit `model:*` override label (section 1
  # above) is still the way to pick a specific OpenRouter model.
  if [[ "$AGENT" != "claude" ]]; then
    chosen="$DEFAULT_MODEL"
    reason="heuristic: default (AGENT=$AGENT, keyword escalation is claude-only)"
  elif printf '%s' "$ISSUE_BODY" | grep -qiE 'refactor|redesign|architecture|migrat[ei]|complex|cross-cutting'; then
    chosen=claude-opus-5
    reason='heuristic: refactor/architecture keywords'
  elif printf '%s' "$ISSUE_BODY" | grep -qiE 'typo|spelling|grammar|wording|rename|comment-only'; then
    chosen=claude-haiku-4-5
    reason='heuristic: trivial-edit keywords'
  else
    chosen="$DEFAULT_MODEL"
    reason='heuristic: default'
  fi
fi

# --- 3) cost guard on a retry ----------------------------------------------
#
# Attempt 1 runs whatever was chosen, label included — `model:fable` means a
# human judged this issue design-shaped and that judgement stands. A retry is
# not a second decision, though: it is the pipeline spending again on its own,
# and a guarded model is guarded precisely because an unattended repeat is
# what hurts. So from attempt 2 the guard also applies to a label's choice.
#
# Unconditional, unlike classify-agent.sh's ESCALATE_ON_RETRY: turning off
# agent escalation is a preference about which agent retries, not consent to
# spend a second Fable budget.
#
# Guarding here also keeps the blocked id out of $GITHUB_OUTPUT, so the run
# report shows what actually ran.
if (( ATTEMPT > 1 )) && model_is_blocked "$chosen"; then
  # Warn here rather than via allowed_model_or_fallback: its message points at
  # the `model:*` label as the deliberate route, which is wrong advice on this
  # path — the label was used, and the repeat is what the guard objects to.
  printf 'warn: attempt %s will not spend %q a second time; using %q\n' \
    "$ATTEMPT" "$chosen" "$ESCALATE_MODEL" >&2
  printf '::warning::attempt %s does not repeat %s; using %s instead\n' \
    "$ATTEMPT" "$chosen" "$ESCALATE_MODEL"
  reason="$reason, not repeated on attempt $ATTEMPT"
  chosen="$ESCALATE_MODEL"
fi

printf 'chosen: %s (%s)\n' "$chosen" "$reason"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'model=%s\n'  "$chosen" >> "$GITHUB_OUTPUT"
  printf 'reason=%s\n' "$reason" >> "$GITHUB_OUTPUT"
fi
