# Azure DevOps in-job retry — live proof (2026-11-09)

Gap item a of #573. Spec: `docs/superpowers/specs/2026-11-09-azdo-retry-design.md`.
Run in the personal sandbox project, on `<agent-host>`, from branch commit
`af721de`.

**Headline:** a transient failure on attempt 1 was retried in the same job and
attempt 2 opened the draft PR. The next tag on the same work item parked it at
the attempt cap without calling the agent. The first live run found a bug that
the Layer-1 tests had missed (a detached checkout), which is fixed in `af721de`.

## Failure injection (Step 2)

The sandbox pipeline YAML gained a step, gated on the pipeline variable
`AWF_INJECT_TRANSIENT=1`, that puts a `claude` wrapper first on `PATH`. On the
job's first call the wrapper prints a transient-shaped result
(`API Error: 529 Overloaded`, 3 turns, $0.05) and exits 1; later calls `exec`
the real CLI. Nothing in agent-workflow changed for the injection. The same
change wrapped the steps in a job with `timeoutInMinutes: 240`.

## Results

- [x] **0. First attempt found a bug.** Run 42 (a fresh item): attempt 1 failed
  `transient` as injected, then the workspace reset stopped the run with
  `error: branch 'HEAD' not found`.
  - **Cause:** Azure Pipelines checks out a detached HEAD. The attempt never
    branched, so the driver recorded the branch as `HEAD` and the reset ran
    `git branch -D HEAD`.
  - **Fix (`af721de`):** a detached HEAD now means "no branch". Layer-1 tests
    for a detached checkout were added first and reproduced the failure.
- [x] **1. Retry.** Run 44 on a fresh item:
  - attempt 1 failed `transient` (`next: retrying in 10s`);
  - the reset put the workspace back on `main` at the merge commit;
  - attempt 2 succeeded and opened one draft PR, linked to the work item;
  - exactly two `## ai-implement run (pipeline, Azure DevOps) — attempt N`
    comments;
  - the job was green.
- [x] **2. Cap.** Re-tagging the same item queued run 47. It printed
  `attempt=3`, `proceed=false`, posted `## ai-implement parked`, set the
  `parked` tag, made **no** agent call, and the job was green.
- [ ] **3. Remote branch.** Not shown live: the injection fails before the agent
  does anything, so no branch reached the server. Layer-1 covers the line
  (`transient-pushed,success`).
- [x] **4. Workspace.** Attempt 2 ran the agent-workflow scripts from the clone
  in the agent's temp directory after the reset, so `git clean -ffdx` in the
  checkout did not touch it. Attempt 2 started on the default branch.
- [x] **5. Real comment format.** Read back through the comments API: the
  report is stored as markdown with `format: "html"` and no wrapper tags, and
  `**Turns:**` and `**Cost:**` survive as text. The converter needed no change.
- [x] **6. Fixture.** The attempt-1 report, trimmed to `id` and `text`, is
  `tests/fixtures/azdo-comments-report-live.json`. A forge-adapter case checks
  that `check-attempt-cap.sh` counts it as one real attempt and not a
  non-start.
- [x] **7. Timing.** Run 44's job took 82 s (attempt 2's agent took 39 s),
  against a 240-minute budget.

## Discoveries (not acted on)

- The service hook again missed the first tag on one fresh item and delivered
  it about a minute later for another, which adds to the existing TODO entry.
  One extra run (46) found the tag already consumed and exited cleanly.
- The success report ends with `next: review and merge !<id>`. The plan's text
  also names an "auto-merge is unavailable" closing line; Task 3's flow wins.
- `tests/run-enrich-batch-doc-tests.sh` failed twice under a full sweep and
  passed alone both times. It is unrelated to this item.

## Cleanup

- The probe PR was abandoned and its branch deleted.
- `AWF_INJECT_TRANSIENT` was removed from the pipeline; the gated step stays in
  the sandbox YAML, inert.
- The `ai-implement` pipeline is pinned back to `d563723`.
