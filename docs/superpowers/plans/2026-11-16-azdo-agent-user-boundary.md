# Azure DevOps Agent User Boundary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In Azure Pipelines runs, run the implement and self-fix agents as a second, credential-free Linux user (`awf-agent`) whose output the driver treats as hostile data.

**Architecture:** Three root-owned entry points in the agent image (`awf-agent-run`, `awf-agent-git`, `awf-agent-reap`) are the only things `azp` may run as `awf-agent`, through one sudoers rule with an environment allowlist. A driver library (`scripts/lib/agent-boundary.sh`) wraps them: it seeds the agent's own workspace from a bundle, runs the agent, reaps every agent process, and fetches the agent's commits back from a bundle into the driver's checkout (which the agent cannot write) with hooks off. `implement-azdo.sh` and the self-fix path use the library whenever `ci_host` is `pipelines`, and refuse to run an agent there without it. Local runs are unchanged.

**Tech Stack:** bash 5, git, jq, sudo, Docker (image only), Layer-1 bash tests with mocks in `tests/mocks/`.

**Spec:** `docs/superpowers/specs/2026-11-16-azdo-agent-user-boundary-design.md`

## Global Constraints

- Every script: `#!/usr/bin/env bash`, `set -euo pipefail`, `IFS=$'\n\t'`; no `eval`.
- `shellcheck -x -e SC1091` clean on every changed script; `bash tests/run-all.sh` green (`run-enrich-batch-doc-tests.sh` is known-flaky under the sweep: rerun it alone if it is the only failure).
- Tests mock `sudo`, `claude`, `az`; no network, no Docker, no real Azure DevOps.
- Boundary user: `awf-agent`. Entry point dir in the image: `/usr/local/libexec/awf-agent/`. Agent workspaces: under `/home/awf-agent/ws/`.
- Environment allowlist (sudoers `env_keep`), exactly: `CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY MODEL MAX_TURNS`.
- Entry point protocol version: `1` (each entry point prints `1` for `--protocol`).
- Result JSON cap: 65536 bytes. Branch names: `git check-ref-format --branch` AND `^[A-Za-z0-9._/-]{1,100}$`.
- Every git call on agent-produced data: `-c core.hooksPath=/dev/null -c core.fsmonitor=false`.
- The Azure DevOps token never appears in a process argv: authenticated git calls get `http.extraheader` through `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_0`/`GIT_CONFIG_VALUE_0`.
- Pipeline mode = `ci_host` prints `pipelines` (`scripts/lib/ci-host.sh`). Local mode behaviour, report wording and exit codes stay as they are.
- Public repo: no organisation, host or project names anywhere.
- Commits: Conventional Commits, scope `azdo`, footer `Part of #591` (not `Closes`), one commit per task.

## Review Focus

1. A sudo that exists but refuses (`no-new-privileges`, missing rule, wrong user) must fail closed with one line naming it, never fall back to running the agent as `azp` → Task 5 test `preflight_BoundaryRefused_ExitsBeforeAgent`.
2. An agent that leaves a background process (`sleep 999 &`) must not survive into the judging phase → Task 3 test `reap_SurvivorRemains_ReturnsFailure` and Task 5 test `attempt_ReapFails_InvalidEvidence`.
3. A hostile branch name in the bundle (`--upload-pack=x`, `../x`, 300 chars, `a b`) must fail the attempt closed, not reach a git command line → Task 3 test `valid_branch_name_RejectsHostileNames`.
4. A bundle whose commits do not descend from the attempt's base, or that carries a `.github`/pipeline file change, must not be pushed → Task 3 test `collect_WrongBase_Fails`, and the existing pipeline-file guard still runs (Task 5 test `attempt_PipelineFileInBundle_Refused`).
5. A consumer checkout persisted with credentials (`http.<url>.extraheader` set by `persistCredentials: true`) must make the pipeline run refuse before the agent starts → Task 3 test `checkout_has_credentials_DetectsExtraheader`, Task 5 test `preflight_CheckoutHasCredentials_Refuses`.

---

### Task 1: Boundary entry points

**Files:**
- Create: `docker/azp-agent/boundary/awf-agent-run`
- Create: `docker/azp-agent/boundary/awf-agent-git`
- Create: `docker/azp-agent/boundary/awf-agent-reap`
- Test: `tests/run-agent-boundary-entrypoint-tests.sh`

**Interfaces:**
- Produces (CLI contracts, all run as `awf-agent` via sudo):
  - `awf-agent-run --protocol` → prints `1`, exit 0.
  - `awf-agent-run <workspace> -- <claude-args...>` → `cd <workspace>` and `exec "$AWF_AGENT_CLAUDE" <claude-args...>` with the environment reduced to the allowlist plus `HOME=/home/awf-agent`, `PATH=/usr/local/bin:/usr/bin:/bin`. stdin/stdout pass through (prompt in, result out). `AWF_AGENT_CLAUDE` defaults to `/home/awf-agent/.local/bin/claude`.
  - `awf-agent-git --protocol` → `1`.
  - `awf-agent-git <workspace> seed <bundle-file> <branch-or-sha>` → clones the bundle into `<workspace>` (must not exist yet) and checks out `<branch-or-sha>` detached; sets the commit identity `ai-implement <ai-implement@noreply.invalid>` in the workspace config.
  - `awf-agent-git <workspace> commit <message>` → `git add -A` and commit when the tree is dirty; exit 3 when there is nothing to commit.
  - `awf-agent-git <workspace> bundle <base-sha>` → writes to stdout a bundle of `<base-sha>..HEAD` plus the current branch ref (or `HEAD` when detached); exit 3 when HEAD has no commit beyond `<base-sha>`.
  - `awf-agent-reap --protocol` → `1`. `awf-agent-reap` → `kill -KILL -1`, then prints the number of remaining processes of its own uid other than itself; exit 0 when 0, else 1.
  - Every entry point: `<workspace>` must resolve (realpath) to a direct child of `$AWF_WS_ROOT` (default `/home/awf-agent/ws`), else exit 2; every git call carries the Global Constraints' hook/fsmonitor flags; usage errors exit 2.

- [ ] **Step 1: Write the failing tests.** Run each entry point directly (no sudo), with `AWF_WS_ROOT=$TMP/ws`, `AWF_AGENT_CLAUDE=$ROOT/tests/mocks/claude`, and env polluted with `AZURE_DEVOPS_EXT_PAT=leak SYSTEM_ACCESSTOKEN=leak`:
  - `run_Protocol_PrintsOne`, `git_Protocol_PrintsOne`, `reap_Protocol_PrintsOne`.
  - `run_StripsCredentials`: a claude mock that dumps `env` to stdout; assert output contains `MODEL=` when set and does not contain `leak`.
  - `run_WorkspaceOutsideRoot_Exit2`: `<workspace>` = `$TMP/elsewhere` and `$TMP/ws/../elsewhere` → exit 2, mock not called.
  - `git_SeedCommitBundle_RoundTrip`: seed from a bundle of a two-commit repo at its first commit, create a file, `commit "x"`, `bundle <first-sha>` → `git bundle verify` passes in a fresh repo and `git bundle list-heads` names one commit.
  - `git_HooksIgnored`: after seed, write an executable `.git/hooks/pre-commit` that touches a marker; `commit` → marker absent.
  - `git_CommitClean_Exit3`, `git_BundleNoNewCommits_Exit3`.
  - `reap_KillsBackgroundProcess`: start `sleep 300 &` under the test user, run `awf-agent-reap` → the sleep is gone. Guard this test with `AWF_REAP_TEST=1` only inside a throwaway `unshare --user --pid --fork --mount-proc` namespace when available, else skip with a printed reason (it must never kill the developer's own processes).
- [ ] **Step 2: Run** `bash tests/run-agent-boundary-entrypoint-tests.sh` → FAIL (files missing).
- [ ] **Step 3: Implement** the three scripts per the contracts above.
- [ ] **Step 4: Run** the test → PASS; `shellcheck -x -e SC1091 docker/azp-agent/boundary/*` clean.
- [ ] **Step 5: Commit** `feat(azdo): add the agent user boundary entry points`.

### Task 2: Image and agent start

**Files:**
- Modify: `docker/azp-agent/Dockerfile`
- Create: `docker/azp-agent/sudoers-awf-agent`
- Modify: `scripts/azp-agent-start.sh`
- Test: `tests/run-azp-agent-dockerfile-tests.sh`, `tests/run-azp-agent-start-tests.sh`

**Interfaces:**
- Consumes: Task 1's three files.
- Produces: in the image, `/usr/local/libexec/awf-agent/{awf-agent-run,awf-agent-git,awf-agent-reap}` (root:root 0755), `/etc/sudoers.d/awf-agent` (root:root 0440), user `awf-agent` with home `/home/awf-agent` and `/home/awf-agent/ws`, and the Claude CLI installed for `awf-agent` at `/home/awf-agent/.local/bin/claude`.

The sudoers file, exactly:

```
Defaults:azp env_reset
Defaults:azp env_keep = "CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY MODEL MAX_TURNS"
azp ALL=(awf-agent) NOPASSWD: /usr/local/libexec/awf-agent/awf-agent-run, /usr/local/libexec/awf-agent/awf-agent-git, /usr/local/libexec/awf-agent/awf-agent-reap
```

- [ ] **Step 1: Write the failing tests** in `run-azp-agent-dockerfile-tests.sh` (awk-parsed, each with a mutated-copy negative case as the file already does): `sudo` in the apt list of stage `base`; `useradd` of `awf-agent` with a uid other than 1000 and no `-G azp`; `COPY` of the three entry points with `--chmod=0755` and of `sudoers-awf-agent` with `--chmod=0440` into the paths above, done before `USER 1000`; `install-claude-cli.sh` run once as `USER awf-agent`; `chmod 0700 /home/azp`. A static test on `sudoers-awf-agent`: its rule line names exactly the three paths, runas `awf-agent`, no `ALL` command, no `(root)`; `visudo -cf` passes when `visudo` exists (skip otherwise). In `run-azp-agent-start-tests.sh`: `start_SetsAgentDirMode0700` (the script runs `chmod 0700` on the agent dir before `run.sh --once`; assert on a temp dir with mode 0755).
- [ ] **Step 2: Run** both test files → FAIL.
- [ ] **Step 3: Implement** the Dockerfile changes, the sudoers file, and `chmod 0700 "$agent_dir"` in `azp-agent-start.sh` before the hand-over to `run.sh --once`.
- [ ] **Step 4: Run** both → PASS; `hadolint` if installed.
- [ ] **Step 5: Commit** `feat(azdo): add the awf-agent user and its sudo rule to the agent image`.

### Task 3: Driver boundary library

**Files:**
- Create: `scripts/lib/agent-boundary.sh`
- Create: `tests/mocks/sudo`
- Test: `tests/run-agent-boundary-lib-tests.sh`

**Interfaces:**
- Consumes: Task 1 contracts. `AWF_BOUNDARY_DIR` (default `/usr/local/libexec/awf-agent`), `AWF_WS_ROOT` (default `/home/awf-agent/ws`).
- Produces (functions; all return 0 on success, 1 on failure with one line on stderr naming the cause):
  - `boundary_check` — calls each entry point's `--protocol` through `sudo -n -u awf-agent`; fails unless all print `1`.
  - `boundary_new_workspace` → prints a fresh path `$AWF_WS_ROOT/<run-id>-<n>` (not created).
  - `boundary_seed <workspace> <bundle-dir> <ref>` — writes `git bundle create <bundle-dir>/seed.bundle <ref>` from the current checkout (mode 0644, dir 0711), then `awf-agent-git <workspace> seed <bundle> <ref>`.
  - `boundary_exec_claude <workspace> <claude-args...>` — `sudo -n -u awf-agent "$AWF_BOUNDARY_DIR/awf-agent-run" <workspace> -- <args...>`; stdin/stdout pass through.
  - `boundary_commit <workspace> <message>` — `awf-agent-git … commit`; returns 3 when nothing to commit.
  - `boundary_reap` — `awf-agent-reap`; fails when survivors remain.
  - `boundary_collect <workspace> <base-sha> <bundle-dir>` — bundle via stdout into `<bundle-dir>/out.bundle`; in the current checkout (azp-owned, never written by the agent): `git bundle verify`, `git fetch` the bundle's single head into `refs/awf/collected`, require `git merge-base --is-ancestor <base-sha> refs/awf/collected`, then prints the branch name the bundle carried (empty when detached). All git calls with the hook/fsmonitor flags.
  - `valid_branch_name <name>` — Global Constraints' rule.
  - `cap_file_bytes <file> <max>` — fails when the file is larger.
  - `checkout_has_credentials` — true when `git config --get-regexp '^http\..*extraheader$'` matches or any remote URL contains `@` before the host.
  - `azdo_git <git-args...>` — runs git with `GIT_CONFIG_COUNT=1`, `GIT_CONFIG_KEY_0=http.extraheader`, `GIT_CONFIG_VALUE_0=<Basic header>` in its environment only.
- `tests/mocks/sudo`: accepts `-n -u awf-agent <cmd> <args...>`, appends argv to `$SUDO_LOG`, fails with `sudo: a password is required` when `SUDO_MOCK_DENY=1`, else runs `<cmd>` under `env -i` with only the allowlist plus `AWF_*` and `PATH`/`HOME`.

- [ ] **Step 1: Write the failing tests:** `check_AllProtocolsOne_Succeeds`; `check_SudoDenied_FailsNamingSudo` (`SUDO_MOCK_DENY=1`, stderr contains `sudo`); `check_WrongProtocol_Fails` (an entry point stub printing `2`); `seed_collect_RoundTrip` (real Task 1 entry points via the mock; agent commits one file; collect prints the branch and `refs/awf/collected` has the commit); `collect_WrongBase_Fails` (bundle built on an unrelated root); `collect_HookInAgentRepo_NotRun` (agent workspace has `core.fsmonitor` and hooks set to touch markers; no marker after collect); `valid_branch_name_RejectsHostileNames` (`--upload-pack=x`, `../x`, `a b`, 101 chars, empty → reject; `ai/591-boundary` → accept); `cap_file_bytes_Over_Fails` (65537 bytes vs 65536); `checkout_has_credentials_DetectsExtraheader` (+ a clean repo → false); `azdo_git_TokenNotInArgv` (a `git` wrapper first in PATH dumps argv and the `GIT_CONFIG_*` env; argv lacks the token, env has it); `reap_SurvivorRemains_ReturnsFailure` (reap stub exits 1).
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS, shellcheck clean.
- [ ] **Step 5: Commit** `feat(azdo): add the driver side of the agent user boundary`.

### Task 4: Agent wrappers and prompt

**Files:**
- Modify: `scripts/lib/agent-cmd-claude-implement.sh`, `scripts/lib/agent-cmd-claude-fix.sh`, `scripts/build-agent-prompt.sh:121-125`
- Test: `tests/run-agent-boundary-lib-tests.sh` (wrapper section), the existing prompt tests in `tests/run-script-tests.sh`

**Interfaces:**
- Consumes: `boundary_exec_claude` (Task 3).
- Produces: both wrappers honour `AGENT_WORKSPACE`: when set, they run `boundary_exec_claude "$AGENT_WORKSPACE" "${args[@]}"` instead of `claude "${args[@]}"` (same args, same redirections). `build-agent-prompt.sh` honours `PROMPT_PUSH=0` (azdo only): the closing lines say to commit on a new branch and **not** to push, because there is no remote; default (`PROMPT_PUSH` unset or `1`) keeps today's text byte-for-byte.

- [ ] **Step 1: Failing tests:** `implementWrapper_AgentWorkspace_UsesBoundary` (sudo mock log shows `awf-agent-run <ws> -- --print --output-format json …`); `implementWrapper_NoWorkspace_Unchanged` (claude mock called directly, sudo log empty); same pair for the fix wrapper; `prompt_PushOff_SaysDoNotPush` (contains `Do NOT push`, lacks `push the`); `prompt_Default_Unchanged` (golden compare with today's output).
- [ ] **Step 2–4:** run → FAIL, implement, run → PASS.
- [ ] **Step 5: Commit** `feat(azdo): route the agent wrappers through the boundary when asked`.

### Task 5: Implement driver in pipeline mode

**Files:**
- Modify: `scripts/implement-azdo.sh` (`preflight` ~133, `run_attempt` 216-241, `_azdo_auth_header` users 259-280, `reset_workspace` 502-513, `render_report` 405-420)
- Test: `tests/run-implement-azdo-tests.sh` (new section) and a new fixture repo helper in that file

**Interfaces:**
- Consumes: Task 3 functions, Task 4 `AGENT_WORKSPACE` / `PROMPT_PUSH`, `scripts/import-result-output.sh` (`RESULT_JSON_FILE`, `OUT_DIR`; outputs `result-file`, `valid` on `GITHUB_OUTPUT`).
- Produces: new globals `AGENT_WORKSPACE`, `EVIDENCE_ERROR`; `render_report` prints `- evidence: <EVIDENCE_ERROR>` after the metrics line when it is non-empty.

Behaviour in pipeline mode (local mode untouched):
1. `preflight`: after the existing checks, `checkout_has_credentials` → print `error: the checkout carries a credential (persistCredentials must be false); refusing to run the agent` and exit 1; `boundary_check` failing → print `error: the agent user boundary is not available: <cause>` and exit 1. Both before any agent runs and before `read_work_item`'s writes (there are none today; keep it so).
2. `run_attempt`: `AGENT_WORKSPACE="$(boundary_new_workspace)"`, `boundary_seed "$AGENT_WORKSPACE" "$WORK_DIR/handoff" "origin/$DEFAULT_BRANCH"`, build the prompt with `PROMPT_PUSH=0`, run the wrapper (stdin prompt, stdout `$WORK_DIR/raw-result.json`) under the existing `timeout`, then `boundary_reap`. Then: raw result over 65536 bytes → treated as empty; `import-result-output.sh` with `RESULT_JSON_FILE=$WORK_DIR/raw-result.json OUT_DIR=$WORK_DIR/import`; `RESULT_FILE` = its `result-file`. Then `HEAD_BRANCH="$(boundary_collect …)"`, `valid_branch_name`, and `git checkout -B "$HEAD_BRANCH" refs/awf/collected` in the driver's checkout.
3. Any of reap failure, collect failure, invalid branch name, or import `valid=false` → `EVIDENCE_ERROR="<cause>"` and `ATTEMPT_CLASS=bug` (no retry, via the existing policy). A bundle with no new commits is not invalid evidence: it keeps today's "committed nothing" path.
4. `_azdo_auth_header` callers (`remote_branch_exists`, `remote_branch_sha`, `push_branch`) use `azdo_git` in both modes.
5. `reset_workspace` additionally deletes `refs/awf/collected`; the agent workspace is not reused (each attempt gets a new one).
6. `main` sets `umask 077` before creating `WORK_DIR`, then `chmod 0711 "$WORK_DIR"` in pipeline mode only, so `awf-agent` can reach `handoff/seed.bundle` (0644 in a 0711 dir) and nothing else in it.

- [ ] **Step 1: Failing tests** (pipeline mode via the env `ci_host` reads; `sudo`/`claude`/`az` mocked; the claude mock commits in its cwd and prints a result JSON): `preflight_BoundaryRefused_ExitsBeforeAgent` (exit 1, message contains `boundary`, claude mock never called); `preflight_CheckoutHasCredentials_Refuses`; `attempt_Success_PushesCollectedBranch` (the push mock sees the agent's branch; the agent ran via `awf-agent-run`; no `AZURE_DEVOPS_EXT_PAT` in the claude mock's env dump); `attempt_ReapFails_InvalidEvidence` (report contains `**Outcome:** failed: bug` and `- evidence:`; no push); `attempt_HostileBranchName_InvalidEvidence`; `attempt_OversizedResult_InvalidEvidence`; `attempt_PipelineFileInBundle_Refused` (existing guard message); `local_Mode_Unchanged` (no sudo call; today's assertions still pass); `authGit_TokenNeverInArgv` (git wrapper dumping argv across a full run never sees the token).
- [ ] **Step 2–4:** run → FAIL, implement, run the whole file and `tests/run-implement-azdo-*`/`run-azdo-*` → PASS.
- [ ] **Step 5: Commit** `feat(azdo): run the implement agent as awf-agent in pipeline runs`.

### Task 6: Self-fix in pipeline mode

**Files:**
- Modify: `scripts/azdo-self-fix.sh`, `scripts/self-fix-pr.sh:150-160`
- Test: `tests/run-azdo-review-tests.sh` (self-fix section)

**Interfaces:**
- Consumes: Task 3 functions, Task 4 fix wrapper.
- Produces: `self-fix-pr.sh` honours `SKIP_COMMIT=1`: it skips the "agent made no changes" check and the commit (the caller owns both). In pipeline mode `azdo-self-fix.sh`: `boundary_check` (fail → `stop 1 "self-fix stopped: the agent user boundary is not available"`), seeds a new workspace at `HEAD` of the PR branch, runs `self-fix-pr.sh` with `SKIP_COMMIT=1 SKIP_PUSH=1 AGENT_WORKSPACE=<ws>`, then `boundary_commit` (3 → `stop 1` with today's "made no change" wording), `boundary_reap` (fail → `stop 1 "self-fix stopped: an agent process survived the fix"`), `boundary_collect` and fast-forwards `SF_HEAD_REF` to `refs/awf/collected` (not a fast-forward → `stop 4`), then the existing `require_pr_branch`, pipeline-file guard and `push_branch`.

- [ ] **Step 1: Failing tests:** `selfFix_Pipeline_CommitsAsAgentAndPushes`; `selfFix_Pipeline_NoChange_StopsWithTodayWording`; `selfFix_Pipeline_ReapFails_Stops`; `selfFix_Pipeline_BoundaryMissing_Stops`; `selfFix_Pipeline_PipelineFile_Refused`; `selfFix_Local_Unchanged`; `selfFixPr_SkipCommit_DoesNotCommit`.
- [ ] **Step 2–4:** FAIL → implement → PASS (plus the existing self-fix suites).
- [ ] **Step 5: Commit** `feat(azdo): run the self-fix agent as awf-agent in pipeline runs`.

### Task 7: Isolation guard

**Files:**
- Create: `tests/run-azdo-isolation-tests.sh`

**Interfaces:**
- Consumes: the files of Tasks 1–6.

Static checks, each with a mutated-copy negative case (the style of `run-agent-isolation-tests.sh`):
- `implement-azdo.sh` and `azdo-self-fix.sh` reach `agent-cmd-claude-implement.sh` / `self-fix-pr.sh` only with `AGENT_WORKSPACE` set on the pipeline path, and call `boundary_check` before them;
- no `git -c http.extraheader` remains in `scripts/` (the token stays out of argv);
- every `git` call inside `agent-boundary.sh` and the three entry points carries `core.hooksPath=/dev/null` and `core.fsmonitor=false`;
- the sudoers file lists exactly the three entry points and `env_keep` exactly the allowlist;
- `implement-azdo.sh` reads the agent result only through `import-result-output.sh`.

- [ ] **Step 1:** write the guard (it passes on the finished tree; the negative cases prove each check bites). **Step 2:** run → PASS, with each mutation reported as caught.
- [ ] **Step 3: Commit** `test(azdo): guard the agent user boundary`.

### Task 8: Operator docs and ADR

**Files:**
- Modify: `docs/AZDO-PIPELINE-SETUP.md` (new section `## 13. Agent user boundary`, plus a pointer in §1 and §7), `docs/DECISIONS.md` (append `## ADR-024 — The Azure DevOps agent runs as its own user, not in its own job (2026-11-16)`)

Content: what the boundary is, that a rebuilt image is required and nothing changes in the pipeline YAML, that `persistCredentials: false` is now enforced by the driver, that the container must not run with `no-new-privileges`, that a logged-in CLI session is not supported in pipeline mode, and the Layer-3 check below. The ADR records the decision and the rejected job split (persistent `/azp/agent` volume, same-uid token access), with the spec as its source.

- [ ] **Step 1:** write both. **Step 2:** `bash tests/run-all.sh` (docs lints included) → PASS; leak grep from the Global Constraints clean.
- [ ] **Step 3: Commit** `docs(azdo): document the agent user boundary`.

## Layer-3 verification (operator, after merge — not part of the agent's run)

On the sandbox project, with the rebuilt image: run one `ai-implement` item whose plan asks the agent to report `id -un`, `cat /proc/1/environ` and `touch /azp/agent/x` in its PR description. Expected: `awf-agent`, permission denied, permission denied. Record the result in `docs/ai-notes/`.
