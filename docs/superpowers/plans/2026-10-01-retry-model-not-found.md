# Retry Model-Not-Found Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A 0-turn opencode run that dies on a transient `ProviderModelNotFoundError` is classified `transient` and retried. That retry escalates to Claude. Any failed agent run also makes the `implement` job conclude `failure` instead of green.

**Architecture:** Three small changes on the existing failure path (`adapt-opencode-result.sh` → `classify-failure.sh` → `retry-dispatch.sh`, then the `implement` job's end):
1. The adapter stops discarding every error event but the last.
2. The classifier gets a 0-turn model-not-found branch that maps to the existing `transient` class, so `retry-dispatch.sh` needs no change.
3. A new last step in the `implement` job exits 1 when `outcome == 'failed'`. Stub runs are exempt, so the act suite is unaffected.

**Tech Stack:** Bash, `jq`, GitHub Actions reusable-workflow YAML, the Layer-1 fixture suite (`tests/run-script-tests.sh`, discovered by `tests/run-all.sh`), shellcheck and actionlint via pre-commit.

**Spec:** `docs/superpowers/specs/2026-10-01-retry-model-not-found-design.md`

## Prerequisite: pushing a workflow-file change

Task 3 edits `.github/workflows/agent-implement.yml`. A pipeline run can push
that file only if the pipeline App has repository permission `Workflows: Read
and write` (see `docs/PIPELINE-APP-SETUP.md` and the prerequisite in
`docs/superpowers/plans/2026-09-27-app-token-pushes.md`). Without it the whole
push is rejected. A local implementation is unaffected.

## Global Constraints

- **TDD.** Write each new assertion first, run it, and watch it fail for the stated reason before you implement. Never edit an existing assertion to make it pass.
- **Real fixture text.** `tests/fixtures/opencode-model-not-found.json` holds the two `error` events from game-sky-fury run 36632007246 **byte-for-byte** (below). Do not "clean up" the message, the `ref`, or the session id.
- **No new failure class.** Map to `transient`. The `failure-class` output's documented value set (`agent-implement.yml` around line 318) stays as it is.
- **The model-not-found branch requires `num_turns == 0`** and comes **after** `api_auth`. That way the `#164` missing-secret `AuthError` stays `api_auth`.
- **The adapter output stays byte-identical for single-error and text-bearing streams.** The existing `adapt-opencode-result` assertions must stay green untouched.
- **The fail step is the last step of the `implement` job**, gated on `always() && !inputs.stub-claude && steps.outputs.outputs.outcome == 'failed'`.
- Structural workflow assertions strip YAML comments or extract the job block, as the existing `#430`/`#302` guards do.
- Conventional Commits, each ending `(#439)`.

**Line numbers are as of `origin/main` at the time of writing.** Anchor on the quoted text.

Test commands:

```bash
bash tests/run-script-tests.sh        # the suite all new assertions live in (~40 s)
bash tests/run-all.sh                 # full Layer-1 (what `just test` and CI run)
just lint-shell                       # shellcheck + actionlint (needs pre-commit + Docker)
```

---

### Task 1: The adapter keeps every error message

**Files:**
- Create: `tests/fixtures/opencode-model-not-found.json`
- Modify: `tests/run-script-tests.sh`, section `adapt-opencode-result — normalize OpenCode output to canonical shape` (around line 2606)
- Modify: `scripts/adapt-opencode-result.sh`, the `result:` expression (around lines 109-114)

- [ ] **Step 1: Add the real fixture**

Create `tests/fixtures/opencode-model-not-found.json` with exactly these two lines:

```json
{"type":"error","timestamp":1790716558351,"sessionID":"ses_f10f9c524ffesGQuaVc2YkeLUu","error":{"name":"UnknownError","data":{"message":"Model not found: openrouter/z-ai/glm-5.2. Did you mean: z-ai/glm-4-32b, z-ai/glm-4.5, z-ai/glm-4.5-air?"}}}
{"type":"error","timestamp":1790716558351,"sessionID":"ses_f10f9c524ffesGQuaVc2YkeLUu","error":{"name":"UnknownError","data":{"message":"Unexpected server error. Check server logs for details.","ref":"err_662ec1ef"}}}
```

- [ ] **Step 2: Write the failing adapter assertions**

In `tests/run-script-tests.sh`, directly after the `# Preflight missing-key event → canonical error result (#164)` block, before `# Unparseable input → bug-bucket result`, add:

```bash
# Transient catalog miss (#439): opencode emits the useful message FIRST and a
# generic "Unexpected server error" LAST. Keeping only the last error event threw
# away the one line the classifier can bucket, so the run became class=bug.
# Fixture is verbatim from game-sky-fury run 36632007246.
out="$(EXECUTION_FILE="$FIXTURES/opencode-model-not-found.json" MODEL=z-ai/glm-5.2 bash "$ADAPT_OC")"
assert_equals "$(printf '%s' "$out" | jq -r '.is_error')"  "true" "model-not-found → is_error true"
assert_equals "$(printf '%s' "$out" | jq -r '.num_turns')" "0"    "model-not-found → num_turns 0"
assert_contains "$(printf '%s' "$out" | jq -r '.result')" 'Model not found: openrouter/z-ai/glm-5.2' \
  "multi-error stream → result keeps the first error message"
assert_contains "$(printf '%s' "$out" | jq -r '.result')" 'Unexpected server error' \
  "multi-error stream → result keeps the last error message too"
```

- [ ] **Step 3: Run it and confirm it fails**

Run: `bash tests/run-script-tests.sh 2>&1 | grep -E 'model-not-found|multi-error|tests passed'`
Expected: `✗ multi-error stream → result keeps the first error message`. Today `.result` is only `Unexpected server error. Check server logs for details.` The other three new assertions pass.

- [ ] **Step 4: Implement**

In `scripts/adapt-opencode-result.sh`, replace

```jq
    result: (
      ($texts | last | .part.text)
      // ($errs  | last | .error.data.message)
      // ($errs  | last | .error.name)
      // ""
    ),
```

with

```jq
    result: (
      ($texts | last | .part.text)
      // (if ($errs | length) > 0
          then [ $errs[] | (.error.data.message // .error.name // empty) ] | join("\n")
          else null end)
      // ""
    ),
```

In the header comment, change the line `#   - error       — failure; .error.data.message becomes the result and flips` / `#     is_error.` so it says every error event's `.error.data.message` (falling back to `.error.name`) is joined, in stream order, into the result. Add the reason: opencode may follow the meaningful error with a generic "Unexpected server error" (#439).

- [ ] **Step 5: Run it and confirm it passes**

Run: `bash tests/run-script-tests.sh 2>&1 | tail -3`
Expected: all tests pass, including the existing `rate-limit`, `auth-fail`, `missing-key` and `unparseable` adapter assertions.

- [ ] **Step 6: Commit**

```bash
git add tests/fixtures/opencode-model-not-found.json tests/run-script-tests.sh scripts/adapt-opencode-result.sh
git commit -m "fix(retry): keep every opencode error message in the adapter result (#439)"
```

---

### Task 2: Classify a 0-turn model-not-found as transient

**Files:**
- Modify: `tests/run-script-tests.sh`, the adapter→classifier block (around line 2660) and section `classify-failure — buckets per fixture` (around line 2676)
- Modify: `scripts/classify-failure.sh`

- [ ] **Step 1: Write the failing classifier assertions**

After `assert_contains "$out" 'class=api_auth' "missing OPENROUTER_API_KEY → api_auth (no retry)"`, add:

```bash
# Transient opencode catalog miss (#439): 0 turns + "Model not found" is an
# infrastructure blip, not a bug. Retrying it (and escalating to Claude on
# attempt 2) is what the operator ended up doing by hand.
out="$(adapter_to_classifier opencode-model-not-found.json)"
assert_contains "$out" 'class=transient' "opencode 0-turn model-not-found → transient (retried)"
```

In section `classify-failure — buckets per fixture`, before `ec="$(run_capture_ec env bash "$CLASSIFY_FAIL")"`, add:

```bash
# The model-not-found branch is guarded by num_turns == 0: a catalog miss can only
# happen before the first step. The same text after real turns is something else
# and must still reach the operator as a bug (#439).
mnf_tmp="$(mktemp --suffix=.json)"
jq -nc '{type:"result",subtype:"error_during_execution",is_error:true,duration_ms:0,num_turns:0,total_cost_usd:0,session_id:"s",result:"Model not found: openrouter/z-ai/glm-5.2. Did you mean: z-ai/glm-4.5?",usage:{input_tokens:0,output_tokens:0,cache_creation_input_tokens:0,cache_read_input_tokens:0}}' > "$mnf_tmp"
out="$(RESULT_FILE="$mnf_tmp" bash "$CLASSIFY_FAIL")"
assert_contains "$out" 'class=transient' "model-not-found at 0 turns → transient"
jq -c '.num_turns = 3' "$mnf_tmp" > "$mnf_tmp.3" && mv "$mnf_tmp.3" "$mnf_tmp"
out="$(RESULT_FILE="$mnf_tmp" bash "$CLASSIFY_FAIL")"
assert_contains "$out" 'class=bug' "model-not-found after real turns → still bug"
rm -f "$mnf_tmp"
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `bash tests/run-script-tests.sh 2>&1 | grep -E 'model-not-found|tests passed'`
Expected: `✗ opencode 0-turn model-not-found → transient (retried)` and `✗ model-not-found at 0 turns → transient`, both with `class=bug`. `model-not-found after real turns → still bug` passes.

- [ ] **Step 3: Implement**

In `scripts/classify-failure.sh`:

1. After `result_text="$(jq -r '.result // ""' "$RESULT_FILE")"`, add:

   ```bash
   num_turns="$(jq -r '.num_turns // ""' "$RESULT_FILE")"
   ```

2. Between the `transient` regex branch and `elif [[ "$subtype" == "error_max_turns" ]]; then`, add:

   ```bash
   elif [[ "$num_turns" == "0" ]] && printf '%s' "$result_text" | grep -qiE 'model not found|ProviderModelNotFoundError'; then
     # opencode resolves the model against a catalog it fetches at startup; when
     # that fetch fails it falls back to a bundled snapshot that may not know a
     # newer model, and dies before the first step (#439). Transient: retry, and
     # escalate-on-retry moves attempt 2 to Claude. The 0-turn guard keeps a
     # mid-run model error in `bug`; api_auth is matched first, so the #164
     # missing-key preflight never lands here.
     class=transient
   ```

3. In the header, extend the `transient` line to `#   - transient    → 5xx / network / timeout / 0-turn model-not-found — retry with exponential backoff`.

- [ ] **Step 4: Run it and confirm it passes**

Run: `bash tests/run-script-tests.sh 2>&1 | tail -3`
Expected: all tests pass. Also confirm that `retry-dispatch — policy decisions` still shows `✓ transient attempt=1 → 10s backoff`. The retry side needs no change.

- [ ] **Step 5: Commit**

```bash
git add tests/run-script-tests.sh scripts/classify-failure.sh
git commit -m "fix(retry): retry a 0-turn opencode model-not-found as transient (#439)"
```

---

### Task 3: Fail the implement job when the agent run failed

**Files:**
- Modify: `tests/run-script-tests.sh`: a new section at the end, just before `# --- summary ---`
- Modify: `.github/workflows/agent-implement.yml`: append a step after `- name: Post run report` (around line 980), immediately before `  ai_review_ai_merge:` (around line 1000)

- [ ] **Step 1: Write the failing structural assertions**

Add before `# --- summary ---`:

```bash
section "agent-implement.yml — a failed agent run fails the implement job (#439)"

# The OpenCode step swallows opencode's exit code on purpose so the adapter,
# classifier, retry and run report still run. Nothing turned the failure back into
# a red job, so game-sky-fury run 36632007246 showed green with
# "Outcome: failed: error_during_execution" in its report.
WF439="$ROOT/.github/workflows/agent-implement.yml"
impl439="$(awk '/^  implement:$/{f=1;next} f && /^  [a-z_]+:$/{exit} f' "$WF439")"
last439="$(printf '%s\n' "$impl439" | grep -E '^      - name: ' | tail -1 | sed 's/^      - name: //')"
assert_equals "$last439" "Fail the job when the agent run failed" \
  "the implement job's LAST step fails it on a failed run (post-run steps run first)"
step439="$(printf '%s\n' "$impl439" | awk '/^      - name: Fail the job when the agent run failed$/{f=1;print;next} f && /^      - name: /{exit} f' | grep -vE '^[[:space:]]*#')"
assert_contains "$step439" 'always()'                                  "fail step runs after earlier failures too"
assert_contains "$step439" '!inputs.stub-claude'                       "fail step skips stub runs (act suite asserts outputs)"
assert_contains "$step439" "steps.outputs.outputs.outcome == 'failed'" "fail step keys off the run outcome"
assert_contains "$step439" 'exit 1'                                    "fail step actually fails"
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `bash tests/run-script-tests.sh 2>&1 | grep -A1 -E 'LAST step|fail step'`
Expected: `✗ the implement job's LAST step …` with `expected 'Fail the job when the agent run failed' got 'Post run report'`, plus the four `fail step …` assertions failing.

- [ ] **Step 3: Implement**

In `.github/workflows/agent-implement.yml`, after the `Post run report` step's `run: bash .claude-pipeline/scripts/post-run-report.sh` line and before the blank line and `  ai_review_ai_merge:`, insert:

```yaml

      - name: Fail the job when the agent run failed
        # Last step on purpose (#439). The OpenCode step swallows opencode's exit
        # code so the adapter, classifier, retry, labels and run report above can
        # all run; without this the job ends green on a failed run and only the
        # ai:failed label tells the truth. Job outputs are still published from a
        # failed job, and the review jobs already require outcome == 'success'.
        # Stub runs are tests: the act suite asserts their outputs from verify-*
        # jobs that would be skipped behind a red call job (same carve-out as
        # `Plan retry`'s DRY_RUN). A parked run has no result file, so outcome is
        # empty and this is skipped.
        if: ${{ always() && !inputs.stub-claude && steps.outputs.outputs.outcome == 'failed' }}
        env:
          FAILURE_CLASS: ${{ steps.classify_failure.outputs.class }}
          RETRY_DECISION: ${{ steps.retry.outputs.decision }}
        run: |
          printf '::error title=Implement failed::agent run failed (class=%s, retry=%s); see the run report on the issue\n' \
            "$FAILURE_CLASS" "${RETRY_DECISION:-none}"
          exit 1
```

- [ ] **Step 4: Run it and confirm it passes**

Run: `bash tests/run-script-tests.sh 2>&1 | tail -3`
Expected: all pass. The `#430` and `#302` structural counts are unaffected because the step adds no `app_token`, `npm` or `install-claude-cli` reference. If any count changes, stop and investigate. Do not edit the count.

Run: `just lint-shell`
Expected: actionlint is clean on `agent-implement.yml`.

- [ ] **Step 5: Commit**

```bash
git add tests/run-script-tests.sh .github/workflows/agent-implement.yml
git commit -m "fix(implement): fail the job when the agent run failed (#439)"
```

---

### Task 4: Troubleshooting docs and full verification

**Files:**
- Modify: `docs/CONSUMER-SETUP.md`, the `Troubleshooting — ProviderModelNotFoundError` blockquote (around line 397)
- Modify: `docs/DEFAULT-MODEL-CHEATSHEET.md`, the `ProviderModelNotFoundError` bullet (around line 155)

- [ ] **Step 1: Update both entries**

Keep the "almost always a missing `OPENROUTER_API_KEY`" guidance. Add one or two sentences: if the key is present (the run log shows `OPENROUTER_API_KEY present`) and the run died at 0 turns, opencode most likely failed to fetch its model catalog and fell back to a bundled snapshot that lacks newer models. Since #439 the pipeline classifies this as `transient` and retries it automatically; with `escalate-on-retry`, the retry runs on Claude. Only a failure that **recurs** on retry with an `agent:opencode` label points to a genuinely wrong model id.

- [ ] **Step 2: Full verification**

Run: `bash tests/run-all.sh`
Expected: every runner passes.

Run: `just lint-shell`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add docs/CONSUMER-SETUP.md docs/DEFAULT-MODEL-CHEATSHEET.md
git commit -m "docs(retry): explain the transient model-not-found retry (#439)"
```
