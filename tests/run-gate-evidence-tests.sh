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
assert_eq "no execution file → empty usage (#571 F3)" "" "$(field "$out" execution-usage)"

section "export: a long result text is elided head+tail"
jq --arg t "$(printf 'A%.0s' $(seq 1 6000))$(printf 'Z%.0s' $(seq 1 6000))" '.result = $t' \
  "$FIX/result-success-cheap.json" > "$T/long.json"
rj="$(field "$(RESULT_FILE="$T/long.json" bash "$EXPORT")" result-json)"
text="$(printf '%s' "$rj" | jq -r .result)"
assert_eq "head kept" "$(printf 'A%.0s' $(seq 1 4000))" "${text:0:4000}"
assert_eq "tail kept" "$(printf 'Z%.0s' $(seq 1 4000))" "${text: -4000}"
if [[ "$text" == *"elided by export-result-output.sh"* ]]; then pass "elision is marked"; else fail "elision is marked"; fi

section "export: usage ships as a fixed-size aggregate, both stream shapes (#571 F1)"
u="$(field "$(RESULT_FILE="$FIX/result-success-cheap.json" EXECUTION_FILE="$FIX/exec-high-context.ndjson" bash "$EXPORT")" execution-usage)"
assert_eq "claude NDJSON → usage_aggregate with the stream's sums and max" \
  "$(jq -cs '[.[] | select(.type=="assistant") | .message.usage] as $u
    | {type:"usage_aggregate", events:($u|length),
       max_prompt_tokens:([$u[] | .input_tokens + .cache_read_input_tokens + .cache_creation_input_tokens] | max),
       input_tokens:([$u[].input_tokens]|add), output_tokens:([$u[].output_tokens]|add),
       cache_read_input_tokens:([$u[].cache_read_input_tokens]|add),
       cache_creation_input_tokens:([$u[].cache_creation_input_tokens]|add)}' "$FIX/exec-high-context.ndjson")" "$u"
u="$(field "$(RESULT_FILE="$FIX/result-opencode-success.json" EXECUTION_FILE="$FIX/opencode-success.json" bash "$EXPORT")" execution-usage)"
assert_eq "opencode stream → usage_aggregate with the stream's sums and max" \
  "$(jq -cs '[.[] | select(.type=="step_finish") | .part.tokens] as $t
    | {type:"usage_aggregate", events:($t|length),
       max_prompt_tokens:([$t[] | .input + .cache.read + .cache.write] | max),
       input_tokens:([$t[].input]|add), output_tokens:([$t[].output]|add),
       cache_read_input_tokens:([$t[].cache.read]|add),
       cache_creation_input_tokens:([$t[].cache.write]|add)}' "$FIX/opencode-success.json")" "$u"
printf 'not json at all\n' > "$T/garbage.txt"
assert_eq "unparseable stream → empty" "" "$(field "$(RESULT_FILE="$FIX/result-success-cheap.json" EXECUTION_FILE="$T/garbage.txt" bash "$EXPORT")" execution-usage)"
printf '{"type":"system"}\n{"type":"user"}\n' > "$T/no-usage.ndjson"
assert_eq "stream without usage events → empty, not zeros" "" "$(field "$(RESULT_FILE="$FIX/result-success-cheap.json" EXECUTION_FILE="$T/no-usage.ndjson" bash "$EXPORT")" execution-usage)"

section "export: a 1000-event stream stays small (#571 F1)"
jq -nc 'range(1000) | {type:"assistant", message:{id:"msg_\(.)", model:"claude-sonnet-5",
  usage:{input_tokens:(. + 1), cache_creation_input_tokens:2, cache_read_input_tokens:(. * 10),
         output_tokens:3, service_tier:"standard",
         cache_creation:{ephemeral_5m_input_tokens:2, ephemeral_1h_input_tokens:0},
         server_tool_use:{web_search_requests:0, web_fetch_requests:0}}}}' > "$T/claude-1000.ndjson"
u="$(field "$(RESULT_FILE="$FIX/result-success-cheap.json" EXECUTION_FILE="$T/claude-1000.ndjson" bash "$EXPORT")" execution-usage)"
if (( ${#u} < 4096 )); then pass "claude 1000 events → under 4 KiB (${#u} B)"; else fail "claude 1000 events → under 4 KiB" "${#u} bytes"; fi
assert_eq "claude 1000 events → correct sums and max" \
  '{"type":"usage_aggregate","events":1000,"max_prompt_tokens":10992,"input_tokens":500500,"output_tokens":3000,"cache_read_input_tokens":4995000,"cache_creation_input_tokens":2000}' "$u"
jq -nc 'range(1000) | {type:"step_finish", sessionID:"ses", part:{type:"step-finish", reason:"tool-calls",
  tokens:{total:0, input:(. + 1), output:3, reasoning:0, cache:{write:2, read:(. * 10)}}, cost:0.001}}' > "$T/opencode-1000.ndjson"
u="$(field "$(RESULT_FILE="$FIX/result-opencode-success.json" EXECUTION_FILE="$T/opencode-1000.ndjson" bash "$EXPORT")" execution-usage)"
if (( ${#u} < 4096 )); then pass "opencode 1000 events → under 4 KiB (${#u} B)"; else fail "opencode 1000 events → under 4 KiB" "${#u} bytes"; fi
assert_eq "opencode 1000 events → correct sums and max" \
  '{"type":"usage_aggregate","events":1000,"max_prompt_tokens":10992,"input_tokens":500500,"output_tokens":3000,"cache_read_input_tokens":4995000,"cache_creation_input_tokens":2000}' "$u"

section "export: result-json stays bounded (#571 F1)"
jq '.permission_denials = [range(5000) | {tool_name:"Bash", tool_use_id:"toolu_\(.)", tool_input:{command:"rm -rf /tmp/x\(.)"}}]
    | .modelUsage = ([range(3000) | {key:"model-\(.)", value:{inputTokens:1, outputTokens:1, costUSD:0.1}}] | from_entries)' \
  "$FIX/result-success-cheap.json" > "$T/huge.json"
rj="$(field "$(RESULT_FILE="$T/huge.json" bash "$EXPORT")" result-json)"
if (( ${#rj} < 65536 )); then pass "huge permission_denials/modelUsage → under 64 KiB (${#rj} B)"; else fail "huge permission_denials/modelUsage → under 64 KiB" "${#rj} bytes"; fi
assert_eq "bounded result keeps what the gate reads" \
  "$(jq -c '{type, subtype, is_error, num_turns, total_cost_usd, usage}' "$FIX/result-success-cheap.json")" \
  "$(printf '%s' "$rj" | jq -c '{type, subtype, is_error, num_turns, total_cost_usd, usage}')"
head -c 200000 /dev/zero | tr '\0' 'E' > "$T/big.txt"
jq --rawfile t "$T/big.txt" '.api_error = $t | .extra_blob = $t' \
  "$FIX/result-opencode-rate-limit.json" > "$T/huge-strings.json"
rj="$(field "$(RESULT_FILE="$T/huge-strings.json" bash "$EXPORT")" result-json)"
if (( ${#rj} < 65536 )); then pass "huge unknown string fields → under 64 KiB (${#rj} B)"; else fail "huge unknown string fields → under 64 KiB" "${#rj} bytes"; fi
assert_eq "a bounded rate limit still classifies" "class=rate_limit" \
  "$(printf '%s' "$rj" > "$T/rl.json"; RESULT_FILE="$T/rl.json" bash "$ROOT/scripts/classify-failure.sh" | tail -1)"

section "export: the report renders the same from the aggregate as from the raw stream"
render() { RESULT_FILE="$FIX/$1" ISSUE_NUMBER=42 WORKFLOW_RUN_URL=https://example.test/run/1 \
  RENDER_ONLY=1 MODEL=claude-sonnet-5 AGENT="$2" EXECUTION_FILE="$3" bash "$ROOT/scripts/post-run-report.sh"; }
for case in "result-success-cheap.json claude exec-high-context.ndjson" \
            "result-lastturn.json claude exec-multiturn.ndjson" \
            "result-opencode-success.json opencode opencode-success.json"; do
  IFS=' ' read -r res agent stream <<< "$case"
  field "$(RESULT_FILE="$FIX/$res" EXECUTION_FILE="$FIX/$stream" bash "$EXPORT")" execution-usage > "$T/agg-$stream"
  assert_eq "same report from raw $stream and its aggregate" \
    "$(render "$res" "$agent" "$FIX/$stream")" "$(render "$res" "$agent" "$T/agg-$stream")"
done

section "post-run-report: no execution file → n/a and result.json's tokens (#571 F3)"
out="$(render result-success-expensive.json claude '')"
if [[ "$out" == *"n/a (no execution log provided)"* ]]; then pass "context row is n/a"; else fail "context row is n/a"; fi
if [[ "$out" == *"| Input tokens | 8,500 |"* ]]; then pass "input tokens come from result.json"; else fail "input tokens come from result.json"; fi

section "post-run-report: a hostile aggregate never reaches shell arithmetic"
# shellcheck disable=SC2016  # the literal $(…) is the payload under test
printf '{"type":"usage_aggregate","events":1,"max_prompt_tokens":"a[$(touch %s)]","input_tokens":1,"output_tokens":1,"cache_read_input_tokens":1,"cache_creation_input_tokens":1}\n' "$T/pwned" > "$T/evil-agg.json"
render result-success-cheap.json claude "$T/evil-agg.json" > /dev/null 2>&1 || true
if [[ ! -e "$T/pwned" ]]; then pass "string field is not evaluated"; else fail "string field is not evaluated"; fi
out="$(render result-success-cheap.json claude "$T/evil-agg.json" 2>/dev/null || true)"
if [[ "$out" == *"n/a (no execution log provided)"* ]]; then pass "malformed aggregate degrades to n/a"; else fail "malformed aggregate degrades to n/a"; fi

section "export: bad input"
printf '{not json' > "$T/bad.json"
out="$(RESULT_FILE="$T/bad.json" bash "$EXPORT")"
assert_eq "invalid result → empty result-json" "" "$(field "$out" result-json)"
assert_eq "invalid result → is-error=true" "true" "$(field "$out" is-error)"
rc=0; RESULT_FILE='' bash "$EXPORT" >/dev/null 2>&1 || rc=$?
assert_eq "missing RESULT_FILE → exit 2" "2" "$rc"
: > "$T/go"; GITHUB_OUTPUT="$T/go" RESULT_FILE="$FIX/result-success-cheap.json" bash "$EXPORT" >/dev/null
assert_eq "writes exactly three single-line outputs" "3" "$(wc -l < "$T/go" | tr -d ' ')"

# imp <dir> <result-json|-> <usage|-> — run import with its inputs as files ("-" = no file)
imp() {
  local d="$T/$1"; mkdir -p "$d/in"
  local rf="$d/in/result.raw" uf="$d/in/usage.raw"
  if [[ "$2" == "-" ]]; then rf="$d/in/missing-result"; else printf '%s' "$2" > "$rf"; fi
  if [[ "$3" == "-" ]]; then uf="$d/in/missing-usage"; else printf '%s' "$3" > "$uf"; fi
  RESULT_JSON_FILE="$rf" EXECUTION_USAGE_FILE="$uf" OUT_DIR="$d" bash "$IMPORT" 2>/dev/null
}
AGG='{"type":"usage_aggregate","events":3,"max_prompt_tokens":15500,"input_tokens":4100,"output_tokens":2100,"cache_read_input_tokens":12000,"cache_creation_input_tokens":12000}'

section "import: a valid result round-trips"
rj="$(jq -c . "$FIX/result-success-cheap.json")"
out="$(imp imp1 "$rj" "$AGG")"
assert_eq "valid=true" "true" "$(field "$out" valid)"
assert_eq "result file holds the result" "$rj" "$(jq -c . "$(field "$out" result-file)")"
assert_eq "an aggregate yields an execution file holding it" "$AGG" "$(jq -c . "$(field "$out" execution-file)")"

section "import: no usage data → no execution file (#571 F3, deliberate contract change)"
out="$(imp imp-empty "$rj" '')"
assert_eq "empty usage → no execution file" "" "$(field "$out" execution-file)"
out="$(imp imp-nousage "$rj" -)"
assert_eq "missing usage file → no execution file" "" "$(field "$out" execution-file)"
assert_eq "missing usage file → result still valid" "true" "$(field "$out" valid)"
out="$(imp imp-arr "$rj" '[]')"
assert_eq "an empty usage array → no execution file" "" "$(field "$out" execution-file)"

section "import: a malformed aggregate is dropped, never trusted"
for bad in '{"x":1}' '[{"type":"assistant","message":{"usage":{"input_tokens":1}}}]' \
           "${AGG/\"input_tokens\":4100/\"input_tokens\":\"4100\"}" \
           "${AGG/\"output_tokens\":2100/\"output_tokens\":-1}" \
           "${AGG/\"output_tokens\":2100/\"output_tokens\":1.5}" \
           "${AGG/usage_aggregate/result}" \
           "${AGG/\"events\":3/\"events\":0}" \
           "${AGG/\"max_prompt_tokens\":15500,/}" \
           "$AGG$AGG" '"usage_aggregate"' '{not json'; do
  out="$(imp imp-badagg "$rj" "$bad")"
  assert_eq "no execution file for: $bad" "" "$(field "$out" execution-file)"
  assert_eq "result still valid for: $bad" "true" "$(field "$out" valid)"
done
out="$(imp imp-extra "$rj" "${AGG%\}},\"note\":\"\$(id)\"}")"
assert_eq "extra aggregate fields are not passed through" "$AGG" "$(jq -c . "$(field "$out" execution-file)")"

section "import: anything else becomes a synthetic failure"
for bad in '' '{not json' '[]' '{"type":"assistant","is_error":false}' '{"type":"result","is_error":"no"}' "$rj$rj"; do
  out="$(imp imp-bad "$bad" -)"
  rf="$(field "$out" result-file)"
  assert_eq "valid=false for: ${bad:-<empty>}" "false" "$(field "$out" valid)"
  assert_eq "synthetic result is an error for: ${bad:-<empty>}" "true error_invalid_evidence" \
    "$(jq -r '"\(.is_error) \(.subtype)"' "$rf")"
  assert_eq "classifies as bug for: ${bad:-<empty>}" "class=bug" \
    "$(RESULT_FILE="$rf" bash "$ROOT/scripts/classify-failure.sh" | tail -1)"
done
out="$(imp imp-missing - "$AGG")"
assert_eq "missing RESULT_JSON_FILE → valid=false" "false" "$(field "$out" valid)"
assert_eq "missing RESULT_JSON_FILE → error_invalid_evidence" "error_invalid_evidence" \
  "$(jq -r .subtype "$(field "$out" result-file)")"
out="$(OUT_DIR="$T/imp-noenv" bash "$IMPORT" 2>/dev/null)"
assert_eq "no input env at all → valid=false" "false" "$(field "$out" valid)"
assert_eq "no input env at all → no execution file" "" "$(field "$out" execution-file)"

section "export → import end to end"
ex="$(RESULT_FILE="$FIX/result-opencode-rate-limit.json" bash "$EXPORT")"
out="$(imp imp4 "$(field "$ex" result-json)" "$(field "$ex" execution-usage)")"
assert_eq "a rate limit survives the hand-over" "class=rate_limit" \
  "$(RESULT_FILE="$(field "$out" result-file)" bash "$ROOT/scripts/classify-failure.sh" | tail -1)"
ex="$(RESULT_FILE="$FIX/result-success-cheap.json" EXECUTION_FILE="$T/claude-1000.ndjson" bash "$EXPORT")"
out="$(imp imp5 "$(field "$ex" result-json)" "$(field "$ex" execution-usage)")"
assert_eq "a 1000-event aggregate survives the hand-over" "$(field "$ex" execution-usage)" \
  "$(jq -c . "$(field "$out" execution-file)")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then printf '  - %s\n' "${FAIL_NAMES[@]}"; exit 1; fi
