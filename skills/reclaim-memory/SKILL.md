---
name: reclaim-memory
description: Free RAM on a memory-capped agent box by finding stale Claude Code sessions, running /loose-ends and /handoff in them via herdr, and closing the ones that are safe to close. Use when the user asks to check memory/RAM on this machine, says the box is slow or near its cap, asks which sessions are old or idle, or wants to clean up / close old Claude tabs or panes.
---

# Reclaim memory on the agent box

Meant for a shared box that runs many Claude Code sessions under a hard memory cap
(container limit, no swap). On such a box hitting the cap can stall the whole host
instead of OOM-killing. The machine's own cap and failure mode belong in the user's
`~/.claude/CLAUDE.md`; read it first. Open `claude` sessions
(about 220 to 480 MB each) are almost always the cause. The goal is to free memory
**without losing work**: every session with loose ends gets a handoff before it closes.

## 1. Measure

```bash
free -h
ps -C claude -o rss= | awk '{s+=$1;n++} END{printf "%.1f GB in %d procs\n",s/1048576,n}'
```

Under ~2 GB available is the danger zone. Mention it and advise against heavy jobs.

## 2. Inventory sessions

For each `claude` PID, list tty, RSS, start date (`ps -o lstart=`, **not** `etime`,
which shows garbage like `441077233-18:35` after container restores) and cwd
(`readlink /proc/$PID/cwd`). Mark this session's own tty (`ps -o tty= -p $PPID`)
so it never gets closed.

Sort into groups for the user:

- **Dead**: the cwd ends in `(deleted)`, meaning the worktree is gone.

- **Duplicates**: several sessions in the same directory. Keep the newest.

- **Old**: started more than ~2 weeks ago.

- **Recent**: leave these to the user.

## 3. Map to herdr panes

Do this only inside herdr (`test "$HERDR_ENV" = 1`). Load the `herdr` skill for CLI details.

- `herdr agent list` gives the pane id, `agent_status` and cwd. **Match sessions to
  panes by cwd.** `HERDR_PANE_ID` in `/proc/$PID/environ` goes stale once a pane
  moves to another workspace.

- Sessions that aren't in the list run outside herdr. Report them for the user to
  handle by hand; you can't drive them.

- **Skip** panes that are `working` (busy) or `blocked` (waiting on the user's answer).

## 4. /loose-ends, then /handoff

Before sending anything, read each target pane
(`herdr agent read <pane> --source recent-unwrapped --lines 80`; the output is
**plain text, not JSON**). If the input line holds an unsent draft, **skip the pane**:
a prompt would be glued onto the user's text. Report it instead.

Text after `❯` isn't always a draft. Claude Code shows a **dimmed prompt suggestion**
there. Check with `--format ansi`: `ESC[2m` before the text means it's a suggestion,
which a prompt simply replaces. Sending Enter does **not** submit a suggestion. To act
on one, send its text with `herdr agent prompt`.

Send `/loose-ends` to the eligible idle or done panes in parallel
(`herdr agent prompt <pane> "/loose-ends" --wait --timeout 400000`), then read the replies:

`--wait` can return before the slash command is even submitted (seen 2026-11-10 on 5 of 13
panes: the read showed `/loose-ends` still in the input line with the slash menu open, and
the reply arrived a minute later). Don't press Enter to "fix" it. Re-read the pane after
a minute, and before deciding, also re-check `agent_status`: a pane that turns `working`
meanwhile may have a new prompt from the user and must be skipped.

- "Nothing outstanding" means the pane can be closed as it is.

- Anything open: send `/handoff` and confirm from the transcript that the handoff
  was saved (and pushed, if the repo does that). On a **detached HEAD** it can't
  commit, so the files exist only in that worktree. Warn the user not to delete it.

`/handoff` sometimes asks a question. If the transcript shows an answer you didn't
send, or `/clear` sitting in the input line, tell the user. Someone else may be
working in that pane.

## 5. Close, only with approval

Present the result as a numbered checklist: handed off, clean, skipped (and why),
outside herdr. **Close only what the user confirms.** Use `herdr pane close <pane>`,
then run `free -h` again and report memory before and after. Handed-off sessions
resume with `/pickup` in the same worktree.

Never close the current session's pane, panes in `working` or `blocked` state, or
anything outside herdr.

If you run into blockers, find a solution and update this skill for the future.
