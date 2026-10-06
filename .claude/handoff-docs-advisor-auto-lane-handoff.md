## Resume: auto lane — sandbox end-to-end run for #373, ready to start

Run `/factory-advisor auto lane`, then read `docs/ai-notes/2026-10-06-auto-lane-sandbox-e2e.md` (on branch `docs/advisor-auto-lane-handoff`): it holds the milestone state, the finished sandbox setup, and the exact run command.

**Next step:** confirm `gh auth status` no longer reports an invalid `GH_TOKEN` (the PAT was rotated in Passbolt), confirm `~/.config/agent-workflow/autopilot.env` holds `CLAUDE_CODE_OAUTH_TOKEN`, re-run `scripts/autopilot.sh --dry-run --max 1` (expect `would: enrich … sandbox#16`), then have the operator start the paid run and verify every stage from evidence. For any implementation work that comes out of it, use `superpowers:subagent-driven-development`.
