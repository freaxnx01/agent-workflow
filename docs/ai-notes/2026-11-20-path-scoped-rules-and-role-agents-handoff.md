# Handoff: path-scoped rules rollout and the role-agents brainstorm (#560)

Saved 2026-11-20. This session covered two threads.

## 1. Path-scoped rules: design and plans done, rollout in progress

- Spec: `docs/superpowers/specs/2026-10-23-path-scoped-rules-design.md` (on main, merged via #561).
- Plans: `docs/superpowers/plans/2026-10-23-path-scoped-rules-{1-ai-instructions,2-sync,3-pointers,4-integration}.md`.

| Step | Issue / PR | State on 2026-11-20 |
|---|---|---|
| 1. ai-instructions: `.ai/rules/` tier, validator, three pilot rules as copies | ai-instructions#55 → PR #57 | **Open draft.** Review fixes pushed (d925aa3: CI wiring; db9e0e0: extra fixtures and CRLF `.gitattributes`), 11/11 cases pass. Waiting on human review and merge. |
| 2. agent-skills: sync writes the rules out per tool, released as 0.5.0 | agent-skills#11 | Not started. Run **locally** once #57 merges, starting with plan 2's Task 1 spike (does opencode honour `instructions: [".claude/rules/*.md"]` under `OPENCODE_CONFIG_CONTENT`?). |
| 3. ai-instructions: replace the three sections with one-line pointers | ai-instructions#56 | **Gated:** dispatch only after sync 0.5.0 is released. |
| 4. agwf: `/integration` reports rules and flags `rules-invisible-to-opencode` | agent-workflow#562 → PR #563 | **Merged.** Task 3 (re-sync agwf as the pilot repo) is still open; it needs steps 2 and 3 done first. |

Low-priority review findings I left on purpose (reasons are in the PR comments):

- a symlinked rule file is reported as unreadable;
- globs prefixed with `./` or matching `.claude/**` don't count as covering the rules;
- the CHANGELOG regeneration order;
- the commands in the ai-instructions CLAUDE.md.

Cleanup:

- remove the worktree `.worktrees/pr563` (its PR #563 is merged);
- remove the ai-instructions worktree `.worktrees/rules57` after #57 merges;
- delete the local branch `docs/path-scoped-rules-spec` (its PR #561 is merged).

## 2. Role agents (#560): brainstorm just started

- Issue: agent-workflow#560 (milestone `next`, `needs-enrichment`). The issue body lists the candidates and the open questions:
  - `enricher`: read-only tools, strong model;
  - `doc-writer`: Markdown-only tools, cheaper model;
  - implementer/reviewer leaf workers;
  - where agents live: user level via `link-agents.sh`, project level, or pipeline `claude -p --agents`;
  - nested spawning is reported to be flaky;
  - opencode has no equivalent.
- Inspiration: Alex Sprogis' `ai-coding-starter-kit`. Its agent configs only set model, tools and turn limit; the skills that make heavy edits run as forked subagents, and the planning skills stay inline.
- Brainstorming state (`superpowers:brainstorming`):
  - The opener has been sent: the user can skip the questions, plus one open question.
  - **Nothing has been decided yet. No spec exists.**
- Open question to the user: *"Think of the last time you ran `/enrich` or had a doc written: what went wrong, or cost more than it should have, that made you think 'this should be its own agent'?"*
- Next step:
  - Continue the brainstorm from the user's answer.
  - When it's done, write the spec to `docs/superpowers/specs/YYYY-MM-DD-role-agents-design.md`.
  - Then run a builder check, get the user's approval, and run writing-plans.
  - Per the subagent-driven-default partial, an issue-based plan is dispatched through the `/enrich` ending, not run locally.
