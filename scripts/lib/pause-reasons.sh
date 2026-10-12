#!/usr/bin/env bash
#
# pause-reasons.sh — the failure classes that PAUSE the pipeline instead of
# failing the issue.
#
# A pause class is a show-stopper for the whole repo, not a problem with the
# issue the run happened to pick up: an exhausted API key fails every dispatch
# in the same minute. So a pause class does not retry, does not count as an
# attempt, does not stamp ai:failed — it raises one alarm issue and stops new
# dispatches until an operator clears it (#517).
#
# One row per reason, pipe-separated:
#   class|reason-id|alarm title|operator hint
#
# Adding a reason is one row here plus a branch in classify-failure.sh — that
# is the whole contract (#518 adds `model_unavailable` this way).
#
# Sourced, not executed. Exposes:
#   is_pause_class <class>           0 when the class pauses the pipeline
#   pause_reason_for_class <class>   the reason id
#   pause_title <class|reason>       alarm issue title (without the emoji)
#   pause_hint <class|reason>        what the operator has to do

PAUSE_REASONS=(
  'out_of_credits|out_of_credits|OpenRouter key limit / credits exhausted|Top up credits or raise the key limit at https://openrouter.ai/settings/keys, then resume.'
)

# Match on either the class or the reason id, so callers that only have one of
# them (the workflow has the class, pipeline-pause.sh has the reason) share a
# lookup. First match wins.
_pause_row() {
  local row
  for row in "${PAUSE_REASONS[@]}"; do
    if [[ "${row%%|*}" == "$1" ]]; then printf '%s' "$row"; return 0; fi
    local reason="${row#*|}"; reason="${reason%%|*}"
    if [[ "$reason" == "$1" ]]; then printf '%s' "$row"; return 0; fi
  done
  return 1
}

is_pause_class()         { _pause_row "$1" >/dev/null; }
pause_reason_for_class() { _pause_row "$1" | cut -d'|' -f2; }
pause_title()            { _pause_row "$1" | cut -d'|' -f3; }
pause_hint()             { _pause_row "$1" | cut -d'|' -f4; }
