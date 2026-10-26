#!/usr/bin/env bash
#
# run-gate-evidence-tests.sh — Layer-1 tests for the evidence hand-over between
# an agent job and its gate job (#535): export-result-output.sh,
# import-result-output.sh, check-verdict-binding.sh.
set -euo pipefail
IFS=$'\n\t'
unset GITHUB_OUTPUT GITHUB_REPOSITORY GITHUB_ACTIONS GITHUB_TOKEN

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/tests/fixtures"
EXPORT="$ROOT/scripts/export-result-output.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0; FAIL_NAMES=()
section() { printf '\n── %s ──\n' "$1"; }
pass() { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAIL_NAMES+=("$1"); printf '  ✗ %s\n' "$1"; [[ $# -gt 1 ]] && printf '      %s\n' "$2"; return 0; }
assert_eq() { if [[ "$3" == "$2" ]]; then pass "$1"; else fail "$1" "expected: $2 | actual: $3"; fi; }
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

section "export: a normal result passes through compact"
out="$(RESULT_FILE="$FIX/result-success-cheap.json" bash "$EXPORT")"
assert_eq "result-json is the compact result" "$(jq -c . "$FIX/result-success-cheap.json")" "$(field "$out" result-json)"
assert_eq "is-error=false on success" "false" "$(field "$out" is-error)"
assert_eq "no execution file → empty usage array" "[]" "$(field "$out" execution-usage)"

section "export: a long result text is elided head+tail"
jq --arg t "$(printf 'A%.0s' $(seq 1 6000))$(printf 'Z%.0s' $(seq 1 6000))" '.result = $t' \
  "$FIX/result-success-cheap.json" > "$T/long.json"
rj="$(field "$(RESULT_FILE="$T/long.json" bash "$EXPORT")" result-json)"
text="$(printf '%s' "$rj" | jq -r .result)"
assert_eq "head kept" "$(printf 'A%.0s' $(seq 1 4000))" "${text:0:4000}"
assert_eq "tail kept" "$(printf 'Z%.0s' $(seq 1 4000))" "${text: -4000}"
if [[ "$text" == *"elided by export-result-output.sh"* ]]; then pass "elision is marked"; else fail "elision is marked"; fi

section "export: usage events only, both stream shapes"
u="$(field "$(RESULT_FILE="$FIX/result-success-cheap.json" EXECUTION_FILE="$FIX/exec-high-context.ndjson" bash "$EXPORT")" execution-usage)"
assert_eq "claude NDJSON → only assistant usage entries" \
  "$(jq -cs '[.[] | select(.type=="assistant") | {type, message:{usage:(.message.usage // {})}}]' "$FIX/exec-high-context.ndjson")" "$u"
u="$(field "$(RESULT_FILE="$FIX/result-opencode-success.json" EXECUTION_FILE="$FIX/opencode-success.json" bash "$EXPORT")" execution-usage)"
assert_eq "opencode stream → only step_finish token entries" \
  "$(jq -cs '[.[] | select(.type=="step_finish") | {type, part:{tokens:(.part.tokens // {})}}]' "$FIX/opencode-success.json")" "$u"
printf 'not json at all\n' > "$T/garbage.txt"
assert_eq "unparseable stream → []" "[]" "$(field "$(RESULT_FILE="$FIX/result-success-cheap.json" EXECUTION_FILE="$T/garbage.txt" bash "$EXPORT")" execution-usage)"

section "export: the report renders the same from the reduced usage"
render() { RESULT_FILE="$FIX/result-success-cheap.json" ISSUE_NUMBER=42 WORKFLOW_RUN_URL=https://example.test/run/1 \
  RENDER_ONLY=1 MODEL=claude-sonnet-5 AGENT=claude EXECUTION_FILE="$1" bash "$ROOT/scripts/post-run-report.sh"; }
field "$(RESULT_FILE="$FIX/result-success-cheap.json" EXECUTION_FILE="$FIX/exec-high-context.ndjson" bash "$EXPORT")" execution-usage > "$T/usage.json"
assert_eq "same report from full stream and reduced usage" "$(render "$FIX/exec-high-context.ndjson")" "$(render "$T/usage.json")"

section "export: bad input"
printf '{not json' > "$T/bad.json"
out="$(RESULT_FILE="$T/bad.json" bash "$EXPORT")"
assert_eq "invalid result → empty result-json" "" "$(field "$out" result-json)"
assert_eq "invalid result → is-error=true" "true" "$(field "$out" is-error)"
rc=0; RESULT_FILE='' bash "$EXPORT" >/dev/null 2>&1 || rc=$?
assert_eq "missing RESULT_FILE → exit 2" "2" "$rc"
: > "$T/go"; GITHUB_OUTPUT="$T/go" RESULT_FILE="$FIX/result-success-cheap.json" bash "$EXPORT" >/dev/null
assert_eq "writes exactly three single-line outputs" "3" "$(wc -l < "$T/go" | tr -d ' ')"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then printf '  - %s\n' "${FAIL_NAMES[@]}"; exit 1; fi
