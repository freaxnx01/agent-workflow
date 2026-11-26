# Azure DevOps PR validation with a private NuGet feed — design (#699)

## Intent

On Azure DevOps a repo whose build needs a package that only a private Azure
Artifacts feed serves cannot pass its PR build validation: the validation
pipeline deliberately maps no credential (`docs/AZDO-PIPELINE-SETUP.md` §9),
so `dotnet restore` fails with `NU1101`. With a required build-validation
policy every PR of such a repo is red. `docs/AZDO-CUTOVER.md` step 6 asks for
validation equivalent to the GitHub CI, so this blocks the cutover of any
consumer with a private feed.

The fix must keep §9's rule intact: **code from the PR never runs while a
credential is reachable.**

## Goals

- A PR that does not change private package references passes validation on a
  repo with `AWF_NUGET_FEEDS` set.
- The token reaches exactly one step, which runs only agent-workflow code at a
  pinned ref and MSBuild only on the PR's **target-branch** commit.
- A consumer without private feeds sees no change: no new variable, no clone,
  no behaviour change.

## Non-goals

- A PR that adds a private package or raises its version still fails. It needs
  a human override (*Bypass policies when completing pull requests*). In the
  consumer that prompted this issue, no commit touched a private reference in
  seven months, so the override is a rare manual step. A static,
  MSBuild-free fetch of the PR's new private versions is a possible follow-up
  issue, not part of this one.
- Non-.NET feeds (npm, Maven, Python).

## Anti-goals

- Mapping `System.AccessToken` into the build/test step, or into any step
  that executes a file from the PR's checkout.
- MSBuild evaluating any file the PR controls while the token is set,
  including a `Directory.Build.props` found by walking up from the seed
  worktree.

## Approaches

- **A — seed restore from the target branch (chosen).** Reuse
  `scripts/lib/private-feed-restore.sh` (#641/#682): a trusted step restores
  the target-branch commit with the token into the fixed fallback folder; the
  untokened build then reads private packages from it via
  `NUGET_FALLBACK_PACKAGES`. Small, reuses proven code, and the trust model is
  already reviewed.
- **B — A plus a static fetch of the PR's new private versions.** Parse
  `PackageReference`/`PackageVersion` as plain XML and download missing
  private packages through the feed API. It turns the "new version" PR green,
  but needs version ranges, MSBuild properties and transitive private
  dependencies, all in token-holding code. Rejected for now: there were no such
  changes in seven months.
- **C — documentation only.** Every PR would need an override, which makes the
  validation worthless. Rejected.

## Design

### Trust model

The validation pipeline has **no user boundary**: unlike the implement run,
where the agent runs as `awf-agent` (ADR-024), the PR's build/test step runs as
the same user (`azp`) as the new token-holding step. Within one job the order
protects the token, because the trusted step runs first. Across jobs it does
not: an earlier validation job on a persistent agent could plant something the
next job's trusted step executes. Examples:

- `~/.gitconfig` hooks or filters;
- MSBuild user-location `ImportBefore` targets;
- a NuGet credential-provider plugin under `~/.nuget/plugins`;
- a `Directory.Build.props` above `Agent.TempDirectory`;
- a shadowing `dotnet` on `PATH`.

Chosen mitigation: **both trusted steps run hermetically**, and §9.6 requires
agents that are fresh per job.

- The fetch step and the restore step run under `env -i`, with:
  - a new `HOME` and `DOTNET_CLI_HOME` in a fresh mode-0700 temp directory;
  - `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_NOSYSTEM=1`;
  - `PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`;
  - only the variables the script needs passed through.
- The agent-workflow clone uses `-c core.hooksPath=/dev/null -c
  core.fsmonitor=false`.
- `dotnet` is invoked by the absolute path the image installs.
- MSBuild user-location imports are disabled with
  `ImportUserLocationsByWildcardBeforeMicrosoftCommonProps=false`,
  `…AfterMicrosoftCommonTargets=false` and the matching `ImportByWildcard…`
  properties, passed as environment variables, never as argv carrying the
  token.
- Plugins are kept away from the token:
  - `NUGET_PLUGIN_PATHS` is set to an empty file in the fresh temp dir;
  - `NUGET_PACKAGES` is unset, so `--packages` decides.
- The seed worktree sits in a fresh directory under `Agent.TempDirectory`. The
  entry point refuses when any ancestor of that directory up to `/` holds a
  `Directory.Build.props`, `Directory.Build.targets`,
  `Directory.Packages.props` or `nuget.config`, so the MSBuild walk-up finds
  nothing from an earlier job.

Out of scope, captured separately: in validation the PR code can write to the
persistent `/azp/agent` volume as `azp`. That is a pre-existing exposure of the
agent binaries and is filed as its own issue.

### Seed commit

For a PR build, Azure DevOps checks out `refs/pull/<n>/merge`, whose
`Build.SourceVersion` is a merge commit. Its first parent is the target
branch's tip at merge time. The seed is therefore `HEAD^1`, so no further
fetch is needed and no credential is needed for one.

- The template sets `fetchDepth: 2` on the checkout so the first parent is
  present.
- The entry point refuses, with a clear message, when `HEAD` is not a merge
  commit with two parents, for example on a manual run or when the build is not
  for a PR.
- `HEAD^1` is trustworthy only when the target is the default branch.
  The entry point refuses unless `SYSTEM_PULLREQUEST_TARGETBRANCH` equals
  `refs/heads/<default>`. The default branch comes from
  `BUILD_REPOSITORY_DEFAULTBRANCH` when Azure DevOps sets it, otherwise from
  `AWF_DEFAULT_BRANCH` (default `main`). A PR retargeted onto an
  agent-pushed branch, or a policy added to another branch, then cannot turn
  untrusted code into the seed.

### New entry point `scripts/azdo-pr-feed-restore.sh`

Runs in the trusted step. Its order of work:

1. If `AWF_NUGET_FEEDS` is blank, print a note and exit 0 (defence in depth:
   the template's step condition already skips it).
2. Require `SYSTEM_ACCESSTOKEN`, mapped by the step, and export it as
   `AZURE_DEVOPS_EXT_PAT` for `feed_write_config`. Never print it.
3. Run the same cheap checks as `preflight_restore`/`preflight_cache` in
   `scripts/implement-azdo.sh`:
   - `feed_restore_config_check`;
   - `feed_restore_targets_syntax_check`;
   - the fixed cache path `/var/cache/awf-nuget`, which must be a real
     directory owned by the user.

   The cache check moves from `implement-azdo.sh` into the library, so both
   callers share one copy and the error text stays identical.
4. Take the work directory from `AWF_PR_RESTORE_WORK_DIR`, which the template
   sets to `$(Agent.TempDirectory)`. Refuse when it is not absolute, or when
   it lies inside `BUILD_SOURCESDIRECTORY`. MSBuild walks up from the seed
   worktree looking for `Directory.Build.props`, and nothing above it may come
   from the PR.
5. Run `feed_pre_restore HEAD^1 <work-dir>` from inside the checkout. All git
   calls go through `bgit`, the existing wrapper with hooks and fsmonitor
   disabled.
6. Handle the result:
   - On rc 2, print `private feed restore: <first cause line>` and exit 1.
   - On rc 1, print the same Feed Reader message the implement run uses,
     `private feed restore failed (<first feed URL>): check that the build
     service has the Feed Reader role on the feed`, and exit 1.

   `dotnet restore`'s own error stays in the log above that line.

7. After a successful restore, and only then, emit
   `##vso[task.setvariable variable=NUGET_FALLBACK_PACKAGES]/var/cache/awf-nuget`.
   The build step therefore points at the cache only when this job filled it,
   and never reads a cache an earlier job left behind.

Exit codes: 0 restored or nothing to do, 1 refused or failed, 2 usage
(missing `SYSTEM_ACCESSTOKEN` while feeds are set).

### Cleanup

A final step with `condition: always()`, also skipped when
`AWF_NUGET_FEEDS` is empty, runs `scripts/azdo-pr-feed-cleanup.sh`. That
script calls `feed_cache_clear`, so no private package outlives the job on a
persistent agent.

### Template `templates/azdo/pr-validation.yml`

```yaml
steps:
  - checkout: self
    persistCredentials: false
    fetchDepth: 2

  # --- PRIVATE FEEDS (§9.6): leave as is; skipped when AWF_NUGET_FEEDS is empty ---
  - bash: |
      env -i HOME="$(mktemp -d)" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 PATH=/usr/bin:/bin \
        git -c core.hooksPath=/dev/null clone -q --filter=blob:none https://github.com/freaxnx01/agent-workflow "$(Agent.TempDirectory)/aw"
      env -i HOME="$(mktemp -d)" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 PATH=/usr/bin:/bin \
        git -c core.hooksPath=/dev/null -C "$(Agent.TempDirectory)/aw" checkout -q "$(AGENT_WORKFLOW_REF)"
    displayName: fetch agent-workflow (pinned, hermetic)
    condition: and(succeeded(), ne(variables['AWF_NUGET_FEEDS'], ''))
  - bash: '"$(Agent.TempDirectory)/aw/scripts/azdo-pr-feed-restore.sh"'
    displayName: restore private feeds (target branch)
    condition: and(succeeded(), ne(variables['AWF_NUGET_FEEDS'], ''))
    env:
      SYSTEM_ACCESSTOKEN: $(System.AccessToken)
      AWF_PR_RESTORE_WORK_DIR: $(Agent.TempDirectory)

  # --- BUILD/TEST: edit this step only ---
  - script: |
      dotnet build
      dotnet test --no-build
    displayName: Build and test

  - bash: '"$(Agent.TempDirectory)/aw/scripts/azdo-pr-feed-cleanup.sh"'
    displayName: clear private package cache
    condition: and(always(), ne(variables['AWF_NUGET_FEEDS'], ''))
```

- The feed steps are inert for a consumer without `AWF_NUGET_FEEDS`.
- `NUGET_FALLBACK_PACKAGES` reaches the build step only through the
  `task.setvariable` from a successful restore.
- The entry point re-executes itself under `env -i` with the hermetic
  environment from the trust model, passing through only these variables:
  - `SYSTEM_ACCESSTOKEN`;
  - `AWF_NUGET_*`;
  - `AWF_PR_RESTORE_WORK_DIR`;
  - `BUILD_SOURCESDIRECTORY`;
  - `SYSTEM_PULLREQUEST_TARGETBRANCH`;
  - `BUILD_REPOSITORY_DEFAULTBRANCH`;
  - `AWF_DEFAULT_BRANCH`.

### Docs

- **§9.2 in `docs/AZDO-PIPELINE-SETUP.md`:** "no variables" becomes "no
  **secret** variables". The non-secret `AGENT_WORKFLOW_REF`,
  `AWF_NUGET_FEEDS` and `AWF_NUGET_RESTORE` are allowed and needed only with
  private feeds.
- **New §9.6 "Private feeds":** covers these points.
  - What the trusted step does and why it restores the target branch.
  - Which variables to set: the same three values as the implement pipeline.
  - No extra Feed Reader grant is needed. Both pipelines run as the same
    project build service, granted in §14.3.
  - The limitation: a PR that adds or raises a private reference stays red and
    needs the bypass override.
  - The repo's tracked `nuget.config` must not list the private feed. Otherwise
    the untokened restore fails with `NU1301` on any package that is not in
    the fallback folder.
- **§9.6 also states:**
  - The precondition is a **fresh agent per job**, as in
    `docker/azp-agent/azp-agent.service.example`.
  - The hermetic steps reduce the damage when that precondition is not met,
    but do not remove it.
  - The PR must target the default branch.
- **§14:** one sentence pointing to §9.6.
- **`docs/AZDO-CUTOVER.md` step 6:** the validation checkbox mentions §9.6 for
  repos with private feeds.
- **`CHANGELOG.md`:** an entry under the existing `## [Unreleased]`, in its
  `Added`/`Changed` subsections.

### Tests (Layer 1)

`tests/run-azdo-pr-feed-restore-tests.sh` covers these cases, with mocked
`dotnet` and a real throwaway git repo that has a merge commit:

- Feeds blank, so the script exits 0 without calling `dotnet`.
- Feeds set and `SYSTEM_ACCESSTOKEN` missing, so it exits 2.
- `HEAD` is not a two-parent merge, so it exits 1 with the message.
- The work dir lies inside `BUILD_SOURCESDIRECTORY`, so it exits 1.
- On success, `dotnet restore` runs in a worktree of `HEAD^1`, not `HEAD`.
  The mock records its working directory and the seed's commit, the
  temporary config is gone afterwards, and the token never appears in the
  mock's argv log.
- When the restore fails, the script exits 1 with the Feed Reader message.
- A target branch other than the default branch is refused.
- The environment is hermetic. The `dotnet` mock records its environment and
  finds:
  - `HOME` is not the caller's;
  - `GIT_CONFIG_GLOBAL=/dev/null`;
  - the MSBuild user-import switches are set;
  - no variable outside the allowlist is present.

  A planted `$HOME/.gitconfig` with a `core.hooksPath` hook does not run.
- An ancestor `Directory.Build.props` above the work dir is refused.
- `task.setvariable` is printed only on success.
- The cleanup script empties the cache.

The existing `run-private-feed-restore-tests.sh` keeps passing after the
cache check moves into the library. It is wired into `tests/run-all.sh` like
the other runners.

## Left to the builder

- Function names for the moved cache check, as long as `implement-azdo.sh`'s
  behaviour and messages are unchanged.
- Exact §9.6 prose.

## Layer 3 (after merge, not part of the implementation)

In the sandbox:

1. Set the three variables on the validation pipeline.
2. Re-run validation on a PR that does not change the private reference. It
   should be green.
3. Run it on one that raises the version. It should be red, as documented.
