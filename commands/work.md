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

Work a **work item** end to end.

```bash
source "$HOME/.claude/scripts/lib/detect-forge.sh"
source "$HOME/.claude/scripts/lib/azdo.sh"
resolve_azdo_context || { echo "not an Azure DevOps remote"; exit 1; }
```

The read half works: fetch the item, plan against it, implement locally.

```bash
az boards work-item show --id <id> --org "$(azdo_org_url)" \
  --output json --only-show-errors
```

**Two things this command does on GitHub that it cannot do here — say so plainly
rather than half-doing them:**

- **No pipeline dispatch.** agent-workflow's pipeline is GitHub-only (ADR-012),
  so there is no `ai-implement` label to apply and no draft PR to wait on. This
  command's ADO path is local execution only.
- **No issue-body enrichment.** `/enrich` is not ported for writes (see its own
  section), so the plan is not written back to the work item. Keep the plan in
  the repo under `docs/superpowers/plans/` and reference it.

What does work end to end: read the item, write the spec and plan, implement,
open a PR with `az repos pr create --work-items <id>` so the item is linked, and
report from a read-back rather than from the exit code.

## Unknown host

Report the detected host and that it matched no authed GitHub or Forgejo login
and none of the Azure DevOps host forms; point at `gh auth login` /
`tea login add` / `az devops login`. Don't guess a forge.
