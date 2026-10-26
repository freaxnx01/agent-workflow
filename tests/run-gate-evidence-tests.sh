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
IMPORT="$ROOT/scripts/import-result-output.sh"
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

section "import: a valid result round-trips"
rj="$(jq -c . "$FIX/result-success-cheap.json")"
out="$(RESULT_JSON="$rj" EXECUTION_USAGE='[]' OUT_DIR="$T/imp1" bash "$IMPORT")"
assert_eq "valid=true" "true" "$(field "$out" valid)"
assert_eq "result file holds the result" "$rj" "$(jq -c . "$(field "$out" result-file)")"
assert_eq "an empty usage array still yields a file" "[]" "$(jq -c . "$(field "$out" execution-file)")"

section "import: anything else becomes a synthetic failure"
for bad in '' '{not json' '[]' '{"type":"assistant","is_error":false}' '{"type":"result","is_error":"no"}'; do
  out="$(RESULT_JSON="$bad" OUT_DIR="$T/imp-bad" bash "$IMPORT" 2>/dev/null)"
  rf="$(field "$out" result-file)"
  assert_eq "valid=false for: ${bad:-<empty>}" "false" "$(field "$out" valid)"
  assert_eq "synthetic result is an error for: ${bad:-<empty>}" "true error_invalid_evidence" \
    "$(jq -r '"\(.is_error) \(.subtype)"' "$rf")"
  assert_eq "classifies as bug for: ${bad:-<empty>}" "class=bug" \
    "$(RESULT_FILE="$rf" bash "$ROOT/scripts/classify-failure.sh" | tail -1)"
done

section "import: usage that is not an array is dropped"
out="$(RESULT_JSON="$rj" EXECUTION_USAGE='{"x":1}' OUT_DIR="$T/imp3" bash "$IMPORT")"
assert_eq "no execution file" "" "$(field "$out" execution-file)"

section "export → import end to end"
ex="$(RESULT_FILE="$FIX/result-opencode-rate-limit.json" bash "$EXPORT")"
out="$(RESULT_JSON="$(field "$ex" result-json)" EXECUTION_USAGE="$(field "$ex" execution-usage)" OUT_DIR="$T/imp4" bash "$IMPORT")"
assert_eq "a rate limit survives the hand-over" "class=rate_limit" \
  "$(RESULT_FILE="$(field "$out" result-file)" bash "$ROOT/scripts/classify-failure.sh" | tail -1)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then printf '  - %s\n' "${FAIL_NAMES[@]}"; exit 1; fi
