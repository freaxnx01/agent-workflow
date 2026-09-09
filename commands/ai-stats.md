---
description: ai-implement dispatch stats — ship rate, per-issue grade, agent and model breakdown
---

Report how the `ai-implement` pipeline is actually performing: how many issues were
dispatched, how many shipped, what it cost, and which agent/model combinations are
carrying their weight.

Run the collector, then read the report back to me. Arguments passed to `/ai-stats`
go straight through:

```bash
bash "$HOME/.claude/scripts/lib/ai-stats.sh" $ARGUMENTS
```

Common invocations:

| Command | Scope |
|---|---|
| `/ai-stats` | the current repo |
| `/ai-stats --all` | every repo under the authenticated owner that has dispatched |
| `/ai-stats --repo owner/name` | one named repo (repeatable) |
| `/ai-stats --since 30d` | only dispatches in the last 30 days (`Nd` / `Nw` / `Nm`, or an ISO date) |
| `/ai-stats --limit all` | show every row of the per-issue table, not the first 40 |
| `/ai-stats --json` | raw per-issue records, for piping into `jq` |
| `/ai-stats --no-exclude` | include repos excluded by default (see below) |

Sandbox repos (`*-sandbox`) are **excluded from the totals by default** — a sandbox
exists to absorb failed runs, so its zeroes are noise rather than signal. They are
still listed under an **Excluded** heading at the foot of the report, never dropped
silently. `--exclude <glob>` replaces the default globs; `--no-exclude` clears them.
A repo named explicitly with `--repo` always counts.

## Where the numbers come from

Nothing extra is tracked — the report is reconstructed from what the pipeline already
writes to GitHub:

- **Dispatches** — every `ai-implement` label event in an issue's timeline, so a
  redispatch counts as a separate attempt.

- **Outcome, agent, model, turns, cost** — parsed out of the `## ai-implement run`
  comments that `scripts/post-run-report.sh` posts on the issue.

- **Shipped** — the issue was closed by a pull request that was merged.

That means an issue closed by hand, or by a PR that was never linked, reads as *not
shipped* even if the work landed. Say so when the shipped count looks low rather than
treating it as a pipeline failure.

## Enrichment correlation

The report groups issues by whether they carried an `## Implementation Plan` when
dispatched, so you can see whether enrichment actually predicts shipping. Runs from
before this was recorded show as **unknown** — that is most of the history, so give
the split time to fill in before drawing conclusions from it.

## Per-issue grade

| Grade | Meaning |
|---|---|
| **A** | shipped on the first attempt, under $2 |
| **B** | shipped in one or two attempts |
| **C** | shipped, but took three attempts |
| **D** | shipped only after more than three attempts, or cost $10+ |
| **F** | never shipped |

## Reading it back

Lead with the headline rates and the spend per shipped issue. Then call out the
outliers rather than reciting every table — the repos and models burning dispatches
without shipping, and any model whose OK rate is far off its cost. Keep it short; the
full tables are already on screen.

If you run into blockers, find a solution and update this command for the future.
