---
description: Work on an issue end-to-end — plan then subagent-driven implementation
argument-hint: <issue number>
---

Detect the forge, then run the matching section below.

```bash
source "$HOME/.claude/scripts/lib/detect-forge.sh"
detect_forge
```

## GitHub

Implement GitHub issue #$ARGUMENTS end to end (strip any leading `#` from the
number):

1. `gh issue view $ARGUMENTS --comments` — read the issue and its discussion.
2. If scope or requirements are unclear or open-ended, use the
   **superpowers:brainstorming** skill to settle them before any code.
3. Use **superpowers:writing-plans** to produce an implementation plan (markdown).
   TDD is a non-negotiable global constraint — include it verbatim in the plan's
   Global Constraints section: "Use Test-Driven Development for every task: write
   a failing test first, watch it fail, implement minimally to pass, verify green."
4. Create an isolated workspace with **superpowers:using-git-worktrees**, on a
   branch named for the issue (e.g. `issue-$ARGUMENTS-<slug>`).
5. Execute the plan with **superpowers:subagent-driven-development**.
6. When implementation is complete **and verified**, stop and tell me it's ready
   for `/wt:finish` — do not merge yet.

Reference issue #$ARGUMENTS in commits. If the issue doesn't exist, say so and stop.

## Forgejo

Implement Forgejo issue #$ARGUMENTS end to end (strip any leading `#` from the
number).

### Forgejo access

Target the homelab Forgejo (`git.home.freaxnx01.ch`) via **`tea`** (login
`git-home`). Read the issue and its discussion:

```bash
url=$(git remote get-url origin); url=${url%.git}
repo=$(echo "$url" | sed -E 's#.*[:/]([^/]+/[^/]+)$#\1#')
tea issues $ARGUMENTS --login git-home                              # issue detail
tea api --login git-home "repos/$repo/issues/$ARGUMENTS/comments"   # discussion
```

If the issue doesn't exist, say so and stop.

### Steps

1. Read the issue and its comments (above).
2. If scope or requirements are unclear or open-ended, use the
   **superpowers:brainstorming** skill to settle them before any code.
3. Use **superpowers:writing-plans** to produce an implementation plan (markdown).
   TDD is a non-negotiable global constraint — include it verbatim in the plan's
   Global Constraints section: "Use Test-Driven Development for every task: write a
   failing test first, watch it fail, implement minimally to pass, verify green."
4. Create an isolated workspace with **superpowers:using-git-worktrees**, on a
   branch named for the issue (e.g. `issue-$ARGUMENTS-<slug>`).
5. Execute the plan with **superpowers:subagent-driven-development**.
6. When implementation is complete **and verified**, stop and tell me it's ready for
   `/wt:finish` — do not merge yet.

Reference issue #$ARGUMENTS in commits (Forgejo links `Closes #$ARGUMENTS` in the
PR/commit, same as GitHub). Note: the `issue-N-*` branch name lets `/issues`
detect this issue as WIP even before a PR exists.

## Azure DevOps

`detect_forge` said `azdo`, so the remote is an Azure DevOps one — and **this
command has no Azure DevOps section yet**. Say exactly that and **stop**.

Do **not** fall back to the GitHub or Forgejo section. Neither `gh` nor `tea` can
read ADO work items, so running either against this remote fails confusingly at
best; on a command that *writes*, it would aim the write at the wrong forge
entirely. `/issues` is the only command with ADO support today — see **ADR-011**
in agent-workflow's `docs/DECISIONS.md` for the object mapping, and its `TODO.md`
for the port status.

## Unknown host

Report the detected host and that it matched no authed GitHub or Forgejo login
and none of the Azure DevOps host forms; point at `gh auth login` /
`tea login add` / `az devops login`. Don't guess a forge.
