# Private-feed pre-restore under the agent user boundary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An Azure DevOps `ai-implement` run whose consumer restores from a
private Azure Artifacts feed can restore, build and test inside the boundaried
agent call, and the agent still holds no credential.

**Architecture:** before the agent starts, the driver (`azp`) restores the seed
commit with the job's token into `/var/cache/awf-nuget`. `awf-agent` can only
read that folder. `awf-agent-run` points NuGet at it with the constant
`NUGET_FALLBACK_PACKAGES`. The token sits only in a temporary NuGet config
under a `0700` directory, which is deleted on every path. The boundary protocol
goes from 1 to 2, so a stale image is refused.

**Tech Stack:** Bash 5, Docker, `dotnet` CLI (NuGet), the existing Layer-1
harnesses under `tests/`.

**Spec:** `docs/superpowers/specs/2026-11-20-azdo-private-feed-pre-restore-design.md`

## Global Constraints

- **Allowlist unchanged:** the sudoers `env_keep` and `AWF_ENV_ALLOWLIST` stay
  exactly `CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY MODEL MAX_TURNS`.
- **Agent environment constants:** `awf-agent-run` adds exactly these, all
  hard-coded and never read from the caller:
  - `NUGET_FALLBACK_PACKAGES=/var/cache/awf-nuget`
  - `DOTNET_CLI_TELEMETRY_OPTOUT=1`
  - `DOTNET_NOLOGO=1`
- **Cache directory:** `/var/cache/awf-nuget`, owner `azp:azp`, mode `0755`.
  After a restore, directories are `0755` and files `0644`.
- **Protocol:** `2` in all four pins:
  - `AWF_BOUNDARY_PROTOCOL` in `scripts/lib/agent-boundary.sh`;
  - `AWF_PROTOCOL` in `docker/azp-agent/boundary/awf-agent-run`,
    `awf-agent-git` and `awf-agent-reap`.
- **Pipeline variable:** `AWF_NUGET_FEEDS` holds space-separated feed index URLs.
  When it is empty or unset, there is no restore, no `dotnet` call, and no change
  in behaviour.
- **Feed URL check:** a URL must match
  `^https://pkgs\.dev\.azure\.com/[^/]+/` or
  `^https://[A-Za-z0-9-]+\.pkgs\.visualstudio\.com/`. Anything else refuses the
  run.
- **Token:** the value of `AZURE_DEVOPS_EXT_PAT`. It never appears in any argv,
  and it is written only to the temporary NuGet config, mode `0600`, inside a
  `mktemp -d` directory with mode `0700` under `WORK_DIR`.
- **Where the restore runs:** only on a detached worktree of
  `origin/<default branch>`, mode `0700` under `WORK_DIR`, which is removed
  afterwards. It never runs on an agent workspace.
- **Mode:** pipeline mode only, and never on `DRY_RUN=1`.
- **Refusal text** for a failed restore:
  `private feed restore failed (<first feed URL>): check that the build service has the Feed Reader role on the feed`
- **Public repo:** no work-organization, feed, host or repo names anywhere. Use
  `<org>` and `<feed>`.

## Review Focus

- **Several solution files.** A repo root with both a `.sln` and a `.slnx`: each
  is restored. With none, the root directory is restored. Task 2 tests this.
- **A token with XML metacharacters.** A token with `&` or `<` must still produce
  a valid config. It is XML-escaped. Task 2 tests this.
- **Stale packages from a previous job.** The container outlives the job, so the
  cache is emptied before the restore, including dotfiles. Task 2 tests this.
- **Restore failure halfway through.** The worktree and the config directory are
  still removed, and the cache is not left writable. Task 2 tests this.
- **A caller that tries to set the fallback path.** `NUGET_FALLBACK_PACKAGES`
  passed by the caller is ignored. Task 1 tests this.

---

### Task 1: Boundary image — agent constants, cache dir, protocol 2

**Files:**
- Modify: `docker/azp-agent/boundary/awf-agent-run` (env_args, `AWF_PROTOCOL`)
- Modify: `docker/azp-agent/boundary/awf-agent-git`, `docker/azp-agent/boundary/awf-agent-reap` (`AWF_PROTOCOL=2`)
- Modify: `scripts/lib/agent-boundary.sh` (`AWF_BOUNDARY_PROTOCOL=2`)
- Modify: `docker/azp-agent/Dockerfile` (base stage: create `/var/cache/awf-nuget`, `chown azp:azp`, `chmod 0755`)
- Modify: `tests/mocks/awf-boundary/awf-agent-run`, `awf-agent-git`, `awf-agent-reap` (`--protocol` answers `2`)
- Modify: `tests/run-agent-boundary-lib-tests.sh` (stub entry points answer `2`; the wrong-protocol case answers `1`)
- Create: `tests/run-awf-agent-run-tests.sh`
- Modify: `tests/run-azp-agent-dockerfile-tests.sh`

**Interfaces:**
- Produces: the agent always sees `NUGET_FALLBACK_PACKAGES=/var/cache/awf-nuget`.
  Every entry point answers `--protocol` with `2`.

- [ ] **Step 1: Write the failing tests**

`tests/run-awf-agent-run-tests.sh` runs the **real**
`docker/azp-agent/boundary/awf-agent-run`, with these settings:
- `AWF_WS_ROOT` set to a temp dir;
- `AWF_AGENT_CLAUDE` set to a stub that runs `env | sort`;
- a workspace created at `$AWF_WS_ROOT/ws1`.

Use the same prelude, `section` and `check` helpers as
`tests/run-azp-agent-dockerfile-tests.sh`. Cases:

```bash
OUT="$(NUGET_FALLBACK_PACKAGES=/evil AZURE_DEVOPS_EXT_PAT=x SYSTEM_ACCESSTOKEN=y MODEL=m \
  AWF_WS_ROOT="$ROOT" AWF_AGENT_CLAUDE="$STUB" "$RUN" "$ROOT/ws1" -- --print)"
# awf_agent_run_SetsFallbackConstant
grep -qx 'NUGET_FALLBACK_PACKAGES=/var/cache/awf-nuget' <<<"$OUT"
# awf_agent_run_IgnoresCallerFallback
! grep -q '/evil' <<<"$OUT"
# awf_agent_run_SetsDotnetConstants
grep -qx 'DOTNET_CLI_TELEMETRY_OPTOUT=1' <<<"$OUT" && grep -qx 'DOTNET_NOLOGO=1' <<<"$OUT"
# awf_agent_run_DropsCredentials
! grep -qE '^(AZURE_DEVOPS_EXT_PAT|SYSTEM_ACCESSTOKEN)=' <<<"$OUT"
# awf_agent_run_NoCredentialNamesBeyondModelAuth
[[ -z "$(cut -d= -f1 <<<"$OUT" | grep -E 'TOKEN|PAT|ACCESSTOKEN|SECRET|PASSWORD' \
  | grep -vxE 'CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_API_KEY')" ]]
# awf_agent_run_ProtocolIsTwo
[[ "$("$RUN" --protocol)" == 2 ]]
```

Add these to `tests/run-azp-agent-dockerfile-tests.sh`, following the existing
`check` style:
- **`dockerfile_creates_nuget_cache_dir`:** the base stage contains
  `/var/cache/awf-nuget`, a `chown` to `azp:azp` and a `chmod 0755` (or
  `install -d -o azp -g azp -m 0755`).
- **A negative case:** the same check on a copy with the directory line
  removed must fail.
- **`entry_points_share_one_protocol`:** all three entry points and
  `scripts/lib/agent-boundary.sh` declare protocol `2`.
- **`awf_agent_run_allowlist_unchanged`:** the existing `ENV_ALLOWLIST`
  assertion is still true.

- [ ] **Step 2: Run them to verify they fail**

Run: `bash tests/run-awf-agent-run-tests.sh; bash tests/run-azp-agent-dockerfile-tests.sh`
Expected: FAIL on the fallback, dotnet-constant, protocol and cache-dir cases.

- [ ] **Step 3: Implement**

- **`awf-agent-run`:** append the three constants to `env_args` after the
  `HOME`/`PATH` entries, before the allowlist loop, so a caller value can never
  be added on top.
- **Protocol:** set `2` in all four pins, the three mocks, and the
  `run-agent-boundary-lib-tests.sh` stubs. The wrong-protocol case there now
  answers `1`.
- **Comments:** update the header comments of `awf-agent-run` and the sudoers
  file. They say the allowlist is "exactly" four names, which stays true. Add a
  line saying `NUGET_FALLBACK_PACKAGES` is a constant for #641.

- [ ] **Step 4: Run the full suite**

Run: `just test` (or `bash tests/run-script-tests.sh` plus every `tests/run-*-tests.sh`), then `shellcheck -x -e SC1091` on the changed scripts.
Expected: all runners report `0 failed`, and shellcheck is clean.

- [ ] **Step 5: Commit**

```bash
git add docker/azp-agent scripts/lib/agent-boundary.sh tests/mocks/awf-boundary tests/run-agent-boundary-lib-tests.sh tests/run-awf-agent-run-tests.sh tests/run-azp-agent-dockerfile-tests.sh
git commit -m "feat(azdo): give the agent a read-only NuGet fallback folder (#641)"
```

### Task 2: `scripts/lib/private-feed-restore.sh` — the credentialed pre-restore

**Files:**
- Create: `scripts/lib/private-feed-restore.sh`
- Create: `tests/mocks/dotnet`
- Create: `tests/run-private-feed-restore-tests.sh`

**Interfaces:**
- Consumes: `bgit` (the driver's git wrapper used in `scripts/lib/agent-boundary.sh`), or plain `git -C`
- Produces (sourced by the driver; every function prints its cause to stderr on failure):
  - `AWF_NUGET_CACHE` — defaults to `/var/cache/awf-nuget`, overridable for tests only.
  - `feed_restore_enabled` — returns 0 when `AWF_NUGET_FEEDS` holds a non-blank value.
  - `feed_restore_config_check` — returns 1 when `dotnet` is not on `PATH`
    (the message names `--target dotnet`), or when any URL in
    `AWF_NUGET_FEEDS` fails the Global Constraints check (the message names the
    URL).
  - `feed_write_config <file>` — writes a NuGet config with mode `0600`. It has
    `<clear/>`, nuget.org as `nuget.org`, each feed as `feed1`…`feedN`, and
    `<packageSourceCredentials>` for each feed with `Username` set to
    `ai-implement` and `ClearTextPassword` set to the XML-escaped
    `AZURE_DEVOPS_EXT_PAT`.
  - `feed_pre_restore <seed-ref> <work-dir>` — runs the whole restore. Returns 0
    on success and 1 on failure. On both paths it removes the worktree and the
    config directory. On failure the first stderr line is the cause.

- [ ] **Step 1: Write the failing tests**

`tests/mocks/dotnet` appends its argv to `$DOTNET_LOG` and copies the
`--configfile` it gets to `$DOTNET_CONFIG_COPY`. It records the mode of the
config file and of its directory in `$DOTNET_MODE_LOG`, and records `$PWD`. With
`DOTNET_MOCK_FAIL=1` it exits 1. Otherwise it creates
`<--packages>/testpkg/1.0.0/testpkg.1.0.0.nupkg` with mode `0600`, so the chmod
pass is tested.

The tests use a temp git repo with an `origin/main`, `AWF_NUGET_CACHE` set to a
temp dir, and the mocks dir first on `PATH`:

```bash
# feed_restore_enabled_EmptyIsOff / _BlankIsOff / _SetIsOn
# feed_restore_config_check_RejectsForeignHost:
#   AWF_NUGET_FEEDS="https://evil.example/_packaging/f/nuget/v3/index.json" → rc 1, stderr names the URL
# feed_restore_config_check_AcceptsBothAdoForms:
#   "https://pkgs.dev.azure.com/org/_packaging/f/nuget/v3/index.json https://org.pkgs.visualstudio.com/_packaging/f/nuget/v3/index.json" → rc 0
# feed_restore_config_check_NoDotnet: PATH without the mock → rc 1, stderr contains "--target dotnet"
# feed_write_config_EscapesToken: AZURE_DEVOPS_EXT_PAT='a&b<c' → file contains 'a&amp;b&lt;c', mode 600,
#   and `xmllint --noout` (or python3 xml.etree) parses it
# feed_pre_restore_TokenNotInArgv: AZURE_DEVOPS_EXT_PAT=s3cr3t → ! grep -q s3cr3t "$DOTNET_LOG"
# feed_pre_restore_ConfigPrivate: DOTNET_MODE_LOG shows file 600 and dir 700
# feed_pre_restore_ConfigOutsideCacheAndWorkspace: the logged --configfile path is under <work-dir>, not under $AWF_NUGET_CACHE
# feed_pre_restore_RunsOnSeedWorktree: the logged PWD is a worktree whose HEAD == $(git rev-parse origin/main)
# feed_pre_restore_RestoresEachSolution: root with a.sln and b.slnx → two dotnet restore calls naming each
# feed_pre_restore_NoSolutionRestoresRoot: no solution file → one call with no project argument
# feed_pre_restore_EmptiesStaleCache: pre-existing $AWF_NUGET_CACHE/old/.hidden is gone afterwards
# feed_pre_restore_CacheWorldReadable: after success, find "$AWF_NUGET_CACHE" -type f ! -perm 0644 is empty
#   and -type d ! -perm 0755 is empty
# feed_pre_restore_CleansUpOnSuccess / _CleansUpOnFailure: no worktree left (git worktree list),
#   no config dir left under <work-dir>; DOTNET_MOCK_FAIL=1 → rc 1
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bash tests/run-private-feed-restore-tests.sh`
Expected: FAIL, because the library does not exist yet.

- [ ] **Step 3: Implement `scripts/lib/private-feed-restore.sh`**

- **Prelude and header:** the repo's bash prelude and the header-comment style
  of `scripts/lib/agent-boundary.sh`, listing the functions above.
- **Order inside `feed_pre_restore`:**
  1. `umask 077`.
  2. `mktemp -d` under `<work-dir>` for the config directory, and a detached
     worktree under `<work-dir>`; `chmod 0700` both.
  3. Empty the cache with `find "$AWF_NUGET_CACHE" -mindepth 1 -delete`.
  4. `dotnet restore [<solution>] --configfile <cfg> --packages "$AWF_NUGET_CACHE"`
     for each solution.
  5. `chmod -R u=rwX,go=rX "$AWF_NUGET_CACHE"`.
  6. Clean up through a function called on both paths (not an EXIT trap, since
     the driver owns its trap).
- **No credentials in the repo's config:** pass `--configfile`, and the config
  starts with `<clear/>`, so the repository's own `nuget.config` cannot add a
  source that receives the token.

- [ ] **Step 4: Run tests and shellcheck**

Run: `bash tests/run-private-feed-restore-tests.sh && shellcheck -x -e SC1091 scripts/lib/private-feed-restore.sh tests/run-private-feed-restore-tests.sh tests/mocks/dotnet`
Expected: `0 failed`, and shellcheck is clean.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/private-feed-restore.sh tests/mocks/dotnet tests/run-private-feed-restore-tests.sh
git commit -m "feat(azdo): pre-restore private feeds for the boundaried agent (#641)"
```

### Task 3: Wire the pre-restore into the driver, document it

**Files:**
- Modify: `scripts/implement-azdo.sh` (source the lib, `preflight_restore`, `restore_private_feeds`, `main`)
- Modify: `tests/run-azdo-isolation-tests.sh` (structural order)
- Modify: `tests/run-implement-azdo-tests.sh` (behaviour through the existing pipeline-mode harness, around the `awf-boundary` mock setup at ~line 698)
- Modify: `docs/AZDO-PIPELINE-SETUP.md` (new section after §13: "Private package feeds")
- Modify: `CHANGELOG.md` (`[Unreleased]` → `Added`)

**Interfaces:**
- Consumes: Task 2's functions, plus `BOUNDARY_REFUSAL` and `refuse_without_boundary` in `implement-azdo.sh`.
- Produces:
  - `preflight_restore` — called in `preflight` right after `preflight_boundary`.
    When `feed_restore_enabled` holds and `feed_restore_config_check` fails, it
    sets `BOUNDARY_REFUSAL` to `private feed setup: <first stderr line>`.
  - `restore_private_feeds` — called in `main` after
    `DEFAULT_BRANCH="$(resolve_default_branch)"` and before `attempt_loop`, in
    pipeline mode only. On failure it sets `BOUNDARY_REFUSAL` to the exact
    Global Constraints refusal text and calls `refuse_without_boundary`.

- [ ] **Step 1: Write the failing tests**

Add to `tests/run-azdo-isolation-tests.sh`, using `func_body` and `before`:

```bash
# implement_restore_precedes_the_agent:
grep -q 'preflight_restore' <<<"$(func_body "$text" preflight)"
before "$(func_body "$text" preflight)" preflight_boundary preflight_restore
before "$(func_body "$text" main)" resolve_default_branch restore_private_feeds
before "$(func_body "$text" main)" restore_private_feeds attempt_loop
grep -q 'refuse_without_boundary' <<<"$(func_body "$text" restore_private_feeds)"
grep -q 'pipeline_mode' <<<"$(func_body "$text" restore_private_feeds)"
```

Add to `tests/run-implement-azdo-tests.sh`, in pipeline mode, with
`tests/mocks/dotnet` on `PATH`:

- `implement_NoFeeds_NoDotnetCall`: with `AWF_NUGET_FEEDS` unset, `$DOTNET_LOG`
  is empty and the run reaches the agent as before.
- `implement_FeedRestoreFails_RefusesBeforeAgent`: with `DOTNET_MOCK_FAIL=1`,
  the exit is 1, `$SUDO_LOG` has no `awf-agent-run` line, and the posted report
  contains `private feed restore failed (` and `Feed Reader`.
- `implement_ForeignFeedUrl_RefusesBeforeAgent`: with a non-ADO URL, the exit is
  1, `$DOTNET_LOG` is empty, and the report contains `private feed setup:`.
- `implement_FeedRestoreOk_AgentRuns`: the restore succeeds and the agent call
  happens after it. In `$SUDO_LOG`, `awf-agent-run` comes after the `dotnet`
  call (compare timestamps or a shared ordered log).
- `implement_DryRun_NoRestore`: with `DRY_RUN=1` and feeds set, `$DOTNET_LOG` is
  empty.

- [ ] **Step 2: Run them to verify they fail**

Run: `bash tests/run-azdo-isolation-tests.sh; bash tests/run-implement-azdo-tests.sh`
Expected: FAIL on the new cases only.

- [ ] **Step 3: Implement the wiring and the docs**

- **Driver:** source the lib next to `lib/agent-boundary.sh`, and add the two
  functions and the two call sites.
- **New section in `docs/AZDO-PIPELINE-SETUP.md`**, with one subsection for each
  of these:
  - `AWF_NUGET_FEEDS`: the format, with a `<org>`/`<feed>` example, and the
    accepted host forms.
  - The **Feed Reader** role for the project's build service. An operator who
    set a PAT instead needs `Packaging (Read)` on it.
  - The image rebuild with `--target dotnet`. Protocol 2 makes a stale image
    refuse.
  - The limit: a private package the agent adds during a run cannot restore.
  - The refusal message and what to check.
- **CHANGELOG:** add one `Added` line under `[Unreleased]`.

- [ ] **Step 4: Run the full suite and lint**

Run: `just test` and `pre-commit run --all-files` (after `git add`)
Expected: every runner reports `0 failed`, and pre-commit passes.

- [ ] **Step 5: Commit**

```bash
git add scripts/implement-azdo.sh tests/run-azdo-isolation-tests.sh tests/run-implement-azdo-tests.sh docs/AZDO-PIPELINE-SETUP.md CHANGELOG.md
git commit -m "feat(azdo): restore private feeds before the agent starts (#641)"
```

## After merge (operator, not the agent)

Layer 3 on the sandbox, as the spec describes:
- a feed with one test package;
- `AWF_NUGET_FEEDS` set and the Feed Reader role granted;
- the image rebuilt;
- a work item whose task needs the package.

Record the result in `docs/ai-notes/`.
