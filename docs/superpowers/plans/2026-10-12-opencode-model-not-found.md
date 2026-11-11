# OpenCode "Model not found" — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Any OpenRouter model id resolves in opencode on every run; an id OpenRouter does not list stops in preflight as `model_not_found` — a failed run with a comment naming the model and the fix, one ntfy push, no attempt counted, no retry, no escalation.

**Architecture:** `opencode-model-config.sh` builds a provider/model config entry that both opencode call sites export as `OPENCODE_CONFIG_CONTENT` (resolution no longer depends on opencode's catalog). `check-opencode-model.sh` asks OpenRouter's public model list whether the id exists and, if not, synthesizes an opencode `error` event exactly like `check-opencode-auth.sh` does. `classify-failure.sh` turns that event (and opencode's own 0-turn "Model not found") into the class `model_not_found`, which `retry-dispatch.sh` stops on, `post-run-report.sh` explains, and one workflow step pushes to ntfy.

**Tech Stack:** Bash 5, `jq`, `curl`, GitHub Actions YAML, the fixture test harness in `tests/`.

**Spec:** `docs/superpowers/specs/2026-10-12-opencode-model-not-found-design.md` (issue #518).

## Global Constraints

- **Lands after #521: both change `scripts/classify-failure.sh`; rebase on it.** Start from current `origin/main`. Locate every edit in that file by the anchor text this plan names, never by line number.
- Bash, `set -euo pipefail`, `IFS=$'\n\t'`, a header comment per script listing env vars and exit codes (match `scripts/check-opencode-auth.sh`).
- Layer-1 tests are hermetic: `tests/mocks/curl` (`CURL_MOCK_FIXTURE`, `CURL_MOCK_FAIL`, `CURL_MOCK_LOG`) and `tests/mocks/opencode` replace the real tools. No network.
- New tests go in a new `tests/run-opencode-model-tests.sh` (auto-discovered by `tests/run-all.sh`).
- `model_not_found` is **not** a pause class. Do not add a row to `scripts/lib/pause-reasons.sh` and do not add it to the `Raise pipeline alarm` list.
- Do not change the pinned opencode version (`scripts/ensure-toolchain.sh`, `scripts/install-opencode.sh`).
- Never print `OPENROUTER_API_KEY`. The model-list request carries no credential.
- After every task: `bash tests/run-all.sh` and `shellcheck -x -e SC1091 $(find scripts tests -type f -name '*.sh' | sort)`; after Task 4 also `actionlint`.
- Exact strings under test:
  - injected config: `{"provider":{"openrouter":{"models":{"z-ai/glm-5.3":{}}}}}`
  - opencode's own error: `Model not found: openrouter/z-ai/glm-5.3. Did you mean: z-ai/glm-4-32b, z-ai/glm-4.5, z-ai/glm-4.5-air?`
  - preflight message prefix: ``Model not found: `<id>` is not on OpenRouter's model list``
  - class name: `model_not_found`

## Review Focus

- A model id containing a status-code digit run (`mistralai/mistral-small-2503`, `foo/bar-429`) must classify `model_not_found`, not `transient` / `rate_limit` — Task 3.
- The OpenRouter model list is unreachable or returns something that is not a list: the run must proceed, not fail — Task 2.
- A listed id that is a prefix of another (`z-ai/glm-5` when only `z-ai/glm-5.3` is listed) must not pass by substring match — Task 2.
- An unlisted routing suffix (`z-ai/glm-5.3:nitro`) must pass when its base id is listed — Task 2.
- A `model_not_found` report must still count as a non-start, not an attempt, in `check-attempt-cap.sh` — Task 3.

---

### Task 1: Build and inject the model config entry

**Files:**
- Create: `scripts/opencode-model-config.sh`, `tests/run-opencode-model-tests.sh`
- Modify: `scripts/lib/agent-cmd-opencode-fix.sh`, `tests/mocks/opencode`

**Interfaces:**
- Produces: `MODEL=<id> bash scripts/opencode-model-config.sh` → one line of JSON on stdout, exit 0; exit 2 when `MODEL` is empty. `MODEL` may carry a leading `openrouter/`.
- Produces: `tests/mocks/opencode` appends `${OPENCODE_CONFIG_CONTENT:-}` as one line to `$OPENCODE_MOCK_ENV_LOG` when that variable is set.

- [ ] **Step 1: Create the test file with the failing tests**

Create `tests/run-opencode-model-tests.sh`. Copy, verbatim, from `tests/run-pipeline-alarm-tests.sh`: everything from `set -euo pipefail` through the end of `assert_not_equals` (the helper block), and the block from `# --- summary` to the end of the file. Give it this header and these tests between the two copied blocks:

```bash
#!/usr/bin/env bash
#
# run-opencode-model-tests.sh — Layer-1 fixture tests for #518: the injected
# opencode model config, the OpenRouter model-list preflight, the
# `model_not_found` failure class and how a run in that class is reported.
#
# Hermetic by contract: the real `curl` and `opencode` are replaced by the
# mocks at tests/mocks/. No network, no GitHub, no Docker.
#
# Usage: tests/run-opencode-model-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
```

```bash
run_capture_ec() {
  local ec=0
  "$@" >/dev/null 2>&1 || ec=$?
  printf '%s' "$ec"
}

MODEL_CONFIG="$ROOT/scripts/opencode-model-config.sh"
OPENCODE_FIX="$ROOT/scripts/lib/agent-cmd-opencode-fix.sh"
WANT_CONFIG='{"provider":{"openrouter":{"models":{"z-ai/glm-5.3":{}}}}}'

section "opencode-model-config — the injected provider/model entry (#518)"

out="$(MODEL=z-ai/glm-5.3 bash "$MODEL_CONFIG")"
assert_equals "$out" "$WANT_CONFIG" "bare id → one openrouter model entry"

out="$(MODEL=openrouter/z-ai/glm-5.3 bash "$MODEL_CONFIG")"
assert_equals "$out" "$WANT_CONFIG" "openrouter/-prefixed id → prefix stripped from the key"

# An id is data, not JSON: quotes and backslashes must be escaped, not spliced.
out="$(MODEL='a"b\c/d' bash "$MODEL_CONFIG")"
assert_equals "$(printf '%s' "$out" | jq -r '.provider.openrouter.models | keys[0]')" 'a"b\c/d' \
  "id with a quote and a backslash → still valid JSON with the id as the key"

ec="$(run_capture_ec env MODEL= bash "$MODEL_CONFIG")"
assert_equals "$ec" "2" "empty MODEL → exit 2"

section "agent-cmd-opencode-fix — injects the model entry (#518)"

# opencode_fix_env <model> → the OPENCODE_CONFIG_CONTENT the mock opencode saw
opencode_fix_env() {
  local log envlog runner prompt
  log="$(mktemp)"; envlog="$(mktemp)"; runner="$(mktemp -d)"; prompt="$(mktemp)"
  printf 'fix these findings' > "$prompt"
  PATH="$MOCKS:$PATH" OPENCODE_MOCK_LOG="$log" OPENCODE_MOCK_ENV_LOG="$envlog" \
    RUNNER_TEMP="$runner" MODEL="$1" bash "$OPENCODE_FIX" "$prompt" >/dev/null
  cat "$envlog"
  rm -rf "$log" "$envlog" "$runner" "$prompt"
}

assert_equals "$(opencode_fix_env 'z-ai/glm-5.3')" "$WANT_CONFIG" \
  "self-fix with a model → opencode started with the injected entry"
assert_equals "$(opencode_fix_env 'openrouter/z-ai/glm-5.3')" "$WANT_CONFIG" \
  "self-fix with a prefixed model → same entry"
assert_equals "$(opencode_fix_env '')" "" \
  "self-fix without a model → nothing injected"
```

Make it executable: `chmod +x tests/run-opencode-model-tests.sh`.

- [ ] **Step 2: Run it and watch it fail**

Run: `bash tests/run-opencode-model-tests.sh`
Expected: FAIL — `opencode-model-config.sh` does not exist; the three self-fix assertions fail because the mock writes no env log.

- [ ] **Step 3: Write `scripts/opencode-model-config.sh`**

```bash
#!/usr/bin/env bash
#
# opencode-model-config.sh — Print the opencode config that makes one
# OpenRouter model id resolvable (#518).
#
# opencode resolves `--model openrouter/<id>` against a catalog it never waits
# for: on a cold cache (every GitHub-hosted runner) it starts from a snapshot
# compiled into the binary and refreshes in the background, so an id newer than
# the pinned binary resolves only when a 5.4 MB download wins a race against
# startup. Declaring the id in config takes the catalog out of resolution:
# opencode accepts any id listed under `provider.openrouter.models`.
#
# Callers export the output as OPENCODE_CONFIG_CONTENT for the opencode
# process. No file is written, so nothing lands in the agent's checkout.
#
# The entry is deliberately empty: cost and limits come from the catalog when
# it is loaded, and the pipeline holds no per-model metadata — adding a model
# must not need a pipeline change.
#
# Required environment variables:
#   MODEL  OpenRouter model id, with or without a leading `openrouter/`.
#
# Output (stdout): one line of JSON.
#
# Exit codes:
#   0   config printed
#   2   MODEL missing
set -euo pipefail
IFS=$'\n\t'

if [[ -z "${MODEL:-}" ]]; then
  printf 'error: MODEL must be set\n' >&2
  exit 2
fi

jq -nc --arg id "${MODEL#openrouter/}" \
  '{provider: {openrouter: {models: {($id): {}}}}}'
```

- [ ] **Step 4: Teach the opencode mock to record the injected config**

In `tests/mocks/opencode`, extend the header comment with one sentence and append one line at the end of the file:

```bash
# When $OPENCODE_MOCK_ENV_LOG is set, also appends the OPENCODE_CONFIG_CONTENT
# the invocation ran with (an empty line when unset), so a test can assert what
# config the caller injected (#518).
```

```bash
[[ -z "${OPENCODE_MOCK_ENV_LOG:-}" ]] || printf '%s\n' "${OPENCODE_CONFIG_CONTENT:-}" >> "$OPENCODE_MOCK_ENV_LOG"
```

- [ ] **Step 5: Inject in the self-fix wrapper**

In `scripts/lib/agent-cmd-opencode-fix.sh`, replace

```bash
args=(run --format json --print-logs)
[[ -n "$oc_model" ]] && args+=(--model "$oc_model")
```

with

```bash
args=(run --format json --print-logs)
if [[ -n "$oc_model" ]]; then
  args+=(--model "$oc_model")
  # Same injection as the implement job's Run OpenCode step (#518): without it
  # a model newer than the pinned opencode's bundled catalog resolves only when
  # the catalog download wins a race against startup.
  OPENCODE_CONFIG_CONTENT="$(MODEL="$oc_model" bash "$(dirname "${BASH_SOURCE[0]}")/../opencode-model-config.sh")"
  export OPENCODE_CONFIG_CONTENT
fi
```

Add to the wrapper's header comment, after the `MODEL is optional` paragraph:

```bash
# When MODEL is set, the id is also declared to opencode through
# OPENCODE_CONFIG_CONTENT (scripts/opencode-model-config.sh, #518).
```

- [ ] **Step 6: Run the tests**

Run: `bash tests/run-opencode-model-tests.sh && bash tests/run-all.sh`
Expected: PASS. The existing `agent-cmd-opencode-fix` section in `tests/run-script-tests.sh` still passes unchanged (argv is untouched).

- [ ] **Step 7: Commit**

```bash
git add scripts/opencode-model-config.sh scripts/lib/agent-cmd-opencode-fix.sh tests/mocks/opencode tests/run-opencode-model-tests.sh
git commit -m "fix(opencode): declare the model id in config so it always resolves (#518)"
```

---

### Task 2: Preflight — is the id on OpenRouter's model list?

**Files:**
- Create: `scripts/check-opencode-model.sh`, `tests/fixtures/openrouter-models.json`, `tests/fixtures/openrouter-models-malformed.json`
- Modify: `tests/run-opencode-model-tests.sh`

**Interfaces:**
- Produces: `OUTPUT_FILE=<path> MODEL=<id> bash scripts/check-opencode-model.sh` → exit 0 (listed, or the list could not be read), exit 65 (not listed; an opencode `error` event with `error.name == "ModelNotFoundError"` written to `OUTPUT_FILE`), exit 2 (required env missing). Optional `OPENROUTER_MODELS_URL`.

- [ ] **Step 1: Add the fixtures**

`tests/fixtures/openrouter-models.json`:

```json
{"data":[{"id":"z-ai/glm-5.2"},{"id":"z-ai/glm-5.3"},{"id":"meta-llama/llama-4-maverick:free"},{"id":"mistralai/mistral-small-2503"}]}
```

`tests/fixtures/openrouter-models-malformed.json`:

```json
{"error":{"message":"upstream unavailable","code":502}}
```

- [ ] **Step 2: Write the failing tests**

Insert into `tests/run-opencode-model-tests.sh`, before `# --- summary`:

```bash
section "check-opencode-model — OpenRouter model-list preflight (#518)"

OC_MODEL="$ROOT/scripts/check-opencode-model.sh"
OC_MODEL_OUT="$(mktemp)"

# model_check <model> [extra env assignments...] → exit code; OUTPUT_FILE is
# reset first, stdout+stderr land in $OC_MODEL_LOG.
OC_MODEL_LOG="$(mktemp)"
model_check() {
  local model="$1"; shift
  local ec=0
  : > "$OC_MODEL_OUT"
  env PATH="$MOCKS:$PATH" CURL_MOCK_FIXTURE="$FIXTURES/openrouter-models.json" \
    OUTPUT_FILE="$OC_MODEL_OUT" MODEL="$model" "$@" bash "$OC_MODEL" >"$OC_MODEL_LOG" 2>&1 || ec=$?
  printf '%s' "$ec"
}
out_bytes() { wc -c < "$OC_MODEL_OUT" | tr -d ' '; }

assert_equals "$(model_check z-ai/glm-5.3)" "0" "listed id → exit 0"
assert_equals "$(out_bytes)" "0" "listed id → OUTPUT_FILE untouched"
assert_equals "$(model_check openrouter/z-ai/glm-5.3)" "0" "openrouter/-prefixed listed id → exit 0"
assert_equals "$(model_check meta-llama/llama-4-maverick:free)" "0" "listed :free variant → exit 0"
assert_equals "$(model_check z-ai/glm-5.3:nitro)" "0" "unlisted routing suffix on a listed base id → exit 0"

assert_equals "$(model_check z-ai/glm-5.33)" "65" "unlisted id → exit 65"
event="$(cat "$OC_MODEL_OUT")"
assert_equals "$(printf '%s' "$event" | jq -r '.type')" "error" "unlisted id → an opencode error event"
assert_equals "$(printf '%s' "$event" | jq -r '.error.name')" "ModelNotFoundError" "unlisted id → error.name"
msg="$(printf '%s' "$event" | jq -r '.error.data.message')"
assert_contains "$msg" 'Model not found: `z-ai/glm-5.33`' "unlisted id → message starts with the classifier's phrase and names the id"
assert_contains "$msg" 'default-model' "unlisted id → message names the input to fix"
assert_contains "$msg" 'model:' "unlisted id → message names the label to fix"
assert_contains "$msg" 'https://openrouter.ai/models' "unlisted id → message links the id list"
assert_contains "$(cat "$OC_MODEL_LOG")" '::error::' "unlisted id → an error annotation"

# Exact line match, never substring: glm-5 is a prefix of the listed glm-5.3.
assert_equals "$(model_check z-ai/glm-5)" "65" "prefix of a listed id → exit 65"
assert_equals "$(model_check z-ai/glm-9:free)" "65" "suffix on an unlisted base id → exit 65"

# Fail open: an unreadable list must not stop a run injection lets start.
curl_log="$(mktemp)"
assert_equals "$(model_check z-ai/glm-5.33 CURL_MOCK_FAIL=1 CURL_MOCK_LOG="$curl_log")" "0" \
  "model list unreachable → exit 0 (fail open)"
assert_equals "$(out_bytes)" "0" "model list unreachable → OUTPUT_FILE untouched"
assert_contains "$(cat "$OC_MODEL_LOG")" '::warning::' "model list unreachable → a warning annotation"
assert_equals "$(wc -l < "$curl_log" | tr -d ' ')" "2" "model list unreachable → fetched twice (one retry)"

assert_equals "$(model_check z-ai/glm-5.33 CURL_MOCK_FIXTURE="$FIXTURES/openrouter-models-malformed.json")" "0" \
  "body that is not a model list → exit 0 (fail open)"
assert_contains "$(cat "$OC_MODEL_LOG")" '::warning::' "body that is not a model list → a warning annotation"

# The list is public: no credential on the request, none in the output.
: > "$curl_log"
model_check z-ai/glm-5.33 OPENROUTER_API_KEY=sk-or-supersecret CURL_MOCK_LOG="$curl_log" >/dev/null
assert_not_contains "$(cat "$curl_log")" 'Authorization' "request carries no Authorization header"
assert_not_contains "$(cat "$curl_log" "$OC_MODEL_LOG" "$OC_MODEL_OUT")" 'sk-or-supersecret' "key value never appears"
assert_contains "$(cat "$curl_log")" 'https://openrouter.ai/api/v1/models' "default URL is OpenRouter's public model list"

ec="$(run_capture_ec env MODEL=z-ai/glm-5.3 bash "$OC_MODEL")"
assert_equals "$ec" "2" "missing OUTPUT_FILE → exit 2"
ec="$(run_capture_ec env OUTPUT_FILE="$OC_MODEL_OUT" bash "$OC_MODEL")"
assert_equals "$ec" "2" "missing MODEL → exit 2"

rm -f "$OC_MODEL_OUT" "$OC_MODEL_LOG" "$curl_log"
```

- [ ] **Step 3: Run it and watch it fail**

Run: `bash tests/run-opencode-model-tests.sh`
Expected: FAIL — `check-opencode-model.sh` does not exist.

- [ ] **Step 4: Write `scripts/check-opencode-model.sh`**

```bash
#!/usr/bin/env bash
#
# check-opencode-model.sh — Preflight for the OpenCode agent path (#518): is
# the chosen model id one OpenRouter lists?
#
# The pipeline declares the run's model to opencode in config
# (opencode-model-config.sh), so opencode accepts ANY id — a typo included —
# and can no longer tell a new model from a wrong one. The authority on "does
# this id exist" is OpenRouter's public model list, so this asks it before the
# agent starts. A missing id is a configuration error, not a failure of the
# issue: instead of letting the run die opaquely, this synthesizes the opencode
# `error` event `opencode run` never got to write, so
# adapt-opencode-result.sh → classify-failure.sh (`model_not_found`) →
# post-run-report.sh degrade as for any other OpenCode failure.
#
# Fails OPEN: when the list cannot be read (after one retry) the run proceeds.
# The list being down says nothing about the model, and stopping there would
# turn an OpenRouter listing outage into a fleet-wide stop.
#
# Required environment variables:
#   OUTPUT_FILE  Path to write the synthesized event to. Must be the same
#                path the `Run OpenCode` step publishes as `execution_file`.
#   MODEL        OpenRouter model id, with or without a leading `openrouter/`.
#
# Optional environment variables:
#   OPENROUTER_MODELS_URL  Default https://openrouter.ai/api/v1/models. Public:
#                          the request carries no credential.
#
# Exit codes:
#   0   the id is listed, or the list could not be read; OUTPUT_FILE untouched
#   2   required env missing
#   65  the id is not listed; error event written to OUTPUT_FILE
set -euo pipefail
IFS=$'\n\t'

if [[ -z "${OUTPUT_FILE:-}" ]]; then
  printf 'error: OUTPUT_FILE must be set\n' >&2
  exit 2
fi
if [[ -z "${MODEL:-}" ]]; then
  printf 'error: MODEL must be set\n' >&2
  exit 2
fi

MODELS_URL="${OPENROUTER_MODELS_URL:-https://openrouter.ai/api/v1/models}"
model="${MODEL#openrouter/}"

# Prints one listed id per line. Non-zero when the request fails or the body is
# not a non-empty `{data: [...]}` — an empty list would otherwise reject every
# model there is.
fetch_model_ids() {
  curl -sS -f --max-time 15 "$MODELS_URL" 2>/dev/null \
    | jq -er '.data | if type == "array" and length > 0 then .[].id else error("not a model list") end' 2>/dev/null
}

ids=''
for _ in 1 2; do
  if ids="$(fetch_model_ids)"; then break; fi
  ids=''
done

if [[ -z "$ids" ]]; then
  printf '::warning::could not read the OpenRouter model list (%s) — model check skipped for %s\n' \
    "$MODELS_URL" "$model"
  exit 0
fi

# Whole-line, fixed-string match. A here-string, not a pipe: `grep -q` exits on
# the first match, and under pipefail the writer's SIGPIPE would read as "not
# listed".
is_listed() { grep -qxF -- "$1" <<< "$ids"; }

# `:nitro` / `:floor` / `:online` are routing shortcuts OpenRouter accepts on
# any id but does not list; `:free` variants are listed as their own ids. So an
# unlisted suffixed id passes when its base id is listed.
if is_listed "$model" || is_listed "${model%%:*}"; then
  printf 'ok: %s is on the OpenRouter model list\n' "$model"
  exit 0
fi

message="Model not found: \`${model}\` is not on OpenRouter's model list (https://openrouter.ai/models), so the run was stopped before the agent started. Fix the \`default-model\` input in the consumer workflow or the \`model:\` label on this issue, then re-dispatch."

# Same NDJSON `error` event shape opencode itself emits under `--format json`,
# so adapt-opencode-result.sh needs no special case.
jq -nc --arg msg "$message" \
  '{type:"error",timestamp:0,sessionID:"opencode-preflight",
    error:{name:"ModelNotFoundError",data:{message:$msg}}}' > "$OUTPUT_FILE"

printf '::error::%s\n' "$message"
exit 65
```

- [ ] **Step 5: Run the tests**

Run: `bash tests/run-opencode-model-tests.sh && bash tests/run-all.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add scripts/check-opencode-model.sh tests/fixtures/openrouter-models.json tests/fixtures/openrouter-models-malformed.json tests/run-opencode-model-tests.sh
git commit -m "feat(opencode): preflight the model id against OpenRouter's model list (#518)"
```

---

### Task 3: Class `model_not_found` — classify, stop, report

**Files:**
- Create: `tests/fixtures/result-opencode-model-not-found.json`
- Modify: `scripts/classify-failure.sh`, `scripts/retry-dispatch.sh`, `scripts/post-run-report.sh`, `tests/run-script-tests.sh`, `tests/run-opencode-model-tests.sh`

**Interfaces:**
- Consumes: the error event from Task 2 (`error.data.message` starts `Model not found:`).
- Produces: `classify-failure.sh` prints `class=model_not_found`; `retry-dispatch.sh` answers `decision=stop` for it; `post-run-report.sh` with `FAILURE_CLASS=model_not_found` renders outcome `failed: model_not_found`, label `ai:failed`, and a fix block naming `$MODEL`.
- Produces: `tests/fixtures/result-opencode-model-not-found.json` (canonical result shape; Task 4's stub uses it).

- [ ] **Step 1: Add the result fixture**

`tests/fixtures/result-opencode-model-not-found.json`:

```json
{
  "type": "result",
  "subtype": "error_during_execution",
  "is_error": true,
  "duration_ms": 0,
  "num_turns": 0,
  "total_cost_usd": 0,
  "api_error": "Model not found: `z-ai/glm-9` is not on OpenRouter's model list (https://openrouter.ai/models), so the run was stopped before the agent started. Fix the `default-model` input in the consumer workflow or the `model:` label on this issue, then re-dispatch.",
  "api_error_status": null,
  "session_id": "opencode-preflight",
  "result": "Model not found: `z-ai/glm-9` is not on OpenRouter's model list (https://openrouter.ai/models), so the run was stopped before the agent started. Fix the `default-model` input in the consumer workflow or the `model:` label on this issue, then re-dispatch.",
  "usage": {
    "input_tokens": 0,
    "output_tokens": 0,
    "cache_creation_input_tokens": 0,
    "cache_read_input_tokens": 0
  }
}
```

- [ ] **Step 2: Write the failing tests**

(a) `tests/run-script-tests.sh` holds two assertions that encode the #439 behaviour this issue replaces (a 0-turn "Model not found" was `transient`). This is a specified behaviour change, not a test bent to fit an implementation — change them first and watch them fail.

Replace

```bash
# Transient opencode catalog miss (#439): 0 turns + "Model not found" is an
# infrastructure blip, not a bug. Retrying it (and escalating to Claude on
# attempt 2) is what the operator ended up doing by hand.
out="$(adapter_to_classifier opencode-model-not-found.json)"
assert_contains "$out" 'class=transient' "opencode 0-turn model-not-found → transient (retried)"
```

with

```bash
# 0 turns + "Model not found" is its own class since #518: the pipeline now
# declares the model to opencode, so the catalog miss #439 retried cannot
# happen and what is left is a wrong id — which a retry cannot fix.
out="$(adapter_to_classifier opencode-model-not-found.json)"
assert_contains "$out" 'class=model_not_found' "opencode 0-turn model-not-found → model_not_found"
```

and replace

```bash
assert_contains "$out" 'class=transient' "model-not-found at 0 turns → transient"
```

with

```bash
assert_contains "$out" 'class=model_not_found' "model-not-found at 0 turns → model_not_found"
```

In the comment block directly above that second assertion, change `(#439)` to `(#439, #518)`. Leave the `num_turns = 3` → `class=bug` assertion below it as it is.

(b) Insert into `tests/run-opencode-model-tests.sh`, before `# --- summary`:

```bash
section "classify-failure — model_not_found (#518)"

CLASSIFY_FAIL="$ROOT/scripts/classify-failure.sh"
ADAPT_OC="$ROOT/scripts/adapt-opencode-result.sh"

# classify_result_text <num_turns> <result text> → the class line
classify_result_text() {
  local tmp out
  tmp="$(mktemp --suffix=.json)"
  jq -nc --argjson turns "$1" --arg text "$2" \
    '{type:"result",subtype:"error_during_execution",is_error:true,duration_ms:0,
      num_turns:$turns,total_cost_usd:0,session_id:"s",result:$text,
      usage:{input_tokens:0,output_tokens:0,cache_creation_input_tokens:0,cache_read_input_tokens:0}}' > "$tmp"
  out="$(RESULT_FILE="$tmp" bash "$CLASSIFY_FAIL")"
  rm -f "$tmp"
  printf '%s' "$out"
}

assert_equals "$(RESULT_FILE="$FIXTURES/result-opencode-model-not-found.json" bash "$CLASSIFY_FAIL")" \
  'class=model_not_found' "preflight result fixture → model_not_found"

assert_equals "$(classify_result_text 0 'Model not found: openrouter/z-ai/glm-5.3. Did you mean: z-ai/glm-4-32b, z-ai/glm-4.5, z-ai/glm-4.5-air?')" \
  'class=model_not_found' "opencode's own 0-turn error → model_not_found"
assert_equals "$(classify_result_text 0 'ProviderModelNotFoundError')" \
  'class=model_not_found' "bare error name at 0 turns → model_not_found"

# The message carries the model id, and the buckets below match bare digit
# runs. An id must never choose the class.
assert_equals "$(classify_result_text 0 'Model not found: `mistralai/mistral-small-2503` is not on the list')" \
  'class=model_not_found' "id containing 503 → model_not_found, not transient"
assert_equals "$(classify_result_text 0 'Model not found: `foo/bar-429` is not on the list')" \
  'class=model_not_found' "id containing 429 → model_not_found, not rate_limit"
assert_equals "$(classify_result_text 0 'Model not found: `foo/bar-401` is not on the list')" \
  'class=model_not_found' "id containing 401 → model_not_found, not api_auth"

assert_equals "$(classify_result_text 3 'Model not found: openrouter/z-ai/glm-5.3.')" \
  'class=bug' "same text after real turns → still bug"

# The whole chain: preflight event → adapter → classifier.
chain_out="$(mktemp)"; chain_result="$(mktemp --suffix=.json)"
env PATH="$MOCKS:$PATH" CURL_MOCK_FIXTURE="$FIXTURES/openrouter-models.json" \
  OUTPUT_FILE="$chain_out" MODEL=z-ai/glm-5.33 bash "$ROOT/scripts/check-opencode-model.sh" >/dev/null 2>&1 || true
EXECUTION_FILE="$chain_out" MODEL=z-ai/glm-5.33 bash "$ADAPT_OC" > "$chain_result"
assert_equals "$(jq -r '.num_turns' "$chain_result")" "0" "preflight event → adapter → 0 turns"
assert_equals "$(RESULT_FILE="$chain_result" bash "$CLASSIFY_FAIL")" 'class=model_not_found' \
  "preflight event → adapter → classifier → model_not_found"
rm -f "$chain_out" "$chain_result"

# The #164 missing-key preflight must keep its own class.
missing_key="$(mktemp --suffix=.json)"
EXECUTION_FILE="$FIXTURES/opencode-missing-key.json" MODEL=z-ai/glm-5.3 bash "$ADAPT_OC" > "$missing_key"
assert_equals "$(RESULT_FILE="$missing_key" bash "$CLASSIFY_FAIL")" 'class=api_auth' \
  "missing OPENROUTER_API_KEY → still api_auth"
rm -f "$missing_key"

section "model_not_found is alert-only: no retry, no pause, not an attempt (#518)"

retry_err="$(mktemp)"
out="$(CLASS=model_not_found ATTEMPT=1 ISSUE_NUMBER=42 REPO=o/r DRY_RUN=1 \
        bash "$ROOT/scripts/retry-dispatch.sh" 2>"$retry_err")"
assert_contains "$out" 'decision=stop' "retry-dispatch: model_not_found → stop"
assert_not_contains "$(cat "$retry_err")" 'unknown CLASS' "retry-dispatch knows the class"
rm -f "$retry_err"

# shellcheck source=scripts/lib/pause-reasons.sh
source "$ROOT/scripts/lib/pause-reasons.sh"
if is_pause_class model_not_found; then
  fail "model_not_found is not a pause class" "pause-reasons.sh lists it"
else
  pass "model_not_found is not a pause class"
fi

report="$(RENDER_ONLY=1 RESULT_FILE="$FIXTURES/result-opencode-model-not-found.json" \
          ISSUE_NUMBER=42 WORKFLOW_RUN_URL=https://example/run/test \
          FAILURE_CLASS=model_not_found MODEL=z-ai/glm-9 AGENT=opencode \
          bash "$ROOT/scripts/post-run-report.sh")"
assert_contains "$report" '## ai-implement run' "report keeps the run heading"
assert_contains "$report" ':x: failed: model_not_found' "report names the class as the outcome"
assert_contains "$report" 'Model `z-ai/glm-9` is not on OpenRouter' "report names the model"
assert_contains "$report" 'default-model' "report names the input to fix"
assert_contains "$report" 'https://openrouter.ai/models' "report links the id list"
assert_contains "$report" 'LABELS: ai:failed' "report stamps ai:failed"

# Every other class renders exactly as before: no fix block.
other="$(RENDER_ONLY=1 RESULT_FILE="$FIXTURES/result-opencode-model-not-found.json" \
         ISSUE_NUMBER=42 WORKFLOW_RUN_URL=https://example/run/test \
         FAILURE_CLASS=bug MODEL=z-ai/glm-9 bash "$ROOT/scripts/post-run-report.sh")"
assert_not_contains "$other" 'is not on OpenRouter' "another class → no model fix block"

# "Not an attempt" is check-attempt-cap's non-start rule: 0 turns AND $0.00.
comment="${report%%$'\n---\nLABELS:'*}"
cap="$(ISSUE_COMMENTS_JSON="$(jq -nc --arg b "$comment" '[{body:$b}]')" \
       ISSUE_NUMBER=42 REPO=o/r DRY_RUN=1 bash "$ROOT/scripts/check-attempt-cap.sh")"
assert_contains "$cap" 'attempt=1' "a model_not_found report does not consume an attempt"
assert_contains "$cap" 'non-starts=1' "it is counted as a non-start"
assert_contains "$cap" 'proceed=true' "and the next dispatch proceeds"
```

- [ ] **Step 3: Run both suites and watch them fail**

Run: `bash tests/run-opencode-model-tests.sh; bash tests/run-script-tests.sh`
Expected: FAIL — the classifier still answers `transient` (and `rate_limit` / `api_auth` for the digit ids), `retry-dispatch.sh` warns `unknown CLASS`, the report has no fix block.

- [ ] **Step 4: Classify — `scripts/classify-failure.sh`**

Delete the whole `elif` branch that begins

```bash
elif [[ "$num_turns" == "0" ]] && printf '%s' "$result_text" | grep -qiE 'model not found|ProviderModelNotFoundError'; then
```

together with its comment and its `class=transient` line (it sits between the `transient` branch and the `error_max_turns` branch).

Insert this branch immediately **before** the line that starts `elif printf '%s' "$result_text" | grep -qiE 'rate.?limit|` — that is, directly after the `out_of_credits` branch's `class=out_of_credits` line, whatever #521 made that branch's condition:

```bash
elif [[ "$num_turns" == "0" ]] && printf '%s' "$result_text" | grep -qiE 'model not found|ProviderModelNotFoundError'; then
  # The model id is not one OpenRouter lists (check-opencode-model.sh's
  # preflight event), or opencode itself could not resolve it. A configuration
  # error on the workflow input or the issue's `model:` label — no retry can
  # fix it and it is not a verdict on the issue (#518, replacing the
  # `transient` bucket from #439: the pipeline now declares the model to
  # opencode, so the catalog miss that bucket retried cannot occur).
  # Matched BEFORE rate_limit, api_auth and transient: those match bare digit
  # runs and this message carries the model id — `mistral-small-2503` contains
  # `503`. The 0-turn guard keeps a mid-run model error in `bug`. The #164
  # missing-key preflight says nothing about a model not being found, so it
  # still reaches api_auth.
  class=model_not_found
```

In the header comment: add `model_not_found |` to the `class=` list (after `out_of_credits |`), remove ` / 0-turn model-not-found` from the `transient` line, and add after the `out_of_credits` entry:

```bash
#   - model_not_found → the model id is not on OpenRouter's list — operator
#                    fixes the id; no retry, not an attempt, one ntfy push
```

- [ ] **Step 5: Stop — `scripts/retry-dispatch.sh`**

Replace the case label `out_of_credits|api_auth|bug)` with `out_of_credits|model_not_found|api_auth|bug)` and append to that branch's comment:

```bash
    # model_not_found is a wrong model id (#518): the operator corrects
    # `default-model` or the `model:` label and re-dispatches. Not retrying is
    # also what keeps escalate-on-retry from moving the issue to Claude.
```

- [ ] **Step 6: Report — `scripts/post-run-report.sh`**

(a) Directly after the `fi` that closes the `CHECKS_BLOCKED_BLOCK` construction, add:

```bash
# #518: a run that stopped because OpenRouter does not list its model gets the
# fix spelled out — the outcome line alone would send the reader to the logs.
# Same shape as CHECKS_BLOCKED_BLOCK (leading and trailing newline) so the two
# can share one line of the comment template and an empty one renders nothing.
MODEL_FIX_BLOCK=''
if [[ "$FAILURE_CLASS" == "model_not_found" ]]; then
  MODEL_FIX_BLOCK="
> [!WARNING]
> **Model \`${MODEL:-unknown}\` is not on OpenRouter's model list.**
> Set the \`default-model\` input in the consumer workflow, or the \`model:\` label
> on this issue, to an id from <https://openrouter.ai/models>, then re-dispatch.
> The run stopped before the agent started, so it does not count as an attempt.
"
fi
```

(b) In the status chain, insert between the `is_pause_class` branch and the `elif [[ "$IS_ERROR" == "true" || "$SUBTYPE" == error_* ]]; then` branch:

```bash
elif [[ "$FAILURE_CLASS" == "model_not_found" ]]; then
  # #518: a wrong model id. Still `## ai-implement run` + ai:failed — the run
  # did fail — but it has 0 turns and $0.00, so check-attempt-cap.sh counts it
  # as a non-start, never as an attempt.
  STATUS_EMOJI=':x:'
  STATUS_TEXT='failed: model_not_found'
  STATUS_LABEL='ai:failed'
```

(c) In `render_comment`, change the line `${CHECKS_BLOCKED_BLOCK}` to `${CHECKS_BLOCKED_BLOCK}${MODEL_FIX_BLOCK}`.

(d) In the header comment's `FAILURE_CLASS` entry, add: `` `model_not_found` (#518) renders `failed: model_not_found` plus a block naming the model and the fix. ``

- [ ] **Step 7: Run the tests**

Run: `bash tests/run-all.sh`
Expected: PASS, including the unchanged report golden assertions in `tests/run-script-tests.sh` (an empty `MODEL_FIX_BLOCK` adds no character to the comment).

- [ ] **Step 8: Commit**

```bash
git add scripts/classify-failure.sh scripts/retry-dispatch.sh scripts/post-run-report.sh tests/fixtures/result-opencode-model-not-found.json tests/run-script-tests.sh tests/run-opencode-model-tests.sh
git commit -m "fix(pipeline): class model_not_found — no retry, no escalation, fix named in the report (#518)"
```

---

### Task 4: Wire the workflow, the act test and the docs

**Files:**
- Modify: `.github/workflows/agent-implement.yml`, `.github/workflows/agent-implement.test.yml`, `scripts/lib/pause-reasons.sh`, `docs/CONSUMER-SETUP.md`, `docs/DEFAULT-MODEL-CHEATSHEET.md`, `tests/run-opencode-model-tests.sh`

**Interfaces:**
- Consumes: `scripts/check-opencode-model.sh` (exit 65 + event), `scripts/opencode-model-config.sh` (stdout JSON), class `model_not_found`, `tests/fixtures/result-opencode-model-not-found.json`, `scripts/notify-ntfy.sh` (`NTFY_URL`, `NTFY_TOPIC`, `NTFY_TOKEN`, `NTFY_TITLE`, `NTFY_MESSAGE`, `NTFY_PRIORITY`, `NTFY_TAGS`, `NTFY_CLICK`; always exits 0).

- [ ] **Step 1: Write the failing wiring tests**

Insert into `tests/run-opencode-model-tests.sh`, before `# --- summary`:

```bash
section "agent-implement.yml — model preflight, injection and alert are wired (#518)"

WF="$ROOT/.github/workflows/agent-implement.yml"
wf="$(cat "$WF")"
line_of() { grep -nF -- "$1" "$WF" | head -1 | cut -d: -f1; }

assert_contains "$wf" 'bash .claude-pipeline/scripts/check-opencode-model.sh' "Run OpenCode calls the model preflight"
assert_contains "$wf" "printf 'exit_code=65\\n'" "a failed model preflight publishes exit_code 65"
assert_contains "$wf" 'opencode models openrouter --refresh' "the catalog is warmed before the run"
assert_contains "$wf" 'OPENCODE_CONFIG_CONTENT="$(bash .claude-pipeline/scripts/opencode-model-config.sh)"' \
  "the model entry is injected"
assert_contains "$wf" 'export OPENCODE_CONFIG_CONTENT' "and exported to opencode"

run_line="$(line_of 'opencode run \')"
for needle in 'scripts/check-opencode-auth.sh' 'scripts/check-opencode-model.sh' \
              'opencode models openrouter --refresh' 'export OPENCODE_CONFIG_CONTENT'; do
  if (( $(line_of "$needle") < run_line )); then
    pass "'$needle' comes before 'opencode run'"
  else
    fail "'$needle' comes before 'opencode run'" "line $(line_of "$needle") vs $run_line"
  fi
done
if (( $(line_of 'scripts/check-opencode-auth.sh') < $(line_of 'scripts/check-opencode-model.sh') )); then
  pass "the key preflight runs before the model preflight"
else
  fail "the key preflight runs before the model preflight"
fi

assert_contains "$wf" "steps.classify_failure.outputs.class == 'model_not_found'" \
  "an alert step is gated on the class"
assert_contains "$wf" "contains(fromJSON('[\"out_of_credits\"]'), steps.classify_failure.outputs.class)" \
  "the pause list is still out_of_credits only"
assert_contains "$wf" 'opencode_model_not_found)' "the stub knows the model_not_found fixture"
assert_not_contains "$wf" "#518's second" "the stale 'second pause reason' note is gone"
assert_not_contains "$(cat "$ROOT/scripts/lib/pause-reasons.sh")" 'model_unavailable' \
  "pause-reasons.sh no longer promises a model pause reason"

test_wf="$(cat "$ROOT/.github/workflows/agent-implement.test.yml")"
assert_contains "$test_wf" 'stub-fixture: opencode_model_not_found' "act: a call job exercises the class"
assert_contains "$test_wf" 'want model_not_found' "act: a verify job asserts the class"

setup_doc="$(cat "$ROOT/docs/CONSUMER-SETUP.md")"
assert_contains "$setup_doc" '### Adding a new OpenRouter model' "CONSUMER-SETUP documents adding a model"
assert_contains "$setup_doc" 'model_not_found' "CONSUMER-SETUP names the class"
assert_not_contains "$setup_doc" 'classifies that as `transient`' "CONSUMER-SETUP drops the #439 retry advice"
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bash tests/run-opencode-model-tests.sh`
Expected: FAIL on every assertion in the new section.

- [ ] **Step 3: `Run OpenCode` step — preflight, warm-up, injection**

In `.github/workflows/agent-implement.yml`, step `Run OpenCode`, insert directly after the `fi` that closes the `check-opencode-auth.sh` block:

```yaml
          # Preflight (#518): the model is declared to opencode below, so
          # opencode accepts any id and cannot tell a new model from a wrong
          # one. Ask OpenRouter's public model list instead, and stop here —
          # as `model_not_found`, through the same degradation path — when the
          # id is not on it. Fails open when the list cannot be read.
          if ! OUTPUT_FILE="$out_file" bash .claude-pipeline/scripts/check-opencode-model.sh; then
            printf 'execution_file=%s\n' "$out_file" >> "$GITHUB_OUTPUT"
            printf 'exit_code=65\n' >> "$GITHUB_OUTPUT"
            exit 0
          fi
```

In the same step, insert directly after the `esac` that closes the `case "$oc_model" in` block:

```yaml
          # Model resolution (#518). opencode never waits for its catalog
          # (models.dev): on a cold cache — every GitHub-hosted runner — it
          # starts from a snapshot compiled into the binary and refreshes in
          # the background, so an id newer than the pinned opencode resolved
          # only when a 5.4 MB download won a race against startup (four of
          # five parallel runs lost it). Two steps, in this order:
          #   1. `models --refresh` is the one call that waits for the catalog,
          #      so cost and context limits are real. Best-effort.
          #   2. Declaring the id in config makes it resolve even when the
          #      catalog is unreachable — the part that must not fail.
          timeout 60 opencode models openrouter --refresh >/dev/null 2>&1 || true
          OPENCODE_CONFIG_CONTENT="$(bash .claude-pipeline/scripts/opencode-model-config.sh)"
          export OPENCODE_CONFIG_CONTENT
```

- [ ] **Step 4: Stub fixture, alert step, stale notes**

(a) In step `Stub Claude run (diagnostic mode)`, add a case before the `*)` default:

```yaml
            opencode_model_not_found)
              cp .claude-pipeline/tests/fixtures/result-opencode-model-not-found.json "$out"
              ;;
```

In the `stub-fixture` input description, change `success | rate_limit | task_failure.` to `success | rate_limit | task_failure | opencode_success | opencode_rate_limit | opencode_task_failure | opencode_model_not_found.`

(b) Replace the comment above step `Raise pipeline alarm`

```yaml
      # #517: the classes in this list pause the whole repo instead of failing
      # the issue (scripts/lib/pause-reasons.sh). One list, so #518's second
      # reason is added here and nowhere else in this file. continue-on-error
      # because an alarm that cannot be raised must not also lose the run
      # report below it.
```

with

```yaml
      # #517: the classes in this list pause the whole repo instead of failing
      # the issue (scripts/lib/pause-reasons.sh). One list, so a further pause
      # reason is added here and nowhere else in this file. continue-on-error
      # because an alarm that cannot be raised must not also lose the run
      # report below it.
```

(c) Insert a new step between `Raise pipeline alarm` and `Plan retry`:

```yaml
      # #518: a model id OpenRouter does not list is a configuration error on
      # one input or one label — the issue's run fails with the fix in its
      # report, and this pushes it to the operator. Deliberately NOT a pause
      # class: other issues may carry a working `model:` label, so dispatches
      # continue. One push per failing run. continue-on-error for the same
      # reason as the alarm above; notify-ntfy.sh exits 0 on every path anyway.
      - name: Alert on model not found
        id: model_alert
        continue-on-error: true
        if: always() && steps.classify_failure.outputs.class == 'model_not_found'
        env:
          NTFY_URL: ${{ secrets.NTFY_URL }}
          NTFY_TOPIC: ${{ vars.NTFY_TOPIC }}
          NTFY_TOKEN: ${{ secrets.NTFY_TOKEN }}
          NTFY_TITLE: ${{ format('{0}: model not found', github.repository) }}
          NTFY_MESSAGE: ${{ format('Issue #{0}: OpenRouter does not list model {1}. Fix default-model or the model: label, then re-dispatch.', inputs.issue-number, steps.triage.outputs.model || inputs.default-model) }}
          NTFY_PRIORITY: high
          NTFY_TAGS: warning
          NTFY_CLICK: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
        run: bash .claude-pipeline/scripts/notify-ntfy.sh
```

(d) In the `failure-class` workflow output, change the description to:

```yaml
        description: 'Failure bucket from classify-failure.sh (success | out_of_credits | model_not_found | rate_limit | api_auth | transient | task_failure | bug).'
```

(e) In `scripts/lib/pause-reasons.sh`, replace

```bash
# Adding a reason is one row here plus a branch in classify-failure.sh — that
# is the whole contract (#518 adds `model_unavailable` this way).
```

with

```bash
# Adding a reason is one row here plus a branch in classify-failure.sh — that
# is the whole contract. Not every operator-fixable class belongs here:
# `model_not_found` (#518) is alert-only, because a wrong model id on one
# issue's label says nothing about the other issues in the repo.
```

- [ ] **Step 5: Layer-2 act test**

In `.github/workflows/agent-implement.test.yml`, add after the `call-opencode-task-failure` job:

```yaml
  call-opencode-model-not-found:
    name: Reusable workflow — opencode model not found (#518)
    uses: ./.github/workflows/agent-implement.yml
    with:
      issue-number: 9014
      default-model: z-ai/glm-9
      timeout-minutes: 10
      dry-run: true
      local-scripts: true
      stub-claude: true
      stub-fixture: opencode_model_not_found
      agent: opencode
      attempt: 1
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: not-used-by-stub
```

and after the `verify-opencode-task-failure` job:

```yaml
  verify-opencode-model-not-found:
    name: Assert opencode model-not-found path
    needs: call-opencode-model-not-found
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: read
    env:
      OUTCOME:   ${{ needs.call-opencode-model-not-found.outputs.outcome }}
      NUM_TURNS: ${{ needs.call-opencode-model-not-found.outputs.num-turns }}
      FAILURE:   ${{ needs.call-opencode-model-not-found.outputs.failure-class }}
      RETRY:     ${{ needs.call-opencode-model-not-found.outputs.retry-decision }}
    steps:
      - name: Assert a wrong model id is model_not_found and is not retried
        run: |
          fail=0
          [[ "$OUTCOME" == "failed" ]]            || { echo "::error::outcome=$OUTCOME (want failed)"; fail=1; }
          [[ "$NUM_TURNS" == "0" ]]               || { echo "::error::num-turns=$NUM_TURNS (want 0)"; fail=1; }
          [[ "$FAILURE" == "model_not_found" ]]   || { echo "::error::failure-class=$FAILURE (want model_not_found)"; fail=1; }
          [[ "$RETRY" == "stop" ]]                || { echo "::error::retry-decision=$RETRY (want stop)"; fail=1; }
          (( fail == 0 )) || exit 1
          echo "opencode-model-not-found OK: failure=$FAILURE retry=$RETRY"
```

The call job needs no `permissions:` block of its own: like its siblings it inherits the workflow-level block at the top of the file, which `tests/run-script-tests.sh` (section "agent-implement.test.yml — caller permissions cover the callee (#435)") already checks against the callee. This plan adds no permission to the callee.

- [ ] **Step 6: Docs**

(a) `docs/CONSUMER-SETUP.md`: in the blockquote `Troubleshooting — ProviderModelNotFoundError / "Model not found: openrouter/…"`, replace the second paragraph (from `> If the key *is* present` through `> to a genuinely wrong model id.`) with:

```markdown
> If the key *is* present (the run log shows `OPENROUTER_API_KEY present`), the
> model id is wrong. Since #518 the pipeline checks the id against
> [OpenRouter's model list](https://openrouter.ai/models) before the agent
> starts and fails the run as `model_not_found`: the run report names the model
> and the fix, the operator gets one ntfy push (when ntfy is configured), and
> the run is neither retried nor counted as an attempt. Correct `default-model`
> or the issue's `model:` label and re-dispatch.
```

and add, directly after the `OpenCode requires tool-use` blockquote in the "Per-issue model labels" section:

```markdown
### Adding a new OpenRouter model

Set `default-model` (or map a `model:*` label) to the id exactly as
[openrouter.ai/models](https://openrouter.ai/models) shows it, e.g.
`z-ai/glm-5.3`. Nothing else is needed, however new the model is:

- The pipeline declares the id to opencode itself
  (`scripts/opencode-model-config.sh`), so it does not have to be in the model
  catalog bundled with the pinned opencode version.
- Before each run the pipeline refreshes opencode's catalog from models.dev so
  cost and context limits are reported. A model too new for models.dev still
  runs; its run report then shows `$0.00`.
- An id OpenRouter does not list stops the run before the agent starts, as
  `model_not_found` (see Troubleshooting below).

Check that the model advertises `tools` first — see the note above.
```

(b) `docs/DEFAULT-MODEL-CHEATSHEET.md`, Troubleshooting, first bullet: replace the text from `If the key is present` through `means the model id is genuinely wrong.` with:

```markdown
If the key is present, the model id is wrong: since #518 the pipeline checks
  it against OpenRouter's model list before the agent starts and fails the run
  as `model_not_found` (no retry, not an attempt, one ntfy push). Fix
  `default-model` or the `model:` label. A model newer than the pinned
  opencode's bundled catalog is fine — the pipeline declares the id itself.
```

- [ ] **Step 7: Run everything**

Run: `bash tests/run-all.sh && shellcheck -x -e SC1091 $(find scripts tests -type f -name '*.sh' | sort) && actionlint`
Expected: PASS, no findings. If `act` and Docker are available: `just test-act` — `verify-opencode-model-not-found` passes.

- [ ] **Step 8: Commit**

```bash
git add .github/workflows/agent-implement.yml .github/workflows/agent-implement.test.yml scripts/lib/pause-reasons.sh docs/CONSUMER-SETUP.md docs/DEFAULT-MODEL-CHEATSHEET.md tests/run-opencode-model-tests.sh
git commit -m "fix(opencode): preflight, inject and alert on the model id in the implement job (#518)

Closes #518"
```
