---
description: Pre-review PRs against their issue's AC, then trigger Claude to fix (Copilot disabled)
argument-hint: "[PR numbers, e.g. 83 84 — or empty for all open non-merged PRs]"
---

Pre-review open pull request(s) in the current repo, post the review, and — only
when there are actionable fixes — nudge the agent that owns the PR to address them.

## Which PRs

`$ARGUMENTS` is an optional space-separated list of PR numbers. If empty, review
every open PR that still needs attention: `gh pr list --state open --json
number,title,author,isDraft,headRefName` — include drafts (agent PRs are usually
drafts), but skip a PR that is already approved with no open threads. Always say
which PRs you picked before starting.

**Skip a PR the pipeline's own AI-review / human-merge flow (ADR-004) already
reviewed and approved** — check for a "Reviewed ✓ — promoted to ready" comment
from the pipeline on the PR (`gh pr view <N> --json comments`). That means an agent
already reviewed this exact diff and a human just needs to merge; running this
manual pass again is redundant unless the user explicitly wants a second
opinion. If the linked issue instead carries `ai:review-blocked`, that flow
ran and found problems (left the PR draft) — still worth this manual pass, and
say so, since its own verdict/reason is useful context to fold in
rather than re-derive from scratch.

## Reviewing (one reviewer per PR, in parallel)

For **each** PR, dispatch a subagent (parallel when there are 2+ — one per PR) that
does a real review, not a diff skim:

1. **Find the linked issue** — from the PR body (`Closes #N` / `implements #N`) or
   the branch name; `gh pr view <N> --json title,body,files,headRefName` +
   `gh pr diff <N>`.
2. **Read the actual source**, not just the diff — verify claims in context.
3. **Review focus, in priority order:**
   - **Correctness bugs** — logic errors, regressions, broken behavior.
   - **Acceptance-criteria coverage** — walk the linked issue's checklist; mark each
     met / partial / missing.
   - **Project conventions** — read `CLAUDE.md`; honor the stack rules (e.g. for
     .NET here: `ProblemDetails` for all errors, `IStringLocalizer` for UI strings,
     `WebApplicationFactory` integration tests, no swallowed exceptions, no hardcoded
     test returns, non-root Docker final stage).
   - **Security** — secrets, header logging, auth, CORS, input validation.
   - **Quality** — reuse, simplification, dead code, scope creep.
4. **Return** a tight report: size, a **verdict** (`Approve` / `Approve-with-nits` /
   `Changes-requested`), findings grouped **Blocking** / **Should-fix** / **Nits**
   (each with `file:line` + one line), then an **AC coverage** checklist. No file dumps.

## Posting the review

Post each review as a **comment-type** review (works on drafts; never auto-approve):

```bash
gh pr review <N> --comment --body-file <file>
```

Lead the body with the verdict. Keep it to the structured findings + AC coverage.

## Triggering the owning agent (only if fixes are needed)

Skip this entirely for a clean `Approve`. For `Changes-requested` or
`Approve-with-nits` **with actionable items**, post a **second, separate** comment
(not the review) addressed to the agent, with a concise **numbered** fix list (the
blocking items first).

**Copilot is disabled as of 2026-09-01** (GitHub Copilot access was revoked on
this account) — never nudge `@copilot`, even for a PR it opened, and even as a
"just get any agent to pick this up" fallback. To re-enable, restore the
pre-2026-09-01 version of this section (see git history).

Pick the mention from the PR's owner — `gh pr view <N> --json author,assignees,headRefName`:

- `app/copilot-swe-agent` → no nudge. Copilot can't act on it — tell the user
  the fix needs a manual pass or a re-dispatch to Claude instead.
- `app/anthropic-code-agent` (assignee *Claude*, branch `claude/…`) → mention
  Claude's agent.
- `app/github-actions` (opened by the `agent-workflow` pipeline via the
  `ai-implement` label) → no nudge. There is currently no mechanism for
  `agent-workflow` to react to review comments with the *same* model that did
  the implementation — that gap is tracked as `agent-workflow#193` (builds on
  `#81`). Post the should-fix findings as the review comment as normal, but
  **skip the second nudge comment** — tell the user the fix needs either a
  manual pass, a redispatch through `agent-workflow`, or `#193` implemented,
  and let them choose.
- If a repo defines its own `.github/workflows/*claude*.yml`, that's a self-hosted
  `@claude` Action — then `@claude` is genuinely the trigger; check for it first.

Reformat code-fence/backtick content safely for a shell `--body` (or use a body file).

## Verifying the agent's follow-up — don't trust the self-report

After nudging, re-check the PR directly rather than trusting the agent's reply
comment. Observed on a real nudge round-trip: the agent's summary claimed it
had updated the PR description **and** un-drafted it; neither was true — only
the code-file fix in its list actually landed. Diff the actual commit / fetch
the actual PR body before treating any item as resolved.

**Known structural limit — some coding-agent sandboxes can't edit PR metadata
at all.** A coding agent's internal `report_progress`-style tool can commit and
push code, but its sandbox may have GitHub REST API egress blocked (observed:
`Blocked by DNS monitoring proxy`, `gh auth` failing) — so it has **no path** to
`gh pr edit` / a PATCH call, no matter how it's asked. If a nudge asks for a
title/description/draft-state change and the agent's follow-up says it can't
apply it (rather than silently omitting it), that's not a one-off miss to
re-nudge — apply the edit yourself with your own `gh` access
(`gh pr edit <N> --title "..." --body-file <file>`, `gh pr ready <N>`) using
the exact text the agent proposed. Re-nudging a structural limitation just
burns another round-trip for nothing.

When monitoring a PR for "is this actually done" (e.g. a background poll),
gate on the literal content, not a cosmetic flag: hash the PR body with one
consistent command chain used at both baseline and each check (don't mix e.g.
jq's `@base64` filter with an external `base64` binary — they encode
identically-same text differently and produce false positives), and don't
gate solely on `isDraft`/a `[WIP]` title, since some agents leave both
untouched even after genuinely finishing (see the note on `review_requested`
above). The GitHub web UI's "Agents" tab showing a run as "Completed" is a
useful nudge to go look, not proof of a specific outcome — always re-verify
the actual PR state or diff. Default poll interval for this kind of loop: **60
seconds** — comfortably within a monitor's own 30s-minimum guidance for remote
APIs, with no need to go slower.

### Two dedup bugs that produce false "new"/silently-dropped events

Both observed in the same review-nudge-CI loop on a real PR — build the poll
loop's seen-set carefully, since a wrong dedup key silently breaks the signal
it exists to produce:

- **Seed the baseline in one shot before the loop starts, not inside the
  first iteration.** A loop that checks `[ -n "$seen_set" ]` as a proxy for
  "have I completed the first pass" breaks if `seen_set` is being built
  *during* that same pass — the check flips true partway through the initial
  listing (as soon as the second pre-existing item is appended), so most of
  the baseline gets misreported as "new" on the very first poll. Fix: query
  the full baseline once, store it, and only start comparing against it on
  the *next* poll — never mutate-and-check the same accumulator in one pass.
- **`gh run rerun <run-id>` reuses the same run ID — it does not mint a new
  one.** A poll loop that marks a run ID "seen" the moment it observes a
  `action_required`/pending conclusion (so it doesn't re-trigger the rerun
  every cycle) must **not** add that ID to the same permanently-seen set used
  for reporting results — otherwise the run's real terminal conclusion
  (`success`/`failure`) arrives under an ID the loop already wrote off, and
  the actual outcome never gets reported. Only mark an ID permanently seen
  once its conclusion is a genuine terminal state, not a gated/pending one.

**How to apply:** before shipping any poll-loop dedup logic, trace through it
by hand for the specific case of "the same identifier reappears with a
different state" (a rerun, a retry, a status transition) — most dedup bugs in
this class come from conflating "I've observed this ID once" with "I've
observed this ID's *final* state."

## After

Print, per PR: number, URL, verdict, and whether an agent was pinged (and which
mention). Note that Copilot pushes to the **existing branch**, so PR numbers don't
change and commit authorship will be mixed. Don't merge anything.

If there's no `gh`/repo context, say so and stop.
