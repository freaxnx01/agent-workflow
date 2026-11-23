# Cutover runbook: GitHub → Azure DevOps as the only forge (#643)

## Intent

An operator moving a consumer from the GitHub pipeline (agent-workflow v2) to
Azure DevOps as its **only** forge needs one ordered, checkable runbook. The
GitHub repository stays as a read-only archive. The steps are scattered today:
- the setup doc;
- the boundary and feed sections;
- the migration script (#642);
- lessons from the first backup, done by hand.

A step done out of order loses work. A `git push --mirror` running next to the
ADO pipeline deletes every agent branch.

## Goals

- `docs/AZDO-CUTOVER.md` lists the steps in order. Each step has a checklist
  and a "Check:" command or observation that proves it is done.
- `docs/AZDO-PIPELINE-SETUP.md` links to it.
- The doc carries no organization, host or repository names. Use `<org>`,
  `<project>`, `<repo>`, `contoso`.

## Non-goals

- A backup script: the backup is a few commands in the runbook (decided
  2026-11-23).
- Automating the cutover.
- Anything specific to one consumer's CI. The runbook names the categories to
  carry over (build, tests with filters, extra tools) without copying any
  consumer's YAML.

## Approaches

1. **One runbook, with each step pointing into the existing setup sections
   (chosen).** It stays short and does not duplicate the setup doc.
2. **Inline every setup detail.** Rejected: it would duplicate sections 1–14 of
   `AZDO-PIPELINE-SETUP.md`, and the two would drift apart.

## Design: ten steps (headings `## 1.` … `## 10.`, in this order)

The issue listed "archive" before "migrate". But the migration writes a link
comment on each GitHub issue, and an archived repository rejects comments, so
the archive moves to the end (author's call). Each step has a checklist and a
`Check:` line.

1. **Preconditions.**
   - #626 (agent user boundary) and #641 (private-feed pre-restore) are merged.
   - The image is rebuilt from that commit with `--target dotnet`, and
     `awf-agent-run --protocol` prints `2`.
   - #642's migration script is on the pinned `AGENT_WORKFLOW_REF`.
   - Enriching migrated items waits for #683 (Markdown work items). It does
     not block the cutover.
2. **Back up the GitHub repository.** The commands are given verbatim, with
   `<owner>/<repo>` placeholders:
   - `git clone --mirror`;
   - add `+refs/pull/*:refs/pull/*` and fetch;
   - `git bundle create … --all`;
   - `gh api --paginate` exports of issues, issue comments, pulls, PR review
     comments, PR reviews, labels and milestones into JSON;
   - the names of the Actions secrets (values cannot be read).

   GitHub's own migration archive API needs the `admin:org` scope, so the
   runbook does not rely on it. Check: `git bundle verify` passes, and the
   issue count in the JSON matches `gh issue list --state all`.
3. **Freeze on GitHub.**
   - Open PRs are merged, closed, or noted for re-creation.
   - No `ai-implement` run is in progress.
   - The `ai-implement` label is removed from open issues.
   - Check: `gh run list` shows nothing in progress.
4. **Last sync, then stop the mirror.**
   - If a GitHub → ADO mirror workflow exists, run it once more, then disable
     it.
   - **Never run a mirror alongside the ADO pipeline:** `git push --mirror`
     deletes every ADO branch and merge the agent created.
   - Check: the ADO default-branch head equals the GitHub head.
5. **Disable the GitHub workflows.** Disable `agent.yml` and any
   project-automation workflows with `gh workflow disable`. Do **not** archive
   yet. Check: `gh workflow list` shows them disabled.
6. **Set up Azure DevOps** in the target organization, by
   `AZDO-PIPELINE-SETUP.md` sections:
   - the pool and agent (sections 1–4);
   - repository permissions (5);
   - the branch policy (6);
   - variables (7), with a per-person `claude setup-token`;
   - the service hook (8);
   - PR build validation equivalent to the GitHub CI (9);
   - `AWF_TOOLCHAIN` routing (10);
   - retry and caps (11);
   - AI review (12);
   - the boundary (13), with `persistCredentials: false`;
   - private feeds (14): `AWF_NUGET_FEEDS`, Feed Reader for the build service,
     and `packageSourceMapping` when the repo's `nuget.config` lists the feed.

   Add a table with one row per GitHub secret name, mapping it to its ADO
   variable or "not needed".
7. **Migrate the open issues** with `scripts/migrate-gh-issues-to-azdo.sh`:
   1. `--dry-run`.
   2. The real run with `--area`.

   Keep the printed work item ids for rollback. No `--close` yet.
8. **Verify** with one small work item end to end:
   - the tag triggers the run;
   - the log shows `turns :` sized from the plan file (#651) or a stated
     fallback;
   - the private-feed restore succeeds when feeds are set;
   - a draft PR opens;
   - PR validation passes;
   - the AI review posts.
9. **Close the GitHub issues and archive.**
   1. Close every open issue whose comments carry the `awf-migrated-to:`
      marker. Use a `gh api --paginate` + `gh issue close` loop, given
      verbatim. The migration script's `--close` only acts on issues it
      creates in that run, and skips already-migrated ones (#642).
   2. Then archive the repository.

   Check: `gh repo view --json isArchived`.
10. **Rollback:**
    - un-archive the GitHub repository and re-enable its workflows;
    - turn off the ADO service hook;
    - leave the migrated work items, which are harmless, or delete them by the
      ids from step 7.
    - The mirror stays off unless ADO is abandoned entirely.

## Tests (Layer 1)

`tests/run-azdo-cutover-doc-tests.sh` checks:
- The ten numbered headings exist, in order.
- `AZDO-PIPELINE-SETUP.md` links `AZDO-CUTOVER.md`.
- The mirror warning is present (`push --mirror` and "Never").
- Every `dev.azure.com/` URL uses `<org>` or `contoso`.
- Every `github.com/` repo reference uses `<owner>`.
- Each step section contains a `Check:` line.

## Acceptance criteria

- [ ] `docs/AZDO-CUTOVER.md` exists with the ten steps in the order above, each with a checklist and a `Check:` line.
- [ ] The backup step gives the mirror, bundle and JSON-export commands and
      names the `admin:org` limit of GitHub's migration API.
- [ ] The mirror warning is explicit.
- [ ] The ADO setup step references setup sections 1–14, including the
      boundary and private-feed specifics.
- [ ] The migration step uses `--dry-run`, then `--area`, and `--close` only
      after verification. The archive comes after the migration write-back.
- [ ] Rollback is described.
- [ ] `AZDO-PIPELINE-SETUP.md` links the runbook.
- [ ] No organization, host or repo names. `tests/run-azdo-cutover-doc-tests.sh`
      passes.
