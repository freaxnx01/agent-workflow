# Azure DevOps ai-implement pipeline — PoC design

**Issue:** #573 · **Date:** 2026-10-30 · **Status:** approved pending review

## Intent

Prove that agent-workflow's implement lane can run **unattended on Azure DevOps**:
someone adds the `ai-implement` tag to a work item, walks away, and later finds a
draft PR linked to it. Today the same result needs a person to run
`scripts/implement-azdo.sh` from a local shell.

This is a **proof of concept** for phase 1 of #573. It answers "does the
one-driver, two-adapter shape work on a real Azure Pipelines agent?", not "is it
production-ready for every consumer".

## Goals

- Tag → pipeline run → `implement-azdo.sh` → draft PR, with no local session.
- A thin pipeline YAML: a tag check plus a call into the driver, nothing else.
- The first, minimal **CI-host adapter** seam (identity only, see D5), so the
  driver does not grow `if azure-pipelines` branches.
- Everything in this public repository is generic; anything that identifies a
  machine, agent pool or organization other than the sandbox lives only in the
  private sandbox repository.

## Non-goals

- Retry / escalate-on-retry (phase 2) and AI review / merge envelope (phase 3).
- Changing `.github/workflows/agent-implement.yml` in any way.
- Reusing templates across repos via `resources.repositories` (see D4).
- Microsoft-hosted agents (see D2).

## Anti-goals — a failure even if it works

- Any hostname, IP, agent-pool name, or non-sandbox organization/project name
  committed to this repository, its issues or PRs (this repository is public).
- A run that writes to any organization other than the sandbox.
- A pipeline that runs the agent on every work-item edit, or twice for one tag.
- An agent that can degrade the other workloads on its host.

## Constraints

- **Organization:** the personal sandbox organization, project
  `agent-workflow-sandbox`. A **new repository `practice`** is created next to the
  existing one; sandbox fixture work items 1–4 and probe item #6 are never written.
- **Credentials:** never echoed or logged; a PAT travels on stdin or in the
  environment only. No credential in any repository.
- **Live verification is local/manual**; CI has no Azure DevOps credential.
- Bash conventions and Layer-1 testing per the CI stack overlay apply to every
  new script.

## Decisions

### D1 — Trigger: service hook on tag change → incoming-webhook pipeline

A service-hook subscription on **Work item updated**, filtered to changes of the
**Tags** field (and to the `practice` Area Path), posts to an **Incoming WebHook**
service connection. The pipeline declares that webhook under `resources.webhooks`
and is triggered by it.

Service hooks cannot express "tag X was just added", so the pipeline's **first
step** reads the work item and exits successfully, without running the agent,
unless `ai-implement` is present.

**Double-dispatch guard:** the first thing a qualifying run does is **remove the
`ai-implement` tag** (through `forge_issue_label_remove`). That edit itself fires
the hook again; the follow-up run finds no tag and exits in seconds. A manual
"Run pipeline" with a work-item-id parameter is kept as a fallback entry point.

### D1a — Trust gate: only allowlisted taggers start the agent

`scripts/lib/agent-cmd-claude-implement.sh` runs Claude with permissions bypassed
and its header justifies that only by "the caller is a human at a terminal". An
unattended tag trigger removes that human, so the guard step also checks **who
added the tag**: it reads the work item's revisions, finds the revision that
introduced `ai-implement`, and compares its `System.ChangedBy` identity against an
**allowlist pipeline variable** (the maintainer). Anyone else: tag removed, a
comment says why, the agent does not run. The wrapper's header is amended to name
this gate as the unattended justification. *(Decided by the maintainer.)*

### D1b — Failures leave a trace on the work item

Because the guard removes the tag first, a failed run would otherwise leave an
untagged item with nothing on it. A `condition: failed()` step posts a short
failure comment (outcome, link to the run) through `forge_issue_comment`.
*(Builder's call, settled in review.)*

### D2 — Agent: self-hosted, containerized, registered to the sandbox org

The Microsoft-hosted free tier now requires linking an Azure subscription, so the
PoC uses the free self-hosted parallel job instead. The agent runs as the stock
Azure Pipelines agent **inside a container**, on a build host the maintainer is
entitled to use, in a dedicated agent pool.

- Resource caps (≈2 CPUs, 4 GB RAM), its own `/tmp`, non-root user — the host
  also serves other CI workloads.
- The image carries the driver's toolchain: bash, git, jq, python3, `az` +
  `azure-devops` extension, Node and the Claude CLI.
- The agent downloads itself and registers at first start using a PAT passed in
  the environment; the start script removes the PAT from the environment once
  configuration succeeds. No credential is baked into the image.
- **Persistent** agent (restart policy, not one container per job), with the
  pipeline set to clean the workspace for every job. *(Builder's call.)*

**Where it lives:** a generic `Dockerfile` and start script in this repository
(parameterized entirely by environment variables). The concrete `docker run`
invocation — host, pool name, caps — and the pipeline YAML itself are recorded
only in the `practice` repository, inside the sandbox project, which is
**private** (verified 2026-10-30). The public repository gets no pipeline YAML in
this PoC.

### D3 — Identity: the pipeline's own token for ADO, the subscription token for Claude

- Azure DevOps calls (work item read/update, push, PR) use `System.AccessToken`,
  exported as `AZURE_DEVOPS_EXT_PAT` for the driver. The project's build service
  identity is granted *Contribute*, *Create branch*, *Contribute to pull requests*
  on `practice` and *Edit work items* on its Area Path.
- The agent authenticates with the maintainer's Claude subscription through
  `CLAUDE_CODE_OAUTH_TOKEN`, a **secret pipeline variable** — the same token the
  GitHub pipeline uses.

### D4 — Getting the driver: pinned public clone, not a template resource

The pipeline step clones this public repository at a **pinned ref** (tag or SHA,
supplied as a pipeline variable) and runs `scripts/implement-azdo.sh` from it.
This needs no GitHub service connection. Sharing a YAML template through
`resources.repositories` is deferred: it is the right reuse mechanism later, but
it adds a GitHub service connection and buys nothing for a single PoC repository.
(#573's "Shape" names `resources.repositories`; this PoC deliberately defers it.)

### D5 — CI-host adapter: one verb now

A small sourced library (sibling of `scripts/lib/forge.sh`) with a single verb,
**identity**: resolve the token forge calls use (`GITHUB_TOKEN` on Actions,
`System.AccessToken` on Pipelines, the caller's PAT in a local shell). Platform
detection is by environment (`GITHUB_ACTIONS` vs `TF_BUILD`).

**set-output is deferred**: nothing in this pipeline reads a step output, and
`implement-azdo.sh` already points `GITHUB_OUTPUT` at a temp file for the shared
classifiers, which therefore stay untouched (no GitHub-path regression risk).
Re-dispatch is phase 2's seam. *(Builder's call, settled in review.)*

### D6 — ADR-017 is amended, not reversed

ADR-017's reason ("on this forge the reader is a human or a local session") no
longer holds once a pipeline runs. The decision stands: the pipeline agent has the
repository checked out and reads the spec and plan files the work item points to.
The amendment says so.

### D7 — The test work item carries a committed spec and plan

The PoC's work item points at a small spec and plan committed to `practice`, so
the run exercises ADR-017's "work item points at the files" path. `/enrich` does
not change in this PoC. *(Builder's call.)*

## Success — the PoC is done when

- [ ] Adding `ai-implement` to a work item in `practice` produces, with no local
      session, a draft PR linked to that work item and a report comment on it.
- [ ] Editing any other field of that work item does not run the agent.
- [ ] One tag addition yields exactly one agent run (the guard run exits early).
- [ ] A tag added by an identity not on the allowlist runs no agent and leaves an
      explanatory comment.
- [ ] A failed run leaves a failure comment on the work item.
- [ ] A manual run with a work-item-id parameter also works.
- [ ] The container stays inside its caps during a run.
- [ ] A manual `git grep` with the maintainer's private term list (kept outside
      this repository, see #575) finds nothing new. #575 is not a prerequisite.
- [ ] New scripts have Layer-1 tests; `tests/run-script-tests.sh` passes; shellcheck
      clean.
- [ ] ADR-017 amended; a run record lands under `docs/ai-notes/`.

## Prerequisites (maintainer, outside the repo)

1. The sandbox PAT widened to Code (read, write & manage), Build (read & execute),
   Service Connections (read, query & manage), Agent Pools (read & manage),
   Service Hooks (read, query & manage), Security (manage).
2. The `practice` repository created (by the builder once the PAT allows it).

## Left to the builder

- Image base, exact package versions, and how the Claude CLI is installed.
- The service-hook filter details beyond "Tags changed, practice Area Path".
- Names of the new adapter library, Dockerfile location and pipeline variables.
- Whether the guard step and tag removal are one script or two.
