# Agent-step timeout: report it, grade the pushed work — Design

**Issue:** #567 · **Status:** approved (quick mode, headless) · **Blocked by:** #535

## Problem

When `Run Claude Code` hits its step-level `timeout-minutes`
(`inputs.claude-timeout-minutes`), the runner kills the step before
`claude-code-base-action` sets `execution_file`. Every later step in the
implement job is gated on a result file (`agent-implement.yml:961`, `:979`,
`:1060`, `:1079`, `:1123`), so classify, verify-PR, plan coverage and the run
report are all skipped, and both review jobs are skipped because
`needs.implement.outputs.outcome` is empty.

Observed: game-rhyflitzer #353, run 39326893816. The step was killed at
exactly 100 minutes. By then the agent had pushed commits for plan Tasks 1–10
of 11 to PR #393. No report was posted, no review ran, the PR stayed draft,
and the only trace on the issue was the previous attempt's report.

## What #535 already changes

#535 (part 1) moves every decision into a new `implement_gate` job that runs
whenever a trusted pre-agent marker says the agent was due
(`agent-eligible`). A missing result becomes a synthetic
`error_invalid_evidence` result (`import-result-output.sh`), classified
`bug`, reported `ai:failed`. So after #535 a timeout **does** get a report —
but it says "invalid evidence", grades no plan coverage (`find_pr` only runs
on `outcome == success`), and tells the operator nothing about the pushed work.

This design sits on top of #535 and is dispatched only after it merges.

## Design

1. **Trusted start time.** #535's pre-agent step `Mark the agent step reached`
   (`id: agent_reached`) also writes `started-at=<epoch seconds>`. A new
   implement output `agent-started-at` carries it. It is written before any
   agent runs, so it is a trusted output in #535's sense.

2. **Detect the timeout in the gate.** A new script
   `scripts/detect-agent-timeout.sh` runs in `implement_gate` right after
   `Import the implement job's result`. It declares a timeout only when all of
   these hold:
   - the imported evidence is invalid (`valid=false`: no result came back),
   - the agent is `claude` (the only agent step with a step-level wall-clock
     cap; `Run OpenCode` has none, `agent-implement.yml:791-883`),
   - `now - agent-started-at >= claude-timeout-minutes * 60`.

   Every input is trusted (pre-agent output, workflow input, the gate's own
   clock). The elapsed time includes the post-agent steps, so it can only
   overstate — a run that crashed in its last minute or two is reported as a
   timeout, which is accepted. On a timeout it rewrites the result file to a
   synthetic `error_agent_timeout` result with `duration_ms` = elapsed and a
   `timeout_minutes` field, and outputs `timed-out=true`.

3. **Classify without retry.** `classify-failure.sh` maps
   `error_agent_timeout` to a new class `agent_timeout`, ahead of the text
   regexes. `retry-dispatch.sh` stops on it: a retry would start a second
   full-length run against a PR that already holds the first run's work.

4. **Grade the pushed work.** `find_pr` in the gate also runs when
   `timed-out == 'true'`, so `Check plan coverage` and `Check the PR's required
   checks can run` grade the PR the agent pushed.

5. **Say it in the report.** `post-run-report.sh` gets a rung for
   `error_agent_timeout`, below the pause and model-not-found rungs and above
   the generic agent-error rung:
   - PR present, coverage `partial` → `:warning: timed out at the agent's
     N-minute wall-clock cap: plan task(s) X have no file in the PR`,
     label `ai:partial`.
   - PR present, coverage `complete` → `:warning: timed out … every plan task
     has a file in the PR, but the run did not finish`, `ai:partial`.
   - PR present, coverage unverifiable → `:warning: timed out … work was pushed
     to the PR; plan coverage unverifiable`, `ai:partial`.
   - No PR → `:x: failed: timed out at … before a PR was opened`, `ai:failed`.

6. **No review.** The gate's `outcome` stays `failed` (the result is an
   error), so neither review job runs and the PR stays draft. A human picks it
   up from the report.

## Rejected

- **Exporting the agent step's `outcome` from the implement job.** That output
  would be written on a runner the agent touched. The elapsed-time rule needs
  no evidence at all.
- **Running the human-merge review on a timed-out PR.** The work is
  incomplete by definition (at least the final verification never ran);
  reviewing it spends a review and invites a promotion. #568 is about keeping
  partial PRs out of promotion in general.
- **Retrying a timeout** (`task_failure` retries once). It doubles the most
  expensive kind of run and the retry starts from the issue, not from the PR.
- **Adding a step timeout to `Run OpenCode`.** It would cap OpenCode at
  `claude-timeout-minutes` (default 10) where it gets the job timeout today; a
  behaviour change for every consumer, out of scope.
- **An act scenario.** A stub that sleeps past a 1-minute cap costs a minute
  per test run and only re-proves GitHub's step timeout; the gate logic is
  covered by Layer-1 tests.

## Testing

Layer-1: a new runner `tests/run-agent-timeout-tests.sh` for the detector;
fixture-driven cases for `classify-failure.sh`, `retry-dispatch.sh` and
`post-run-report.sh` in `tests/run-script-tests.sh`; structural greps of the
workflow wiring in `tests/run-script-tests.sh`.

## Consequences

- A timed-out run reports `$0.00` and `0` turns: the action never wrote its
  stream, so cost and turns are unknown, not zero. The report's duration is
  the measured elapsed time.
- Uncommitted work at the moment of the kill is still lost: `Verify or recover
  PR` needs a result file and stays skipped. The contract's push-per-task rule
  is what limits the loss.
- An OpenCode run that hits the **job** timeout is not covered: the whole job
  dies, and whether the gate still runs depends on #535's `!cancelled()`.
- Overlap: #568 also edits `post-run-report.sh`'s status ladder and
  `agent-implement.yml`; #553 edits `agent-implement.yml` and
  `tests/run-script-tests.sh`. Dispatch none of them concurrently with this.
