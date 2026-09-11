# Session record — handoff overview + Herdr fan-out (2026-09-09/10)

Working notes for the `worktree-handoff-overv` session. Everything designed here
**shipped**; this file exists so the remaining verification steps can be picked up
cold.

## What was asked

> "should make central handoffs.md (overview) with wt/branch name and resume prompt
> — wenn herdr: handoff all open sessions / pickup all handoffed sessions"

Classified **bounded** (existing `/handoff` + `/pickup` flows to change), so: three
clarifying questions, a short in-chat design, approval, then implementation. No spec
or plan document — this record is the artifact.

## Decisions (full rationale in ADR-011, `docs/DECISIONS.md`)

- The overview is **derived, never authored** — regenerated from the committed
  per-branch `.claude/handoff-<branch>.md` files on every `/handoff` and `/pickup`.
  An append-a-row index cannot survive the Herdr fan-out (N sessions writing at
  once); regeneration is idempotent by construction.
- **Two locations**, both written by one run: `.claude/handoffs.md` (one repo, all
  worktrees) and `~/.claude/handoffs.md` (this machine, one marker-delimited section
  per repo). Only the calling repo's section is rewritten. Answered by the user as
  "Both"; the machine-wide half matters because the live Herdr session had agents in
  four different repositories.
- **Neither index is committed.** A tracked central file would reintroduce the
  fixed-shared-path failure that branch-slugged naming exists to avoid.
- **Rows keyed by branch**, worktree as a convenience column — the branch travels
  with a clone, `.worktrees/<name>` does not.
- **Fan-out acts on `idle`/`done` only**; `working`, `blocked` and `unknown` are
  skipped and reported, never waited on. `/pickup all` **reuses live panes only** —
  it never splits a pane or starts an agent.
- **A handoff is never committed to `main`** — the fan-out would otherwise push a
  child onto the default branch.

## Shipped

| PR | What |
|---|---|
| #306 | `scripts/lib/handoff-index.sh` + both indexes, Herdr `all` mode in `/handoff` and `/pickup`, ADR-011, 34 fixture assertions |
| #316 | deleted three stale handoffs the index surfaced, each verified done first |
| #317 | `hooks/handoff-resume.sh` resolves the branch slug; 16 fixture assertions — the hook had none before |

All three squash-merged to `main` (`a5c5311`, `bb33f11`, `a532b28`) and installed
into `~/.claude/` via `setup/bootstrap.sh` (`/update-commands`).

`#317` was the sharpest find: since `/handoff` moved to branch-keyed names, the
`SessionStart(clear)` hook had been reading only the pre-slug `.claude/handoff.md`,
so `/clear` was silently injecting **nothing** — the hook's entire purpose, quietly
not happening, and invisible because it had no tests.

## Verified

- Full Layer-1 suite green: 593 + 20 + 46 + 34 + 16.
- `shellcheck -x` clean across `scripts/`, `tests/`, `hooks/`; markdownlint clean.
- Index: real runs across three repos — cross-repo section preservation, no file
  created in a handoff-free repo, lock timeout (exit 4) and stale-lock reclaim.
- Hook: live run against another repo's real branch-keyed handoff (no legacy file
  present) injected the correct phase; the old hook would have found nothing.

## Not verified — what remains

1. **`/handoff all` end-to-end.** The fan-out is prompt-level policy in the two
   command docs. Never exercised, deliberately: each child commits and pushes, so a
   dry run means real pushes in two private repos. The enumeration/partition half
   was dry-run correct against a live five-pane board.
2. **`/clear` → auto-injection.** The reason this handoff exists. After `/clear`,
   the fixed hook should surface `.claude/handoff-worktree-handoff-overv.md`
   without `/pickup` being typed. That is the exact path #317 repaired.
3. **`/wt:finish`** for this worktree. Its branch is merged; step 5 of `/handoff`
   pushes the handoff, which recreates the deleted remote branch — `/wt:finish`
   should delete both it and the local branch.

## Parked (in `TODO.md`, not acted on)

- **No CI job runs the Layer-1 suite at all.** `just test` drives five
  `tests/run-*-tests.sh` entry points locally, but the only workflows are `lint`
  (pre-commit) and `gate-selftest` — a broken fixture test still goes green on a PR.
  Also `run-link-skills-tests.sh` and `run-parse-enrich-args-tests.sh` are in
  neither `just test` nor CI.
- Issues **#198 / #199 remain open** — they cover the skills-layer refactor. An
  earlier note in #306 wrongly said they had shipped; corrected in #316.
