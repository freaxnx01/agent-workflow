---
description: ai-implement backlog readiness — how many issues could be dispatched at all, and what is blocking the rest
---

`/ai-stats` answers *how did the dispatches go?*. This answers the question that comes
before it: **how many issues could be dispatched at all?**

Those are different failures. A repo can have a flawless ship rate and still be
starved, because the pipeline only ever sees the handful of issues someone enriched.
No dispatch-outcome report can detect that — an issue that was never dispatched leaves
no dispatch record to count.

Run the collector, then read the report back to me. Arguments pass straight through:

```bash
bash "$HOME/.claude/scripts/lib/ai-funnel.sh" $ARGUMENTS
```

Common invocations:

| Command | Scope |
|---|---|
| `/ai-funnel` | the current repo, every issue |
| `/ai-funnel --milestone september` | one milestone (case-insensitive substring) |
| `/ai-funnel --repo owner/name` | a named repo instead of the current clone |
| `/ai-funnel --state open` | open issues only |
| `/ai-funnel --limit all` | every row of the blocked/ready tables, not the first 20 |
| `/ai-funnel --json` | raw per-issue records, for piping into `jq` |

## The funnel

Each stage is a subset of the one above it:

```text
total → open → live (not parked) → carrying a plan → ready to dispatch
                                 ↘ blocked on enrichment
```

**Ready to dispatch** is the number that matters — the queue depth an operator can
actually fill right now. It applies `/gh:implement`'s own preconditions, so an issue
counted here is one that command will accept: open, not `🧊 parked`, not already
carrying `ai-implement`, no `needs-enrichment` / `❓ to-be-defined`, and an
`## Implementation Plan` section in the body.

The **What is blocking the rest** table names every blocker per issue rather than the
first one, so `/enrich` targets are obvious at a glance.

## Where the numbers come from

Nothing extra is tracked. Labels, the issue body, and the timeline:

- **Dispatched** — `ai-implement` LabeledEvent entries. Two entries is a re-dispatch.

- **Shipped** — a merged pull request that closed the issue, read from
  **`ClosedEvent.closer`** with `closedByPullRequestsReferences` as a second source.
  Both are needed: GitHub forms **no closing reference** for a PR authored by
  `app/github-actions`, which is every PR this pipeline opens. On
  `BI-ArchiveUploader`, #263, #328 and #258 all shipped via a merged agent PR and all
  three read as an empty `closedByPullRequestsReferences`. `closer` sees them.

  `/ai-stats` reads the same union (it did not, until #319 — it read the reference list
  alone and undercounted shipped on exactly the repos it exists to measure), so the two
  commands agree on what shipped.

- **Shipped by the pipeline vs. by hand** — reported separately. An issue can ship
  without ever being dispatched, so folding the two together produces a ship rate
  above 100%.

- **Turn budget** — `### Task N` headings counted exactly as `classify-turns.sh:113`
  counts them, so the tier shown is the tier a dispatch will really get.

## The #297 warning

If a plan's task headings are at the wrong level — `## Task N` or `# Task N` instead of
`### Task N` — `classify-turns.sh` scores them **zero** and the run silently lands on
the 50-turn floor, however large the plan actually is. The report calls those out by
issue number. It is invisible otherwise: the issue body looks completely enriched.

## Reading it back

Lead with **queue depth** and **enrichment coverage** — they are the two numbers that
decide whether the pipeline can be kept busy. Then say which issues to enrich next,
using the blocker table; prefer ones whose files do not collide with whatever is
currently running.

Do not recite every table. If enrichment coverage is low, that is the finding, and the
ship rate below it is measuring a sample too small to mean much — say so rather than
reporting both as equals.

If you run into blockers, find a solution and update this command for the future.
