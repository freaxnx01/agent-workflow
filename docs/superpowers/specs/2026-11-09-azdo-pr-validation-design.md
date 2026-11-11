# Azure DevOps PR build validation for agent PRs — Design (gap item c)

**Issue:** #573 · **Date:** 2026-11-09 · **Status:** draft, written unattended under
the maintainer's go-ahead of 2026-11-06 (spec → plan → implement without a
design interview). Calls marked *(my call)* were made by the author, not the
maintainer.

## Intent

On GitHub the consumer repo's own CI gates the agent's PR: a red build blocks
the merge. On Azure DevOps the `ai-implement` run opens a draft PR and nothing
checks it, so a reviewer has to build it by hand to know whether it compiles.
This item gives an Azure DevOps project a copy-paste PR validation pipeline and
the setup steps that make it a required gate on the default branch.

## Goals

1. **G1:** a template pipeline a consumer copies into its repo and edits only in
   the build/test step.
2. **G2:** a branch policy on the default branch makes that pipeline a
   **required** check for every PR, including the agent's draft PRs.
3. **G3:** the validation run carries **no secret**: no Claude token, no
   pipeline secret variable, and no `System.AccessToken` in any step's
   environment. It runs code the agent wrote, and that code is untrusted.
4. **G4:** the setup guide covers it, and a Layer-1 test enforces G3 on the
   template.
5. **G5:** proven live once in the sandbox. A green PR passes, a red PR blocks
   completion, and the check runs on a draft PR.

## Non-goals

- Reading the validation result back into the `ai-implement` run (waiting for
  checks, self-fix on a red build). That belongs to gap item b or later.
- Auto-merge. Completion stays a human action.
- Hosting the template so consumers can `extends:` or `template:` it straight
  from GitHub. That needs a GitHub service connection in every consumer
  project, which costs more than copying 30 lines.

## Anti-goals

- A validation pipeline that runs on the same agent registration while holding
  the Claude token's pipeline variables. That would hand any secret to
  agent-written code.
- A template that only works for .NET. The build step is a clearly marked
  placeholder, with a .NET example.

## Decisions

### C1 — Template location: `templates/azdo/pr-validation.yml` *(my call)*

This is a new top-level `templates/` directory. `docker/azp-agent/` is for the
image, and `docs/` is prose. A YAML file the consumer copies is neither. The
file header says "copy into your repo as `azure-pipelines-pr.yml`".

### C2 — Trigger is the branch policy, not YAML

In Azure Repos, the `pr:` key is ignored. Build validation policies queue the
pipeline. So the template has `trigger: none` and `pr: none`, and the guide
creates the pipeline, then the policy:

- *Build validation*, required.
- Trigger automatic.
- Expiry "immediately when the default branch is updated".

### C3 — Secret-free by construction

- `checkout: self` with `persistCredentials: false`, so no token lands in
  `.git/config`.
- No `env:` mapping of `System.AccessToken`.
- The guide says to create this pipeline **without** the `ai-implement`
  pipeline's variables. Those are per-pipeline, so a separate pipeline does not
  inherit them. Never put the Claude token in a variable group linked here.
- The guide also notes that a build service token is still issued to the job.
  It is not exposed to steps unless mapped, and *Limit job authorization scope
  to current project* should be on.

### C4 — Pool is a parameter with a placeholder

`pool: <pool>`, as everywhere else in the public repo. The sandbox pool name
lives only in the private sandbox repo. The one-container-per-job agent from
#577 is what makes running untrusted PR code on the self-hosted pool
acceptable: nothing survives the job.

### C5 — Layer-1 test

`tests/run-azdo-templates-tests.sh`, wired into `just test`, parses the template
with `python3 -c 'import yaml'`. It skips with a notice if PyYAML is absent, but
it is present on the agent image and CI. It asserts:

- `trigger` and `pr` are `none`;
- every `checkout` step has `persistCredentials` false or unset;
- no step `env` value references `System.AccessToken`, `SYSTEM_ACCESSTOKEN` or
  `CLAUDE`;
- no `variables:` group reference.

The C6 guard also gets Layer-1 cases in the `implement-azdo` tests:

- a diff touching `azure-pipelines-pr.yml` → exit 1, no push, no PR call;
- a diff touching `src/` only → proceeds;
- `PIPELINE_FILE_GLOBS` adds a path.

A fixture with a bad template (a step that maps the access token) proves the
test can fail.

### C6 — A run that edits pipeline files fails *(maintainer's decision, 2026-11-09)*

Build validation runs the YAML **from the PR's source branch**, which the agent
writes. An agent PR could therefore edit `azure-pipelines-pr.yml` to map the
access token, add a variable group or change the pool. The Layer-1 test only
guards the template, so on its own it cannot stop this.

So before pushing, `implement-azdo.sh` checks
`git diff --name-only origin/<default>...HEAD`. If any path matches the
pipeline-file list, the run **fails**, with no push and no PR, and the failure
report names the file or files. Default list *(my call)*:

- `azure-pipelines*.yml`
- `azure-pipelines*.yaml`
- `.azure-pipelines/**`
- `.azuredevops/**`

A consumer extends the list with a pipeline variable, `PIPELINE_FILE_GLOBS`.
That variable can only add paths, never remove the defaults. Item b's self-fix
push applies the same check.

This extends #577 G5 (a run cannot change what runs next) from the
`ai-implement` pipeline to the validation pipeline. The guide states the
consequence plainly: pipeline changes are made by humans.

### C7 — Draft PRs *(maintainer's decision, 2026-11-09)*

The live proof checks whether the policy runs on a draft PR. If it does not,
that is accepted: the check runs once a human publishes the PR, which is when
it gates completion anyway. The guide records whichever result the live test
shows. Neither the agent nor item b ever publishes the PR.

## Live proof (sandbox)

1. PR in `practice`: add `azure-pipelines-pr.yml`, from the template with
   `dotnet build` + `dotnet test` on the sample from item d, or `true` if d has
   not landed yet. Create the pipeline and the required build-validation
   policy. Merge (sandbox merges are approved).
2. A PR that breaks a test → the check is red and the PR cannot complete.
3. Fix it → green.
4. One draft PR from an `ai-implement` run → find out whether the policy runs
   on a draft. **Verify; don't assume.** Record the answer (C7).
5. A work item that asks the agent to edit `azure-pipelines-pr.yml` → the run
   fails before the push, with the file named (C6).

Results go in `docs/ai-notes/<date>-azdo-pr-validation-run.md`, with no org,
pool or host names.

## Left to the builder

- The exact policy click path and the wording of the guide section. Add it as
  §9 in `docs/AZDO-PIPELINE-SETUP.md`.
- Whether to add a `just test` sub-recipe or extend the existing aggregate.
