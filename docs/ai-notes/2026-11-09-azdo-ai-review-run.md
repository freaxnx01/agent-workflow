# Azure DevOps AI review and self-fix — live proof (2026-11-09)

Gap item b of #573. Spec: `docs/superpowers/specs/2026-11-09-azdo-ai-review-design.md`.
Run in the personal sandbox project, on `<agent-host>`. The final runs used
branch commit `5265f9a`.

**Headline:** after the draft PR opened, the same `review-pr.sh` posted one PR
thread per head commit and a verdict comment on the work item. With
`SELF_FIX=1`, a `request_changes` review led to a fix commit by `ai-implement`,
a re-review on the new commit, and `approve`. The PR stayed a draft with no
reviewers. The live runs found two driver gaps, both fixed test-first.

## Results

- [x] **0. Live runs found two gaps.**
  - **Empty PR (run 50).** The agent branched, left its edits uncommitted and
    reported success. The driver pushed a branch identical to `main` and opened
    an empty draft PR. The review refused to review an empty diff
    (`review_failed`) and the job stayed green, as designed. **Fix
    (`dad3211`):** the driver refuses to open a PR when the branch has no
    commit beyond the default branch, and (`6dc3f8b`) logs the agent's closing
    message. The next run of the same request (run 53) stopped at that check.
  - **Self-fix skipped (run 58).** The review said `request_changes`, but
    self-fix was skipped because the checkout was not clean. The sandbox repo
    had no `.gitignore`, so `dotnet test` left `bin/` and `obj/` untracked.
    The check was **not** loosened. The sandbox got a standard .NET
    `.gitignore`, and (`5265f9a`) the driver now logs the leftover files when
    it skips.
- [x] **1. Approve path (run 55).**
  - one PR thread, verdict `approve`, whose marker is the PR's head commit;
  - the work item got `## ai-review verdict: approve` with `!<id>`;
  - the PR is still a draft with no reviewers;
  - the job was green in 84 s.
- [x] **2. Self-fix path (run 61, `SELF_FIX=1`).**
  - the first thread is `request_changes`, on the agent's commit;
  - a fix commit authored `ai-implement <ai-implement@noreply.invalid>` is on
    the PR branch, pushed by the driver;
  - a second thread carries the fix commit's marker, verdict `approve`;
  - the verdict comment says `approve` and `self-fix: 1 iteration(s)`;
  - the PR is still a draft with no reviewers;
  - the job was green in 139 s.
  - **Not checked live:** `.git/config` in the job. The sandbox pipeline's own
    checkout step uses `persistCredentials: true`, which writes an
    `extraheader` itself, so the check would not isolate this code. Layer-1
    covers it (`self_fix_secret_never_persisted`). The run logs show no token.
- [x] **3. Marker round trip and resource name.**
  - `--area git --resource pullRequestThreads` was accepted for the POST.
  - The threads read back through `forge_pr_comments_json` hold
    `<!-- review-pr:<sha> -->` verbatim, so a second review of the same commit
    posts nothing (the marker check is covered in Layer-1).
  - Azure DevOps adds a system thread ("The reference … was updated") after a
    push. It has content but no marker, and the parser handles it.
- [x] **4. Fixture.** The threads of the self-fix PR, trimmed to thread id and
  comment `content`, are `tests/fixtures/azdo-pr-threads-live.json`. A
  forge-adapter case reads both markers from it.
- [x] **5. Timing.** 84 s and 139 s, against the 240-minute budget.

## Discoveries (not acted on)

- The agent's own commits carry the git identity configured in the agent
  image, which is the maintainer's. The fix commit uses `ai-implement`. Whether
  the implement commit should also use a neutral identity is a separate
  decision.
- The service hook missed the first tag on fresh items again (runs queued by
  hand with `workItemId`), and `az pipelines runs list` omitted in-progress
  runs, so `az pipelines runs show <id>` is the reliable check.
- `tests/run-enrich-batch-doc-tests.sh` failed once more under a full sweep and
  passed alone.

## Cleanup

- The probe PRs were abandoned and their branches deleted.
- `SELF_FIX` was removed from the pipeline.
- The `ai-implement` pipeline is pinned back to `d563723`.
- The sandbox keeps its new `.gitignore`.
