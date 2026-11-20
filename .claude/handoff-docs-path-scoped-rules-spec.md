## Resume: role-agents brainstorm (#560), plus the path-scoped rules rollout

Read `docs/ai-notes/2026-11-20-path-scoped-rules-and-role-agents-handoff.md` (repo agent-workflow).

**Phase:**

- Brainstorming agent-workflow#560 (role agents in `.claude/agents/`) with `superpowers:brainstorming`.
- The opener has been sent and I'm waiting on the user's answer. Nothing is decided and no spec exists.

**Next step:**

- Re-ask the open question from the notes, or start drafting if the user says "just start".
- When the brainstorm is done: write the spec to `docs/superpowers/specs/`, then writing-plans.
- For any implementation, use `superpowers:subagent-driven-development`, except where the issue-dispatch exception applies.

**Side thread:** path-scoped rules rollout.

- Waiting on the human to merge ai-instructions PR #57.
- Then run agent-skills#11 locally.
- Then dispatch ai-instructions#56 (gated on sync 0.5.0).
- Then re-sync agwf (plan 4, Task 3).
