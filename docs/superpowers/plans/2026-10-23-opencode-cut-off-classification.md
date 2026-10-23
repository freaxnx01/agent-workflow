# opencode cut-off classification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An opencode run whose last `step_finish` has `reason: "tool-calls"` (and no error events) is reported as a cut-off failure and retried as `transient`, instead of being classified `success`.

**Architecture:** `scripts/adapt-opencode-result.sh` detects the cut-off structurally and emits `subtype: "error_agent_cut_off"`, `is_error: true`. `scripts/classify-failure.sh` maps that subtype to `class=transient` right after the success check. The existing retry policy and workflow wiring do the rest; no workflow file changes.

**Tech Stack:** Bash 5, jq, fixture-driven tests in `tests/run-script-tests.sh`.

**Spec:** `docs/superpowers/specs/2026-10-23-opencode-cut-off-classification-design.md`

## Global Constraints

- Subtype string, exactly: `error_agent_cut_off`.
- Result text, exactly: `OpenCode stopped after a tool-calls step, before the model answered (agent loop cut off). Model: <MODEL>` (with `<MODEL>` the `MODEL` env, default `unknown`).
- Cut-off requires BOTH: zero `error` events AND last `step_finish` `.part.reason == "tool-calls"`.
- Streams with error events keep `subtype: "error_during_execution"` unchanged.
- Do not edit `.github/workflows/agent-implement.yml` or `tests/run-pipeline-alarm-tests.sh`.
- Bash prelude `set -euo pipefail` / `IFS=$'\n\t'` stays; shellcheck must pass.

## Review Focus

- A stream with an `error` event AND a last `tool-calls` step must stay `error_during_execution` (errors win) — pinned in Task 1.
- `opencode-success.json` has a mid-stream `tool-calls` step and ends `stop`; it must stay `success` — pinned in Task 1 (existing asserts) and Task 2.
- The cut-off result text must not be bucketed by the text regexes into another class — the classifier branch sits before them; pinned in Task 2 by the canonical fixture.
- Turns/tokens/cost on a cut-off stream are still computed (the run report shows real cost) — pinned in Task 1.
- `error_agent_cut_off` must reach `retry-dispatch.sh` as `transient`, which retries on attempt 1 — the class mapping is pinned in Task 2; the transient retry policy is already pinned in `tests/run-script-tests.sh` (section `retry-dispatch — policy decisions`).

---

### Task 1: Adapter detects the cut-off

**Files:**
- Create: `tests/fixtures/opencode-cut-after-tool-calls.json`
- Modify: `scripts/adapt-opencode-result.sh` (header comment + aggregation jq program)
- Test: `tests/run-script-tests.sh` (section `adapt-opencode-result — normalize OpenCode output to canonical shape`, after the `# Unparseable input → bug-bucket result` block)

**Interfaces:**
- Produces: adapter output with `.subtype == "error_agent_cut_off"`, `.is_error == true`, `.result` = the Global Constraints text, for a cut-off stream.

- [ ] **Step 1: Create the raw fixture** (structure of run 39326381307, trimmed):

`tests/fixtures/opencode-cut-after-tool-calls.json`:

```json
{"type":"step_start","timestamp":1000,"sessionID":"ses_cut","part":{"type":"step-start"}}
{"type":"tool_use","timestamp":1400,"sessionID":"ses_cut","part":{"type":"tool","tool":"read","state":{"status":"error","error":"The user rejected permission to use this specific tool call."}}}
{"type":"tool_use","timestamp":1600,"sessionID":"ses_cut","part":{"type":"tool","tool":"bash","state":{"status":"completed"}}}
{"type":"step_finish","timestamp":1700,"sessionID":"ses_cut","part":{"type":"step-finish","reason":"tool-calls","tokens":{"total":24554,"input":7133,"output":0,"reasoning":77,"cache":{"write":0,"read":17344}},"cost":0.002024}}
```

- [ ] **Step 2: Write the failing tests** — insert after the unparseable block:

```bash
# Cut off after a tool-calls step (#558): the last step_finish asked for tool
# calls and the model never answered. Structure from game-rhyflitzer run
# 39326381307. Not a success: is_error, its own subtype, usage still summed.
out="$(MODEL=z-ai/glm-5.3 EXECUTION_FILE="$FIXTURES/opencode-cut-after-tool-calls.json" bash "$ADAPT_OC")"
assert_equals "$(printf '%s' "$out" | jq -r '.is_error')" "true" "cut after tool-calls → is_error true"
assert_equals "$(printf '%s' "$out" | jq -r '.subtype')" "error_agent_cut_off" "cut after tool-calls → subtype error_agent_cut_off"
assert_equals "$(printf '%s' "$out" | jq -r '.num_turns')" "1" "cut after tool-calls → num_turns still counted"
assert_equals "$(printf '%s' "$out" | jq -r '.usage.input_tokens')" "7133" "cut after tool-calls → tokens still summed"
assert_equals "$(printf '%s' "$out" | jq -r '.result')" \
  "OpenCode stopped after a tool-calls step, before the model answered (agent loop cut off). Model: z-ai/glm-5.3" \
  "cut after tool-calls → result names the cut-off and the model"

# A mid-stream tool-calls step is normal: opencode-success.json ends with
# reason=stop and must stay a success (#558).
out="$(EXECUTION_FILE="$FIXTURES/opencode-success.json" bash "$ADAPT_OC")"
assert_equals "$(printf '%s' "$out" | jq -r '.subtype')" "success" "mid-stream tool-calls, last stop → success"

# Errors win: an error event plus a last tool-calls step keeps the error path,
# so the provider evidence the classifier needs is not hidden (#558).
TMP_ERR_CUT="$(mktemp)"
{ cat "$FIXTURES/opencode-cut-after-tool-calls.json"
  printf '%s\n' '{"type":"error","timestamp":1800,"sessionID":"ses_cut","error":{"name":"APIError","data":{"message":"Rate limit exceeded"}}}'
} > "$TMP_ERR_CUT"
out="$(EXECUTION_FILE="$TMP_ERR_CUT" bash "$ADAPT_OC")"
rm -f "$TMP_ERR_CUT"
assert_equals "$(printf '%s' "$out" | jq -r '.subtype')" "error_during_execution" "error event + last tool-calls → error_during_execution"
assert_contains "$(printf '%s' "$out" | jq -r '.result')" 'Rate limit exceeded' "error event + last tool-calls → result keeps the error"
```

- [ ] **Step 3: Run to verify they fail**

Run: `bash tests/run-script-tests.sh 2>&1 | grep -E 'cut after|FAIL' | head`
Expected: FAIL on `cut after tool-calls → is_error true` (adapter returns `false`) and the subtype/result asserts.

- [ ] **Step 4: Implement** — in the aggregation jq program of `scripts/adapt-opencode-result.sh`, add after the `$texts` binding:

```jq
  (($errs | length) == 0
   and (($steps | last | .part.reason?) // "") == "tool-calls") as $cut |
```

and change `subtype`, `is_error` and `result`:

```jq
    subtype: (if ($errs | length) > 0 then "error_during_execution"
              elif $cut then "error_agent_cut_off"
              else "success" end),
    is_error: ((($errs | length) > 0) or $cut),
```

```jq
    result: (
      if $cut
      then "OpenCode stopped after a tool-calls step, before the model answered (agent loop cut off). Model: " + $model
      else
        ($texts | last | .part.text)
        // (if ($errs | length) > 0
            then [ $errs[] | (.error.data.message // .error.name // empty) ] | join("\n")
            else null end)
        // ""
      end
    ),
```

Extend the header's event-format comment with one paragraph:

```bash
#   A stream with no error event whose LAST step_finish has reason
#   "tool-calls" was cut off before the model answered (#558): subtype
#   error_agent_cut_off, is_error true, a fixed result naming the model.
#   classify-failure.sh retries it as transient. Earlier tool-calls steps are
#   normal — only the last one counts.
```

- [ ] **Step 5: Run to verify they pass**

Run: `bash tests/run-script-tests.sh` and `shellcheck -x scripts/adapt-opencode-result.sh`
Expected: all PASS, shellcheck clean.

- [ ] **Step 6: Commit and push**

```bash
git add tests/fixtures/opencode-cut-after-tool-calls.json scripts/adapt-opencode-result.sh tests/run-script-tests.sh
git commit -m "fix(opencode): report a run cut off after a tool-calls step as a failure (#558)"
git push
```

### Task 2: Classifier retries the cut-off as transient

**Files:**
- Create: `tests/fixtures/result-opencode-cut-after-tool-calls.json`
- Modify: `scripts/classify-failure.sh` (header bucket list + one branch after the success check)
- Test: `tests/run-script-tests.sh` (end-to-end block after `adapter_to_classifier opencode-model-not-found.json`; per-fixture block after `result-opencode-task-failure.json`)

**Interfaces:**
- Consumes: adapter subtype `error_agent_cut_off` from Task 1.
- Produces: `class=transient` for that subtype.

- [ ] **Step 1: Create the canonical fixture**

`tests/fixtures/result-opencode-cut-after-tool-calls.json`:

```json
{
  "type": "result",
  "subtype": "error_agent_cut_off",
  "is_error": true,
  "duration_ms": 700,
  "num_turns": 1,
  "total_cost_usd": 0.002024,
  "session_id": "ses_cut",
  "result": "OpenCode stopped after a tool-calls step, before the model answered (agent loop cut off). Model: z-ai/glm-5.3",
  "usage": {
    "input_tokens": 7133,
    "output_tokens": 0,
    "cache_creation_input_tokens": 0,
    "cache_read_input_tokens": 17344
  }
}
```

- [ ] **Step 2: Write the failing tests**

After `out="$(adapter_to_classifier opencode-model-not-found.json)"` and its assert:

```bash
# Cut off after a tool-calls step is a hiccup, not a verdict: retry (#558).
out="$(adapter_to_classifier opencode-cut-after-tool-calls.json)"
assert_contains "$out" 'class=transient' "opencode cut after tool-calls → class=transient"
```

After the `result-opencode-task-failure.json → task_failure` assert:

```bash
out="$(RESULT_FILE="$FIXTURES/result-opencode-cut-after-tool-calls.json" bash "$CLASSIFY_FAIL")"
assert_contains "$out" 'class=transient' "result-opencode-cut-after-tool-calls.json → transient"
```

- [ ] **Step 3: Run to verify they fail**

Run: `bash tests/run-script-tests.sh 2>&1 | grep -E 'cut after|cut-off|FAIL' | head`
Expected: FAIL — the classifier returns `class=bug` for `error_agent_cut_off` (it falls through every regex).

- [ ] **Step 4: Implement** — in `scripts/classify-failure.sh`, directly after the `class=success` branch:

```bash
elif [[ "$subtype" == "error_agent_cut_off" ]]; then
  # opencode stopped after a tool-calls step, before the model answered
  # (#558). adapt-opencode-result.sh emits this subtype only for a stream with
  # no error event, so there is no provider evidence for the branches below to
  # weigh. Keyed on the structural subtype, never on result text (#521). A
  # hiccup, not a verdict on the issue: retry within the transient cap.
  class=transient
```

and in the header bucket list, extend the `transient` line:

```bash
#   - transient    → 5xx / network / timeout, or an opencode run cut off after
#                    a tool-calls step (#558) — retry with exponential backoff
```

- [ ] **Step 5: Run to verify they pass**

Run: `bash tests/run-script-tests.sh && bash tests/run-all.sh && shellcheck -x scripts/classify-failure.sh`
Expected: all PASS, shellcheck clean.

- [ ] **Step 6: Commit and push**

```bash
git add tests/fixtures/result-opencode-cut-after-tool-calls.json scripts/classify-failure.sh tests/run-script-tests.sh
git commit -m "fix(classify): retry an opencode run cut off after a tool-calls step (#558)"
git push
```
