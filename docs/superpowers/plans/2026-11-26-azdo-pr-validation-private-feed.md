# Azure DevOps PR validation with a private NuGet feed — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Azure DevOps PR build validation of a repo with private
NuGet feeds green for PRs that do not change private references. Code from
the PR must never run while the job token is reachable.

**Architecture:**

- A new trusted entry point, `scripts/azdo-pr-feed-restore.sh`, re-executes
  itself in a hermetic environment and checks its inputs. It then restores
  the PR merge commit's first parent (the default-branch tip) with the job
  token, through the existing `feed_pre_restore` from #641/#682. Only after
  success does it hand the untokened build step `NUGET_FALLBACK_PACKAGES`.
- A cleanup entry point empties the cache.
- The template wires both entry points behind
  `ne(variables['AWF_NUGET_FEEDS'], '')`.

**Tech Stack:** Bash 5, git, the `dotnet` CLI (mocked in tests), and Azure
Pipelines YAML.

**Spec:** `docs/superpowers/specs/2026-11-26-azdo-pr-validation-private-feed-design.md`

## Global Constraints

- Every script starts with `set -euo pipefail` and `IFS=$'\n\t'`. Every git
  call goes through `bgit` from `scripts/lib/agent-boundary.sh`.
- The token never travels in argv or is printed. It exists only as
  `SYSTEM_ACCESSTOKEN`, exported as `AZURE_DEVOPS_EXT_PAT`, and inside
  `feed_write_config`'s 0600 file.
- The package cache is fixed at `/var/cache/awf-nuget`. Tests prefix it with
  `AWF_TEST_CACHE_ROOT` and never touch the host folder.
- The hermetic `PATH` is
  `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`.
  `AWF_TEST_HERMETIC_PATH` replaces it in tests only.
- The re-exec passes through only these variables:
  - `SYSTEM_ACCESSTOKEN`;
  - `AWF_NUGET_FEEDS`, `AWF_NUGET_RESTORE`;
  - `AWF_PR_RESTORE_WORK_DIR`, `BUILD_SOURCESDIRECTORY`;
  - `SYSTEM_PULLREQUEST_TARGETBRANCH`, `BUILD_REPOSITORY_DEFAULTBRANCH`,
    `AWF_DEFAULT_BRANCH`;
  - `AWF_TEST_CACHE_ROOT`, `AWF_TEST_HERMETIC_PATH`;
  - test-only `DOTNET_*` mock variables, only when `AWF_TEST_HERMETIC_PATH`
    is set.
- The Feed Reader message is byte-identical to the implement run's:
  `private feed restore failed (<first feed URL>): check that the build service has the Feed Reader role on the feed`
- Exit codes: 0 restored or nothing to do, 1 refused or failed, 2 usage
  (feeds set, `SYSTEM_ACCESSTOKEN` missing).
- Public repo: no organization, project, host or customer names in code,
  docs or tests.
- `CHANGELOG.md` has exactly one `## [Unreleased]` (around line 445). Add to
  its existing subsections; never create a second one (MD024).

## Review Focus

1. **The checkout's own `.git` was tampered with by an earlier job on a
   persistent agent:** a `filter.*` driver or an `include` in `.git/config`,
   or a non-empty `.git/info/attributes`. It would execute during
   `worktree add` with the token in the environment. Expected: refuse before
   writing the token. *Ruling: this goes beyond the spec's list but follows
   its trust model. It is cheap to check and is tested in Task 2.*
2. **`dotnet` resolves to a file the current user can write** (the image's
   `PATH` includes `/home/azp/.local/bin`). Expected: refuse. Tested in
   Task 3.
3. **The build is not for a PR** (manual queue), so `HEAD` is a single-parent
   commit. Expected: a clear refusal, not a restore of `HEAD~1`. Tested in
   Task 2.
4. **The restore fails half-way.** Expected: no `task.setvariable` line, the
   temporary config is gone, and the cleanup step still empties the cache.
   Tested in Tasks 3 and 4.
5. **`AWF_NUGET_FEEDS` holds only whitespace.** Expected: treated as blank,
   exit 0, no `dotnet` call (`feed_restore_enabled` already trims). Tested in
   Task 2.

---

### Task 1: Move the cache-path check into the library

**Files:**

- Modify: `scripts/lib/private-feed-restore.sh` (add the function next to
  `feed_cache_clear`)
- Modify: `scripts/implement-azdo.sh:214-234` (`preflight_cache` becomes a
  wrapper)
- Test: `tests/run-private-feed-restore-tests.sh`

**Interfaces:**

- Produces `feed_cache_path_check`. It takes no arguments and reads
  `AWF_NUGET_CACHE` and `AWF_TEST_CACHE_ROOT`.
  - On success it sets `AWF_NUGET_CACHE="${AWF_TEST_CACHE_ROOT:-}/var/cache/awf-nuget"`
    and returns 0.
  - Otherwise it prints the refusal on stderr and returns 1. The refusal text
    is today's `preflight_cache` text without the `private feed setup: `
    prefix, in three variants:
    - `AWF_NUGET_CACHE must be /var/cache/awf-nuget in a pipeline, not <value>`
    - `AWF_TEST_CACHE_ROOT must be an absolute path`
    - `the package cache <path> is a symlink or not a directory owned by <user>`
- `preflight_cache` in `implement-azdo.sh` keeps its behaviour:
  - It calls `feed_cache_path_check`.
  - On failure it sets
    `BOUNDARY_REFUSAL="private feed setup: <first line>"` and
    `REFUSAL_SECTION='§14'`, but only when `BOUNDARY_REFUSAL` is still empty.
  - On success it sets `FEED_CACHE_CHECKED=1`.

- [ ] **Step 1: Write failing lib tests** in `tests/run-private-feed-restore-tests.sh`,
  as a new section `feed_cache_path_check`:
  - `cache_path_check_default_accepted`: with `AWF_TEST_CACHE_ROOT=$TMP/r`
    and no existing dir, rc 0 and `AWF_NUGET_CACHE == $TMP/r/var/cache/awf-nuget`.
  - `cache_path_check_other_path_refused`: `AWF_NUGET_CACHE=/tmp/x` gives
    rc 1, stderr contains
    `AWF_NUGET_CACHE must be /var/cache/awf-nuget in a pipeline, not /tmp/x`.
  - `cache_path_check_relative_test_root_refused`: `AWF_TEST_CACHE_ROOT=rel`
    gives rc 1, stderr contains `must be an absolute path`.
  - `cache_path_check_symlink_refused`: the cache path is a symlink, giving
    rc 1 and stderr containing `is a symlink or not a directory owned by`.

- [ ] **Step 2: Run them and confirm they fail.**
  `bash tests/run-private-feed-restore-tests.sh` fails with
  `feed_cache_path_check: command not found`.

- [ ] **Step 3: Implement `feed_cache_path_check`** and reduce `preflight_cache`
  to the wrapper described above.

- [ ] **Step 4: Run both runners.**
  `bash tests/run-private-feed-restore-tests.sh && bash tests/run-implement-azdo-tests.sh`.
  Both pass, and no existing `implement-azdo` assertion changed.

- [ ] **Step 5: Commit** with
  `refactor(azdo): share the package-cache path check (#699)`.

### Task 2: Entry point — input guards

**Files:**

- Create: `scripts/azdo-pr-feed-restore.sh` (mode 0755)
- Create: `tests/run-azdo-pr-feed-restore-tests.sh` (mode 0755; picked up
  automatically by `tests/run-all.sh`)

**Interfaces:**

- Consumes:
  - `feed_restore_enabled`, `feed_restore_config_check` and
    `feed_restore_targets_syntax_check` from the library;
  - `feed_cache_path_check` from Task 1;
  - `bgit` from `scripts/lib/agent-boundary.sh`.
- Produces `scripts/azdo-pr-feed-restore.sh`. In this task it runs the guards
  in the order below. Each refusal prints `pr feed restore: <cause>` on
  stderr and exits 1, except guard 2, which exits 2.
  1. Blank `AWF_NUGET_FEEDS` (`feed_restore_enabled` fails): print
     `pr feed restore: AWF_NUGET_FEEDS is empty, nothing to restore` and
     exit 0.
  2. `SYSTEM_ACCESSTOKEN` empty: exit 2.
  3. `feed_restore_config_check`, `feed_restore_targets_syntax_check` and
     `feed_cache_path_check`: their first stderr line becomes the cause.
  4. `AWF_PR_RESTORE_WORK_DIR` is not absolute, or lies at or under
     `BUILD_SOURCESDIRECTORY` (compare `realpath -m`): refuse.
  5. Any ancestor directory of `AWF_PR_RESTORE_WORK_DIR`, up to `/`, holds
     one of these files: refuse and name the file.
     - `Directory.Build.props`, `Directory.Build.targets`,
       `Directory.Packages.props`, `Directory.Solution.props`,
       `Directory.Solution.targets`;
     - `nuget.config`, `NuGet.Config`, `NuGet.config`;
     - `global.json`.
  6. The checkout at `BUILD_SOURCESDIRECTORY` is tampered: refuse and name
     the key. That means `.git/config` contains a key matching
     `^(filter\.|include\.|includeif\.|core\.hookspath|core\.fsmonitor|core\.sshcommand|core\.gitproxy|uploadpack\.|credential\.)`,
     read with `git config --file .git/config --list --name-only`, or
     `.git/info/attributes` is non-empty.
  7. `HEAD` is not a commit with exactly two parents: refuse with
     `the build is not a PR merge commit; run this only from PR build validation`.
  8. The default branch is `BUILD_REPOSITORY_DEFAULTBRANCH`, or
     `refs/heads/${AWF_DEFAULT_BRANCH:-main}` when that is unset. If it is not
     equal to `SYSTEM_PULLREQUEST_TARGETBRANCH`, refuse with
     `the PR targets <target>, not the default branch <default>`.
  9. Resolve `SEED_SHA="$(bgit rev-parse HEAD^1)"`. Task 3 continues from
     here. In this task, print `pr feed restore: seed <sha>` and exit 0.

- [ ] **Step 1: Write the failing tests.**
  - Fixture helper `make_pr_checkout <dir>`:
    - `git init -b main`, commit A, branch `feature` with commit B;
    - check out a detached A, then `git merge --no-ff -m merge B`;
    - so `HEAD^1 == A`, and the helper echoes A's SHA.
  - Each case runs the script with `BUILD_SOURCESDIRECTORY=<dir>`,
    `AWF_PR_RESTORE_WORK_DIR=$TMP/w/<case>`,
    `SYSTEM_PULLREQUEST_TARGETBRANCH=refs/heads/main`,
    `BUILD_REPOSITORY_DEFAULTBRANCH=refs/heads/main`,
    `AWF_NUGET_FEEDS=<ADO feed URL>`, `SYSTEM_ACCESSTOKEN=tok-SECRET`,
    `AWF_TEST_CACHE_ROOT=$TMP/c` and
    `PATH=$ROOT/tests/mocks:$PATH`.
  - Cases:
    - `blank_feeds_exits_0_without_dotnet`: `AWF_NUGET_FEEDS='  '` gives
      rc 0, and `DOTNET_LOG` is absent.
    - `missing_token_exits_2`
    - `non_ado_feed_refused`: `https://example.com/v3/index.json` gives
      rc 1 and the stderr starts with `pr feed restore:`.
    - `work_dir_inside_sources_refused`
    - `ancestor_directory_build_props_refused`: plant
      `$TMP/w/Directory.Build.props`; rc 1, and stderr names
      `Directory.Build.props`.
    - `git_filter_in_checkout_config_refused`:
      `git config filter.x.smudge cat`; rc 1, stderr names `filter.x.smudge`.
    - `info_attributes_refused`
    - `single_parent_head_refused`
    - `target_not_default_refused`:
      `SYSTEM_PULLREQUEST_TARGETBRANCH=refs/heads/agent/x`
    - `default_branch_falls_back_to_main`:
      `BUILD_REPOSITORY_DEFAULTBRANCH` unset gives rc 0.
    - `seed_is_first_parent`: stdout contains `seed <A's sha>`.
    - `token_never_printed`: in no case does stdout or stderr contain
      `tok-SECRET`.

- [ ] **Step 2: Run and confirm failure.**
  `bash tests/run-azdo-pr-feed-restore-tests.sh` fails: no such script.

- [ ] **Step 3: Implement the guards.** Use one small function per guard
  (≤20 lines each) and a `main` that calls them in order.

- [ ] **Step 4: Run the tests and shellcheck.**
  `bash tests/run-azdo-pr-feed-restore-tests.sh && shellcheck -x -e SC1091 scripts/azdo-pr-feed-restore.sh tests/run-azdo-pr-feed-restore-tests.sh`.
  Both pass.

- [ ] **Step 5: Commit** with
  `feat(azdo): guard the PR-validation feed restore (#699)`.

### Task 3: Entry point — hermetic restore and handoff

**Files:**

- Modify: `scripts/azdo-pr-feed-restore.sh`
- Modify: `tests/mocks/dotnet`. Add a `DOTNET_ENV_LOG` option that dumps
  `env` (sorted, the values of `SYSTEM_ACCESSTOKEN` and
  `AZURE_DEVOPS_EXT_PAT` replaced by `<set>`) to that file.
- Test: `tests/run-azdo-pr-feed-restore-tests.sh`

**Interfaces:**

- Consumes `feed_pre_restore <seed-ref> <work-dir>` (rc 0 ok, 1 failed,
  2 nothing to restore) and `FEED_URLS` (filled by `feed_list`) from the
  library.
- Produces the full behaviour of `scripts/azdo-pr-feed-restore.sh`:
  - **Re-exec.** At the very top, before sourcing anything, when
    `AWF_PR_RESTORE_HERMETIC` is not `1`:
    - create `h="$(mktemp -d)"` with mode 0700;
    - `exec env -i` with `HOME=$h`, `DOTNET_CLI_HOME=$h`,
      `NUGET_PLUGIN_PATHS=$h/no-plugins`, `GIT_CONFIG_GLOBAL=/dev/null`,
      `GIT_CONFIG_NOSYSTEM=1`, and `PATH` set to the fixed `PATH` (or
      `AWF_TEST_HERMETIC_PATH`);
    - set `DOTNET_CLI_TELEMETRY_OPTOUT=1` and
      `DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1`;
    - set `ImportUserLocationsByWildcardBeforeMicrosoftCommonProps=false`,
      `ImportUserLocationsByWildcardAfterMicrosoftCommonProps=false`,
      `ImportUserLocationsByWildcardBeforeMicrosoftCommonTargets=false` and
      `ImportUserLocationsByWildcardAfterMicrosoftCommonTargets=false`;
    - set `AWF_PR_RESTORE_HERMETIC=1`, plus the pass-through allowlist from
      Global Constraints;
    - run `bash "$0"`.
    - The temp dir is removed by an EXIT trap in the re-executed process
      (pass its path as `AWF_PR_RESTORE_HOME`).
  - **dotnet trust check**, after the guards:
    - `command -v dotnet` must resolve, through `realpath`, to a file that
      neither it nor its directory is writable (`-w`) by the current user;
    - otherwise refuse with `dotnet at <path> is writable by <user>`.
  - **Restore.**
    - `export AZURE_DEVOPS_EXT_PAT="$SYSTEM_ACCESSTOKEN"`;
    - `mkdir -p` the work dir;
    - run `feed_pre_restore "$SEED_SHA" "$work_dir"` from inside
      `BUILD_SOURCESDIRECTORY`, with stderr to a cause file in the work dir;
    - replay the cause file to stderr.
    - rc 2: print `private feed restore: <first cause line>` and exit 1.
    - rc 1: print the Feed Reader message for `${FEED_URLS[0]}` and exit 1.
  - **Handoff.** On rc 0 only, print exactly
    `##vso[task.setvariable variable=NUGET_FALLBACK_PACKAGES]<cache path>`
    and exit 0.

- [ ] **Step 1: Write the failing tests.** Run them with
  `AWF_TEST_HERMETIC_PATH=$TMP/bin`. `$TMP/bin` holds a copy of
  `tests/mocks/dotnet` plus symlinks to `bash`, `git`, `env`, `mktemp`,
  `realpath`, `rm`, `mkdir`, `chmod`, `cat`, `head`, `find`, `cp`, `stat`,
  `dirname`, `sort`, `id` and `sed`. The directory and the copy are
  `chmod a-w`.
  - `restore_runs_on_seed_worktree`: the `DOTNET_LOG` `head=` line equals
    A's SHA and the `pwd=` line is under the work dir.
  - `token_not_in_argv`: the `argv=` lines lack `tok-SECRET`.
  - `temp_config_removed`: no `feed-config.*` remains under the work dir.
  - `hermetic_env`:
    - the `DOTNET_ENV_LOG` has `HOME` different from the caller's;
    - it has `GIT_CONFIG_GLOBAL=/dev/null`;
    - all four `ImportUserLocationsByWildcard…=false` switches are present;
    - it contains no `CANARY_VAR` that the test exported before running.
  - `planted_global_hook_not_run`:
    - the caller's `HOME` holds a `.gitconfig` with `core.hooksPath` set to
      a dir whose `post-checkout` touches `$TMP/hook-ran`;
    - after the run, `$TMP/hook-ran` does not exist.
  - `writable_dotnet_refused`: chmod `u+w` on the mock gives rc 1 and stderr
    containing `is writable by`.
  - `success_emits_setvariable`: stdout has the exact `##vso[...]` line with
    `$TMP/c/var/cache/awf-nuget`.
  - `restore_failure_message_and_no_setvariable`:
    - with `DOTNET_MOCK_FAIL=1`, rc is 1;
    - stderr contains the exact Feed Reader message for the test's feed URL;
    - stdout lacks `task.setvariable`.
  - `nothing_to_restore`:
    - in a fixture with no `.sln` or `*proj` at the root, rc is 1;
    - stderr starts with `private feed restore: no solution or project`.
  - The fixture from Task 2 gains `Sample.sln` in commit A, so the success
    cases have a restore target.

- [ ] **Step 2: Run and confirm failure** of the new cases.

- [ ] **Step 3: Implement the re-exec, trust check, restore and handoff.**
  Replace Task 2's temporary `seed <sha>` print with the restore. Keep the
  `seed_is_first_parent` assertion green by asserting the `head=` line
  instead, and update that case.

- [ ] **Step 4: Run** the new runner, `run-private-feed-restore-tests.sh` and
  shellcheck. All pass.

- [ ] **Step 5: Commit** with
  `feat(azdo): restore private feeds for PR validation (#699)`.

### Task 4: Cleanup entry point

**Files:**

- Create: `scripts/azdo-pr-feed-cleanup.sh` (mode 0755)
- Test: `tests/run-azdo-pr-feed-restore-tests.sh`

**Interfaces:**

- Consumes `feed_cache_path_check` and `feed_cache_clear`.
- Produces `scripts/azdo-pr-feed-cleanup.sh`:
  - When `feed_cache_path_check` passes, run `feed_cache_clear` and exit
    with its rc (0 when the cache is absent).
  - When the check refuses, print `pr feed cleanup: <cause>` and exit 1.
  - It needs no token and does not re-exec.

- [ ] **Step 1: Write the failing tests.**
  - `cleanup_empties_cache`: a file under `$TMP/c/var/cache/awf-nuget/x`
    is gone and the folder stays.
  - `cleanup_absent_cache_ok`: rc 0.
  - `cleanup_symlink_refused`: rc 1.
- [ ] **Step 2: Run and confirm failure.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the runner and shellcheck. Both pass.
- [ ] **Step 5: Commit** with
  `feat(azdo): clear the package cache after PR validation (#699)`.

### Task 5: Template and documentation

**Files:**

- Modify: `templates/azdo/pr-validation.yml`
- Modify: `docs/AZDO-PIPELINE-SETUP.md`:
  - §9.2 item 2;
  - a new §9.6 after §9.5;
  - one sentence in §14 before §14.1.
- Modify: `docs/AZDO-CUTOVER.md` (the step-6 PR build validation checkbox,
  around line 179)
- Modify: `CHANGELOG.md`, adding to the existing `## [Unreleased]`
  subsections only.
- Test: `tests/run-azdo-pr-feed-restore-tests.sh` (template assertions)

**Interfaces:**

- Consumes the script paths from Tasks 2–4, and the `AGENT_WORKFLOW_REF`
  variable already documented in §7.

- [ ] **Step 1: Write failing template assertions** in the runner, with
  plain `grep` on `templates/azdo/pr-validation.yml`.
  - `template_fetch_depth_2`: `fetchDepth: 2`.
  - `template_token_only_in_restore_step`:
    - `System.AccessToken` occurs exactly once;
    - that occurrence is in the block whose `bash:` line names
      `azdo-pr-feed-restore.sh`.
  - `template_feed_steps_conditional`: three occurrences of
    `ne(variables['AWF_NUGET_FEEDS'], '')`.
  - `template_cleanup_always`: `always()` occurs on the cleanup step.
  - `template_build_step_has_no_env_token`: the block after
    `# --- BUILD/TEST` contains neither `System.AccessToken` nor
    `NUGET_FALLBACK_PACKAGES`.
  - `template_fetch_hermetic`: the fetch block contains
    `GIT_CONFIG_GLOBAL=/dev/null` and `core.hooksPath=/dev/null`.

- [ ] **Step 2: Run and confirm failure.**

- [ ] **Step 3: Edit the template** to match the spec's YAML block exactly.
  Keep the existing header comment, and add one line under it:
  `With private feeds see docs/AZDO-PIPELINE-SETUP.md section 9.6.`

- [ ] **Step 4: Edit the docs.**
  - **§9.2 item 2:** "Create it with **no secret** variables". Name the three
    non-secret variables that are allowed (`AGENT_WORKFLOW_REF`,
    `AWF_NUGET_FEEDS`, `AWF_NUGET_RESTORE`), and say they are needed only for
    §9.6.
  - **§9.6 "Private feeds"** covers, in this order:
    - what the trusted steps do, and why they restore the target branch
      (`HEAD^1` of the merge commit);
    - which variables to set;
    - that no extra Feed Reader grant is needed (same build service as §14.3);
    - the **fresh agent per job** precondition;
    - that the PR must target the default branch;
    - that a PR adding or raising a private reference stays red and needs
      *Bypass policies when completing pull requests* plus an override;
    - that the tracked `nuget.config` must not list the private feed;
    - the refusal messages and what each means.
  - **§14:** "PR build validation restores the same feeds: section 9.6."
  - **AZDO-CUTOVER:** append to the validation checkbox:
    "with private feeds, also 9.6".
  - **CHANGELOG `Added`:** "Azure DevOps PR build validation restores private
    NuGet feeds from the target branch (#699)."
  - **CHANGELOG `Changed`:** "The package-cache path check is shared by the
    implement run and PR validation."

- [ ] **Step 5: Verify.**
  - `bash tests/run-all.sh` passes.
  - `npx --no-install markdownlint-cli2 docs/AZDO-PIPELINE-SETUP.md docs/AZDO-CUTOVER.md CHANGELOG.md`
    reports 0 issues.
  - `grep -c '^## \[Unreleased\]' CHANGELOG.md` prints `1`.

- [ ] **Step 6: Commit** with
  `docs(azdo): wire private feeds into PR validation (#699)`.
