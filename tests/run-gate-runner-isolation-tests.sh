#!/usr/bin/env bash
#
# run-gate-runner-isolation-tests.sh — Layer-1 tests for
# scripts/check-gate-runner-isolation.sh (#592 F7): the implement job refuses a
# self-hosted run whose gate would land on the agent's own machine.
set -euo pipefail
IFS=$'\n\t'
unset GITHUB_OUTPUT GITHUB_REPOSITORY GITHUB_ACTIONS GITHUB_TOKEN

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/check-gate-runner-isolation.sh"
# Absolute, so the missing-jq case can run the script with an empty PATH.
BASH_BIN="$(command -v bash)"

PASS=0; FAIL=0; FAIL_NAMES=()
section() { printf '\n── %s ──\n' "$1"; }
pass() { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAIL_NAMES+=("$1"); printf '  ✗ %s\n' "$1"; [[ $# -gt 1 ]] && printf '      %s\n' "$2"; return 0; }
assert_eq() { if [[ "$3" == "$2" ]]; then pass "$1"; else fail "$1" "expected: $2 | actual: $3"; fi; }
assert_has() { if [[ "$3" == *"$2"* ]]; then pass "$1"; else fail "$1" "missing: $2 | in: $3"; fi; }
assert_lacks() { if [[ "$3" != *"$2"* ]]; then pass "$1"; else fail "$1" "unexpected: $2 | in: $3"; fi; }

# check <runner-labels> <gate-runner-labels> [allow] — run the script, capture
# stdout+stderr in OUT and the exit code in RC.
check() {
  OUT=""; RC=0
  OUT="$(RUNNER_LABELS="$1" GATE_RUNNER_LABELS="$2" ALLOW_SHARED_GATE_RUNNER="${3:-false}" \
    bash "$SCRIPT" 2>&1)" || RC=$?
}

section "a hosted runner never needs a separate gate"
check '["ubuntu-latest"]' ''
assert_eq "isolation_HostedOnly_Allows: exit 0" "0" "$RC"
assert_eq "isolation_HostedOnly_Allows: silent" "" "$OUT"
check '["ubuntu-24.04-arm"]' ''
assert_eq "isolation_HostedDatedImage_Allows: exit 0" "0" "$RC"
check '["windows-latest"]' ''
assert_eq "isolation_HostedWindows_Allows: exit 0" "0" "$RC"
check '["macos-15"]' ''
assert_eq "isolation_HostedMacos_Allows: exit 0" "0" "$RC"

section "self-hosted with the gate elsewhere is the intended posture"
check '["self-hosted","linux"]' '["ubuntu-latest"]'
assert_eq "isolation_SelfHostedGateSet_Allows: exit 0" "0" "$RC"
assert_lacks "isolation_SelfHostedGateSet_Allows: no warning" "::warning" "$OUT"

section "self-hosted without a gate runner is refused"
check '["self-hosted","linux"]' ''
assert_eq "isolation_SelfHostedNoGate_Refuses: exit 1" "1" "$RC"
assert_has "isolation_SelfHostedNoGate_Refuses: titled error" \
  "::error title=Gate shares the agent's runner::" "$OUT"
assert_has "isolation_SelfHostedNoGate_Refuses: names gate-runner-labels" "gate-runner-labels" "$OUT"
assert_has "isolation_SelfHostedNoGate_Refuses: names the opt-out" "allow-shared-gate-runner" "$OUT"

section "the self-hosted label matches case-insensitively"
check '["Self-Hosted","linux"]' ''
assert_eq "isolation_MixedCaseSelfHosted_Refuses: exit 1" "1" "$RC"
assert_has "isolation_MixedCaseSelfHosted_Refuses: titled error" \
  "::error title=Gate shares the agent's runner::" "$OUT"

section "an empty gate array is no runner at all, same as unset"
check '["self-hosted"]' '[]'
assert_eq "isolation_GateEmptyArray_Refuses: exit 1" "1" "$RC"

section "the opt-out proceeds, loudly"
check '["self-hosted"]' '' true
assert_eq "isolation_OptOut_AllowsWithWarning: exit 0" "0" "$RC"
assert_has "isolation_OptOut_AllowsWithWarning: warns" "::warning" "$OUT"

section "a pool with no GitHub-hosted image may be persistent, so refuse it"
# GitHub dispatches on custom labels alone: '["homelab","claude"]' is the same
# persistent machine as '["self-hosted","homelab"]' and must not pass silently.
check '["homelab","claude"]' ''
assert_eq "isolation_CustomLabelsNoGate_Refuses: exit 1" "1" "$RC"
assert_has "isolation_CustomLabelsNoGate_Refuses: titled error" \
  "::error title=Gate shares the agent's runner::" "$OUT"
assert_has "isolation_CustomLabelsNoGate_Refuses: says why it did not recognize the pool" \
  "names no GitHub-hosted image" "$OUT"
check '["homelab","claude"]' '["ubuntu-latest"]'
assert_eq "isolation_CustomLabelsGateSet_Allows: exit 0" "0" "$RC"
assert_eq "isolation_CustomLabelsGateSet_Allows: silent" "" "$OUT"
check '["homelab","claude"]' '' true
assert_eq "isolation_CustomLabelsOptOut_AllowsWithWarning: exit 0" "0" "$RC"
assert_has "isolation_CustomLabelsOptOut_AllowsWithWarning: warns" "::warning" "$OUT"

section "malformed runner labels are a usage error, not a verdict"
check 'self-hosted' ''
assert_eq "isolation_MalformedLabels_UsageError: exit 2" "2" "$RC"
check '["self-hosted",3]' ''
assert_eq "isolation_NonStringElement_UsageError: exit 2" "2" "$RC"

section "malformed gate labels are caught here, not by the gate job's runs-on"
# Unvalidated, 'self-hosted' read as "a gate pool is named" and the run went all
# the way through the agent before the gate's fromJSON() failed to evaluate.
check '["self-hosted"]' 'self-hosted'
assert_eq "isolation_MalformedGateLabels_UsageError: exit 2" "2" "$RC"
assert_has "isolation_MalformedGateLabels_UsageError: names the offending input" \
  "::error title=Malformed gate-runner-labels::" "$OUT"
check '["self-hosted"]' '["a",]'
assert_eq "isolation_UnparseableGateLabels_UsageError: exit 2" "2" "$RC"
# A hosted implement pool exits early on the isolation question, but the gate
# job still cannot start on labels it cannot parse — so validate first.
check '["ubuntu-latest"]' '["a",]'
assert_eq "isolation_MalformedGateLabelsOnHosted_UsageError: exit 2" "2" "$RC"

section "a missing jq is reported as itself, not as bad input"
OUT=""; RC=0
OUT="$(PATH='' RUNNER_LABELS='["self-hosted","linux"]' GATE_RUNNER_LABELS='' \
  "$BASH_BIN" "$SCRIPT" 2>&1)" || RC=$?
assert_eq "isolation_NoJq_UsageError: exit 2" "2" "$RC"
assert_has "isolation_NoJq_UsageError: names jq" "::error title=jq is missing::" "$OUT"
assert_lacks "isolation_NoJq_UsageError: does not blame the labels" "Malformed" "$OUT"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then printf '  - %s\n' "${FAIL_NAMES[@]}"; exit 1; fi
