---
description: Update my user-level slash commands and hooks from agent-workflow (pull + reinstall)
---

Update my personal user-level Claude Code slash commands and hooks. **All 46 commands
now live in one repo**, [freaxnx01/agent-workflow](https://github.com/freaxnx01/agent-workflow)
(`~/repos/github/freaxnx01/public/agent-workflow`) — the issue-workflow console plus
the generic session-hygiene, handoff/pickup and `wt:*` commands, and the
`handoff-resume` hook.

`config` keeps the CLAUDE.md partials and remains the one-URL machine bootstrap; its
installer delegates both commands and hooks to agent-workflow.

Steps:

1. Run the idempotent config installer. It pulls `config` for the partials, then
   clones/pulls agent-workflow and reinstalls every command (as copies) and the
   hooks via its link steps — so one command refreshes everything:

   ```bash
   bash ~/repos/github/freaxnx01/public/config/setup/01-claude-commands.sh
   ```

2. Report concisely which commands were added, changed, or removed since before the
   pull. Use the installer output plus, for whichever repos fast-forwarded:

   ```bash
   git -C ~/repos/github/freaxnx01/public/config         log --oneline @{1}.. 2>/dev/null
   git -C ~/repos/github/freaxnx01/public/agent-workflow log --oneline @{1}.. 2>/dev/null
   ```

   If nothing changed in either, just say "Already up to date."

Notes:

- This is read-only (pull + relink) — no auth needed.
- Do **not** confuse this with `/sync-ai-instructions`, which refreshes a *project's*
  `.ai/` + `.claude/commands/` + `CLAUDE.md` from the `freaxnx01/ai-instructions`
  repo. This command is only about the user-level commands shared across all projects.
