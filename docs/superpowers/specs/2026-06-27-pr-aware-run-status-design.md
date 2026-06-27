# PR-aware run status with recovery — design (#100)

**Issue:** [#100](https://github.com/freaxnx01/agent-pipeline/issues/100) — concurrent runs report `ai:done` but silently open no PR (`gh pr create` race).
**Date:** 2026-06-27
**Status:** Approved

## Problem

The implement job's status is derived **solely** from the agent execution result. In
`scripts/post-run-report.sh`, `ai:done` vs `ai:failed` is chosen from `IS_ERROR` alone —
it never checks whether a pull request actually exists. So when the agent pushes a branch
with real commits but `gh pr create` does not complete (secondary rate limits / transient
API errors under concurrency, or the permission trap of CONSUMER-SETUP gotcha #6), the run
still stamps `ai:done`. The work survives on an orphan branch, but no PR links it and no
error signal is raised. In a batch of 8 issues, 3 runs failed this way.

Key constraint discovered during design: the **workflow does not name the branch**. The
agent is instructed (`claude-implement.yml` ~L330) to "implement on a new branch and open a
draft PR", so the branch name is agent-chosen. Recovery must therefore discover the branch
from the **post-agent local git state**, not a predetermined name.

## Goals

1. A successful-looking run that produced **no PR** must not be reported as `ai:done`.
2. Where the work exists on a pushed branch, **recover it** by opening the PR from the
   workflow (with retry/backoff) rather than only flagging the failure.
3. Only when recovery is impossible or fails does the run become `ai:failed`, with a comment
   that names the real cause.

## Non-goals

- **No batch jitter/stagger.** Reducing the up-front race is explicitly out of scope for this
  change; post-hoc verify + recover is the reliable lever.
- No change to how the agent itself calls `gh pr create` (it runs inside the agent's turn).
- No new status label — reuse `ai:failed`.

## Architecture

A new workflow step in `claude-implement.yml` runs **after the agent step** and **before
`post-run-report.sh`**, in the same job and checkout. It invokes a new script
`scripts/verify-or-recover-pr.sh`, which uses the existing `scripts/find-pipeline-pr.sh` as
the source of truth for "does a PR exist". The step exposes a `pr-present` output that
`post-run-report.sh` consumes to make status PR-aware.

```
agent step ──▶ verify-or-recover-pr.sh ──▶ post-run-report.sh
                 │  find-pipeline-pr.sh         │  status = ai:failed when
                 │  (+ recovery via             │  IS_ERROR=false AND
                 │   gh pr create w/ backoff)    │  PR_PRESENT=false
                 └─ outputs: pr-present, recovered
```

## Components

### `scripts/verify-or-recover-pr.sh` (new)

Single purpose: after a run, ensure a PR exists for the issue when one should, recovering if
possible, and report whether one is now present.

**Inputs (env):**
- `ISSUE_NUMBER` (required) — issue being implemented.
- `REPO` — `owner/repo` (default `$GITHUB_REPOSITORY`).
- `DEFAULT_BRANCH` (required for recovery) — base branch to diff against and target.
- `IS_ERROR` — `true|false`, the agent result error flag (default `false`).
- `GH_TOKEN` / ambient `gh` auth.
- `RECOVER_PRS_JSON`, `GIT_STATE_*` style overrides — test seams so Layer-1 fixtures can
  drive the script without a real git remote or `gh` (mirrors `find-pipeline-pr.sh`'s
  `PIPELINE_PRS_JSON` seam).

**Logic (guard clauses):**
1. If `IS_ERROR=true` → no-op. Emit `pr-present=false recovered=false`. (Genuine agent
   failure; existing handling owns it.)
2. Run `find-pipeline-pr.sh`. If `found=true` → emit `pr-present=true recovered=false`.
3. Recovery path. Determine the agent branch via `git rev-parse --abbrev-ref HEAD`. Recovery
   is attempted only when **all** hold:
   - branch is **not** `DEFAULT_BRANCH` (and not detached `HEAD`),
   - branch exists on `origin` (`git ls-remote --exit-code --heads origin <branch>`),
   - branch is **ahead** of `origin/DEFAULT_BRANCH` (has commits).
   If any fail → emit `pr-present=false recovered=false` (nothing to recover).
4. Open the PR: `gh pr create --draft --base "$DEFAULT_BRANCH" --head "$branch"` with a body
   containing `Closes #<ISSUE_NUMBER>`, wrapped in the retry/backoff helper. After it
   returns, re-run `find-pipeline-pr.sh` to confirm.
   - confirmed → `pr-present=true recovered=true`.
   - `gh pr create` exhausts retries or the non-retryable branch (permissions) → emit
     `pr-present=false recovered=false`.

**Outputs:** `found`/`pr-present`/`recovered` to stdout and, when set, `$GITHUB_OUTPUT`
(same dual-output pattern as `find-pipeline-pr.sh`).

**Exit codes:** `0` success (regardless of `pr-present`); `2` required env missing.

### `lib/gh-retry.sh` (new shared helper)

`gh_retry_pr_create` (or a generic `with_backoff`) — runs a command with exponential backoff:
- up to 3 attempts, jittered sleep between them;
- retries only on transient/secondary-rate-limit signatures in stderr
  (e.g. `secondary rate limit`, `rate limit`, `was submitted too quickly`, HTTP 5xx/timeouts);
- fails fast (no retry) on non-retryable errors — notably the permission message from gotcha
  #6 (`not permitted to create or approve pull requests`);
- `set +x` around any token-bearing invocation; `printf` for logging.

### `scripts/post-run-report.sh` (modified)

Add one **optional** input `PR_PRESENT` (unset = current behaviour, preserving existing
callers and tests). New rule in the status block:

- `IS_ERROR=false` **and** `PR_PRESENT=false` → status becomes `ai:failed`,
  `STATUS_TEXT="failed: run completed but no PR was opened"`, labels swap accordingly.
- `IS_ERROR=false` and (`PR_PRESENT=true` or unset) → unchanged `ai:done`. When the new
  step reports `recovered=true`, the comment notes the PR was opened by pipeline recovery.

### `.github/workflows/claude-implement.yml` (modified)

Insert the verify-or-recover step after the agent step, capturing `pr-present` (and
`recovered`) as step outputs, and pass `PR_PRESENT` into the `post-run-report.sh` step's env.

## Data flow

1. Agent runs, pushes branch, *may or may not* open the PR; emits result JSON → `IS_ERROR`.
2. verify-or-recover step: PR found? → done. Else discover branch, attempt recovery.
3. Step outputs `pr-present`.
4. post-run-report stamps `ai:done` (PR present, possibly recovered) or `ai:failed`
   (no PR) and renders the comment with the correct cause.

## Error handling

- Recovery never masks a genuine agent error (`IS_ERROR=true` short-circuits).
- Non-retryable `gh pr create` failures (permissions) fail fast → `ai:failed`, surfacing
  gotcha #6 loudly instead of silently.
- Recovery is best-effort: if the branch is missing or not pushed, the run is honestly marked
  `ai:failed`; no fabricated success.
- Script is `set -euo pipefail`; required-env failures exit `2`.

## Testing (Layer-1, mocked `gh`/git)

New fixtures + `tests/run-script-tests.sh` cases for `verify-or-recover-pr.sh`:
- `IS_ERROR=true` → no-op, `pr-present=false`.
- PR already exists → `pr-present=true recovered=false`, no `gh pr create` call.
- No PR + recoverable branch → recovery opens PR → `pr-present=true recovered=true`.
- No PR + no branch (or not pushed / not ahead) → `pr-present=false recovered=false`.
- `gh pr create` fails-then-succeeds (transient) → retry helper recovers → `recovered=true`.
- `gh pr create` permanent (permission) → fails fast → `pr-present=false`.

`post-run-report.sh` cases:
- `IS_ERROR=false` + `PR_PRESENT=false` → `ai:failed` + the no-PR status text.
- `IS_ERROR=false` + `PR_PRESENT` unset/true → unchanged `ai:done` (regression guard).

`lib/gh-retry.sh`: retryable vs non-retryable classification unit cases.

All Layer-1, no network/GitHub, < 5s total. Every new branch covered by a fixture
(repo convention). `actionlint` + `shellcheck -x` clean.

## Documentation

Update CONSUMER-SETUP.md gotcha #6 to note the pipeline now verifies-and-recovers the PR and
marks `ai:failed` when it can't, so the missing-PR case is no longer silent. CHANGELOG
`[Unreleased]` → Fixed.
