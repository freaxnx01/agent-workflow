# Cutover: GitHub to Azure DevOps as the only forge

How to move a consumer repository from the GitHub pipeline (agent-workflow v2)
to Azure DevOps as its **only** forge. The GitHub repository stays behind as a
read-only archive — nothing is deleted, and every step is reversible until
step 9.

Do the steps in the order given: a step done early loses work. Replace `<org>`,
`<project>`, `<repo>`, `<owner>`, `<pool>`, `<image>` and `<area>` throughout.
Section numbers in parentheses are sections of
[AZDO-PIPELINE-SETUP.md](AZDO-PIPELINE-SETUP.md), which this runbook points
into rather than repeating.

## 1. Preconditions

The Azure DevOps path needs the agent user boundary and the private-feed
pre-restore in the pinned `AGENT_WORKFLOW_REF`, and an image rebuilt from that
commit. Without the rebuild an `ai-implement` run refuses before the agent
starts (13).

- [ ] #626 (agent user boundary) and #641 (private-feed pre-restore) are merged
      at the commit `AGENT_WORKFLOW_REF` pins.
- [ ] The agent image is rebuilt from that commit with `--target dotnet` (1).
- [ ] `scripts/migrate-gh-issues-to-azdo.sh` (#642) exists at that ref.
- [ ] A `dotnet restore` of the target repo's default branch succeeds against
      every private feed the repo needs (14).

Enriching the migrated work items needs Markdown work-item bodies (#683). That
is not a precondition: migrated items are readable without it, and the cutover
does not wait.

Check: inside the rebuilt image, the boundary answers protocol `2`.

```bash
docker run --rm --entrypoint /usr/local/libexec/awf-agent/awf-agent-run \
  <image>-dotnet --protocol
```

## 2. Back up the GitHub repository

Everything GitHub holds that ADO will not: pull-request refs, issue and review
comments, labels, milestones. GitHub's own migration-archive API needs the
`admin:org` scope, which a repository owner does not have on a user account, so
this runbook does not use it — these commands need only a normal `repo` token.

- [ ] A mirror clone, with `refs/pull/*` fetched into it.
- [ ] A verified bundle of every ref.
- [ ] JSON exports of issues, issue comments, pulls, PR review comments, PR
      reviews, labels and milestones.
- [ ] The **names** of the Actions secrets and variables. Values cannot be
      read; they are re-created by hand in step 6.

```bash
# A mirror clone: every branch, tag and note.
git clone --mirror https://github.com/<owner>/<repo>.git <repo>.git
cd <repo>.git

# Pull-request refs are not part of a mirror. Add them, then fetch.
git config --add remote.origin.fetch '+refs/pull/*:refs/pull/*'
git fetch --prune origin

# One portable file holding every ref fetched above, including refs/pull/*.
BUNDLE="../<repo>-$(date +%Y%m%d).bundle"
git bundle create "$BUNDLE" --all
git bundle verify "$BUNDLE"

# The metadata GitHub keeps outside git. --slurp returns one array per page,
# so `jq add` joins them into a single document.
mkdir -p ../export
for path in \
  'issues?state=all&per_page=100' \
  'issues/comments?per_page=100' \
  'pulls?state=all&per_page=100' \
  'pulls/comments?per_page=100' \
  'labels?per_page=100' \
  'milestones?state=all&per_page=100'
do
  name="$(printf '%s' "${path%%\?*}" | tr '/' '-')"
  gh api --paginate --slurp "repos/<owner>/<repo>/$path" \
    | jq 'add' > "../export/$name.json"
done

# PR reviews are per pull request, so they need a loop.
gh pr list -R <owner>/<repo> --state all --limit 1000 --json number \
  -q '.[].number' \
  | while read -r pr; do
      gh api --paginate --slurp "repos/<owner>/<repo>/pulls/$pr/reviews" \
        | jq 'add' > "../export/pr-$pr-reviews.json"
    done

# Secret and variable names only — the values are write-only.
gh secret   list -R <owner>/<repo> > ../export/secret-names.txt
gh variable list -R <owner>/<repo> > ../export/variable-names.txt
```

Check: `git bundle verify` prints `The bundle is okay`, and the exported issue
count matches GitHub's own. The `issues` endpoint returns pull requests too, so
filter them out before comparing.

```bash
jq '[.[] | select(has("pull_request") | not)] | length' ../export/issues.json
gh issue list -R <owner>/<repo> --state all --limit 1000 | wc -l
```

## 3. Freeze on GitHub

No work may be in flight while the forge moves. A run that starts after the
last sync writes a branch and a PR that ADO will never see.

- [ ] Every open PR is merged, closed, or its branch recorded for re-creation
      on ADO.
- [ ] No `ai-implement` run is in progress or queued.
- [ ] The `ai-implement` label is removed from every open issue, so a replayed
      webhook cannot start one.

Check: both run queries and the PR list come back empty.

```bash
gh run list -R <owner>/<repo> --status in_progress
gh run list -R <owner>/<repo> --status queued
gh pr list  -R <owner>/<repo> --state open
```

## 4. Last sync, then stop the mirror

If the repository was mirrored from GitHub to ADO during the transition, this is
the last time that mirror may run.

- [ ] Run the mirror workflow once more, after the freeze of step 3.
- [ ] Disable it (`gh workflow disable <mirror>.yml`) and revoke the ADO
      credential it used.

> **Never run a mirror alongside the ADO pipeline.** `git push --mirror` deletes
> every ref the destination has and the source does not. Once the pipeline has
> run, that is every branch the agent pushed, every PR branch open on it and
> every merge completed in ADO — work that exists nowhere else. Disabling the
> workflow is not enough if it can still be dispatched by hand; revoke the
> credential as well.

Check: the ADO default-branch head equals the GitHub head.

```bash
git ls-remote https://github.com/<owner>/<repo>.git HEAD
git ls-remote https://dev.azure.com/<org>/<project>/_git/<repo> HEAD
```

## 5. Disable the GitHub workflows

GitHub stops acting on the repository here, but it stays writable: the
migration in step 7 writes a link comment on each issue, and an archived
repository rejects comments.

- [ ] `gh workflow disable agent.yml -R <owner>/<repo>`.
- [ ] Disable every project-automation caller too — issue intake, the
      backlog-milestone caller, any scheduled stats or report workflow.
- [ ] Do **not** archive the repository yet. That is step 9.

Check: the workflows report as disabled.

```bash
gh workflow list -R <owner>/<repo> --all
```

## 6. Set up Azure DevOps

Do the full setup in the target organization, in the order the setup doc gives.
Each item below is a section of `AZDO-PIPELINE-SETUP.md`.

- [ ] The image, the agent registration, the systemd unit and the pool setting
      (1–4). Auto-update stays **off**.
- [ ] Repository permissions for the build service (5) — and no *Queue builds*.
- [ ] The branch policy on the default branch: require a pull request, no
      bypass for the build service (6).
- [ ] Pipeline variables (7). `CLAUDE_CODE_OAUTH_TOKEN` is marked secret and
      comes from a per-person `claude setup-token` — never a shared one, and
      never a token copied out of the GitHub secret, which cannot be read.
- [ ] The incoming webhook connection and the *Work item updated* service hook,
      with the tag and area filters (8).
- [ ] PR build validation equivalent to the GitHub CI (9): the same build, the
      same test filters, the same extra tools, as a separate pipeline with no
      secret variables and no variable group. With private feeds, also 9.6:
      without it every PR of such a repo is red. On its own pool
      `<validation-pool>`, with its own agent, and with `<pool>`'s pipeline
      permissions listing only the `ai-implement` pipeline (9.7, *Run
      validation on its own pool*).
- [ ] `AWF_TOOLCHAIN` routing to the `dotnet` agent (10).
- [ ] Retry policy, attempt cap and job timeout (11).
- [ ] AI review, and self-fix if wanted (12).
- [ ] The agent user boundary (13): the `ai-implement` pipeline's checkout says
      `persistCredentials: false`, and the container does not set
      `no-new-privileges`.
- [ ] Private feeds (14) when the repo uses any: `AWF_NUGET_FEEDS` with each
      feed's v3 index URL, the **Feed Reader** role for
      `<project> Build Service (<org>)` on every feed, and a
      `packageSourceMapping` in the repo's `nuget.config` if that file lists the
      private feed.

The GitHub secrets map across as follows.

| GitHub Actions secret | Azure DevOps |
|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | pipeline variable, marked secret (7) |
| `OPENROUTER_API_KEY` | not needed — this path runs Claude only |
| `PIPELINE_APP_ID` | not needed — the job's `System.AccessToken` replaces the GitHub App |
| `PIPELINE_APP_PRIVATE_KEY` | not needed, same reason |
| `NTFY_TOKEN` | pipeline variable, marked secret, only if notifications are wanted |
| `NTFY_URL` | pipeline variable, only if notifications are wanted |

Check: a tag on a throwaway work item in the area the hook filters on starts a
pipeline run, and the run reaches the agent rather than refusing at preflight.

## 7. Migrate the open issues

`scripts/migrate-gh-issues-to-azdo.sh` creates one work item per open GitHub
issue and writes a link comment back on the issue. `--area` is required: the
service-hook filter of step 6 only sees items in that area.

- [ ] A dry run first: it writes nothing and reports per issue.
- [ ] The real run, after reading that output.
- [ ] Keep the printed work item ids. Step 10 needs them.
- [ ] Leave the GitHub issues open. Step 9 closes them, after step 8 has proved
      the ADO side works.

```bash
# Dry run: reports what it would create, writes nothing.
scripts/migrate-gh-issues-to-azdo.sh --repo <owner>/<repo> \
  --area '<project>\<area>' --dry-run

# The real run.
scripts/migrate-gh-issues-to-azdo.sh --repo <owner>/<repo> \
  --area '<project>\<area>'
```

Check: the number of work items created equals the dry run's planned count, and
every migrated issue carries a link comment with the `awf-migrated-to:` marker.
A re-run of the script prints `skip` for each of them.

## 8. Verify

Take one small migrated work item through the whole path before closing
anything on GitHub.

- [ ] Tagging the item triggers the run through the service hook (8).
- [ ] The log's `turns :` line is sized from the plan file (#651), or names the
      fallback it used.
- [ ] The private-feed restore succeeds when `AWF_NUGET_FEEDS` is set (14).
- [ ] The agent opens a **draft** PR.
- [ ] Publishing that PR queues the validation build, and it passes (9.3, 9.5).
- [ ] The AI review posts its verdict on the PR and on the work item (12).

Check: the work item has an `## ai-implement run` comment and an
`## ai-review verdict:` comment, and the PR's build validation is green.

## 9. Close the GitHub issues and archive

Only now. The migration's write-back is done, so GitHub can go read-only.

The script's own closing option acts only on the issues it created in that run
and skips ones already migrated (#642), so a cutover run spread over several
invocations would leave issues open. Close by the marker instead — it is the
record of what actually migrated.

- [ ] Run the close loop. It closes an issue only if a comment carries the
      marker `<!-- awf-migrated-to: https://dev.azure.com/<org>/<project>#<id> -->`
      (the project segment is percent-encoded).

```bash
gh api --paginate --slurp 'repos/<owner>/<repo>/issues?state=open&per_page=100' \
  | jq -r 'add | .[] | select(has("pull_request") | not) | .number' \
  | while read -r issue; do
      if gh api --paginate --slurp \
          "repos/<owner>/<repo>/issues/$issue/comments" \
          | jq -e 'add | any(.body | contains("awf-migrated-to:"))' >/dev/null
      then
        gh issue close "$issue" -R <owner>/<repo> \
          --comment 'Migrated to Azure DevOps. This repository is now a read-only archive.'
      else
        printf 'not migrated, left open: #%s\n' "$issue"
      fi
    done
```

- [ ] Deal with every issue the loop printed as `not migrated` — migrate it by
      hand, or decide to drop it.
- [ ] Point the README at Azure DevOps and push that change, while the
      repository is still writable.
- [ ] Archive it: `gh repo archive <owner>/<repo>`.

Check: the repository is archived and no issue is left open.

```bash
gh repo view <owner>/<repo> --json isArchived
gh issue list -R <owner>/<repo> --state open
```

## 10. Rollback

Nothing in steps 1–9 destroys data, so a rollback is re-enabling GitHub and
silencing ADO.

- [ ] `gh repo unarchive <owner>/<repo>`.
- [ ] Re-enable the workflows disabled in step 5: `gh workflow enable
      agent.yml -R <owner>/<repo>`, and each project-automation caller.
- [ ] Reopen the issues closed in step 9 (`gh issue reopen`) if work continues
      on GitHub.
- [ ] Disable the ADO *Work item updated* service hook subscription (8), so a
      tag no longer starts a run.
- [ ] Leave the migrated work items. They are harmless once the hook is off;
      delete them by the ids kept in step 7 if they are in the way.
- [ ] The mirror stays **off**. Re-enabling it after ADO has run the pipeline
      destroys every agent branch and merge there (step 4). Turn it back on only
      if ADO is abandoned entirely, and only after the ADO repository has been
      cloned as a backup.

Check: the GitHub repository reports `"isArchived": false`, `gh workflow list`
shows the callers active, and the ADO service hook is disabled.
