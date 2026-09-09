---
description: Validate issue readiness, then label it ai-implement so the agent-workflow picks it up and opens a draft PR
argument-hint: <issue number>
---

Hand issue #$ARGUMENTS to the **agent-workflow** by applying the `ai-implement` label.
Strip any leading `#` from the argument.

The pipeline trigger: `issues: labeled` → `agent.yml` in the current repo fires →
Claude Code implements the issue on a new branch and opens a draft PR.

## Preconditions — check before labeling

1. **Issue is open and not parked** — `gh issue view <N> --json state,labels`; stop if
   closed or carrying `🧊 parked`.
2. **Not already queued** — if `ai-implement` is already on the issue, say so and stop
   (avoid double-triggering).
3. **Pipeline is wired up** — `.github/workflows/agent.yml` must exist in the repo;
   if it doesn't, tell the user to wire up the consumer stub first (see
   `docs/CONSUMER-SETUP.md` §1 in `agent-workflow`), then stop. Note
   `/sync-ai-instructions` does **not** create this file — it syncs instruction
   files only, and carries no workflow template.
   A legacy `claude.yml` stub also counts as wired up, but warn that it should be
   renamed: retry-on-rate-limit and chain-dispatch redispatch `agent.yml` by
   default and the retry target is not consumer-overridable, so the initial run
   works while retries silently 404.
4. **Issue is ready for an agent** — read the full issue body and comments with
   `gh issue view <N> --comments`, then judge whether an AI agent has enough to
   implement it without guessing. A ready issue has **all three**:
   - **Acceptance criteria** — concrete, testable conditions ("given X, when Y, then Z";
     or a checklist of behaviours). Vague goals ("make it better") don't count.
   - **Scope / spec** — what to build: endpoints, data model, UI behaviour, or a
     concise implementation plan. The agent must be able to start without asking
     clarifying questions.
   - **No blocking unknowns** — no open design questions, unresolved dependencies, or
     "TBD" placeholders that the agent cannot resolve from the codebase alone.

   If any of the three is missing, **stop** — do not label. Tell the user specifically
   what's missing and suggest they add it to the issue body before re-running.
   If it carries `needs-enrichment` or `❓ to-be-defined`, treat that as a hard stop
   (don't just warn — the label signals the issue is not ready).

5. **Issue body has an `## Implementation Plan` section** — a mechanical check, not a
   judgment call:

   ```bash
   gh issue view <N> --repo <owner/repo> --json body --jq .body \
     | grep -qi '^## Implementation Plan' && echo ready || echo "NO PLAN"
   ```

   If it prints `NO PLAN`, **stop** — do not label. Tell the user the issue was never
   enriched and to run `/enrich <N>` first.

   This is a hard stop even when precondition 4 passed, because a readable proposal
   plus acceptance criteria is *not* the same thing as a plan, and the pipeline reads
   that exact heading twice:
   - `classify-turns.sh` sizes the turn budget from the `### Task N` headings under it.
     No section means no size estimate, and the run falls back to
     `UNPLANNED_MAX_TURNS` — a blind guess, not a measurement.
   - The agent gets no task decomposition, so it spends its budget rediscovering the
     decomposition `/enrich` would have written down.

   #260 and #262 both cleared precondition 4 on the strength of an `## Acceptance
   criteria` section, were labeled with no plan, and each burned its full turn budget
   without opening a PR — $4.62 of compute for nothing. If you deliberately want to
   dispatch a genuinely trivial issue without enriching it, say so explicitly and
   apply a `turns:50` label alongside `ai-implement` to keep the budget honest.

## Post the implementation contract

Read `~/.claude/commands/gh/implementation-contract.md` and follow it: apply its
ordered detection rule to this issue, pick **one** variant, and post that variant
as an issue comment with `<N>` replaced by the actual issue number.

That file is the single source of truth for both the rule and the two contract
bodies — do not restate either here.

Before posting, print one line naming the variant chosen and the rule that selected
it, e.g. `contract: docs-only (rule 1 — AC says "no test is added or changed")`, so
the operator can correct it before the agent picks the issue up.

**On a re-dispatch, check the contract is not stale before relying on it.** The
contract is a comment, and re-applying `ai-implement` does not re-post it — the
agent reads whatever comment is already there, however old. When
`implementation-contract.md` has changed since it was posted, the run silently
follows superseded instructions.

So before labelling, look for an existing contract comment on the issue:

- **None** → post the chosen variant, as above.
- **One that matches the variant you would post now** → leave it; say so and move on.
- **One that differs** → post the current variant as a new comment, opening it with
  one line naming what it supersedes and why, e.g.
  `> **Superseding the contract posted at <timestamp>.** It told you to commit but
  never to push, so a truncated run lost everything.` Do not edit or delete the old
  comment — the issue's history is how an operator reconstructs which instructions a
  given run actually followed.

This is not hypothetical. `flowhub#20` was dispatched three times against a contract
posted before the push-per-task fix landed. The third run implemented six of seven
tasks, committed each one exactly as that stale contract asked, pushed none of them,
and produced nothing — the fix had been merged hours earlier and the issue never saw it.

## Apply the label(s)

Ensure the `ai-implement` label exists in the repo (create it if absent — color `#0075ca`,
description "Trigger: agent-workflow Claude implementation"):

```bash
gh label create ai-implement --color "0075ca" --description "Trigger: agent-workflow Claude implementation" --force
```

**Check whether the repo's `agent.yml` wires the AI-review / human-merge flow**
(`grep -qE "(ai-review-human-merge|pre-preview): true" .github/workflows/agent.yml`
if checked out locally, or
`gh api repos/<owner>/<repo>/contents/.github/workflows/agent.yml --jq '.content' | base64 -d`
otherwise — match either spelling, since `pre-preview` is deprecated but still
honoured until v3). If it does, also apply `ai-review-human-merge` so the pipeline's
own agent review (ADR-004, named by ADR-009) runs automatically after the draft PR
opens.

**Apply the trigger label in its own call, never combined with the review label.**
`gh issue edit` is atomic across `--add-label` flags: if any named label does not exist
in the repo, the whole call fails and **neither** label is applied — so a missing review
label silently prevents the run from ever starting:

```text
$ gh issue edit 307 --add-label ai-implement --add-label ai-review-human-merge
failed to update 1 issue
$ gh issue view 307 --json labels --jq '[.labels[].name]'
[]
```

That is a **bootstrap deadlock**, because `ai-review-human-merge` is created by
`ensure-issue-labels.sh`, which the pipeline runs *inside* the implement job. On a
consumer onboarded before ADR-009 the label only comes into existence once a run has
started — and the run cannot start, because applying the label is what fails. Note the
error names neither the label nor the reason.

So: trigger first, review label second, tolerating both the new and the deprecated
spelling:

```bash
gh issue edit <N> --add-label ai-implement

gh issue edit <N> --add-label ai-review-human-merge \
  || gh issue edit <N> --add-label ai-pre-preview \
  || echo "note: neither review label exists in this repo — the PR will stay draft;
run 'REPO=<owner/repo> bash scripts/ensure-issue-labels.sh' to create them"
```

If the repo does **not** wire that flow, apply just `ai-implement`
(the extra label would be an inert no-op, but don't apply labels a repo's pipeline
doesn't act on):

```bash
gh issue edit <N> --add-label ai-implement
```

**Upgrading a consumer across ADR-009.** A repo onboarded before the rename carries the
old `ai-auto-review` / `ai-pre-preview` labels and not the new ones. Re-running the
label script is idempotent (existing labels are preserved unchanged, colors included),
so it is the right first step when a consumer's dispatch behaves oddly:

```bash
REPO=<owner/repo> bash scripts/ensure-issue-labels.sh
```

## Report

Print:

- Issue number, title, and URL
- "agent-workflow triggered — Claude will open a draft PR shortly"
- If the human-merge flow is wired: "the pipeline will review its own PR automatically and
  promote it from draft to ready on approve — no `/gh:review` needed unless it
  gets blocked (`ai:review-blocked` label) or you want a second opinion"
- If not: remind the user to watch for a new PR and review it with `/gh:review`
  when it appears
