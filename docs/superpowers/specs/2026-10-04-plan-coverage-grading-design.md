# Grade a run against its plan, not just its exit

**Issue:** [#457](https://github.com/freaxnx01/agent-workflow/issues/457)
**Date:** 2026-10-04
**Status:** Approved (interactive enrichment)

## Problem

An `ai-implement` run is graded only on how the agent session ended. #430's
second run (2026-09-27) hit the Workflows-permission wall on push, left two
of three plan tasks as a patch in PR #432's body, and was graded `ai:done`.
The operator found out by reading comments.

The auto lane (#373) trusts that grade with nobody reading the PR, so the
same shape would be auto-merged as a partial fix.

## What decides the grade today

Read from `main` on 2026-10-04:

- `scripts/post-run-report.sh:276-300` picks `ai:done` / `ai:failed` from the
  result JSON's `is_error` / `subtype`, `PR_PRESENT`, and `SALVAGED`. Nothing
  compares the PR against the plan.
- The `ai_review_ai_merge` job (`.github/workflows/agent-implement.yml:1030`)
  runs when `needs.implement.outputs.outcome == 'success'`, which is derived
  from `is_error` alone.
- `/ai-stats` (`scripts/lib/ai-stats.sh:186`) counts a run as shipped when the
  report's `Outcome:` line carries `:white_check_mark:`.

## Decisions

- **File-level evidence, not commit messages** (issue question 1). It needs
  no cooperation from the agent, and #430's missing tasks were a patch in a
  PR body — no commit message would have shown them either.
- **A task counts as landed when at least one of its listed files is in the
  PR's diff** (question 2). A task whose files are all shared with another
  landed task is therefore counted as landed. This is a known blind spot,
  documented in the script, accepted because shared test files are common
  and flagging them would make `partial` fire on clean runs.
- **Unverifiable plans keep today's grade but cannot be AI-merged**
  (question 3). Fail closed only where nobody reads the PR; the human-merge
  flow and the stats are unchanged for them.

## Design

### `scripts/check-plan-coverage.sh` — query only

Inputs (env):

- `ISSUE_BODY_FILE` — the issue body.
- `CHANGED_FILES_FILE` — the PR's changed paths, one per line.

Parsing, inside the `## Implementation Plan` section only (up to the next
level-2 heading that is not a task heading):

- A task starts at a line matching `^#{2,3} Task [0-9]+` (the same pattern
  `scripts/classify-turns.sh:129` counts).
- A task's files are its lines matching
  `^- (Create|Modify|Test|Delete): ` — the first backticked token on the line,
  with a trailing `:<digits>…` line-range suffix stripped
  (`scripts/autopilot.sh:171-244` → `scripts/autopilot.sh`).
- Bodies elided to fit GitHub's 65,536-character cap keep every task's
  **Files** block by `/enrich`'s own rule, so they parse unchanged.

Grading:

| Situation | Output |
|---|---|
| No `## Implementation Plan`, zero tasks, or **any** task with no file entries | `coverage=unverifiable`, `reason=<no-plan\|no-tasks\|task-without-files:N>` |
| At least one task has **none** of its files in the changed set | `coverage=partial`, `missing-tasks=<comma-separated task numbers>` |
| Every task has at least one file in the changed set | `coverage=complete` |

Output is `key=value` lines on stdout (`coverage`, `missing-tasks`,
`reason`; empty values allowed). Exit 0 on any grade; 2 on a usage error
(an input variable unset or the file unreadable).

### Workflow — `.github/workflows/agent-implement.yml`

- New step **`Check plan coverage`** (`id: plan_coverage`) directly after
  `Verify or recover PR`, `if: always() && !inputs.dry-run &&
  steps.verify_pr.outputs.pr-present == 'true'`. A script
  (`scripts/plan-coverage-step.sh`) fetches the issue body and
  `gh api --paginate repos/<repo>/pulls/<n>/files` (taking `filename` and,
  for renames, `previous_filename`), runs `check-plan-coverage.sh`, and writes
  its outputs to `$GITHUB_OUTPUT`.
- **Any fetch failure yields `coverage=unverifiable`, `reason=fetch-failed`**
  — never `complete`, never `partial`. The step must never fail the job.
- New implement-job output `plan-coverage`.
- `ai_review_ai_merge`'s `if:` gains
  `&& needs.implement.outputs.plan-coverage == 'complete'`. A partial or
  unverifiable run therefore never enters the AI-merge job. The human-merge
  job is not gated.

### Report — `scripts/post-run-report.sh`

New optional env: `PLAN_COVERAGE`, `MISSING_TASKS`, `PLAN_COVERAGE_REASON`.

Grade precedence: agent error → no PR → **partial** → salvaged → success.

- **partial:** `**Outcome:** :warning: partial: plan task(s) <list> have no
  file in the PR`, status label **`ai:partial`**. `/ai-stats` counts only
  `:white_check_mark:` as shipped, so it needs no change.
- **unverifiable:** grade unchanged; the report adds
  `**Plan coverage:** not checked — <reason>`.
- **complete / unset:** report unchanged.

The opposite-label logic becomes "remove the other two status labels"
(`ai:done`, `ai:failed`, `ai:partial` minus the chosen one), so a re-run that
changes the grade never leaves two grades on the issue.

### Labels — `scripts/ensure-issue-labels.sh`

Registers `ai:partial` alongside `ai:done` / `ai:failed`.

## Testing

Layer-1, fixture-driven:

- `check-plan-coverage.sh`: #430's shape (3 tasks, 1 landed → `partial`,
  `missing-tasks=2,3`); all landed → `complete`; a task whose only file is
  shared with a landed task → `complete`; no plan → `unverifiable`/`no-plan`;
  plan with no task headings → `no-tasks`; a task with no Files lines →
  `task-without-files:N`; line-range suffix stripped; an elided body;
  `## Task N` (h2) headings; a usage error exits 2.
- `plan-coverage-step.sh` with `gh` mocked: success writes the script's
  outputs; a failing `pulls/<n>/files` call writes `unverifiable` /
  `fetch-failed` and exits 0.
- `post-run-report.sh` (`RENDER_ONLY=1`): partial renders `:warning:` and
  labels `ai:partial`; unverifiable keeps `:white_check_mark:` and adds the
  coverage line; agent error and no-PR still win over partial; partial wins
  over salvaged.
- `actionlint` clean on the new step and condition.

## Acceptance criteria

- [ ] A run whose PR lacks every file of at least one plan task is graded `ai:partial`, not `ai:done`
- [ ] The run report names the missing task(s)
- [ ] The AI-merge job does not run for a partial or unverifiable run
- [ ] A fixture test reproduces the #430 shape: 3 tasks planned, 1 landed → partial
- [ ] Plans without countable tasks or Files blocks grade as today, say "not checked" in the report, and are not AI-merged
- [ ] A failed file-list fetch is `unverifiable`, never `complete`
- [ ] At most one of `ai:done` / `ai:failed` / `ai:partial` is on an issue after a run
- [ ] `ensure-issue-labels.sh` registers `ai:partial`
- [ ] Full suite, `shellcheck`, `actionlint`, `markdownlint` clean

## Out of scope

- #426 (`Closes #N` closes a partially-fixed issue). `ai:partial` is the
  signal it can key on; the fix stays there.
- Re-checking coverage after the review job's self-fix pushes.
- Commit-message evidence per task.
