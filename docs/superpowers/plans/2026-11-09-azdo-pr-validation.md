# Azure DevOps PR Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Azure DevOps consumers a secret-free, copy-paste PR validation pipeline that is a required gate for agent PRs. Also stop `implement-azdo.sh` from opening a PR when the agent touched pipeline files.

**Architecture:** A sourceable guard library (`scripts/lib/pipeline-file-guard.sh`) diffs the agent branch against the default branch and matches the changed paths against pipeline-file globs. `implement-azdo.sh` calls it between the "still on default branch" check and the push/PR block. A static YAML template (`templates/azdo/pr-validation.yml`) is checked by a Layer-1 runner that parses it with PyYAML and proves each assertion against a bad fixture. The setup guide gains §9. The live proof is run by the orchestrator in the sandbox.

**Tech Stack:** Bash 5 (`set -euo pipefail`, `IFS=$'\n\t'`), git, Python 3 + PyYAML (test only), Azure Pipelines YAML, shellcheck.

**Spec:** `docs/superpowers/specs/2026-11-09-azdo-pr-validation-design.md`

## Global Constraints

- The repo is **public**. Never write an org, pool, host, project or work-repo name. Use `<org>`, `<pool>`, `<project>`. Test fixtures keep the existing fake `contoso/MyProject/my-repo`.
- Every new script starts with `#!/usr/bin/env bash`, `set -euo pipefail` and `IFS=$'\n\t'`. The library is sourced, so it only *defines* functions and must not change the caller's shell options.
- Default pipeline-file globs, verbatim: `azure-pipelines*.yml`, `azure-pipelines*.yaml`, `.azure-pipelines/**`, `.azuredevops/**`.
- `PIPELINE_FILE_GLOBS`: comma-separated, **additive only**, and it can never remove a default.
- Template: `trigger: none`, `pr: none`, `checkout: self` with `persistCredentials: false`. No `env:` mapping of `System.AccessToken`, no variable group, and `pool: <pool>`. The header says "copy into your repo as `azure-pipelines-pr.yml`".
- A pipeline-file hit means exit 1, no push and no PR call.
- Layer-1 tests are hermetic: no network. Each new `tests/run-*-tests.sh` is picked up by `tests/run-all.sh` automatically, so do not edit `run-all.sh` or the `justfile`.
- `shellcheck -x -e SC1091` must pass on every new or changed `.sh` file. Run lint only after `git add`, because untracked files are skipped.
- Commit messages: Conventional Commits, scope `azdo`, with `(#573)` in the subject.

## Review Focus

1. **Rename out of a pipeline path.** `git mv azure-pipelines-pr.yml x.yml` must be caught. With default rename detection `--name-only` shows only `x.yml`, so the guard uses `--no-renames`. Task 1 tests this.
2. **A pipeline file in a subdirectory.** `ci/azure-pipelines.yml` must be caught. A glob with no `/` matches the path's basename, and a glob with `/` matches the full path. Task 1 tests this.
3. **The diff cannot be computed.** If the base ref is missing or there is no merge base in a shallow clone, the guard must fail closed: non-zero with a message, never 0. Task 1 tests this, and Task 2 tests that the driver exits 1.
4. **Messy `PIPELINE_FILE_GLOBS`.** Values like `" ci/*.yml , ,deploy/** "` are trimmed and empty entries skipped. Neither `*` nor an empty value may disable the defaults. Task 1 tests this.
5. **`$(System.AccessToken)` macro-expanded inside a `script:` body**, not in `env:`. This leaks the token just the same. The template test scans every string value in the document, not only `env`. Task 3 tests this.

---

### Task 1: `pipeline_file_guard` library

**Files:**
- Create: `scripts/lib/pipeline-file-guard.sh`
- Test: `tests/run-pipeline-file-guard-tests.sh` (new runner, auto-discovered)

**Interfaces:**
- Consumes: nothing.
- Produces: `pipeline_file_guard <base-ref>`, defined when the file is sourced.
  - Return **0**: no changed path matches.
  - Return **1**: at least one path matches. Each offending path goes to stderr, one per line, as `  <path>`.
  - Return **2**: the diff could not be computed, for example an unknown base ref or no merge base. A one-line `pipeline_file_guard: cannot diff <base-ref>...HEAD` goes to stderr.
  - Callers treat any non-zero as "do not push". The code 2 extends the fixed 0/1 contract for the fail-closed case.
  - Reads env `PIPELINE_FILE_GLOBS` (optional).
  - Prints nothing to stdout.

- [ ] **Step 1: Write the failing runner**

Model the harness on `tests/run-implement-azdo-tests.sh`: `pass`/`fail`/`assert_eq`/`assert_contains`, a summary, and exit 1 on any failure. Add a helper `make_repo` that creates a temp repo with `git init -q -b main`, a commit with `README.md`, and `git update-ref refs/remotes/origin/main HEAD`, then `git checkout -q -b agent/x`. Each case commits its change on `agent/x`, then runs `( cd "$repo" && source "$ROOT/scripts/lib/pipeline-file-guard.sh" && pipeline_file_guard origin/main )` and captures rc and stderr. Use `env -u PIPELINE_FILE_GLOBS` unless the case sets it.

| Test name | Change on `agent/x` | Env | rc | stderr contains |
|---|---|---|---|---|
| `src_only_passes` | add `src/app.cs` | — | 0 | (empty) |
| `root_yml_blocked` | add `azure-pipelines-pr.yml` | — | 1 | `azure-pipelines-pr.yml` |
| `root_yaml_blocked` | add `azure-pipelines.yaml` | — | 1 | `azure-pipelines.yaml` |
| `nested_basename_blocked` | add `ci/azure-pipelines.yml` | — | 1 | `ci/azure-pipelines.yml` |
| `dot_azure_pipelines_deep_blocked` | add `.azure-pipelines/a/b.yml` | — | 1 | `.azure-pipelines/a/b.yml` |
| `dot_azuredevops_blocked` | add `.azuredevops/policies.yml` | — | 1 | `.azuredevops/policies.yml` |
| `deletion_blocked` | base has `azure-pipelines-pr.yml`; branch deletes it | — | 1 | `azure-pipelines-pr.yml` |
| `rename_out_blocked` | base has `azure-pipelines-pr.yml`; branch `git mv` to `x.yml` | — | 1 | `azure-pipelines-pr.yml` |
| `all_offenders_listed` | add `azure-pipelines-pr.yml` + `.azuredevops/a.yml` + `src/a.cs` | — | 1 | both pipeline paths; not `src/a.cs` |
| `extra_glob_adds_path` | add `deploy/build.yml` | `PIPELINE_FILE_GLOBS='deploy/**'` | 1 | `deploy/build.yml` |
| `extra_glob_trimmed_and_empty_skipped` | add `deploy/build.yml` | `PIPELINE_FILE_GLOBS=' ci/*.yml , ,deploy/** '` | 1 | `deploy/build.yml` |
| `extra_glob_cannot_remove_defaults` | add `azure-pipelines-pr.yml` | `PIPELINE_FILE_GLOBS=''` | 1 | `azure-pipelines-pr.yml` |
| `unknown_base_fails_closed` | add `src/app.cs`; call with `origin/nope` | — | 2 | `cannot diff` |
| `uncommitted_pipeline_edit_ignored` | commit `src/app.cs`; leave `azure-pipelines-pr.yml` untracked | — | 0 | (empty) |

For the base-side cases, commit the pipeline file on `main` before running `update-ref` and creating the branch. The last row is pinned on purpose: only committed changes are pushed, so only they matter.

- [ ] **Step 2: Run it and confirm it fails**

Run: `bash tests/run-pipeline-file-guard-tests.sh`
Expected: FAIL, because `scripts/lib/pipeline-file-guard.sh` does not exist.

- [ ] **Step 3: Implement `pipeline_file_guard` in `scripts/lib/pipeline-file-guard.sh`**

Header comment: purpose (C6), the default globs, `PIPELINE_FILE_GLOBS`, the return codes above, and the matching rule.

Approach:
- `git diff --name-only --no-renames -z "$base...HEAD"`, read with `mapfile -d ''`. If the diff fails, return 2. Use a temp file or a `||` check, so a failed process substitution is not mistaken for an empty diff.
- Build the glob list from the four defaults plus `PIPELINE_FILE_GLOBS`. Split on `,` with a local `IFS=,` read, trim leading and trailing whitespace from each entry, and skip empty entries.
- Matching:
  - A glob containing `/` is tested as `[[ $path == $glob ]]` on the full path (bash `*` crosses `/`, so `**` behaves like `*`).
  - A glob with no `/` is tested against `${path##*/}`.
  - Disable the SC2053 warning (unquoted right-hand side) with a reason comment, because the right-hand side is intentionally a pattern.
- Keep each function at 20 lines or fewer: split out `_pfg_globs` and `_pfg_matches <path>`.

- [ ] **Step 4: Run it and confirm it passes**

Run: `bash tests/run-pipeline-file-guard-tests.sh`
Expected: all ✓, exit 0.

- [ ] **Step 5: Lint**

Run: `git add scripts/lib/pipeline-file-guard.sh tests/run-pipeline-file-guard-tests.sh && shellcheck -x -e SC1091 scripts/lib/pipeline-file-guard.sh tests/run-pipeline-file-guard-tests.sh`
Expected: no output, exit 0.

- [ ] **Step 6: Commit**

```bash
git commit -m "feat(azdo): add pipeline-file guard library (#573)"
```

### Task 2: Wire the guard into `implement-azdo.sh`

**Files:**
- Modify: `scripts/implement-azdo.sh`: source the library next to the other `source` lines; add the guard call right after the `still on %s` block and before the `git ls-remote` push block; document it in the header (new section "Pipeline-file guard", exit 1).
- Create: `tests/mocks/claude`, an executable stand-in for the Claude CLI.
- Modify: `tests/run-implement-azdo-tests.sh`: add a non-dry `run_agent_driver` helper and a "pipeline-file guard" section.

**Interfaces:**
- Consumes: `pipeline_file_guard <base-ref>` from Task 1.
- Produces:
  - The driver contract: when the guard returns non-zero, the driver prints `error: the agent changed pipeline files; refusing to push or open a PR:` to stderr, followed by the guard's path lines, and exits 1.
  - `tests/mocks/claude`, with this contract:
    - It drains stdin.
    - It runs `git checkout -q -b "${CLAUDE_MOCK_BRANCH:-agent/test}"`.
    - For each comma-separated path in `CLAUDE_MOCK_TOUCH`, it creates the file (parent dirs included) and commits all of them in one commit.
    - It prints `$CLAUDE_MOCK_RESULT` (a JSON fixture path) to stdout.
    - It exits 0.

- [ ] **Step 1: Write the mock and the failing driver tests**

`run_agent_driver` mirrors `run_driver`, with these differences:
- It omits `DRY_RUN=1`.
- It passes `AZURE_DEVOPS_EXT_PAT=pat`, `CLAUDE_MOCK_RESULT=$FIXTURES/result-success-cheap.json` and `AZ_MOCK_LOG=$TMP/az.log`.
- It passes `GIT_ALLOW_PROTOCOL=file`. With that set, `git ls-remote` and `git push` against the fake `https://dev.azure.com/...` origin fail at once with "transport 'https' not allowed" and never touch the network.
- It passes the git identity variables (`GIT_AUTHOR_NAME`/`EMAIL`, `GIT_COMMITTER_NAME`/`EMAIL`), because `env -i` drops them.
- It resets the repo before each case:
  - `git checkout -q main`;
  - delete `agent/test`;
  - `git update-ref refs/remotes/origin/main main`.

  So `REPO_AZ` needs an initial commit on `main` (`git init -q -b main` plus one commit), added in the existing setup block. The existing dry-run cases must still pass.
- It truncates `$TMP/az.log` before each case.

Cases:

| Test name | Env | Assertions |
|---|---|---|
| `pipeline_file_blocks_run` | `CLAUDE_MOCK_TOUCH=azure-pipelines-pr.yml` | rc `1`; stderr contains `refusing to push or open a PR` and `azure-pipelines-pr.yml`; `az.log` does not contain `repos pr create`; stderr does not contain `could not push` |
| `src_only_proceeds_past_guard` | `CLAUDE_MOCK_TOUCH=src/app.cs` | stderr does not contain `pipeline files`; stderr contains `could not push` (it reached the push, which `GIT_ALLOW_PROTOCOL` stops); rc `1` |
| `extra_glob_blocks_run` | `CLAUDE_MOCK_TOUCH=deploy/build.yml`, `PIPELINE_FILE_GLOBS=deploy/**` | rc `1`; stderr contains `deploy/build.yml`; `az.log` does not contain `repos pr create` |
| `missing_base_ref_blocks_run` | `CLAUDE_MOCK_TOUCH=src/app.cs`, and delete `refs/remotes/origin/main` before the run | rc `1`; stderr contains `cannot diff`; stderr does not contain `could not push` |

- [ ] **Step 2: Run them and confirm they fail**

Run: `bash tests/run-implement-azdo-tests.sh`
Expected: `pipeline_file_blocks_run`, `extra_glob_blocks_run` and `missing_base_ref_blocks_run` fail, because the driver reaches `could not push` instead. `src_only_proceeds_past_guard` may already pass. The dry-run cases pass.

If a case fails earlier than the push (for example in `build-agent-prompt.sh` or `classify-failure.sh`), fix the test environment (missing env, fixture or mock). Do not fix it in the driver.

- [ ] **Step 3: Add the guard call in `scripts/implement-azdo.sh`**

`pipeline_file_guard "origin/$default_branch"`, placed after the default-branch check and before the `git ls-remote` line. On non-zero, print the error line from Interfaces and `exit 1`. The guard's own stderr already lists the paths. Do not post a work-item comment here. On Pipelines, the `azdo-report-failure` step does that.

- [ ] **Step 4: Run the full suite**

Run: `bash tests/run-implement-azdo-tests.sh && bash tests/run-all.sh`
Expected: all ✓; `runners: N   failed: 0`.

- [ ] **Step 5: Lint**

Run: `git add tests/mocks/claude tests/run-implement-azdo-tests.sh scripts/implement-azdo.sh && shellcheck -x -e SC1091 tests/mocks/claude tests/run-implement-azdo-tests.sh scripts/implement-azdo.sh`
Expected: exit 0.

- [ ] **Step 6: Commit**

```bash
git commit -m "feat(azdo): refuse to push agent changes to pipeline files (#573)"
```

### Task 3: PR validation template and its Layer-1 test

**Files:**
- Create: `templates/azdo/pr-validation.yml`
- Create: `tests/run-azdo-templates-tests.sh` (auto-discovered by `tests/run-all.sh`)
- Create: `tests/fixtures/azdo-templates/bad-trigger.yml`, `bad-pr.yml`, `bad-persist-credentials.yml`, `bad-env-access-token.yml`, `bad-env-system-accesstoken.yml`, `bad-env-claude.yml`, `bad-script-macro.yml`, `bad-variable-group.yml`, `bad-nested-variable-group.yml`

**Interfaces:**
- Consumes: nothing.
- Produces: the template. It is the file §9 of the guide (Task 4) tells consumers to copy.

- [ ] **Step 1: Write the failing runner and the bad fixtures**

The runner defines `check_template <file>`. It runs `python3 - "$file"` with a heredoc checker that loads the YAML (`yaml.safe_load`), walks the document recursively, prints one violation per line, and exits 1 if there are any. Violations to detect:
- `trigger_not_none`: top-level `trigger` is not the string `none`.
- `pr_not_none`: top-level `pr` is not the string `none`.
- `persist_credentials`: any mapping with a `checkout` key whose `persistCredentials` is truthy.
- `env_secret`: any mapping under an `env` key whose value, as a string, matches `System.AccessToken`, `SYSTEM_ACCESSTOKEN` or `CLAUDE` (case-insensitive for `CLAUDE`), or whose key matches `CLAUDE` or `SYSTEM_ACCESSTOKEN`.
- `access_token_anywhere`: any string value anywhere in the document containing `System.AccessToken` or `SYSTEM_ACCESSTOKEN`. This covers Review Focus 5. Comments are not parsed, so the template's header may mention the token.
- `variable_group`: any `variables` list, at any depth, containing a mapping with a `group` key.

If `python3 -c 'import yaml'` fails, print `SKIP: PyYAML not available` and exit 0.

Assertions:

| Test name | Input | Expected |
|---|---|---|
| `template_is_clean` | `templates/azdo/pr-validation.yml` | rc 0, no output |
| `template_has_pool_placeholder` | template text | contains `pool: <pool>` (grep) |
| `template_header_names_target` | template text | contains `azure-pipelines-pr.yml` |
| `template_persist_credentials_false` | template text | contains `persistCredentials: false` |
| `detects_<name>` (one per fixture) | each `bad-*.yml` | rc 1; output contains that fixture's violation id |

Each bad fixture is the good template with exactly one defect:
- `bad-script-macro.yml`: has `script: echo $(System.AccessToken)` and no `env`.
- `bad-nested-variable-group.yml`: puts `- group: x` under a job's `variables`.

- [ ] **Step 2: Run it and confirm it fails**

Run: `bash tests/run-azdo-templates-tests.sh`
Expected: `template_is_clean` and the grep cases fail (the template is missing). Every `detects_*` case passes, which proves the checker can fail.

- [ ] **Step 3: Write `templates/azdo/pr-validation.yml`**

About 30 lines. It needs:
- A comment header:
  - "Copy into your repo as `azure-pipelines-pr.yml`".
  - Triggered by a build-validation branch policy, not by YAML.
  - Never link a variable group or map `System.AccessToken`: this runs agent-written code.
  - See `docs/AZDO-PIPELINE-SETUP.md` §9.
- `trigger: none`
- `pr: none`
- `pool: <pool>`
- `steps:`:
  - `- checkout: self` with `persistCredentials: false`, and `fetchDepth` left at the default.
  - One clearly marked `# --- BUILD/TEST: edit this step only ---` script step. Its default is `dotnet build` then `dotnet test --no-build`, with a comment that non-.NET repos replace it (`true` as the minimal placeholder).

- [ ] **Step 4: Run it and confirm it passes**

Run: `bash tests/run-azdo-templates-tests.sh && bash tests/run-all.sh`
Expected: all ✓; `failed: 0`.

- [ ] **Step 5: Lint**

Run: `git add templates/azdo tests/fixtures/azdo-templates tests/run-azdo-templates-tests.sh && shellcheck -x -e SC1091 tests/run-azdo-templates-tests.sh`
Expected: exit 0.

- [ ] **Step 6: Commit**

```bash
git commit -m "feat(azdo): add secret-free PR validation pipeline template (#573)"
```

### Task 4: Setup guide §9 and changelog

**Files:**
- Modify: `docs/AZDO-PIPELINE-SETUP.md`: append `## 9. PR build validation`.
- Modify: `CHANGELOG.md`: add an `## [Unreleased]` section above `## [2.1.0]` (create it if absent) with an `### Added` entry.

**Interfaces:**
- Consumes: the template path from Task 3, and the guard's globs and env var from Task 1.
- Produces: docs only.

- [ ] **Step 1: Write §9**

Subsections, using `<org>`, `<project>` and `<pool>` placeholders only:
1. **Add the pipeline file.** Copy `templates/azdo/pr-validation.yml` to `azure-pipelines-pr.yml` in the repo root and edit only the build/test step. Do this through a human PR, because the agent cannot (see 9.4).
2. **Create the pipeline.** Use *Pipelines > New pipeline > Azure Repos Git > Existing YAML file* and pick `azure-pipelines-pr.yml`. Create it with **no** variables, and link **no** variable group. Never put `CLAUDE_CODE_OAUTH_TOKEN` here. Variables are per pipeline, so it inherits nothing from the `ai-implement` pipeline. Turn on *Project settings > Pipelines > Settings > Limit job authorization scope to current project*. Note that a build service token is still issued to the job, but no step sees it unless it is mapped, and the template maps none.
3. **Require it on the default branch.** Go to *Repos > Branches > `<default>` > Branch policies > Build validation > +*, then:
   - pick the pipeline;
   - set Trigger to **Automatic**;
   - set Policy requirement to **Required**;
   - set Build expiration to **Immediately when `<default>` is updated**.

   Explain that `pr:` in YAML is ignored on Azure Repos, which is why the template says `pr: none`.
4. **Pipeline files are changed by humans.** An `ai-implement` run whose changes touch these globs fails before the push and opens no PR, and its log names the files:
   - `azure-pipelines*.yml`
   - `azure-pipelines*.yaml`
   - `.azure-pipelines/**`
   - `.azuredevops/**`

   Explain the matching rule: a glob without `/` matches the file name at any depth. Explain how to add paths with the pipeline variable `PIPELINE_FILE_GLOBS` (comma-separated, additive only). State the limitation: if the agent pushed the branch itself, the ref stays on the server, but no PR is opened, so no validation run is queued.
5. **Draft PRs.** Write `Whether the policy runs on a draft PR: <to be recorded by the live proof>`. The orchestrator fills this in during Task 5. Either answer is acceptable (C7).

- [ ] **Step 2: Add the changelog entry**

`### Added`: PR build validation template for Azure DevOps (`templates/azdo/pr-validation.yml`, setup guide §9), and `implement-azdo.sh` refusing to push agent changes to pipeline files (`PIPELINE_FILE_GLOBS`) (#573).

- [ ] **Step 3: Verify**

Run: `grep -n '^## 9\. PR build validation' docs/AZDO-PIPELINE-SETUP.md && grep -n 'PIPELINE_FILE_GLOBS' docs/AZDO-PIPELINE-SETUP.md CHANGELOG.md && bash tests/run-all.sh`
Expected: each grep finds a match; `failed: 0`. Also check by eye that the diff introduces no real org, pool or host name.

- [ ] **Step 4: Commit**

```bash
git add docs/AZDO-PIPELINE-SETUP.md CHANGELOG.md
git commit -m "docs(azdo): add PR build validation setup and pipeline-file rule (#573)"
```

### Task 5: Orchestrator-run live proof (sandbox)

**Not for implementer subagents.** The orchestrator performs these steps in the private sandbox project after Tasks 1–4 are merged, or are available on a pinned `AGENT_WORKFLOW_REF`. Sandbox names stay in the private sandbox repo and never go into this repo.

**Files:**
- Create: `docs/ai-notes/2026-11-XX-azdo-pr-validation-run.md` (use the actual date). It contains no org, pool, host or work-repo names.
- Modify: `docs/AZDO-PIPELINE-SETUP.md` §9.5 (the draft-PR answer).

- [ ] **Step 1: Install the validation pipeline.** Open a human PR in the sandbox repo that adds `azure-pipelines-pr.yml` from the template. Use `dotnet build` + `dotnet test` on item d's sample, or `true` if d has not landed. Create the pipeline (no variables) and the required build-validation policy, following §9. Merge it.
  Record: the pipeline is created with zero variables; the policy is Required/Automatic/expire-on-update.
- [ ] **Step 2: Red blocks completion.** Open a PR that breaks a test.
  Record: the check is red, and *Complete* is blocked with the policy named.
- [ ] **Step 3: Green passes.** Push a fix to the same PR.
  Record: the check is green and completion is allowed.
- [ ] **Step 4: Draft PR.** Trigger one `ai-implement` run on an ordinary work item.
  Record, verified and not assumed: does the build-validation policy queue a run on the agent's **draft** PR? Fill in §9.5 with the observed answer.
- [ ] **Step 5: Pipeline-file guard.** Tag a work item that asks the agent to edit `azure-pipelines-pr.yml`.
  Record:
  - the run fails;
  - the log shows `refusing to push or open a PR` and names the file;
  - no PR exists;
  - whether the branch reached the server (that is, whether the agent pushed it itself);
  - the failure comment appears on the work item.
- [ ] **Step 6: Secret check.** In the validation run's log of Step 3, confirm that no step's environment holds a token. Check `.git/config` has no `extraheader`.
  Record: the result.
- [ ] **Step 7: Write the run note and commit.** Write it as a checklist of Steps 1–6 with each observed result. Run the public-repo leak grep before committing.
  ```bash
  git add docs/ai-notes/2026-11-XX-azdo-pr-validation-run.md docs/AZDO-PIPELINE-SETUP.md
  git commit -m "docs(azdo): record PR validation live proof (#573)"
  ```
