# Azure DevOps track — state and next steps (#573)

**Date:** 2026-11-06 · **Status:** open decisions, nothing in flight

## Done

- **Phase 1 PoC** (#576): tag `ai-implement` on a work item → service hook →
  Incoming WebHook → Azure Pipeline → trust gate (`scripts/azdo-tag-guard.sh`) →
  `scripts/implement-azdo.sh` → Claude Code → draft PR + report comment.
  Run note: `docs/ai-notes/2026-10-30-azdo-pipeline-poc-run.md`.
- **Hardening** (#577, merged `d563723`): revision-guarded tag removal with retry,
  one job per `--rm` container under systemd, pinned + hash-checked agent and
  digest-pinned base image, protected default branch, exit 66 proven live.
  Setup guide: `docs/AZDO-PIPELINE-SETUP.md`. The sandbox pipeline runs
  `d563723` and passed an untagged check (run 21).

## Gap to the GitHub path

| GitHub (`agent-implement.yml` v2) | Azure DevOps today |
|---|---|
| retry / re-dispatch, attempt cap, pause on credits | none — draft PR, human review |
| AI review + self-fix loop | none |
| auto-merge lanes | none |
| repo CI gates the agent's PR | no PR build-validation template |
| runner has the project's tool chain | agent image has no .NET/Node/etc. tool chain |

## Open decisions (ask the maintainer, interview mode)

1. **Token source for a second user (a teammate who does not use Passbolt).**
   The Claude OAuth token is a secret pipeline variable — one per pipeline, not
   per person. Options to put to the maintainer:
   - each person runs `claude setup-token` and pastes the token into the
     secret variable of **their own** pipeline/project (no Passbolt needed;
     Passbolt was only the maintainer's storage);
   - one shared pipeline needs a per-tagger token, which today would put every
     token into the agent's environment — not recommended without a design;
     two pipelines on one tag would race on the guard's tag removal (65 path);
   - a company-owned token / plan — the company's decision. A personal
     subscription token must not be shared between people.
   Also: in a multi-member project, anyone who can edit the pipeline YAML can
   queue it from their branch and read the secret → add a branch-control check
   on the pool or variable group.
2. **"Close the gap over the weekend"** — candidate unattended scope, sandbox
   only, Layer-1 tests + live sandbox runs, feature branches + draft PRs, no
   merges, no work-org writes:
   a. retry / re-dispatch (CI-host adapter verb: re-queue the pipeline with
      `workItemId`), attempt cap from report comments;
   b. AI review of the draft PR posted as ADO PR threads, then a self-fix loop;
   c. a PR build-validation pipeline template + docs;
   d. a tool-chain layer for the agent image (e.g. .NET SDK) as an opt-in variant.
   Each needs spec → plan → subagent-driven implementation; get the maintainer's
   scope pick and a durable authorization for the outward sandbox actions first.
3. **Pilot with a real .NET work repository** (chosen as next step). Copying
   work code into the personal sandbox org needs the maintainer's explicit OK
   first; the alternative is running the pilot in the work org.
