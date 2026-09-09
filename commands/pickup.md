---
description: Resume work saved by /handoff (reads .claude/handoff-<branch>.md)
---

Resume the work saved by `/handoff` for the **current branch**.

## Locate the handoff file

Handoffs are keyed by branch so that sibling git worktrees, which share one file
path but not one task, don't resume each other's work:

```bash
slug="$(git rev-parse --abbrev-ref HEAD | tr '/' '-')"
[ "$slug" = "HEAD" ] && slug="detached-$(git rev-parse --short HEAD)"
ls -1 ".claude/handoff-$slug.md" 2>/dev/null || ls -1 .claude/handoff*.md 2>/dev/null
```

Resolution order:

1. `.claude/handoff-<slug>.md` — the current branch's handoff. Use it.
2. `.claude/handoff.md` — legacy unslugged name from before branch-keyed handoffs.
   Use it, and mention it should be renamed to the slugged form on the next
   `/handoff`.
3. Neither exists, but other `.claude/handoff-*.md` files do — those belong to
   **other branches**. Do not silently resume one. List them with their branch
   names and ask which (if any) to use.
4. Nothing at all — say there's nothing to resume and stop.

For step 3 and 4, `.claude/handoffs.md` (or `~/.claude/handoffs.md` for every repo
on this machine) is the fastest way to see what else is parked and where it lives.
Regenerate it first if it looks out of date:

```bash
bash "$HOME/.claude/scripts/lib/handoff-index.sh"
```

## Resume

Read the file and resume exactly as it directs: open the spec/plan file it
references, re-establish where things stand, and continue from the stated next
step — using `superpowers:subagent-driven-development` for any implementation.

**Check staleness first.** Report when the handoff was last committed
(`git log -1 --format=%ad --date=short -- <file>`) and, if the branch has moved on
since, say so before acting — a handoff that predates later commits may describe
work already done. A stale handoff nobody cleaned up is a known failure mode;
treat an old date as a reason to verify, not to trust.

## After resuming

Once the handed-off phase is genuinely complete, delete the handoff file, commit
that deletion, and regenerate the index so the row disappears with it:

```bash
bash "$HOME/.claude/scripts/lib/handoff-index.sh"
```

Leaving the file behind is what turns it stale for the next reader — including
future you on another machine. Leaving the index behind is worse: it advertises
work that is already done.

## Herdr mode — pick up every handed-off session

Trigger this instead of the single-branch flow when the invocation says `all`,
`herdr`, or "all sessions" **and** this session is inside Herdr (`HERDR_ENV=1`).
If `HERDR_ENV` is unset, say so and run the single-branch flow above.

Invoke the `herdr` skill first. The installed CLI is the authority on syntax — what
follows is the *policy*, not a flag reference.

1. **Read the board.** Regenerate and read `~/.claude/handoffs.md` for every repo
   involved, so you know which branches have a saved handoff and which worktree
   each one lives in.

2. **Enumerate live sessions** with `herdr agent list` and match each agent's `cwd`
   to a handoff row's worktree path. Three cases:

   | Case | Action |
   |---|---|
   | live agent in a worktree that has a handoff | prompt it to `/pickup` |
   | live agent with no handoff for its branch | leave it alone; mention it once |
   | handoff with no live agent | **don't spawn anything** — list it with its resume line |

   Reusing live panes only is deliberate: a pane you didn't open is mine to
   arrange. Print the orphans' resume lines (`cd <worktree>` → `claude` →
   `/pickup`) so starting one is a copy-paste, and offer to spawn them if I ask.

3. **Skip what can't take a prompt** — same partition as `/handoff all`: act on
   `idle` and `done`; skip `working`, `blocked` and `unknown`, and report why.
   Never answer another session's blocked dialog.

4. **Prompt each target in sequence:**

   ```bash
   herdr agent prompt <name> "/pickup" --wait --timeout 600000
   ```

   `agent_blocked` and `agent_prompt_stalled` are reports, not retries. After the
   wait returns, `herdr agent read <name> --source recent-unwrapped --lines 40` to
   see what it actually picked up — a settled wait is not a success signal.

5. **Exclude yourself** (`$HERDR_PANE_ID`). Pick your own branch's handoff up last,
   via the single-branch flow above, once the fan-out is reported.

6. **Print the board**: per session — repo, branch, resumed or skipped and why —
   plus the orphaned handoffs with their resume lines.

> **Related:** `/pickup` continues a single handed-off task, or with `all` under
> Herdr, every session that has one. To see the whole-session checklist from
> `/wrap-up`, use `/todo` instead.
