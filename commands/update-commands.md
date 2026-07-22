---
description: Update my user-level slash commands, hooks, and skills from agent-workflow (pull + reinstall)
---

Update my personal user-level Claude Code slash commands and hooks. **All 45 commands
now live in one repo**, [freaxnx01/agent-workflow](https://github.com/freaxnx01/agent-workflow)
(`~/repos/github/freaxnx01/public/agent-workflow`) — the issue-workflow console plus
the generic session-hygiene, handoff/pickup and `wt:*` commands, and the
`handoff-resume` hook.

`agent-workflow` now owns the CLAUDE.md partials, the commands, the hooks, the skills, and the
one-URL machine bootstrap; `config` no longer takes part in any of this.

Steps:

1. Run the idempotent bootstrap. It pulls agent-workflow once, then runs all four
   link steps — partials, commands (as copies), hooks, and skills — so one step refreshes
   everything:

   ```bash
   bash ~/repos/github/freaxnx01/public/agent-workflow/setup/bootstrap.sh
   ```

2. Report concisely which commands were added, changed, or removed since before the
   pull. Use the installer output plus:

   ```bash
   git -C ~/repos/github/freaxnx01/public/agent-workflow log --oneline @{1}.. 2>/dev/null
   ```

   If nothing changed, just say "Already up to date."

Notes:

- This is read-only (pull + relink) — no auth needed.
- Do **not** confuse this with `/sync-ai-instructions`, which refreshes a *project's*
  `.ai/` + `.claude/commands/` + `CLAUDE.md` from the `freaxnx01/ai-instructions`
  repo. This command is only about the user-level commands shared across all projects.
