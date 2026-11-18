#!/usr/bin/env bash
#
# check-gate-runner-isolation.sh — fail closed when the gate would share the
# agent's machine (#592 F7, follows #535 / ADR-020).
#
# `gate-runner-labels` defaults to `runner-labels`. On a persistent self-hosted
# runner that puts implement_gate on the machine the agent just had: same
# workspace, same $HOME. A planted git hook or a modified ~/.local/bin tool then
# runs inside the job that judges the run, which is the weakness the separate
# gate job exists to remove. So a self-hosted run must name a gate pool of its
# own — hosted runners, or an ephemeral self-hosted pool that starts clean per
# job — unless the consumer accepts the risk explicitly.
#
# This step is pre-agent and trusted: it runs in the implement job before any
# agent step, so a refusal fails the job before `agent-eligible` and
# implement_prefail (ADR-023) reports it.
#
# Required environment variables:
#   RUNNER_LABELS  JSON array of the implement job's runner labels.
#
# Optional environment variables:
#   GATE_RUNNER_LABELS       JSON array for the gate jobs. Empty or `[]` counts
#                            as unset: the workflow expression treats '' as
#                            unset, and `[]` names no runner at all.
#   ALLOW_SHARED_GATE_RUNNER "true" accepts the risk and proceeds with a
#                            warning. Anything else is false.
#
# Exit codes:
#   0  the run is allowed (GitHub-hosted, a gate pool is named, or opted out)
#   1  refused: the agent's pool may be persistent, with no gate pool named and
#      no opt-out
#   2  usage: a label input is not a JSON array of strings, or jq is missing
set -euo pipefail
IFS=$'\n\t'

: "${RUNNER_LABELS:?RUNNER_LABELS must be set}"
GATE_RUNNER_LABELS="${GATE_RUNNER_LABELS:-}"
ALLOW_SHARED_GATE_RUNNER="${ALLOW_SHARED_GATE_RUNNER:-false}"

# Probe jq rather than letting the first call fail: every jq below silences
# stderr inside an `if`, which makes a missing jq (exit 127) indistinguishable
# from bad input. Unprobed, a runner without jq reported "runner-labels must be
# a JSON array of strings" for a perfectly valid array — a flatly wrong
# diagnostic on exactly the self-hosted runners this check targets.
if ! command -v jq >/dev/null 2>&1; then
  printf '::error title=jq is missing::check-gate-runner-isolation.sh needs jq and found none; ensure-toolchain.sh installs it, see docs/RUNNER-REQUIREMENTS.md\n'
  exit 2
fi

# require_label_array <input-name> <value> — exit 2 unless the value is a JSON
# array of strings, i.e. something `runs-on: ${{ fromJSON(...) }}` can evaluate.
require_label_array() {
  if printf '%s' "$2" \
    | jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null 2>&1; then
    return 0
  fi
  printf '::error title=Malformed %s::%s must be a JSON array of strings, got: %s\n' \
    "$1" "$1" "$2"
  exit 2
}

require_label_array runner-labels "$RUNNER_LABELS"
# `gate-runner-labels` is optional but validated the same way when set. Taking
# it on trust was worse than not checking it: `gate-runner-labels: 'self-hosted'`
# read as "a gate pool is named", so the check passed, the agent ran to
# completion, and only then did the gate job's
# `runs-on: ${{ fromJSON(inputs.gate-runner-labels ...) }}` fail to evaluate —
# no gate, no verdict, no report, the whole agent spend wasted. Checked here it
# costs nothing, which is this script's entire purpose.
if [[ -n "$GATE_RUNNER_LABELS" ]]; then
  require_label_array gate-runner-labels "$GATE_RUNNER_LABELS"
fi

gate_named=false
if [[ -n "$GATE_RUNNER_LABELS" ]] \
  && printf '%s' "$GATE_RUNNER_LABELS" | jq -e 'length > 0' >/dev/null; then
  gate_named=true
fi

# Who is persistent is decided by what is NOT recognizably GitHub-hosted, not by
# the `self-hosted` label: GitHub dispatches to a self-hosted runner on custom
# labels alone, so `runner-labels: '["homelab","claude"]'` targets the same
# persistent machine while naming nothing this script could match. Testing for
# the conventional label let every such consumer past silently — no refusal, no
# warning — which is not the fail-closed guard the docs advertise.
#
# GitHub-hosted images are all `ubuntu-*`, `windows-*`, `macos-*`. A hosted
# larger-runner group name is ephemeral too, but from the labels alone it is
# indistinguishable from a self-hosted pool, so it lands on the refusal side:
# fail closed, with `allow-shared-gate-runner: true` as the way through.
# Documented in docs/RUNNER-REQUIREMENTS.md § Gate placement.
if printf '%s' "$RUNNER_LABELS" \
  | jq -e 'length > 0 and all(.[]; ascii_downcase | test("^(ubuntu|windows|macos)-"))' >/dev/null; then
  exit 0
fi

if [[ "$gate_named" == true ]]; then
  exit 0
fi

# GitHub matches runner labels case-insensitively, so `Self-Hosted` is the same
# label as `self-hosted`. It only picks the wording — both branches refuse.
if printf '%s' "$RUNNER_LABELS" \
  | jq -e 'any(.[]; ascii_downcase == "self-hosted")' >/dev/null; then
  pool="runner-labels names a self-hosted pool"
else
  pool="runner-labels ($RUNNER_LABELS) names no GitHub-hosted image, so it may be a persistent self-hosted pool"
fi

if [[ "$ALLOW_SHARED_GATE_RUNNER" == true ]]; then
  printf "::warning title=Gate shares the agent's runner::allow-shared-gate-runner is set, so the gate jobs run on the same pool as the agent; only safe on runners that start clean per job — ephemeral self-hosted, or GitHub-hosted larger runners (#592)\n"
  exit 0
fi

printf "::error title=Gate shares the agent's runner::%s, and gate-runner-labels is empty — so the gate would judge this run on the machine the agent just used; set gate-runner-labels to a hosted or ephemeral pool, or set allow-shared-gate-runner: true to accept the risk (the right answer for GitHub-hosted larger runners, which are ephemeral) (#592)\n" \
  "$pool"
exit 1
