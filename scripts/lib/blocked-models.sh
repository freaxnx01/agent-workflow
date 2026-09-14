#!/usr/bin/env bash
#
# blocked-models.sh — models the pipeline may not reach for automatically.
#
# This is a cost guard, not a ban. Fable is the case it exists for: it is the
# right model for design-shaped work (see `model:fable` in classify-task.sh,
# added by #330) and the wrong one to arrive by accident, because its
# per-token cost and rate limit are both high enough that an unattended repeat
# hurts.
#
# So the rule is *who chose it*, not *which model it is*:
#
#   allowed  — an explicit `model:fable` label on the issue. A human decided
#              this one issue is design-shaped; that is the whole point of #330.
#   blocked  — every route where nobody decided per-issue:
#                · `default-model` / `escalate-model` in a consumer's agent.yml,
#                  which the `claude-*` prefix test in classify-task.sh waves
#                  through (it only separates Claude ids from OpenRouter ids)
#                · `review-model`, which drives review and the self-fix loop
#                · a retry (attempt 2+) of a deliberate Fable run — the first
#                  attempt was chosen, the repeat is not
#
# The keyword heuristic never picks Fable on its own and never did (#330).
#
# Sourced, not executed:
#   source "$(dirname "${BASH_SOURCE[0]}")/blocked-models.sh"
#
# Guarded call sites (each one is a route with no per-issue decision behind it):
#   scripts/classify-task.sh          — DEFAULT_MODEL / ESCALATE_MODEL, and the
#                                       resolved model on a retry
#   scripts/lib/agent-cmd-claude.sh   — review path (review-model)
#   scripts/lib/agent-cmd-claude-fix.sh — self-fix path (FIX_MODEL)
#   scripts/review-pr.sh              — its own default wrapper, for ad-hoc runs
#
# To guard another model, add a pattern below — every call site picks it up.

# Glob patterns (not regexes) matched against the whole model id.
BLOCKED_MODEL_PATTERNS=('*fable*')

# Last-resort substitute. Must not itself match a pattern above; the test
# suite asserts that.
BLOCKED_MODEL_FALLBACK='claude-sonnet-5'

# model_is_blocked <model> — query; 0 when the denylist matches.
# An empty model is never blocked: an empty MODEL is how a caller says
# "omit --model and use the CLI's own default".
model_is_blocked() {
  local model="${1:-}" pattern
  [[ -z "$model" ]] && return 1
  for pattern in "${BLOCKED_MODEL_PATTERNS[@]}"; do
    # shellcheck disable=SC2053 # glob match is the point; not a literal compare
    if [[ "$model" == $pattern ]]; then
      return 0
    fi
  done
  return 1
}

# allowed_model_or_fallback <model> [substitute] — echo a model safe to run
# on a route with no per-issue decision behind it:
# <model> when allowed, else <substitute>, else BLOCKED_MODEL_FALLBACK. A
# blocked <substitute> falls back too, so a repo that set both to Fable
# cannot smuggle it back in.
#
# stdout is the answer; a substitution also warns on stderr (and as a
# GitHub Actions annotation) so the run report does not quietly disagree
# with what the operator configured.
allowed_model_or_fallback() {
  local requested="${1:-}" substitute="${2:-$BLOCKED_MODEL_FALLBACK}"

  if ! model_is_blocked "$requested"; then
    printf '%s' "$requested"
    return 0
  fi

  if [[ -z "$substitute" ]] || model_is_blocked "$substitute"; then
    substitute="$BLOCKED_MODEL_FALLBACK"
  fi

  printf 'warn: model %q is not available on this route (cost and rate limit are too high for an unattended run; use a model:* label to choose it per issue); using %q\n' \
    "$requested" "$substitute" >&2
  printf '::warning::model %s is not available on this route; using %s instead\n' \
    "$requested" "$substitute" >&2

  printf '%s' "$substitute"
}
