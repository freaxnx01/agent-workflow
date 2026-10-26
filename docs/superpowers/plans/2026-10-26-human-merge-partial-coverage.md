# Human-merge Promotion Holds a Partial PR — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The human-merge gate does not promote a PR whose final head grades `partial` against the issue's Implementation Plan; it leaves it draft and says why.

**Architecture:** `ai_review_human_merge_gate` (added by #553) gets the same `Recheck plan coverage on the final head` step the AI-merge gate has. `Promote draft to ready` additionally requires the grade not to be `partial`; `Mark issue blocked` fires on `partial` and passes `PLAN_COVERAGE=partial`, which `post-auto-review-block.sh` (#553 Task 5) already turns into the reason. Dry-run skips the recheck, so act scenarios are unchanged.

**Tech Stack:** GitHub Actions YAML, Bash, Layer-1 fixture tests with the `gh` mock.

**Spec:** `docs/superpowers/specs/2026-10-26-human-merge-partial-coverage-design.md`

## Global Constraints

- **Starts from `main` after #553 merged.** The job `ai_review_human_merge_gate`, the step ids `binding` / `find_pr` / `verdict`, `scripts/check-verdict-binding.sh`, `tests/run-gate-evidence-tests.sh` (with its `block` helper) and the `PLAN_COVERAGE` reason in `post-auto-review-block.sh` all come from #553. If any is missing, stop: the dependency has not landed.
- Only the grade `partial` holds promotion. `complete`, `unverifiable` and an empty grade (step skipped or crashed) promote as today.
- Job outputs reach a `run:` script only through `env:`. Never write `${{ … }}` inside a `run:` body.
- No new permission on any job, no consumer stub change: `tests/run-caller-permissions-tests.sh` stays green.
- Pinned actions only; no new action is needed.
- After every task: `bash tests/run-all.sh`, `shellcheck -x -e SC1091 scripts/*.sh scripts/lib/*.sh tests/*.sh`, `actionlint .github/workflows/*.yml`.

## Review Focus

- **`unverifiable` must still promote.** A plan with a task that has no Files block grades `unverifiable`; holding it would park good PRs. Pinned by the structural assertion on the promote `if:` (`!= 'partial'`, not `== 'complete'`).
- **An `unverifiable` grade must never become the refusal reason** when the block step runs for another reason (e.g. no PR found). Pinned by the `PLAN_COVERAGE` env expression assertion.
- **A non-approve verdict or failed binding still wins** as the stated reason over coverage. Pinned in `run-gate-evidence-tests.sh` (`VERDICT=block` with `PLAN_COVERAGE=partial`).
- **Dry-run unchanged.** The recheck is skipped under `inputs.dry-run`, and both `if:` additions are guarded by it; `just test-act` proves it.
- **The coverage step crashing must not block promotion silently or fail the job.** `continue-on-error: true`; an empty grade is not `partial`, so the PR promotes as today.

---

### Task 1: The human-merge gate holds a partial PR

**Files:**
- Modify: `.github/workflows/agent-implement.yml`
- Modify: `tests/run-script-tests.sh`
- Modify: `tests/run-gate-evidence-tests.sh`

**Interfaces:**
- Consumes: `scripts/plan-coverage-step.sh` (env `REPO`, `ISSUE_NUMBER`, `PR_NUMBER`, `GH_TOKEN`; output `coverage=complete|partial|unverifiable`), `scripts/post-auto-review-block.sh` env `PLAN_COVERAGE` and `MODE` (#553 Task 5).
- Produces: step id `coverage` in job `ai_review_human_merge_gate`.

- [ ] **Step 1: Write the failing structural tests.** In `tests/run-script-tests.sh`, directly after the block that defines `hmgate` and asserts `check-verdict-binding.sh` (#553 Task 7), add:

```bash
section "agent-implement.yml — human-merge promotion holds a partial PR (#568)"
hm568="$(awk '/^  ai_review_human_merge_gate:$/{f=1;next} f && /^  [a-z_]+:$/{exit} f' "$ROOT/.github/workflows/agent-implement.yml")"
assert_contains "$hm568" 'plan-coverage-step.sh' "the human-merge gate recomputes plan coverage on the final head"
assert_contains "$hm568" "if: steps.binding.outputs.bound == 'true' && !inputs.dry-run" "coverage is rechecked only for a bound verdict, never in dry-run"
assert_contains "$hm568" "(inputs.dry-run || steps.coverage.outputs.coverage != 'partial')" "promotion holds on partial only, so unverifiable still promotes"
assert_contains "$hm568" "(!inputs.dry-run && steps.coverage.outputs.coverage == 'partial')" "a partial grade marks the issue blocked"
assert_contains "$hm568" "PLAN_COVERAGE: \${{ steps.coverage.outputs.coverage == 'partial' && 'partial' || '' }}" "only a partial grade becomes the refusal reason"
assert_not_contains "$hm568" "steps.coverage.outputs.coverage == 'complete'" "the human-merge gate never requires complete"
```

- [ ] **Step 2: Write the wording test.** In `tests/run-gate-evidence-tests.sh`, at the end of the `block reasons` section (it defines `block()`), add:

```bash
calls="$(block MODE=human-merge PLAN_COVERAGE=partial)"
if [[ "$calls" == *'Review held: plan coverage on the final head is partial. PR stays draft for human review.'* ]]; then pass "human-merge: partial coverage is the reason (#568)"; else fail "human-merge: partial coverage is the reason (#568)" "$calls"; fi
if [[ "$calls" == *'--add-label ai:review-blocked'* ]]; then pass "human-merge: partial coverage labels ai:review-blocked (#568)"; else fail "human-merge: partial coverage labels ai:review-blocked (#568)" "$calls"; fi
calls="$(block MODE=human-merge VERDICT=block PLAN_COVERAGE=partial)"
if [[ "$calls" == *'Review held: agent review verdict: block (gate 4)'* ]]; then pass "human-merge: a non-approve verdict still wins over coverage (#568)"; else fail "human-merge: a non-approve verdict still wins over coverage (#568)" "$calls"; fi
```

- [ ] **Step 3: Run the tests.**

Run: `bash tests/run-all.sh`
Expected: the six `#568` structural assertions in `run-script-tests.sh` FAIL. The three wording checks in `run-gate-evidence-tests.sh` PASS already — #553 Task 5 implemented the reason and `MODE` the prefix; they pin the combination. Everything else stays green.

- [ ] **Step 4: Add the recheck step.** In `.github/workflows/agent-implement.yml`, job `ai_review_human_merge_gate`, insert directly after the step `Check verdict binding` (id `binding`):

```yaml
      - name: Recheck plan coverage on the final head
        # #568: an approve verdict judges the diff it was shown; it does not
        # notice a plan task that never reached the branch (game-rhyflitzer
        # #389 → PR #459 was promoted without its tests.yml task). Graded on
        # the final head because self-fix may have pushed after implement_gate.
        # Only `partial` holds promotion: `unverifiable` is a parser blind spot,
        # and a human merges in this lane anyway.
        id: coverage
        continue-on-error: true
        if: steps.binding.outputs.bound == 'true' && !inputs.dry-run
        env:
          REPO: ${{ github.repository }}
          ISSUE_NUMBER: ${{ inputs.issue-number }}
          PR_NUMBER: ${{ steps.find_pr.outputs.pr-number }}
          GH_TOKEN: ${{ github.token }}
        run: bash .claude-pipeline/scripts/plan-coverage-step.sh
```

- [ ] **Step 5: Gate the promotion.** In the same job, step `Promote draft to ready (human-merge — no auto-merge)`, change its `if:` from `steps.binding.outputs.bound == 'true'` to:

```yaml
        if: steps.binding.outputs.bound == 'true' && (inputs.dry-run || steps.coverage.outputs.coverage != 'partial')
```

- [ ] **Step 6: Report the hold.** In the same job, step `Mark issue blocked when review refuses or PR missing`:
  - extend its `if:` so it reads:

```yaml
        if: |
          needs.ai_review_human_merge.outputs.found != 'true'
          || steps.verdict.outputs.value != 'approve'
          || steps.binding.outputs.bound != 'true'
          || (!inputs.dry-run && steps.coverage.outputs.coverage == 'partial')
```

  - add to its `env:` (keep every existing entry, including `MODE: human-merge` and `BINDING_REASON`):

```yaml
          # #568: only a partial grade is a reason; unverifiable never is.
          PLAN_COVERAGE: ${{ steps.coverage.outputs.coverage == 'partial' && 'partial' || '' }}
```

- [ ] **Step 7: Run the tests.**

Run: `bash tests/run-all.sh && actionlint .github/workflows/*.yml && shellcheck -x -e SC1091 scripts/*.sh scripts/lib/*.sh tests/*.sh`
Expected: all green, including `run-caller-permissions-tests.sh` and `run-agent-isolation-tests.sh` (the new step runs no agent and no decision after one).

- [ ] **Step 8: Commit and push.**

```bash
git add .github/workflows/agent-implement.yml tests/run-script-tests.sh tests/run-gate-evidence-tests.sh
git commit -m "fix(review): hold human-merge promotion when plan coverage is partial (#568)"
git push
```

### Task 2: Document the hold

**Files:**
- Modify: `docs/CONSUMER-SETUP.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: Task 1's behaviour.
- Produces: nothing code depends on.

- [ ] **Step 1: Consumer docs.** In `docs/CONSUMER-SETUP.md`, flow 3 (the line starting `3. **AI review, human merge**`), replace `→ on approve, promote draft→ready; a human merges.` with:

```markdown
→ on approve, promote draft→ready unless a plan task is missing from the PR (plan coverage `partial` on the final head — the PR then stays draft with `ai:review-blocked`); a human merges.
```

- [ ] **Step 2: Changelog.** In `CHANGELOG.md`, under `## [Unreleased]` (create it directly above the newest release heading if it is missing), under `### Fixed` (create it if missing), add:

```markdown
- **review:** The human-merge lane no longer promotes a PR whose plan coverage is `partial`; it stays draft with `ai:review-blocked` and a `Review held: plan coverage on the final head is partial` comment (#568)
```

- [ ] **Step 3: Verify.**

Run: `bash tests/run-all.sh`
Expected: green (docs-only change; any markdown lint in `run-all.sh` passes).

- [ ] **Step 4: Commit and push.**

```bash
git add docs/CONSUMER-SETUP.md CHANGELOG.md
git commit -m "docs(review): human-merge promotion holds a partial PR (#568)"
git push
```

### Task 3: Full verification

**Files:** none — verification only.

- [ ] **Step 1:** `bash tests/run-all.sh` — all green.
- [ ] **Step 2:** `actionlint .github/workflows/*.yml` and `shellcheck -x -e SC1091 scripts/*.sh scripts/lib/*.sh tests/*.sh` — clean.
- [ ] **Step 3:** `just test-act` if Docker is available — every `verify-human-merge-*` scenario passes unchanged (they run `dry-run: true`, so the recheck is skipped and promotion behaves as before). Without Docker, say so in the PR body.
