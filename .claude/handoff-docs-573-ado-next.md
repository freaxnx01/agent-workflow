## Resume: Azure DevOps track after the #577 hardening merge

Read `docs/superpowers/notes/2026-11-06-azdo-next-steps.md` (state, gap table, open
decisions) and the memory note `ado-poc-agent-host` (private host/repo details).
Nothing is in flight; #577 is merged and the sandbox pipeline runs `d563723`.

**Next step:** ask the maintainer, in interview mode, the three open decisions in that
note — (1) Claude token source for a teammate without Passbolt, (2) which gap items to
work on unattended over the weekend and a durable go-ahead for sandbox-only outward
actions, (3) OK to copy the real .NET work repo into the personal sandbox for the pilot.
Then brainstorm → spec → plan per chosen item, and implement with
`superpowers:subagent-driven-development`. Public repo: never write work org/repo/host names.
