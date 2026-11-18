# Gate-Isolation Gaps Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close #592's gaps F6–F9 in `implement_gate`'s isolation:
- fail closed when the gate would share a self-hosted runner;
- scope both App tokens;
- name masking in the evidence warning;
- add act scenarios for bad evidence.

**Architecture:**
- **F7:** a new pre-agent script in the implement job.
- **F8:** explicit `permission-*` inputs on the two `create-github-app-token`
  steps.
- **Guard:** the structural guard `tests/run-agent-isolation-tests.sh` pins
  both, with negative mutators.
- **F9:** two new stub fixtures drive the gate's existing synthetic-failure
  path under act.

**Tech Stack:** Bash 5, GitHub Actions YAML, python3 + PyYAML in the guard, act.

**Spec:** `docs/superpowers/specs/2026-11-18-gate-isolation-gaps-design.md`

## Global Constraints

- New inputs on `agent-implement.yml`, both `type: boolean`, `default: false`:
  - `allow-shared-gate-runner`
  - `app-token-workflows-write`
- `scripts/check-gate-runner-isolation.sh` exit codes:
  - 0: allowed;
  - 1: refused;
  - 2: `RUNNER_LABELS` is not a JSON array of strings.
- The refusal is a `::error title=Gate shares the agent's runner::…` line that
  names both `gate-runner-labels` and `allow-shared-gate-runner`.
- `self-hosted` is matched case-insensitively against whole labels.
- **Implement mint `permission-*`:**
  - `contents: write`, `pull-requests: write`, `issues: write`;
  - `workflows: ${{ inputs.app-token-workflows-write && 'write' || '' }}`;
  - nothing else, never `actions`.
  - At the pinned SHA, an empty `permission-*` value is skipped.
- **Gate mint `permission-*`:** `contents: read`, `issues: write`,
  `pull-requests: read`, `checks: read`, `statuses: read`, and nothing else.
- Stub fixture names: `evidence_empty`, `evidence_oversized`.
- Do not edit `docs/DECISIONS.md`: #626 appends ADR-024 there.
- Commits say `Part of #592`, never `Closes`.

## Review Focus

- **`'["Self-Hosted","linux"]'` with empty gate labels:** refused. The match is
  case-insensitive.
- **Self-hosted with `gate-runner-labels` set:** allowed, with no warning.
- **Self-hosted with the opt-out:** allowed, and a `::warning::` is printed.
- **`PIPELINE_APP_ID` empty:** the mint is skipped as before, and the
  `permission-*` lines change nothing.
- **A plan that edits `.github/workflows/` without
  `app-token-workflows-write`:** the push is refused by GitHub. The docs say so.

---

### Task 1: F7 check script

**Files:**
- Create: `scripts/check-gate-runner-isolation.sh`
- Test: `tests/run-gate-runner-isolation-tests.sh`. `tests/run-all.sh`
  discovers `run-*-tests.sh` automatically.

**Interfaces:**
- Produces: `check-gate-runner-isolation.sh`.
  - Reads env `RUNNER_LABELS` (JSON array), `GATE_RUNNER_LABELS` (JSON array
    or empty) and `ALLOW_SHARED_GATE_RUNNER` (`true`/anything else).
  - Writes nothing to `$GITHUB_OUTPUT`.

- [ ] **Step 1: Write the failing tests.** Use the harness style of
  `tests/run-gate-evidence-tests.sh`: `pass`/`fail`/`assert_eq`, a summary
  line, and exit 1 on any failure. Run the script with `bash "$SCRIPT"`, and
  capture stdout+stderr and the exit code. Cases:
  - `isolation_HostedOnly_Allows`: `RUNNER_LABELS='["ubuntu-latest"]'`, gate
    empty → exit 0, no output.
  - `isolation_SelfHostedGateSet_Allows`: `'["self-hosted","linux"]'`, gate
    `'["ubuntu-latest"]'` → exit 0, no `::warning`.
  - `isolation_SelfHostedNoGate_Refuses`: `'["self-hosted","linux"]'`, gate
    empty → exit 1. The output contains `::error title=Gate shares the agent's
    runner::`, `gate-runner-labels` and `allow-shared-gate-runner`.
  - `isolation_MixedCaseSelfHosted_Refuses`: `'["Self-Hosted","linux"]'`, gate
    empty → exit 1.
  - `isolation_GateEmptyArray_Refuses`: `'["self-hosted"]'`, gate `'[]'` →
    exit 1. An empty array is the same as unset, because the workflow
    expression treats `''` as unset and `[]` as no runner at all.
  - `isolation_OptOut_AllowsWithWarning`: `'["self-hosted"]'`, gate empty,
    `ALLOW_SHARED_GATE_RUNNER=true` → exit 0. The output contains `::warning`.
  - `isolation_MalformedLabels_UsageError`: `RUNNER_LABELS='self-hosted'`
    (not JSON) → exit 2.
  - `isolation_NonStringElement_UsageError`: `'["self-hosted",3]'` → exit 2.

- [ ] **Step 2: Run** `bash tests/run-gate-runner-isolation-tests.sh`. Expected:
  every case fails, because the script is missing.

- [ ] **Step 3: Implement the script.**
  - Use the standard prelude and a header comment naming #592 / F7 and its exit
    codes.
  - Use `jq -e` to validate `RUNNER_LABELS` as an array of strings, and to test
    `any(ascii_downcase == "self-hosted")`.
  - A `GATE_RUNNER_LABELS` that is empty or `[]` counts as unset.
  - No `eval`, and every value is quoted.

- [ ] **Step 4: Run** the new suite, then `shellcheck -x -e SC1091` on both
  files. Expected: all pass.

- [ ] **Step 5: Commit**: `feat(gate): refuse a self-hosted run whose gate
  shares the agent's runner`, with body `Part of #592`.

### Task 2: F7 wiring, shim and docs

**Files:**
- Modify: `.github/workflows/agent-implement.yml`:
  - the input `allow-shared-gate-runner`, next to `gate-runner-labels`;
  - a new implement-job step right after "Checkout agent-workflow scripts".
- Modify: `.github/workflows/claude-implement.yml` (shim): declare and forward
  `gate-runner-labels`, `allow-shared-gate-runner` and
  `app-token-workflows-write`. Add only these three; the shim's other drift is
  out of scope.
- Modify: `tests/run-agent-isolation-tests.sh`
- Modify: `docs/CONSUMER-SETUP.md`, `docs/RUNNER-REQUIREMENTS.md`

**Interfaces:**
- Consumes: Task 1's script.
- Produces: the `check_workflow(path)` refactor of the guard, which Task 3
  extends.

- [ ] **Step 1: Write the failing guard.**
  - Refactor `tests/run-agent-isolation-tests.sh` so the python check takes the
    workflow path as an argument. The script then runs it once on the real file
    (positive) and once per mutated copy in `mktemp -d` (negative). A negative
    passes only when the check reports a problem.
  - Add the assertion: the implement job has a step whose `run` contains
    `check-gate-runner-isolation.sh`. Its index is lower than the first agent
    step's, and its `env` maps:
    - `RUNNER_LABELS: ${{ inputs.runner-labels }}`
    - `GATE_RUNNER_LABELS: ${{ inputs.gate-runner-labels }}`
    - `ALLOW_SHARED_GATE_RUNNER: ${{ inputs.allow-shared-gate-runner }}`
  - Add the assertion: `claude-implement.yml` declares the three inputs and
    forwards each one as `${{ inputs.<name> }}`.
  - Add the negative mutator `mutate_drop_runner_check`, which deletes the
    step's `run:` line with sed. Expected: the guard reports it.

- [ ] **Step 2: Run** `bash tests/run-agent-isolation-tests.sh`. Expected: it
  fails on the missing step and on the shim.

- [ ] **Step 3: Implement.**
  - Add the input. Its description explains the opt-out: ephemeral runners
    only, and it accepts the risk.
  - Add the step "Refuse a gate that shares the agent's runner"
    (`id: gate_runner_isolation`) with the env above, running
    `bash .claude-pipeline/scripts/check-gate-runner-isolation.sh`.
  - Update the shim.
  - Update `gate-runner-labels`' description: it is required on self-hosted
    runners unless `allow-shared-gate-runner` is set.

- [ ] **Step 4: Update the docs.**
  - `CONSUMER-SETUP.md`: in §0 pre-flight and in the inputs reference, document
    that a self-hosted `runner-labels` needs `gate-runner-labels` (a hosted or
    ephemeral pool) or the opt-out, and that otherwise the run is refused before
    the agent starts.
  - `RUNNER-REQUIREMENTS.md`: under "Provisioning self-hosted runners", add a
    short "Gate placement" paragraph saying the same.
  - Don't name any host.

- [ ] **Step 5: Run** the guard, `actionlint`, and `bash tests/run-all.sh`.
  Expected: all green.

- [ ] **Step 6: Commit**: `feat(gate): wire the self-hosted gate check into the
  implement job`, with body `Part of #592`.

### Task 3: F8 scoped App tokens

**Files:**
- Modify: `.github/workflows/agent-implement.yml`:
  - the input `app-token-workflows-write`;
  - the implement and `implement_gate` mint steps.
- Modify: `tests/run-agent-isolation-tests.sh`
- Modify: `docs/PIPELINE-APP-SETUP.md` ("What the App token governs" and the
  Workflows paragraph), `docs/CONSUMER-SETUP.md` (input reference)

**Interfaces:**
- Consumes: `check_workflow(path)` and the mutator harness from Task 2.

- [ ] **Step 1: Write the failing guard.** In the python check, find the step
  in `implement` and in `implement_gate` whose `uses` contains
  `create-github-app-token`. Collect its `with` keys that start with
  `permission-`.
  - **implement:** the keys equal exactly `{permission-contents: write,
    permission-pull-requests: write, permission-issues: write,
    permission-workflows: "${{ inputs.app-token-workflows-write && 'write' ||
    '' }}"}`.
  - **implement_gate:** the keys equal exactly `{permission-contents: read,
    permission-issues: write, permission-pull-requests: read,
    permission-checks: read, permission-statuses: read}`.
  - An empty permission set is its own problem message: `mint is unscoped`.

  Negative mutators:
  - `mutate_unscope_gate_mint` deletes every `permission-` line inside the
    `implement_gate` job.
  - `mutate_implement_mint_actions` inserts `permission-actions: write` after
    the implement mint's `permission-issues` line.
  - `mutate_workflows_always` replaces the workflows expression with `write`.

- [ ] **Step 2: Run** the guard. Expected: the positive check fails on both
  unscoped mints.

- [ ] **Step 3: Implement.** Add the input. Its description says it requires
  the App's Workflows permission and that the mint fails without it. Add the
  `permission-*` lines to both mints. A one-line YAML comment on each mint names
  #592 and says why `actions` is absent.

- [ ] **Step 4: Update the docs.**
  - `PIPELINE-APP-SETUP.md`: the token now carries what each job requests,
    intersected with what the App holds. A plan that edits workflow files needs
    the App's Workflows permission **and** `app-token-workflows-write: true`.
    Without both, the push fails with GitHub's "without 'workflows' permission"
    error.
  - Keep the permission table as is.
  - `CONSUMER-SETUP.md`: add the input.

- [ ] **Step 5: Run** the guard, `actionlint`, and `bash tests/run-all.sh`.
  Expected: all green.

- [ ] **Step 6: Commit**: `fix(security): scope the implement and gate App
  tokens`, with body `Part of #592`.

### Task 4: F6 masking named in the evidence warning

**Files:**
- Modify: `scripts/import-result-output.sh`, the `No valid result evidence`
  warning, and its header comment if needed.
- Test: `tests/run-gate-evidence-tests.sh`

- [ ] **Step 1: Write the failing test.** Add the section `import: the
  no-evidence warning names masking (#592 F6)`. Run the import with an empty
  `RESULT_JSON_FILE`, and assert that stdout contains both `secret-masked` and
  `PIPELINE_APP_ID`.

- [ ] **Step 2: Run** `bash tests/run-gate-evidence-tests.sh`. Expected: the new
  assertion fails.

- [ ] **Step 3: Implement.** Append to the warning text: `; if the agent did
  report a result, GitHub may have dropped the output because it contained a
  secret-masked value (for example a numeric PIPELINE_APP_ID)`. Keep the line a
  single `::warning` line.

- [ ] **Step 4: Run** the suite. Expected: all pass.

- [ ] **Step 5: Commit**: `fix(gate): name secret masking as a cause of missing
  evidence`, with body `Part of #592`.

### Task 5: F9 act scenarios for bad evidence

**Files:**
- Modify: `.github/workflows/agent-implement.yml`:
  - the stub step's `case`, with two new arms;
  - the `stub-fixture` input description.
- Modify: `.github/workflows/agent-implement.test.yml`, which gets two `call-*`
  jobs and two `verify-*` jobs.

- [ ] **Step 1: Write the failing scenarios.** Add `call-evidence-empty` and
  `call-evidence-oversized`. Copy `call-success`'s `with:` and change only
  `stub-fixture`. Their verify jobs mirror `verify-opencode-task-failure` and
  assert:
  - `OUTCOME == failed`
  - `FAILURE == bug`
  - `NUM_TURNS == 0`

  Each `::error::` message names the expected value.

- [ ] **Step 2: Run** `act -W .github/workflows/agent-implement.test.yml -j
  verify-evidence-empty`, and the same with `-j verify-evidence-oversized`.
  Expected: they fail on an unknown stub-fixture (exit 2).

- [ ] **Step 3: Implement the stub arms.**
  - **`evidence_empty`:** `printf 'not json' > "$out"`.
  - **`evidence_oversized`:**
    - Write the canonical success result to `"$out"`, as the `success` arm
      does.
    - Then overwrite `.claude-pipeline/scripts/export-result-output.sh` with a
      script that appends one `result-json=` line to `$GITHUB_OUTPUT`. The line
      holds a canonical result object (`type:"result"`,
      `subtype:"success"`, `is_error:false`, `num_turns:1`,
      `total_cost_usd:0`, `usage` all zero) whose `result` string is 200000
      `x` characters. Build it with `jq -nc` and `"x" * 200000`.
    - Also write `is-error=false`.
    - Guard the arm: refuse with exit 2 unless `.claude-pipeline/scripts` is a
      workspace directory (local-scripts mode).

- [ ] **Step 4: Run** both act jobs. Expected: both pass. **If
  `verify-evidence-oversized` reports `outcome=success`, act did not reproduce
  E2BIG. Stop and report it. Do not shrink or reshape the payload to force a
  pass (spec anti-goal).**

- [ ] **Step 5: Run** `actionlint` and `bash tests/run-all.sh`. Expected: green.

- [ ] **Step 6: Commit**: `test(gate): act scenarios for empty and oversized
  evidence`, with body `Part of #592`.
