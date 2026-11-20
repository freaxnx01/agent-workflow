# Azure DevOps: restore from a private feed under the agent user boundary (#641)

## Intent

The agent user boundary (#591, ADR-024, merged in #626) runs the agent as
`awf-agent` with an environment rebuilt from four allowlisted names. A .NET
consumer whose packages partly come from a **private Azure Artifacts feed** in
its own organization cannot restore inside the agent call: the agent holds no
feed credential, so `dotnet restore`, `dotnet build` and `dotnet test` fail at
the first private package, and the TDD loop never starts.

This blocks moving a .NET consumer onto the Azure DevOps path. The first such
consumer pins its private packages centrally (`Directory.Packages.props`), so
the set of private packages is fixed per commit and an agent rarely adds a new
one.

## Goals

- An `ai-implement` run on a consumer with a private feed can restore, build and
  test inside the agent call.
- The boundary's guarantee holds unchanged: **no credential that can read or
  write the repo, the feed or the organization is readable by the agent.**
  The sudoers `env_keep` list and `AWF_ENV_ALLOWLIST` stay exactly
  `CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY MODEL MAX_TURNS`.
- A consumer without a private feed sees no change.

## Non-goals

- Restoring a private package that the agent **adds** during the run. That
  restore fails with NuGet's own "unable to find package" error, and the run
  reports it like any other failure. Adding a public package still works,
  because nuget.org stays reachable.
- Feeds outside the pipeline's own organization, and feeds that need a PAT
  instead of `System.AccessToken`.
- The GitHub path, where the private-feed case is the consumer's own CI
  concern.

## Anti-goals

- Any secret in the agent's environment, workspace, home directory or package
  folder, even read-only or short-lived. That would be the rejected
  "read-only feed token" approach by another name.
- Running a credentialed restore on code the agent wrote. MSBuild evaluation
  executes repository logic, so a credentialed restore runs **only** on the
  commit the agent is seeded from, before the agent starts.
- A file in the agent's workspace that the boundary's `commit` verb would stage
  (`nuget.config`, `.nuget/`, …).

## Approaches

1. **Driver pre-restore into a read-only fallback folder (chosen).** Before the
   agent call, the driver (as `azp`) restores the seed commit with
   `System.AccessToken` into a fixed directory that `awf-agent` can read but not
   write. `awf-agent-run` points NuGet at it through `NUGET_FALLBACK_PACKAGES`,
   a constant it sets itself. NuGet takes packages found in a fallback folder
   without asking any source, so the private packages resolve offline while
   nuget.org still serves everything else. The boundary is unchanged apart from
   one non-secret constant, so no new ADR is needed. Its limit is the non-goal
   above.
2. **A read-only feed token in the allowlist.** This is the simplest, and the
   agent could restore anything. But the agent could also read the token, and it
   stays valid after the run, with read access to every package feed of the
   organization. That widens the boundary and would need an ADR. Rejected.
3. **A local auth-injecting proxy.** A service in the container adds the token
   to the agent's requests on `localhost`. The agent never sees the token, but
   it can read the whole feed during the run, and the container gains a
   long-running service to operate and test. Rejected as more moving parts for
   little gain over (1).

## Decided design

### Image (`docker/azp-agent/`)

- A directory **`/var/cache/awf-nuget`** is created in the base stage, owned by
  `azp:azp` with mode `0755`. `azp` writes it and `awf-agent` can only read it.
- **`awf-agent-run`** adds the constant `NUGET_FALLBACK_PACKAGES=/var/cache/awf-nuget`
  to the environment it rebuilds. The value is hard-coded in the entry point and
  never comes from the caller. `AWF_ENV_ALLOWLIST` and the sudoers `env_keep`
  do not change.
- The image is rebuilt, so `AWF_BOUNDARY_PROTOCOL` / the entry points'
  `--protocol` go up by one. The driver's existing protocol check then refuses a
  stale image with a clear message instead of running an agent that cannot
  restore.

### Driver (`scripts/implement-azdo.sh`, `scripts/lib/`)

- A new pipeline variable, **`AWF_NUGET_FEEDS`**, holds the space-separated
  feed index URLs (`https://pkgs.dev.azure.com/<org>/_packaging/<feed>/nuget/v3/index.json`).
  When it is empty or unset, the pre-restore is skipped, so nothing changes for
  other consumers.
- **When:** once per run, after the boundary preflight and before the first
  agent call. Do it in pipeline mode only. Self-fix and later attempts reuse the
  same folder.
- **What:** restore the commit the agent is seeded from (`origin/<default
  branch>`), from a detached worktree under the driver's `WORK_DIR`, never from
  a tree the agent touched. The restore writes into `/var/cache/awf-nuget`, which
  is emptied first because the container outlives the job.
- **Credential:** a temporary NuGet config sits in a `mktemp -d` directory under
  `WORK_DIR` with mode `0700`, and is passed with `--configfile`. It lists
  nuget.org and each feed in `AWF_NUGET_FEEDS`, each feed using the job's token
  (`AZURE_DEVOPS_EXT_PAT`, which `lib/ci-host.sh` already exports from
  `SYSTEM_ACCESSTOKEN`). A `trap` deletes the directory on every exit path. The
  token never appears in argv: it goes into the file, or into the environment of
  the single `dotnet` call.
- **Permissions after restore:** directories `0755` and files `0644` throughout
  `/var/cache/awf-nuget`, so `awf-agent` can read every package. It must not be
  able to write, so it cannot poison the next run.
- **Failure:** a failed pre-restore refuses the run **before the agent
  starts**. The report on the work item names the feed and the most likely cause
  (the build service has no Reader role on the feed). The agent's turn budget is
  not burned on a restore that cannot work.

### Consumer setup (`docs/AZDO-PIPELINE-SETUP.md`)

The setup gets a new section that tells the operator to:

- set `AWF_NUGET_FEEDS` on the `ai-implement` pipeline;
- give the project's build service the **Feed Reader** role on each feed;
- rebuild the image (the protocol bump makes a stale image refuse).

## Tests

- **Layer 1, boundary (`tests/run-azp-agent-dockerfile-tests.sh`,
  `tests/run-agent-isolation-*`):**
  - `awf-agent-run` sets `NUGET_FALLBACK_PACKAGES` to the constant even when
    the caller passes a different value.
  - The allowlist and `env_keep` are byte-identical to today.
  - The Dockerfile creates `/var/cache/awf-nuget` as `azp:azp 0755`.
  - The protocol is bumped in lockstep everywhere it is pinned.
- **Layer 1, driver:**
  - An empty `AWF_NUGET_FEEDS` skips the restore. Assert that no `dotnet` call
    was made.
  - The temporary config is written outside the agent workspace and outside the
    fallback folder, with mode `0600` inside a `0700` directory, and it is gone
    after both a success and a failure.
  - The token is not in any `dotnet` argv. Assert with the existing argv-capture
    stub pattern from `run-agent-boundary-lib-tests.sh`.
  - The restore runs on the seed commit's worktree, not on an agent workspace.
  - A failed restore refuses the run before `boundary_exec_claude` and posts the
    report.
  - Mock `dotnet` in `tests/mocks/`.
- **Structural:** a test pins the guarantee from the issue: nothing in the
  agent's rebuilt environment matches `*TOKEN*`, `*PAT*` or `*ACCESSTOKEN*`
  apart from the two existing model-auth names.
- **Layer 3 (sandbox):**
  - Create an Azure Artifacts feed in the personal sandbox org with one tiny test
    package, and reference it from the practice repo.
  - Run `ai-implement` with a work item whose task needs that package to build.
  - Record the result in `docs/ai-notes/`. The record shows the restore
    succeeding, `env` without a feed token, and `touch /var/cache/awf-nuget/x`
    denied.

## Acceptance criteria

- [ ] With `AWF_NUGET_FEEDS` set and the build service holding Feed Reader, the
      agent restores, builds and tests a project that references a private-feed
      package, on the sandbox (Layer 3).
- [ ] With `AWF_NUGET_FEEDS` unset, the driver makes no restore call, and runs
      behave exactly as today.
- [ ] The agent's environment contains no feed, repo or organization credential.
      The allowlist and `env_keep` are unchanged, and a structural test pins this.
- [ ] `/var/cache/awf-nuget` is readable but not writable by `awf-agent`.
- [ ] The temporary NuGet config never sits in the agent workspace or the
      fallback folder, never shows the token in argv, and is deleted on success
      and on failure.
- [ ] A failed pre-restore refuses the run before the agent starts, and the
      report on the work item names the feed and the Feed Reader hint.
- [ ] The boundary protocol is bumped, so a stale image is refused.
- [ ] `docs/AZDO-PIPELINE-SETUP.md` documents `AWF_NUGET_FEEDS`, the Feed Reader
      role, and the image rebuild.

## Settled after the builder check (author's calls)

- **Protocol bump:** all four pins move together:
  - `AWF_BOUNDARY_PROTOCOL` in `scripts/lib/agent-boundary.sh`;
  - `AWF_PROTOCOL` in `awf-agent-run`, `awf-agent-git` and `awf-agent-reap`.

  `boundary_check` compares every entry point against the one driver value.
- **Other `dotnet` constants:** `awf-agent-run` also sets
  `DOTNET_CLI_TELEMETRY_OPTOUT=1` and `DOTNET_NOLOGO=1` as constants. `env -i`
  drops the image's `ENV` values, and telemetry is the one that matters.
  - `dotnet` is found through the `/usr/local/bin/dotnet` symlink without
    `DOTNET_ROOT`.
  - `HOME` is `/home/awf-agent`, which `awf-agent` owns, so the agent's own
    global packages folder (for public packages) is writable.
  - Layer 3 proves the agent's `dotnet test` works under the boundary.
- **No `dotnet` on the image:** when `AWF_NUGET_FEEDS` is set and `dotnet` is
  not on `PATH` (the plain image), the run is refused with a message naming
  `--target dotnet`.
- **Gate:** pipeline mode only. Local mode does not use the boundary and
  restores with the operator's own credentials, so `AWF_NUGET_FEEDS` is ignored
  there.
- **Token:** whatever `AZURE_DEVOPS_EXT_PAT` holds once `lib/ci-host.sh` has run.
  - That is `System.AccessToken` by default, so the Feed Reader role goes to the
    build service.
  - An operator who set a PAT instead needs `Packaging (Read)` on it.
  - The setup docs say both.
- **Insertion point and refusal:** the work is split in two, because
  `preflight` runs before `WORK_DIR` and `DEFAULT_BRANCH` exist
  (`implement-azdo.sh` `main`).
  - **Config check:** a cheap `preflight_restore`, run right after
    `preflight_boundary` in `preflight`, checks that `dotnet` is on `PATH` and
    that every feed URL is an Azure DevOps feed URL. On failure it sets
    `BOUNDARY_REFUSAL` the same way `preflight_boundary` does.
  - **The restore itself:** it runs in `main` after `resolve_default_branch` and
    before `attempt_loop`, and is skipped on `DRY_RUN`. On failure it sets
    `BOUNDARY_REFUSAL` and calls the existing `refuse_without_boundary`, which
    posts the report and exits 1.

  Either way, a refused run never reaches `run_attempt_boundary` /
  `boundary_seed`.
- **Feed URL check:** a feed URL must start with `https://pkgs.dev.azure.com/`
  or match `https://<org>.pkgs.visualstudio.com/`. The token is written for
  these URLs only, so a typo or a hostile variable cannot send it to another
  host.
- **Worktree permissions:** the detached restore worktree and the config
  directory are both `0700` under `WORK_DIR`. `WORK_DIR` itself is `0711` in
  pipeline mode, so `awf-agent` can neither list nor enter them. Both are removed
  before the agent starts.

## Left to the builder

- The exact `dotnet restore` invocation: the solution or project to restore,
  `--packages`, and whether `--configfile` alone is enough. The constraint is
  that the repository's own `nuget.config` hierarchy must not be able to add a
  source that receives the token. With package source mapping, map `*` to
  nuget.org and the private prefixes to the feeds, or simply include the feeds
  as sources. Either way, the token is only sent to the listed feed URLs.
- How the solution to restore is chosen when the repository root holds more than
  one solution file. Proposed default: restore every `*.sln`/`*.slnx` at the
  root.
- Naming of the new helper(s) in `scripts/lib/`.
