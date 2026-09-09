---
description: Save current phase to an MD file + a resume prompt, ready to /clear
---

Prepare a clean context handoff so I can `/clear` and resume cold. Do all of this,
then stop:

1. **Persist the artifact.** Identify the current phase's artifact — the spec or
   the implementation plan. If a spec/plan markdown file already exists for this
   work, use it; otherwise write the current spec or implementation plan to a
   markdown file at a sensible path (e.g. `docs/` or the repo's plans dir).
   Make it complete enough to resume from cold (decisions made, what's done, what's
   next). Report the path.

2. **Write the resume prompt.** Create `.claude/handoff-<slug>.md` (make `.claude/`
   if needed) containing a short, self-sufficient prompt that:
   - names the **exact path** to the artifact from step 1,
   - states the current phase and the next step,
   - instructs to resume using `superpowers:subagent-driven-development` for any
     implementation.

   `<slug>` is the **current branch** with `/` replaced by `-`:

   ```bash
   slug="$(git rev-parse --abbrev-ref HEAD | tr '/' '-')"
   [ "$slug" = "HEAD" ] && slug="detached-$(git rev-parse --short HEAD)"   # detached HEAD
   echo ".claude/handoff-$slug.md"
   ```

   **Never write a bare `.claude/handoff.md`.** A repo with several git worktrees
   checked out has one working copy per branch but a single shared file path — a
   fixed name means worktree B inherits worktree A's handoff the moment it rebases,
   and `/pickup` there resumes the wrong task. Branch-based naming keeps them
   distinct while still letting every handoff be committed and pushed, so it can be
   picked up from another machine or clone.

   Key by **branch**, not by worktree directory name: the branch travels with a
   clone, the `.worktrees/<name>` layout does not.

   Give the file a `## Resume: <one-line phase title>` heading and a
   `**Next step:** …` paragraph. Both are prose you want anyway, and the index in
   step 3 lifts its columns straight out of them.

3. **Regenerate the handoff index.** One command, no arguments needed:

   ```bash
   bash "$HOME/.claude/scripts/lib/handoff-index.sh"
   ```

   It writes two overviews of every handoff it can find:

   | File | Scope |
   |---|---|
   | `.claude/handoffs.md` | this repo — one row per branch, across all its worktrees |
   | `~/.claude/handoffs.md` | this machine — one section per repo, so a whole board of parallel sessions is one file |

   Each row carries the branch, the worktree holding it, the phase, the next step,
   when it was saved, the handoff file, and the resume line.

   The index is **derived, never authored**: every run regenerates it from the
   per-branch files on disk, and only the calling repo's section of the machine-wide
   file is rewritten. That is what makes the Herdr fan-out below safe — N sessions
   handing off at once cannot lose each other's rows. Never hand-edit either file;
   fix the per-branch handoff and re-run.

   The repo-local index is a local artifact — **do not commit it**. If the repo's
   `.gitignore` doesn't cover `.claude/handoffs.md` yet, add that line and include
   it in the commit in step 5.

4. **Clipboard fallback.** Copy the resume prompt from step 2 to the system
   clipboard, using whichever tool exists: `clip.exe` (WSL2/Windows), `pbcopy`
   (macOS), `wl-copy` or `xclip` (Linux).

5. **Commit and push.** Stage the artifact from step 1 and
   `.claude/handoff-<slug>.md`, commit with a conventional message (e.g.
   `docs(handoff): save phase for resume`), and push to the current branch's
   remote. Do this without asking — handoff files are always meant to be durable,
   not left as local-only, uncommitted state. If there is no remote or push fails,
   say so and continue; don't block the handoff on it.

   **Never commit a handoff onto `main`, and never push to `main`.** If the current
   branch is `main` (or the repo's default branch), leave the handoff file
   uncommitted, say so in the report, and stop there — a handoff is not worth
   bypassing branch protection for, and the file stays readable on disk either way.
   The index still lists it, marked `uncommitted`.

   From a worktree whose branch is published onto another branch (e.g.
   `git push origin worktree-finnova:main`), the handoff file lands on that target
   branch. That is fine and intended — the `<slug>` keeps it from colliding with
   any other worktree's handoff sitting beside it. Note that such a push updates
   the *remote* branch only; a local checkout of it stays behind until fetched.

   If a git network command hangs rather than failing, retry it with the
   credential helper cleared — `GIT_TERMINAL_PROMPT=0 git -c credential.helper=
   fetch -p origin` — an inherited helper can block on a prompt no tool-call
   subshell can answer.

6. **Tell me what to do next.** End by printing the artifact path and this exact
   instruction: run `/clear`, then `/pickup` (or paste the clipboard) to resume.
   Note that you cannot run `/clear` yourself — that keystroke is mine.

Keep the resume prompt to a few lines but self-contained.

## Herdr mode — hand off every open session

Trigger this instead of the single-session flow when the invocation says `all`,
`herdr`, or "all sessions" **and** this session is inside Herdr (`HERDR_ENV=1`).
If `HERDR_ENV` is unset, say so and run the single-session flow above.

Invoke the `herdr` skill first. The installed CLI is the authority on syntax — what
follows is the *policy*, not a flag reference.

1. **Enumerate** with `herdr agent list`. Each entry carries `name`, `pane_id`,
   `cwd` and `agent_status`.

2. **Partition by state** and act only on the first group:

   | State | Action |
   |---|---|
   | `idle`, `done` | hand off now |
   | `working` | **skip** — mid-turn; a handoff would freeze a half-finished phase |
   | `blocked` | **skip** — parked on an approval or question dialog only I can answer; report it, never answer it |
   | `unknown` | **skip** — Herdr can't classify it, which is not evidence of anything |

   Don't wait for a `working` session to settle. Report it and let me re-run
   `/handoff all` once it's idle.

3. **Exclude yourself.** Your own pane is `$HERDR_PANE_ID`; you are the
   orchestrator. Handing yourself off mid-fan-out ends the fan-out.

4. **Prompt each target in sequence**, not in parallel — the index writes then
   serialize and the report stays readable:

   ```bash
   herdr agent prompt <name> "/handoff" --wait --timeout 600000
   ```

   - `agent_blocked` — a dialog appeared before the prompt landed. Report, move on.
   - `agent_prompt_stalled` — no lifecycle change within 5s, so nothing started.
     Report it as "did not start"; don't retry blindly.
   - Ten minutes is generous for writing a file, committing and pushing. A target
     that outlasts it is stuck, not slow — report rather than extend the wait.

   After each wait returns, `herdr agent read <name> --source recent-unwrapped
   --lines 40` to confirm it actually wrote a handoff file and to capture the path.
   A returned wait proves the agent settled, not that it succeeded.

5. **Regenerate the machine-wide index** once, for every repo you touched. Each
   child already regenerated its own repo, but re-running is idempotent and closes
   the race between two children finishing at the same moment:

   ```bash
   bash "$HOME/.claude/scripts/lib/handoff-index.sh" --repo <repo-or-worktree-path>
   ```

6. **Print the board** — one line per session: repo, branch, and either where the
   handoff landed or why it was skipped. Then name `~/.claude/handoffs.md` as the
   single file that now describes all of it.

7. **Yourself last.** Run the single-session flow above for this session, then tell
   me to `/clear`.

> **Related:** `/handoff` saves *one* in-flight phase for a `/clear`-and-resume, or
> with `all` under Herdr, every open session at once. To capture *all* of a single
> session's loose ends instead, use `/wrap-up` → `/todo`.
