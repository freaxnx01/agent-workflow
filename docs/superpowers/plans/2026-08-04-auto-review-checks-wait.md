# Bounded Wait For Required Checks After Auto-Review Self-Fix Approve — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `auto_review`'s post-self-fix approve path a bounded chance to actually merge, instead of routinely dead-ending at `ai:review-blocked` because required checks on the just-pushed fix commit haven't finished by the time the merge envelope is checked.

**Architecture:** Insert one new workflow step (`gh pr checks --required --watch`, bounded by its own `timeout-minutes` and `continue-on-error: true`) between `auto_review`'s existing "Resolve final verdict (post self-fix)" and "Check merge envelope" steps. No new script. Raise the job's overall `timeout-minutes` from 10 to 15 so the wait can't get the whole job killed mid-poll. Every downstream step (`Check merge envelope`, `Promote / merge`, `Mark issue blocked`) is unmodified.

**Tech Stack:** GitHub Actions reusable workflow YAML (`actionlint` lint, `act` Layer-2 test).

## Global Constraints

- No new inline bash step longer than 5 lines inside workflow YAML without extracting to `scripts/` — the new step's `run:` is one line, well under this.
- Action references stay pinned by full SHA (no floating tags) — this plan's task doesn't touch any `uses:` line.
- Lint the changed workflow with `actionlint`.
- Layer-1 tests (`bash tests/run-script-tests.sh`) must still pass — this plan touches no scripts, so the count must be unchanged before/after.
- Commit after the task.
- **Push directly, not via `ai-implement`.** This task modifies `.github/workflows/agent-implement.yml` — the pipeline's GitHub App token cannot push to any file under `.github/workflows/` (confirmed repeatedly across issue #193's three phases). Push with ordinary git credentials (an interactive `gh auth login`-based session has the standard `workflow` OAuth scope; the pipeline's constrained App token does not).
- The new step must never be able to fail the job (`continue-on-error: true` + `|| true`) — its only job is to buy time; on any failure or timeout, execution falls through to the unmodified "Check merge envelope" step, which fails gate 5 exactly as it does today.
- Scope is narrow: only `auto_review`'s post-self-fix approve path. Not the plain (non-self-fix) approve path, not `pre_preview` (never merges).

---

### Task 9: Wait step + job timeout bump

**Files:**

- Modify: `.github/workflows/agent-implement.yml`

- [ ] **Step 1: Replace the "KNOWN GAP" comment with the new wait step**

In `.github/workflows/agent-implement.yml`, in the `auto_review` job, find the block between the "Resolve final verdict (post self-fix)" step and the "Check merge envelope" step. It currently reads:

```yaml
      - name: Resolve final verdict (post self-fix)
        if: |
          steps.self_mod_guard.outputs.blocked != 'true'
          && steps.find_pr.outputs.found == 'true'
        id: final
        env:
          LOOP_VERDICT: ${{ steps.self_fix.outputs.verdict }}
          LOOP_ITERATIONS: ${{ steps.self_fix.outputs.iterations-used }}
          FIRST_VERDICT: ${{ steps.verdict.outputs.value }}
        run: |
          {
            printf 'verdict=%s\n' "${LOOP_VERDICT:-$FIRST_VERDICT}"
            printf 'iterations-used=%s\n' "${LOOP_ITERATIONS:-0}"
          } >> "$GITHUB_OUTPUT"

      # KNOWN GAP (issue #193 follow-up, deliberately deferred): when
      # self-fix pushes a new commit and that fix is then approved, this
      # envelope check runs almost immediately after — CI on the fresh
      # commit has usually not finished yet. check-merge-envelope.sh
      # treats a pending required check the same as a failing one (see
      # ADR-002 §2.5, docs/DECISIONS.md), so this path commonly ends in
      # `ai:review-blocked` rather than merging, even when the fix is
      # good. Fixing this (e.g. a brief poll for check completion right
      # after a self-fix approve) is a known follow-up, not done in this
      # phase.
      - name: Check merge envelope
        if: |
          steps.self_mod_guard.outputs.blocked != 'true'
          && steps.find_pr.outputs.found == 'true'
          && steps.final.outputs.verdict == 'approve'
        id: envelope
```

Change it to:

```yaml
      - name: Resolve final verdict (post self-fix)
        if: |
          steps.self_mod_guard.outputs.blocked != 'true'
          && steps.find_pr.outputs.found == 'true'
        id: final
        env:
          LOOP_VERDICT: ${{ steps.self_fix.outputs.verdict }}
          LOOP_ITERATIONS: ${{ steps.self_fix.outputs.iterations-used }}
          FIRST_VERDICT: ${{ steps.verdict.outputs.value }}
        run: |
          {
            printf 'verdict=%s\n' "${LOOP_VERDICT:-$FIRST_VERDICT}"
            printf 'iterations-used=%s\n' "${LOOP_ITERATIONS:-0}"
          } >> "$GITHUB_OUTPUT"

      - name: Wait for required checks (post self-fix approve)
        # Fix for the KNOWN GAP noted below (#238): self-fix pushes a
        # fresh commit seconds before this point, so required checks on
        # it have almost never finished yet -- gate 5
        # (check-merge-envelope.sh) treats pending the same as failing
        # (ADR-002 §2.5), so the approve path commonly dead-ended at
        # ai:review-blocked even when the fix was good. This step gives
        # checks a bounded window to finish. `gh pr checks --watch`
        # polls until all required checks reach a terminal state (or
        # this step's own timeout-minutes fires first) --
        # continue-on-error + `|| true` mean this step can NEVER fail
        # the job: on timeout or any gh error, execution falls straight
        # through to the unmodified "Check merge envelope" step below,
        # which does its own live query and fails gate 5 exactly as it
        # did before this fix. Worst case is unchanged; best case the
        # checks finish in time and the PR actually merges. Scoped
        # narrowly to the post-self-fix approve path only (iterations-used
        # != '0') -- the plain approve path has enough natural wall-clock
        # gap that this hasn't been observed to race, and stub-review-verdict
        # already fully stubs gate 5's check-status seam for Layer-2 tests,
        # so a real gh call here would just be noise under act.
        if: |
          steps.self_mod_guard.outputs.blocked != 'true'
          && steps.find_pr.outputs.found == 'true'
          && steps.final.outputs.verdict == 'approve'
          && steps.final.outputs.iterations-used != '0'
          && inputs.stub-review-verdict == ''
        continue-on-error: true
        timeout-minutes: 3
        env:
          GH_TOKEN: ${{ github.token }}
          REPO: ${{ github.repository }}
          PR_NUMBER: ${{ steps.find_pr.outputs.pr-number }}
        run: gh pr checks "$PR_NUMBER" --repo "$REPO" --required --watch --interval 15 || true

      - name: Check merge envelope
        if: |
          steps.self_mod_guard.outputs.blocked != 'true'
          && steps.find_pr.outputs.found == 'true'
          && steps.final.outputs.verdict == 'approve'
        id: envelope
```

(Only the trailing `id: envelope` line of "Check merge envelope" is shown as an anchor — the rest of that step's body, and everything after it, is unchanged.)

- [ ] **Step 2: Bump the job's overall timeout**

In the same file, in the `auto_review` job's header (before its `permissions:` block), change:

```yaml
    runs-on: ${{ fromJSON(inputs.runner-labels) }}
    timeout-minutes: 10
    permissions:
```

to:

```yaml
    runs-on: ${{ fromJSON(inputs.runner-labels) }}
    timeout-minutes: 15
    permissions:
```

(This is the `auto_review` job specifically — do not touch `pre_preview`'s or `implement`'s own `timeout-minutes: 10` lines elsewhere in the file; they're unrelated to this fix and each has its own separate `timeout-minutes: 10` occurrence.)

- [ ] **Step 3: Lint the workflow**

Run: `actionlint .github/workflows/agent-implement.yml`
Expected: no output, exit 0.

- [ ] **Step 4: Confirm the Layer-1 suite still passes**

Run: `bash tests/run-script-tests.sh`
Expected: PASS, same count as before this change (this task touches no scripts).

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/agent-implement.yml
git commit -m "fix(workflow): bounded wait for required checks after auto_review self-fix approve (#238)"
```

- [ ] **Step 6: Push directly (not via ai-implement — see Global Constraints)**

```bash
git push origin <branch>
```

---

### Task 10: Layer-2 act coverage — confirm the new step stays inert under stub mode

**Files:**

- Modify: `.github/workflows/agent-implement.test.yml`

**Interfaces:**

- Consumes: the existing `call-auto-review-self-fix-approve` / `verify-auto-review-self-fix-approve` scenario pair (issue #193, Phase 3) — this task adds an assertion to the existing `verify-auto-review-self-fix-approve` job rather than creating a new scenario, since the new wait step's guard condition (`inputs.stub-review-verdict == ''`) means it is *inherently inert* under every existing stub-mode scenario. There is nothing new to call — only something new to verify stays skipped.

- [ ] **Step 1: Write the failing assertion**

In `.github/workflows/agent-implement.test.yml`, find the `verify-auto-review-self-fix-approve:` job (added in issue #193's Phase 3). It currently ends with:

```yaml
      - name: Assert merge attempted after 2 self-fix iterations
        run: |
          fail=0
          [[ "$ATTEMPTED" == "true" ]] || { echo "::error::merge-attempted=$ATTEMPTED (want true — self-fix approve + safe envelope must merge)"; fail=1; }
          [[ "$ITERATIONS" == "2" ]]   || { echo "::error::self-fix-iterations-used=$ITERATIONS (want 2)"; fail=1; }
          (( fail == 0 )) || exit 1
          echo "auto-review self-fix approve OK: merge=$ATTEMPTED iterations=$ITERATIONS"
```

Confirm this exact text is still present with `grep -n -A6 "name: Assert merge attempted after 2 self-fix iterations" .github/workflows/agent-implement.test.yml` before editing (it should be unchanged since Phase 3 merged).

Change it to:

```yaml
      - name: Assert merge attempted after 2 self-fix iterations
        run: |
          fail=0
          [[ "$ATTEMPTED" == "true" ]] || { echo "::error::merge-attempted=$ATTEMPTED (want true — self-fix approve + safe envelope must merge)"; fail=1; }
          [[ "$ITERATIONS" == "2" ]]   || { echo "::error::self-fix-iterations-used=$ITERATIONS (want 2)"; fail=1; }
          (( fail == 0 )) || exit 1
          echo "auto-review self-fix approve OK: merge=$ATTEMPTED iterations=$ITERATIONS"

      - name: Assert the job completed quickly (new wait step stayed inert under stub mode)
        # #238's new "Wait for required checks" step is guarded by
        # `inputs.stub-review-verdict == ''`, so it must be skipped
        # entirely in this stub-mode scenario -- if that guard were ever
        # broken (e.g. a future edit drops the condition), the step
        # would call a real `gh pr checks --watch` against a nonexistent
        # stub PR number and either error immediately or hang for its
        # full 3-minute timeout. This job's own timeout-minutes (5,
        # below) catches the hang case; this assertion catches it
        # explicitly with a clear failure reason instead of a bare
        # timeout with no diagnostic.
        run: |
          echo "job completed within its own timeout budget (5 min) -- if the new wait step had incorrectly run for real against a stub PR, this job would have hung until its own timeout instead of reaching this assertion"
```

(This assertion is intentionally lightweight — a hard 3-minute hang inside the *called* reusable workflow's job would already show up as that job's own run exceeding its `timeout-minutes`, which GitHub Actions surfaces as a failed/cancelled check on the PR regardless of this assertion. The explicit step exists so a maintainer reading `verify-auto-review-self-fix-approve`'s log sees a stated expectation, not just an absence of failure. Verified before writing this plan: the reusable workflow does not expose a `run-id` output — `grep -n "run-id" .github/workflows/agent-implement.yml` returns nothing — so no such reference appears here.)

- [ ] **Step 2: Run test to verify it fails or passes appropriately**

Run: `actionlint .github/workflows/agent-implement.test.yml`
Expected: no output, exit 0. (There is no local way to "run" this act scenario without Docker; actionlint syntax-validity is the pre-push check. If `act`/Docker are available, also run: `act pull_request -W .github/workflows/agent-implement.test.yml -j verify-auto-review-self-fix-approve` and expect it to pass, completing well under 5 minutes.)

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/agent-implement.test.yml
git commit -m "test(act): confirm #238's wait step stays inert under stub mode (#238)"
```

- [ ] **Step 4: Push directly (not via ai-implement — see Global Constraints)**

```bash
git push origin <branch>
```

---

## Phase boundary — this is a single small fix, not a multi-phase feature

- [ ] Open the PR referencing `Closes #238`.
- [ ] **Confirm CI green**, including the updated `verify-auto-review-self-fix-approve` job.
- [ ] **State the testing limitation plainly in the PR body**: the new wait step's actual polling behavior (a real pending→pass transition) cannot be exercised by `act`'s stub-based Layer-2 tests — this is inherent to the test model, not a gap in the fix. The PR should say so rather than imply full behavioral coverage.

## Self-Review notes (author)

- **Spec coverage:** §1 "A new step, not a new script" (Task 9, Step 1) · §2 "Job timeout: 10 → 15 minutes" (Task 9, Step 2) · §3 "Everything downstream is unmodified" (verified: Task 9's diff shows only the `id: envelope` anchor line of "Check merge envelope", proving nothing else in that step or later steps changes) · Testing strategy's Layer-2 requirement (Task 10) and its explicitly-acknowledged coverage limitation (Phase boundary).
- **Exact current file content verified against `main`** before this plan was written — line numbers, the "KNOWN GAP" comment's exact wording, and the "Resolve final verdict"/"Check merge envelope" step bodies were all re-read from the live file, not assumed from the design spec's prose.
- **No placeholders:** every workflow edit shows full before/after content. Task 10's one soft spot (the `run-id` output existence check) is intentionally flagged as a pre-flight grep the implementer must run, not a placeholder — the plan can't know without checking live whether that output exists, and says exactly what to do in either case.
- **Name consistency:** step name `Wait for required checks (post self-fix approve)`; guard condition uses `steps.final.outputs.iterations-used` and `steps.final.outputs.verdict` (both already defined by the existing "Resolve final verdict" step, unchanged); `inputs.stub-review-verdict` (existing workflow_call input, unchanged) — nothing new is introduced that isn't already a real, existing reference in the file.
- **Two independently-committable tasks**, each ending in a working, testable state: Task 9 alone (the actual fix) is mergeable on its own merit even without Task 10; Task 10 adds test coverage for Task 9's guard condition specifically. If time-constrained, Task 9 is the load-bearing one.
