---
description: agent-workflow + ai-instructions integration status — what is wired, what it runs on, and what will silently fail
---

Report how a repo is wired into **agent-workflow** and **ai-instructions**, and whether
that wiring will actually work. Read-only — this command never changes anything.

Run the collector, then read the report back to me. Arguments passed to `/integration`
go straight through:

```bash
bash "$HOME/.claude/scripts/lib/integration-status.sh" $ARGUMENTS
```

Common invocations:

| Command | Scope |
|---|---|
| `/integration` | the current repo |
| `/integration --all` | every non-archived repo under the authenticated owner |
| `/integration --repo owner/name` | one named repo (repeatable) |
| `/integration --show-all` | also list the repos with neither half wired |
| `/integration --json` | graded records, for piping into `jq` |
| `/integration --from dump.json` | re-render a previous `--json` dump, no API calls |

## What it reports

**The agent-workflow half** — read from the consumer stub plus the repo around it:

- which stub exists (`agent.yml`, or a legacy `claude.yml`), and the **pinned ref**
  against the current release
- **agent and model** (`agent:` / `default-model:`), and the **flow**:
  `ai-review-human-merge`, `ai-review-ai-merge`, the deprecated `pre-preview`, or
  plain draft-only
- the knobs: `self-fix` and its iteration cap, `timeout-minutes`,
  `claude-timeout-minutes`, `runner-labels`
- the repo-side state a run depends on: secrets set, the `ai-*` labels, "Actions can
  create PRs", and auto-merge/squash for an ai-merge repo

**The ai-instructions half** — which of the five generated files exist, which stack
overlay is in use, and whether `.ai/base-instructions.md` and the stack overlay match
upstream.

Each repo gets one verdict: **healthy**, **degraded** (runs, but not as intended),
**broken** (will fail on dispatch), **partial** (one half only), **not-integrated**, or
**unreadable** (an API read failed after retries, so the repo was *not read* rather
than graded). Unreadable sorts first, then broken — an ungraded repo is worse news
than a graded bad one.

## The findings that justify the API calls

Five failure modes are silent — the run looks fine and does the wrong thing, or never
starts and says nothing useful:

- **`secret-not-forwarded`** — a critical secret (`CLAUDE_CODE_OAUTH_TOKEN`,
  `PIPELINE_APP_ID`, `PIPELINE_APP_PRIVATE_KEY`) is set on the repo but the stub's
  `secrets:` block never passes it through, so the App stays inert with no error
  anywhere (`docs/PIPELINE-APP-SETUP.md` step 7).

- **`openrouter-not-forwarded`** — the same gap for `OPENROUTER_API_KEY`, graded by
  what it actually costs: **broken** on a repo that declares `agent: opencode`, and
  **degraded** on a Claude repo, where it only bites once somebody applies a
  per-issue `agent:opencode` label and the run silently stays on Claude.

- **`flow-label-missing`** — `gh issue edit --add-label` is atomic across its flags.
  One absent label and **neither** lands, so the run never starts and the error names
  no label. This is the bootstrap deadlock described in `/gh:implement`.

- **`permissions-incomplete`** — a reusable workflow cannot be granted more than its
  caller. Missing `actions: write` turns every retry into a hard failure
  (`docs/CONSUMER-SETUP.md` gotcha #5).

- **`opencode-without-key`** — `classify-agent.sh`'s credential guard falls back to
  Claude when `OPENROUTER_API_KEY` is absent, so `agent: opencode` looks honoured
  while the run is not.

## Two things the report deliberately will not claim

**A secret is read as set, never as valid.** The API exposes a secret's name, never
its value, so an expired `CLAUDE_CODE_OAUTH_TOKEN` reads exactly like a working one.
When a repo looks healthy but its runs fail at auth, this is the first thing to
suspect — the report cannot see it.

**An instructions mismatch is "drifted", not "stale".** `ai-instructions` has no tags
and no releases, and the sync skill prints the source SHA without writing it anywhere,
so a repo carries no record of what it was synced from. The comparison is therefore
between git blob SHAs: exact about *whether* the bytes differ, silent about *why*. An
old sync and a deliberate local edit are indistinguishable. If you want that
distinction, the fix is upstream — have the sync write a provenance stamp.

## Cost

`--all` runs two phases: one cheap existence probe per repo, then the deep checks only
on repos that have something wired, four repos at a time. Measured over 82 repos:
**~3 minutes**, a few hundred API calls against a 5000/hour limit. Progress goes to
stderr, so `--json` stays a clean pipe.

`COLLECT_JOBS` raises or lowers the fan-out. Be careful raising it: at 8 the sweep
finished in 1 minute but tripped GitHub's **secondary** rate limit, and 18 wired
repos came back as "not integrated". That class of failure is now caught rather than
silently absorbed — a read that fails after retries makes the repo **`unreadable`**,
listed at the top of the report and never counted as absent — but the right fix is
not to provoke it.

If you are iterating on the report itself, collect once with `--json` and re-render
with `--from` — that costs nothing.

## Acting on it

This command only reports. The fixes live elsewhere:

- pipeline wiring → `/agent-workflow-init`, or `scripts/onboard-consumer.sh`
- missing labels → `REPO=<owner/repo> bash scripts/ensure-issue-labels.sh`
- drifted instructions → the `sync-ai-instructions` skill, run in the target repo

If you run into blockers, find a solution and update this command for the future.
