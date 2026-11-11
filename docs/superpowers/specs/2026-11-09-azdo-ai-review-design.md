# Azure DevOps AI review and self-fix — Design (gap item b)

**Issue:** #573 · **Date:** 2026-11-09 · **Status:** draft, written unattended under
the maintainer's go-ahead of 2026-11-06. Calls marked *(my call)* were made by the
author, not the maintainer.

## Intent

On GitHub the agent's PR gets an AI review, optionally followed by a bounded
self-fix loop, before a human or the merge lane looks at it. On Azure DevOps the
draft PR opens and nothing reviews it. This item runs the **same review and
self-fix scripts** after the draft PR opens, and posts the review as an Azure
DevOps PR thread, so the human reviewer starts from a reviewed and, if enabled,
already-corrected PR.

## Goals

1. **G1:** after the draft PR opens, `review-pr.sh` reviews it. The verdict and
   concerns appear as **one PR thread**, idempotent per head commit.
2. **G2:** opt-in self-fix. With `SELF_FIX=1`, `self-fix-loop.sh` runs up to
   `SELF_FIX_MAX_ITERATIONS` (default 2) fix → re-review passes. It pushes each
   fix to the PR branch.
3. **G3:** the final verdict is reported on the work item, with the PR link.
4. **G4:** the GitHub path is unchanged. Its existing tests stay green.
5. **G5:** proven live in the sandbox: one PR with a review thread, and one with
   a self-fix commit followed by a re-review.

## Non-goals

- Auto-merge, or an AI merge lane. Azure DevOps expresses merge gates as branch
  policies and reviewer votes. That is its own design.
- Waiting for item c's build validation result before or after self-fix.
- Reviewing PRs that a human opened. This runs only inside the `ai-implement`
  job, on the PR that job just opened.

## Anti-goals

- **The agent never votes, approves, completes or publishes the PR.** It leaves
  it a draft. A human decides. A code path that calls the vote or complete
  APIs is a bug, and a Layer-1 test asserts that none exists (A6).
- A review agent with tools. The review stays `agent-cmd-claude.sh`
  (`--print`, no tools), because it reads untrusted diff text.

## Decisions

### B1 — Same job, after the PR opens *(my call)*

Review and self-fix run at the end of `implement-azdo.sh`, after
`forge_pr_create_draft`. They are not a second pipeline. The job already has:

- the checkout on the head branch;
- the push credentials;
- the work item context;

and adding a second trigger would mean a second trust question (see the retry
design). The cost is a longer job, which is covered by the timeout from the
retry design.

### B2 — Diff and head SHA through forge verbs *(revised after the builder check)*

A fixed `DIFF_FILE` / `NEW_HEAD_SHA` is wrong from the first self-fix on.
`self-fix-loop.sh` re-runs `review-pr.sh` with the same environment, so it
would re-review the old diff under the new SHA.

So add two forge verbs:

- `forge_pr_diff <pr>`
  - github: today's exact `gh pr diff` call.
  - azdo: `git diff origin/<default>...HEAD` from the job's checkout.
- `forge_pr_head_sha <pr>`
  - github: today's `gh pr view --json headRefOid`.
  - azdo: `git rev-parse HEAD`.

`review-pr.sh` and `self-fix-loop.sh` call the verbs where they call `gh`
today. The `DIFF_FILE` / `NEW_HEAD_SHA` seams keep precedence for tests. Every
iteration then sees its own diff and SHA. The github branches are byte-for-byte
the current calls, so G4 holds.

### B3 — Posting: a new forge verb pair

`review-pr.sh` posts with `gh pr comment` and checks idempotency with
`gh pr view --json comments`. Move both behind forge verbs in
`scripts/lib/forge.sh`:

- `forge_pr_comment <pr> <body-file>`
  - github: `gh pr comment`.
  - azdo: POST a new thread with one comment (`git/pullRequests/{id}/threads`,
    `status: active`). Use the same call style as the existing azdo code
    (`az devops invoke` or the `curl -K -` helper).
- `forge_pr_comments_json <pr>`: the bodies of existing comments, for the
  `<!-- review-pr:<sha> -->` marker check.

The github branch keeps the exact current `gh` calls, so GitHub behaviour does
not change. Mocks in `tests/mocks/az` / `curl` cover the azdo branch.

### B4 — Self-fix on Azure DevOps

`self-fix-pr.sh` already has `SKIP_CLONE` / `WORK_DIR` seams, so it runs in the
existing checkout. Two GitHub-bound pieces need forge handling:

- **Push auth:** it sets an `x-access-token` remote URL. On Azure DevOps it
  pushes with the same `http.extraheader` Basic auth that `implement-azdo.sh`
  uses. Never write the token into a remote URL or a log.
- **New head SHA:** `self-fix-loop.sh` reads it with `gh pr view`. On Azure
  DevOps use `git rev-parse HEAD` after the fix. Use the `NEW_HEAD_SHA` seam or
  a forge branch, whichever is smaller.

Before each self-fix push, the pipeline-file guard from item c (C6) runs. A fix
that touches a pipeline file stops the loop, and the work item says why.

The commit identity is the pipeline's, not `github-actions[bot]`. Use a
neutral `ai-implement` identity on Azure DevOps *(my call)*.

### B5 — Configuration

Pipeline variables, documented in the guide:

- `AI_REVIEW` (default `1`)
- `SELF_FIX` (default `0`, as on GitHub)
- `SELF_FIX_MAX_ITERATIONS` (default `2`)

These variables only reduce or bound work. None of them can skip the guard.

### B6 — Never vote: enforced by test

A Layer-1 test greps the azdo code paths (`implement-azdo.sh`, the azdo
branches of `forge.sh` / `lib/azdo.sh`) for:

- the PR vote, `reviewers` and `complete` / `autoCompleteSetBy` API shapes;
- `az repos pr update --status`;
- `--draft false`.

Then it runs the end-to-end stub and asserts that the `az` / `curl` mock logs
contain no such call. The grep alone is not evidence: the run must also show it.

## Tests

- **Layer 1:**
  - `forge_pr_comment` / `forge_pr_comments_json` for both forges, with
    fixtures.
  - `review-pr.sh` with `FORGE=azdo`: it posts one thread, and a second run on
    the same SHA posts nothing.
  - The self-fix loop on azdo with the existing fix and review stubs: it pushes
    through extraheader (assert from a git mock or a local bare remote), the
    iterations are bounded, and the final verdict is reported.
  - B6.
- **Live (sandbox):**
  - An item whose change is fine → a review thread with `approve`.
  - An item seeded to draw a concern (for example "add a function, no test
    required") with `SELF_FIX=1` → a review thread, a fix commit pushed, a
    second review thread on the new SHA, and the verdict on the work item.
  - Record both in a run note.

## Left to the builder

- `az devops invoke` versus `curl` for the thread POST. Match whichever
  `lib/azdo.sh` uses for similar writes.
- The thread body format. Reuse the GitHub comment body from `review-pr.sh`;
  markdown renders in Azure DevOps threads.
