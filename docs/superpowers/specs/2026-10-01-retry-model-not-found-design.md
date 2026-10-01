# Retry a transient opencode model-not-found, and stop reporting failed runs as green

**Issue:** [#439](https://github.com/freaxnx01/agent-workflow/issues/439)
**Date:** 2026-10-01
**Status:** Draft (quick-mode enrichment — assumptions recorded on the issue)

## Problem

Observed on `freaxnx01/game-sky-fury` run `36632007246` (issue #6,
2026-09-29, agent `opencode` 1.15.13, model `z-ai/glm-5.2`). The same
configuration had succeeded twenty minutes earlier on game-sky-fury#9.

opencode wrote exactly two events to `opencode-output.json` and exited 1 after
**0 turns, 0 s, $0**:

```json
{"type":"error",...,"error":{"name":"UnknownError","data":{"message":"Model not found: openrouter/z-ai/glm-5.2. Did you mean: z-ai/glm-4-32b, z-ai/glm-4.5, z-ai/glm-4.5-air?"}}}
{"type":"error",...,"error":{"name":"UnknownError","data":{"message":"Unexpected server error. Check server logs for details.","ref":"err_662ec1ef"}}}
```

The stderr log names the cause as `ProviderModelNotFoundError`. The secret was
present (the `#164` preflight printed `OPENROUTER_API_KEY present`), and both
OpenRouter and models.dev still listed the model. The most likely cause is that
opencode's runtime fetch of the model catalog failed, so it fell back to its
bundled snapshot, which only lists glm-4.x. That failure is transient.

Two defects followed from it.

### 1. The failure was bucketed `bug`, so no retry happened

`adapt-opencode-result.sh` builds `.result` from **the last** error event only
(`$errs | last | .error.data.message`). The run's useful message, `Model not
found: …`, was in the first event, so the canonical result became:

```json
{"subtype":"error_during_execution","is_error":true,"num_turns":0,"result":"Unexpected server error. Check server logs for details.", ...}
```

`classify-failure.sh` matches none of its regexes against that text and falls
through to `class=bug`, and `retry-dispatch.sh` stops on `bug`. The redispatch
the operator then triggered by hand (attempt 2, escalated to Claude by
`escalate-on-retry`) succeeded. That is exactly the path the pipeline should
have taken on its own.

The adapter fault matters beyond this case. ADR-001 §2 calls `result`
*load-bearing on failure*, because the classifier keys off it. Dropping all but
the last error event throws away the signal the contract exists to carry.

### 2. The implement job ended green although the run failed

`Implement issue #6` concluded **success**. The run report said `Outcome:
failed: error_during_execution`, and the `outcome` output was `failed`. The
OpenCode step catches opencode's non-zero exit on purpose (`oc_rc`, then
`::warning::` and exit 0, `agent-implement.yml` around line 798), so later
steps still run: the adapter, the classifier, the retry, the labels and the run
report. That part is correct. But nothing turns the failure back into a failing
job at the end, so the Actions overview shows a green run. Only the
`ai:failed` label and the issue comment show the truth.

## Goal

- A 0-turn opencode run that ends in model-not-found gets a **retry**, not a
  stop. With the default `escalate-on-retry: true`, attempt 2 runs on Claude,
  so even a bad model id cannot keep failing on the cheap agent.
- A failed agent run makes the **implement job conclude `failure`**, after
  every post-run step has run.

## Approach

### A. The adapter keeps every error message

When the stream has no `text` event, `.result` becomes **all** error messages,
joined with newlines and kept in stream order, each one
`.error.data.message // .error.name`. The precedence is unchanged otherwise:
the last `text` event still wins when one exists. For a single-error stream,
which covers every existing fixture, the output is byte-identical to today's.

### B. The classifier knows model-not-found

Add a branch to `classify-failure.sh` after `api_auth` and before
`error_max_turns`:

```bash
elif [[ "$num_turns" == "0" ]] && printf '%s' "$result_text" | grep -qiE 'model not found|ProviderModelNotFoundError'; then
  class=transient
```

- **The 0-turn guard keeps it precise.** A catalog miss happens before the
  first step, by construction. A model-not-found text that turns up after real
  turns is something else, and it still falls through to `bug`.
- **Order keeps `#164` intact.** The missing-secret preflight's `AuthError …
  OPENROUTER_API_KEY is not set` is matched by `api_auth` first, so a missing
  key never becomes retryable.
- **It reuses `transient`, not a new class.** The `failure-class` output
  contract, the act assertions and the policy table stay as they are.
  `transient` retries at most `MAX_RETRIES_TRANS` (3) times with a 10 s / 20 s
  backoff, and the issue-level `max-attempts` cap bounds it again. From attempt
  2 the agent escalates to Claude, which never consults opencode's catalog, so
  a genuinely misconfigured model costs at most one extra $0, 0-turn opencode
  run before Claude takes over. The exception is an `agent:opencode` label,
  which pins the agent and allows up to two more such runs.

### C. A last step fails the job on a failed run

Append a final step to the `implement` job:

```yaml
      - name: Fail the job when the agent run failed
        if: ${{ always() && !inputs.stub-claude && steps.outputs.outputs.outcome == 'failed' }}
        env:
          FAILURE_CLASS: ${{ steps.classify_failure.outputs.class }}
          RETRY_DECISION: ${{ steps.retry.outputs.decision }}
        run: |
          printf '::error title=Implement failed::agent run failed (class=%s, retry=%s); see the run report on the issue\n' \
            "$FAILURE_CLASS" "${RETRY_DECISION:-none}"
          exit 1
```

- **It must be the last step.** Every post-run step is `if: always()` and
  already sits above it, so the labels, the retry and the report still run.
  Job outputs (`outcome`, `failure-class`, `retry-decision`) are still
  published from a failed job.
- **Downstream jobs are unaffected.** `ai_review_ai_merge` and
  `ai_review_human_merge` already require `needs.implement.outputs.outcome ==
  'success'`, so they were skipped on a failed run before and still are.
- **`!inputs.stub-claude` keeps the act suite green.** That suite drives stub
  failures through the callee and asserts their outputs. Its `verify-*` jobs
  `need:` the call jobs with no `always()`, so a red call job would skip them
  and turn the test workflow red. The `Plan retry` step already uses the same
  carve-out ("Stub runs are tests — never auto-redispatch").
- **Parked runs stay green.** When `check-attempt-cap` parks a run, no result
  file exists, `outcome` is empty, and the step is skipped.

## Acceptance criteria

- [ ] Fixture `tests/fixtures/opencode-model-not-found.json` contains the two
      error events from run 36632007246 verbatim.
- [ ] `adapt-opencode-result.sh` on that fixture yields `is_error: true`,
      `num_turns: 0`, and a `.result` that contains both `Model not found:
      openrouter/z-ai/glm-5.2` and `Unexpected server error`.
- [ ] The adapter output for every existing opencode fixture is unchanged
      (the existing assertions stay green).
- [ ] Adapter → classifier on the new fixture gives `class=transient`.
- [ ] The same result with `num_turns` > 0 gives `class=bug`.
- [ ] `opencode-missing-key.json` still gives `class=api_auth`.
- [ ] `retry-dispatch.sh` with `CLASS=transient ATTEMPT=1` gives
      `decision=retry` (existing assertion, re-confirmed).
- [ ] `agent-implement.yml`: the `implement` job's **last** step is `Fail the
      job when the agent run failed`. Its `if:` requires `always()`,
      `!inputs.stub-claude` and `outcome == 'failed'`, and it exits 1.
- [ ] The `classify-failure.sh` header and the `ProviderModelNotFoundError`
      troubleshooting entries in `docs/CONSUMER-SETUP.md` and
      `docs/DEFAULT-MODEL-CHEATSHEET.md` describe the transient case and its
      automatic retry.
- [ ] `bash tests/run-all.sh` passes. `just lint-shell` (shellcheck and
      actionlint) passes.

## Out of scope

- **Passing a fallback model to opencode directly** (the issue's alternative
  suggestion). Retry plus escalate-on-retry already gets there one attempt
  later, without new configuration.
- **Pinning or pre-warming opencode's model catalog**, for example a
  `models.dev` cache on the runner. Worth a separate issue if catalog misses
  recur.
- Model-not-found on the **Claude** path (`not_found_error`). That has not been
  observed and would be a different matcher.
- **The Azure DevOps runner** (`scripts/implement-azdo.sh`), which has no retry
  dispatch.
- A new act (Layer-2) stub fixture for model-not-found. The Layer-1 tests cover
  the classifier and the workflow structure.
