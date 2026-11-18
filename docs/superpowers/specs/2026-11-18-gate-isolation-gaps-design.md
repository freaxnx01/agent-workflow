# Close the remaining gate-isolation gaps after #571 — design

Issue: #592. Follows #535 / #571 (the `implement_gate` job).

## Intent

#571 moved every decision about an implement run into `implement_gate`, a job
that never runs an agent. Four gaps keep #535 open. Each one lets an agent, or
plain bad luck, affect the verdict on its own run:

- **F7:** on self-hosted runners the gate can share a machine with the agent.
- **F8:** both App tokens are minted with every permission the installation has.
- **F6:** a masked output can turn a good run into `error_invalid_evidence`, and
  the warning doesn't say so.
- **F9:** no act scenario drives bad evidence end to end.

## Goals

1. **F7, fail closed.**
   - A run whose `runner-labels` contains `self-hosted` and whose
     `gate-runner-labels` is empty refuses in the implement job before the agent
     starts.
   - The refusal is an `::error::` naming `gate-runner-labels` and the opt-out.
   - Consumers who accept the risk set a new boolean input,
     `allow-shared-gate-runner` (default `false`). An example is ephemeral
     self-hosted runners, which start clean per job.
2. **F8, scoped tokens.** Both mints pass explicit `permission-*` inputs:
   - **Implement job:** `contents: write`, `pull-requests: write`,
     `issues: write`. Never `actions`. `workflows: write` only when the new
     boolean input `app-token-workflows-write` is `true` (default `false`).
   - **Gate job:** `contents: read`, `issues: write`, `pull-requests: read`,
     `checks: read`, `statuses: read`.
     - `issues: write` is needed because "Raise pipeline alarm" runs
       `pipeline-pause.sh` with the App token, which creates, pins and closes
       alarm issues.
     - Checks and statuses are read through `gh pr view --json
       statusCheckRollup` in `check-pr-checks-runnable.sh` (#482).
3. **F6.** The `No valid result evidence` warning in
   `scripts/import-result-output.sh` names masking as a possible cause. GitHub
   drops a job output that contains a secret-masked value, for example the
   numeric `PIPELINE_APP_ID`.
4. **F9.** Two new act scenarios in `agent-implement.test.yml`. Each ends with
   the gate replacing the evidence with its synthetic `error_invalid_evidence`
   result. The reusable workflow's outputs show that as `outcome == failed`,
   `failure-class == bug` (`classify-failure.sh` maps the synthetic subtype to
   `bug`, checked 2026-11-18) and `num-turns == 0`. Every stub fixture reports
   at least one turn, so `num-turns == 0` is what proves the gate discarded the
   evidence:
   - **empty evidence:** the stub result is not a JSON object, so
     `export-result-output.sh` emits an empty `result-json`;
   - **oversized evidence:** the stub overwrites the workspace copy of
     `.claude-pipeline/scripts/export-result-output.sh`, which is the #535
     threat. The replacement emits a canonical-looking `result-json` larger than
     128 KiB, and the gate's raw-capture step fails with E2BIG.
5. **Guards.**
   - `tests/run-agent-isolation-tests.sh` asserts the F8 scopes, with negative
     mutators in the style of the #626 guards.
   - A new script test covers the F7 check.

## Non-goals

- **The review jobs' App token mints** (`ai_review_ai_merge`,
  `ai_review_human_merge`). They also run agents (self-fix) on an unscoped
  token, but #592 names only the implement and gate tokens. That work goes in a
  follow-up issue.
- **Layer 3 cancel behaviour** (operator cancel, concurrency supersede, self
  cancel). Only a real run can check it, so it is an operator checklist item on
  the issue, not an acceptance criterion for the agent.
- **No new ADR entry in `docs/DECISIONS.md`.** #626 appends ADR-024 at the end
  of that file, so a second append would conflict. The decisions are recorded
  here and in the consumer docs.
  - ADR-020, which #535's plan wrote, never landed in `DECISIONS.md`. That is a
    separate discovery.

## Anti-goals

- **A consumer whose App lacks Workflows must not start failing.** That is the
  reason for the opt-in. Requesting a permission the installation doesn't have
  fails the token mint.
- **An opt-out that silently re-opens F7 for everyone.** The default stays
  closed.
- **Don't weaken the F9 oversized scenario if act doesn't reproduce E2BIG.** If
  act passes a 200 KiB env value through, stop and report it. Don't swap in a
  payload that is merely invalid.

## Decisions (operator, 2026-11-18)

- F7: fail closed, with the explicit opt-out `allow-shared-gate-runner`.
- F8: workflows write is opt-in through `app-token-workflows-write`.
- Layer 3: an operator checklist, outside the agent's AC.

## Design

### F7: `scripts/check-gate-runner-isolation.sh`

- **Env:**
  - `RUNNER_LABELS` (JSON array);
  - `GATE_RUNNER_LABELS` (JSON array or empty);
  - `ALLOW_SHARED_GATE_RUNNER` (`true`/`false`).
- **Detection:** a `self-hosted` label means any element whose lowercased value
  equals `self-hosted`. GitHub labels are case-insensitive.
- **Exit codes:**
  - 0 when the run is allowed: not self-hosted, gate labels set, or opted out.
    The opt-out still prints a `::warning::` saying the gate shares the agent's
    runner.
  - 1 when it is refused.
  - 2 when `RUNNER_LABELS` is not a JSON array of strings.
- **Placement:** in the implement job, right after "Checkout agent-workflow
  scripts" and before any agent step. It is pre-agent and trusted. A refusal
  fails the implement job before `agent-eligible`, so `implement_prefail`
  (ADR-023) reports it on the issue.
- **Shim:** `claude-implement.yml` gains `gate-runner-labels`, which is missing
  today, plus `allow-shared-gate-runner` and `app-token-workflows-write`. Those
  forward verbatim, so shim consumers on self-hosted runners have a way out.

### F8: mint inputs

- The implement mint gets three fixed `permission-*` lines, plus
  `permission-workflows: ${{ inputs.app-token-workflows-write && 'write' || '' }}`.
  An empty value omits the permission.
- The gate mint gets its five fixed lines.
- **Verified (2026-11-18):** an empty `permission-workflows` requests nothing.
  At the pinned SHA `fee1f7d…`, `lib/get-permissions-from-inputs.js` skips any
  `INPUT_PERMISSION-*` whose value is empty (`if (!value) return permissions;`),
  so one mint step with an expression is enough.
- **Doc updates:**
  - `docs/PIPELINE-APP-SETUP.md` "What the App token governs": the token now
    carries only what each job requests, intersected with what the App holds. A
    workflow-editing plan needs both the App's Workflows permission and
    `app-token-workflows-write: true`.
  - `docs/CONSUMER-SETUP.md` documents both new inputs.
  - `docs/RUNNER-REQUIREMENTS.md` gets a short "self-hosted: gate placement"
    paragraph.

### F9: stub fixtures

- New `stub-fixture` values in `agent-implement.yml`'s stub step:
  `evidence_empty` and `evidence_oversized`.
- `evidence_oversized` runs only under `local-scripts: true`. That is the act
  mode, where `.claude-pipeline/` is a workspace mirror.
- The verify jobs mirror the existing `verify-*` jobs: they assert on the
  reusable workflow's outputs.
- **What act does not show:** act reproduces the Linux 128 KiB per-string env
  cap (execve inside the container). It does not reproduce GitHub's secret
  masking or its 1 MB job-output cap, so F6 stays covered by the warning text
  only.

## Review focus

- A self-hosted run with `gate-runner-labels` set must not be refused.
- `["Self-Hosted","linux"]` must be refused: the case-insensitive match.
- A consumer without the App, where `PIPELINE_APP_ID` is empty: no mint, no
  change.
- A plan that edits workflow files, without the opt-in: the push fails with
  GitHub's "without 'workflows' permission" message. This is expected, and the
  docs must say so.
- The opt-out warning prints even though the run proceeds.
