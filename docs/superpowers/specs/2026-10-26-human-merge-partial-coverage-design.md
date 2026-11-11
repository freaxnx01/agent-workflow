# Human-merge promotion holds a partial PR — design (#568)

## Problem

The human-merge lane promotes a PR from draft to ready on an `approve` verdict
alone. It never looks at plan coverage, so a run the implement job graded
`ai:partial` (a plan task with no file in the diff) still reaches "Reviewed ✓ —
promoted to ready. Merge is yours."

Observed on game-rhyflitzer #389 → PR #459 (run 40025085679): the run report
said `partial: plan task(s) 2 have no file in the PR`. Task 2 was the
`tests.yml` change that schedules the nightly run, the part that makes the rest
do anything. The review judged the diff it had (a correct script with tests),
approved it, and the PR was promoted. Merged as is, the script would never have
run.

The AI-merge lane does not have this gap: its job only runs on
`plan-coverage == 'complete'` today, and after #553 its gate recomputes coverage
on the final head before the envelope.

## Decision

The human-merge gate (`ai_review_human_merge_gate`, introduced by #553)
recomputes plan coverage on the final head and does not promote when the grade
is `partial`. The PR stays draft, the issue gets `ai:review-blocked`, and the
refusal comment names the reason: `Review held: plan coverage on the final head
is partial`.

- **Only `partial` holds.** `unverifiable` (no plan, a task without a Files
  block, a failed fetch) still promotes. In the human-merge lane a person merges
  anyway; holding on `unverifiable` would park every PR whose plan has an
  unparseable task (game-rhyflitzer #348's report read `not checked —
  task-without-files:1,2`) and turn a grading blind spot into a stuck PR.
  `partial` is the one grade that says something is known to be missing.
- **Recomputed on the final head, in the gate.** Self-fix may push after the
  implement gate graded the run, so the implement-time grade can be stale in
  both directions. The gate never runs an agent (ADR-020), so its grade is
  trusted. This is the same step the AI-merge gate gets in #553 Task 6.
- **The review still runs.** A partial PR still gets its review comment and,
  on `request_changes`, its self-fix pass. Only the promotion is withheld.
- **Dry-run is unchanged.** Coverage needs the real PR's files; the act
  scenarios run `dry-run: true` and keep promoting exactly as before.

## Rejected

- **Feed the missing tasks to the reviewer** so it blocks. The verdict would
  depend on a prompt the model may weigh or ignore; a deterministic gate on a
  grade the pipeline already computes is cheaper and cannot be talked out of.
- **Skip the human-merge review job on `partial`** (gate its `if:` on the
  implement gate's coverage). Saves one review, but the human gets no review of
  the part that did land and no comment explaining why nothing happened, and a
  later push that completes the PR is never re-graded.
- **Hold on `unverifiable` too.** See above: it parks good PRs on a parser
  blind spot.
- **Implement it before #535/#553** on today's `ai_review_human_merge` job.
  #535 and #553 rewrite exactly this job and its promote/block steps; doing it
  first means a conflict in `agent-implement.yml` and a second rewrite. It
  follows #553 instead.

## Changes

- `.github/workflows/agent-implement.yml`, job `ai_review_human_merge_gate`:
  - new step `Recheck plan coverage on the final head` (id `coverage`,
    `continue-on-error: true`, `if: steps.binding.outputs.bound == 'true' &&
    !inputs.dry-run`, runs `plan-coverage-step.sh` with the gate's own
    `find_pr` PR number), after `Check verdict binding`;
  - `Promote draft to ready (human-merge — no auto-merge)`: `if:` adds
    `&& (inputs.dry-run || steps.coverage.outputs.coverage != 'partial')`;
  - `Mark issue blocked when review refuses or PR missing`: `if:` adds
    `|| (!inputs.dry-run && steps.coverage.outputs.coverage == 'partial')`;
    `env:` adds `PLAN_COVERAGE: ${{ steps.coverage.outputs.coverage == 'partial'
    && 'partial' || '' }}` so an `unverifiable` grade never becomes the reason.
- `scripts/post-auto-review-block.sh`: no logic change. #553 Task 5 already
  turns `PLAN_COVERAGE` other than `complete` into the reason, and `MODE:
  human-merge` already switches the prefix to `Review held`. A test pins the
  combined wording.
- Tests: structural assertions on the gate (`tests/run-script-tests.sh`) and the
  human-merge refusal wording (`tests/run-gate-evidence-tests.sh`).
- Docs: `docs/CONSUMER-SETUP.md` flow 3 says promotion also needs no missing
  plan task; `CHANGELOG.md` `[Unreleased]` → `### Fixed`.

## Token for the gate

The coverage step calls `gh issue view` and `gh api …/pulls/<n>/files`, which
the gate's `GITHUB_TOKEN` can do with the `contents: read, pull-requests: write,
issues: write` permissions #553 gives it. #553 Task 7 gives this gate no App
token, so the step uses `GH_TOKEN: ${{ github.token }}`; no new permission and
no consumer stub change (`tests/run-caller-permissions-tests.sh`).

## Acceptance criteria

- A human-merge run whose final head grades `partial` keeps the PR draft,
  labels the issue `ai:review-blocked`, and comments `Review held: plan coverage
  on the final head is partial`.
- `complete` and `unverifiable` grades promote as today; a non-approve verdict
  or a failed binding is still reported with its own reason first.
- Dry-run (all act scenarios) is unchanged; `just test-act` still passes.
- `bash tests/run-all.sh`, `actionlint`, `shellcheck` green; no consumer stub
  change.

## Dependencies

Blocked by #553 (which is blocked by #535): the job, the binding step and the
`PLAN_COVERAGE` reason all come from it.
