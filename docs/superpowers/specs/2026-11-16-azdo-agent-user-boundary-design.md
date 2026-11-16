# Azure DevOps: run the implement agent behind a user boundary (#591)

Issue: #591. Origin: #535, fixed for the GitHub path by #571. Track: #573.

## Intent

On GitHub, #571 moved every decision about an implement run (classification,
retry, attempt cap, run report) out of the job the agent runs in, so the agent
can neither forge the evidence nor rewrite the scripts that judge it.

The Azure DevOps path has the same weakness, and a worse one. `scripts/implement-azdo.sh`
runs the agent and then judges it in the same bash process, in the same job and
container, as the same Linux user (`azp`, uid 1000). That user can:

- **read the job's access token.** `AZURE_DEVOPS_EXT_PAT` is exported into the
  agent's environment (from `SYSTEM_ACCESSTOKEN`, `lib/ci-host.sh`), and even
  without it, `/proc/<pid>/environ` of the agent worker is readable by the same
  uid. With the token the agent can push branches, open PRs and post or delete
  work-item comments, including the run reports `check-attempt-cap.sh` counts.
- **rewrite the judge.** The pipeline scripts (`$HERE`), the run's temp dir
  (`result.json`, prompt) and the consumer checkout are all writable by it, and
  bash reads a running script lazily.
- **persist past the run.** `/azp/agent` is a persistent Docker volume owned by
  `azp`. It holds the Azure Pipelines agent binaries and its registration
  credentials (`.credentials`, `.credentials_rsaparams`). An agent that rewrites
  them controls every later job on that registration, secrets included; one that
  copies them can impersonate the agent.

**Why the GitHub split does not carry over.** A separate gate *job* on the same
pool runs on that same persistent volume, so it is not a fresh judge; a fresh one
needs a second agent registration and pool, plus retry and self-fix rebuilt as
unrolled stages. And a job split does not stop the token theft above. The user
decided (2026-11-16) on a **user boundary inside the same job**: the agent runs as
a second, unprivileged Linux user that holds no Azure DevOps credential and can
write nothing the judge relies on.

## Goals

1. In a pipeline run, the implement agent (and the self-fix agent) runs as a
   dedicated unprivileged user, `awf-agent`, never as `azp`.
2. That user cannot read any Azure DevOps credential: not the job token, not a
   PAT, not the agent registration credentials.
3. That user cannot write anything the driver later executes or trusts: the
   pipeline scripts, the driver's temp dir, `/azp/agent`, the `azp` home.
4. Everything that crosses back from the agent (its result JSON, its commits) is
   treated as hostile data: size-capped, schema-checked, never executed, and
   processed with git hooks and repo-local config disabled.
5. No agent-user process survives an attempt: before the driver judges, every
   process of `awf-agent` is gone.
6. The pipeline run **fails closed** when the boundary is not available (user
   missing, sudo rule missing or wrong): it refuses to run the agent at all.
7. A Layer-1 guard keeps the boundary from silently regressing, the counterpart
   of `run-agent-isolation-tests.sh` for the GitHub path.

## Non-goals

- A separate gate job or pool (considered and declined, see Intent).
- Changing what the run does: retry, the attempt cap, the review, self-fix, the
  PR flow and the reports keep their current behaviour and wording.
- Local runs (`RUN_CONTEXT=local`, a human at a terminal). They keep today's
  behaviour; the boundary is a pipeline-mode requirement only.
- Hiding the Claude token from the agent. The agent needs it to run; that is the
  same on GitHub.
- Detecting a well-formed lie. An agent can still make a failed run *look* like a
  success in its own result text, exactly as on GitHub; the guards downstream
  (draft PR, review, PR build validation, human merge) are what catch that.
- Kernel-level escapes from the container.

## Anti-goals

- A boundary that only *looks* enforced: an agent that still runs as `azp`
  because a fallback kicked in. There is no fallback in pipeline mode.
- Moving credentials around the agent instead of away from it (a token in a file
  the agent "shouldn't" read).
- A broad sudo grant. `azp` may run exactly the boundary's fixed commands as
  `awf-agent`, nothing else, and never anything as root.

## Design

### The two users

The image (`docker/azp-agent/Dockerfile`) gains:

- user `awf-agent` (its own uid and group, home `/home/awf-agent`, not in group
  `azp`);
- `sudo`, with one sudoers drop-in (mode 0440) allowing `azp` to run, as
  `awf-agent` only and without a password, exactly three root-owned,
  non-writable entry points:
  - `awf-agent-run`: runs the agent CLI on a prompt in the agent's own
    workspace and writes the result JSON to its stdout;
  - `awf-agent-git`: a fixed set of git operations in the agent's workspace
    (seed it from a bundle, commit, write the commits back as a bundle), with
    hooks and fsmonitor off;
  - `awf-agent-reap`: kills every process of `awf-agent` (`kill -KILL -1` as that
    user) and reports whether any remain.
- an environment allowlist on that rule (`env_reset`, keep only what the agent
  needs: the Claude token, `MODEL`, `MAX_TURNS`). `AZURE_DEVOPS_EXT_PAT`,
  `SYSTEM_ACCESSTOKEN` and every other variable are dropped by sudo, not by the
  caller.
- the Claude CLI installed where `awf-agent` can execute it, with
  `/home/azp` and `/azp/agent` not readable by `awf-agent` (mode 0700 or 0750
  with `azp` as group).

### One attempt, pipeline mode

1. **Prepare (as `azp`).** Unchanged up to the agent call: guard, cap, classify,
   turns budget, prompt. Then the driver makes the agent's workspace: a clone of
   the consumer checkout at the attempt's base commit, created through the
   boundary so it is owned by `awf-agent`, from a source that contains no
   credential. Nothing enforces `persistCredentials: false` on the ai-implement
   pipeline YAML (it is not in this repo; the template guard covers only
   `templates/azdo/pr-validation.yml`), so the driver checks the checkout's git
   config itself and refuses when it carries an `http.*.extraheader` or a
   credential URL. The prompt says, in pipeline mode, to commit on a branch and
   **not** to push: there is no remote (today it says push,
   `build-agent-prompt.sh:122`).
2. **Run (as `awf-agent`).** `sudo -u awf-agent awf-agent-run …` with the prompt
   and the timeout. The agent works and commits in its own workspace. It has no
   remote it can push to.
3. **Reap.** `awf-agent-reap`. If processes remain, the attempt fails closed as
   `error_invalid_evidence`; nothing it left is used.
4. **Collect (as `azp`).** The driver takes the agent's commits as a git bundle
   produced through the boundary, verifies it in a **fresh clone of its own**
   with `core.hooksPath=/dev/null`, `core.fsmonitor=false` and no repo-local
   config from the agent's workspace, and checks that the bundle's base is the
   attempt's base. The branch name comes from the bundle and is hostile input:
   it must pass `git check-ref-format --branch` and `^[A-Za-z0-9._/-]{1,100}$`,
   or the attempt fails closed. The result JSON is size-capped by the driver
   (64 KiB, as #571 caps it on GitHub; `import-result-output.sh` has no cap of
   its own) and then goes through `scripts/import-result-output.sh`
   (allowlisted fields, strict types, fail closed).
5. **Judge and publish (as `azp`).** Classification, retry decision, reports,
   the pipeline-file guard, push and PR all run against the fresh clone, exactly
   as today. The push is the driver's, with the driver's credential.

Self-fix (`azdo-self-fix.sh` → `self-fix-pr.sh`) uses the same boundary with
these differences: the base is the PR head (`REVIEW_HEAD_SHA`), not the default
branch; the commit that `self-fix-pr.sh:160` makes today is made **inside the
boundary, as `awf-agent`**, so the bundle carries it; and there is no result
JSON to import (the fix agent writes a text log, `agent-cmd-claude-fix.sh`),
so its log is read only as size-capped display text. The pipeline-file guard
still runs on the bundle's diff before the driver pushes. The AI review
keeps `agent-cmd-claude.sh` (no tool permissions), as `azp`; it reads a diff and
cannot act, so it stays outside the boundary.

### Failure semantics

- Boundary missing in pipeline mode → exit 1 before any agent runs, with one
  line naming what is missing, and a run report on the work item saying so.
- Agent exits, times out or is killed → same classes as today (`transient` on
  124/137).
- Bundle missing, unverifiable, wrong base, bad branch name, or result JSON
  rejected by the import → invalid evidence. `error_invalid_evidence` is a
  result *subtype*, not a class: `classify-failure.sh` maps it to `bug`, which
  `retry-policy.sh` does not retry. The report keeps `failed: bug` and adds one
  line naming the cause.
- Reap leaves survivors → the same.

### The guard

A Layer-1 test (extend `run-agent-isolation-tests.sh`, or a sibling
`run-azdo-isolation-tests.sh`) asserts at least:

- in pipeline mode, `implement-azdo.sh` and `azdo-self-fix.sh` invoke an agent
  only through the boundary entry point, and refuse when it is unavailable;
- no `AZURE_DEVOPS_EXT_PAT` / `SYSTEM_ACCESSTOKEN` reaches the agent command line
  or its allowlisted environment;
- every git call on agent-produced data passes the hook/fsmonitor overrides;
- the Dockerfile's sudoers rule names only the three entry points, runs as
  `awf-agent` only, and the entry points are root-owned and not group/world
  writable;
- the agent's result is read only through `import-result-output.sh`.

Static Dockerfile checks extend `run-azp-agent-dockerfile-tests.sh`.

## Constraints

- Bash conventions of the repo; `actionlint`/`shellcheck` clean; TDD with mocked
  `sudo`, `claude`, `git` and `az` (no network, no real Azure DevOps).
- The image keeps its pinned base digest and pinned, hash-verified agent version.
- Public repo: no organisation, host or project names in code, docs or tests.
- `docs/AZDO-PIPELINE-SETUP.md` documents what changes for an operator: rebuild
  the image, nothing to add in the pipeline YAML. An existing named volume keeps
  its root-directory mode across a rebuild, so `azp-agent-start.sh` sets
  `/azp/agent` to 0700 at every start; the image alone cannot.
- The container must not run with `no-new-privileges` (sudo is setuid). The
  driver detects a broken sudo and fails closed with a line naming it.

## Acceptance (for the plan)

- Pipeline mode runs the agent as `awf-agent` via the three sudo entry points, and
  exits 1 with a report when the boundary is missing.
- The agent's environment contains no Azure DevOps credential; `awf-agent`
  cannot read `/azp/agent`, `/home/azp`, the scripts' write paths or the driver's
  temp dir, and cannot write any of them.
- Commits return only as a verified bundle into a fresh clone with hooks and
  fsmonitor off; the result JSON only through `import-result-output.sh`.
- No `awf-agent` process survives an attempt; survivors fail the attempt closed.
- Retry, cap, review, self-fix, reports and local mode behave as before (existing
  suites stay green).
- The isolation guard and Dockerfile tests cover the points above.
- A Layer-3 run on the sandbox project confirms the boundary live: from inside an
  agent step, `id` shows `awf-agent`, the job token is not readable, and
  `/azp/agent` is not writable.

## Calls made after the builder check

These were settled by the author, not the user; each can be overturned at review.

- **Entry points are thin and live in the image; the logic stays in the scripts
  clone.** `awf-agent-run` only switches into the agent's workspace, applies the
  environment allowlist and execs `claude` with the arguments the (trusted,
  `azp`) driver computed, so the model denylist and CLI flags change without an
  image rebuild. Each entry point answers `--protocol` with a version number;
  the driver refuses a version it does not know.
- **Environment allowlist:** `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_API_KEY`,
  `MODEL`, `MAX_TURNS`. A logged-in CLI session (under `/home/azp`) is not
  supported in pipeline mode.
- **The token leaves argv.** Authenticated git calls pass `http.extraheader`
  through `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_n` / `GIT_CONFIG_VALUE_n` instead
  of `git -c` (today `implement-azdo.sh:264,271,279`), because `/proc/*/cmdline`
  is world-readable. As a second line, no authenticated call runs while an
  agent process can exist (only after a successful reap).
- **The agent keeps naming its branch**, validated as above, so the existing
  collision and report logic stays as it is.

## Left to the builder

- Exact names and paths of the entry points and the sudoers file.
- How the agent's workspace is seeded (clone through the boundary, or a
  prepared world-readable source copy) as long as it carries no credential.
- Where the Claude CLI lives so both users can execute it.
- Splitting `implement-azdo.sh` further if it helps testability.

## Out of scope, captured

- The agent registration credentials on a persistent volume are also exposed to
  anything else running as `azp` in a job (task scripts, tools the build runs).
  The boundary removes the agent's access; a broader review of what a job can
  reach on that volume belongs to the agent-host hardening track (#573).
