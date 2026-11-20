# Azure DevOps agent user boundary — Layer-3 run (2026-11-20)

The Layer-3 check for #591 (PR #626), as `docs/AZDO-PIPELINE-SETUP.md` §13
asks for. Run in the personal sandbox project, on `<agent-host>`, with the image
rebuilt from `7725bb2` and the driver pinned to `e362091`.

**Headline:** the agent ran as `awf-agent`, could not read the job's
environment, could not write to the Azure Pipelines agent, and saw no ADO
token. Getting there found two bugs, one in the operator docs and one in the
driver, both fixed on the branch.

## Results

- [x] **0a. An existing pipeline was refused.** The first run stopped at the
  boundary check: the sandbox pipeline still had `persistCredentials: true`.
  - That refusal is intended. But §13 did not tell operators to change it, so
    every existing pipeline would have stopped after the image rebuild.
  - **Fix (`2e41a37`):** §13 now says to set `persistCredentials: false`
    before the rebuilt image takes its first job.

- [x] **0b. A correct pipeline was refused too.** With `persistCredentials:
  false` merged, the next run was still refused for a credential in the checkout.
  - **Cause:** the checkout task sets `origin` to
    `https://<org>@dev.azure.com/<org>/...`, a bare user name and no secret.
    `checkout_has_credentials` counted any userinfo in a remote URL as a
    credential, so it refused every Azure DevOps run. The Layer-1 tests had only
    covered `user:pw@`.
  - **Fix (`e362091`):** a bare user equal to the first path segment is
    accepted. A password, or any other bare user, still refuses, because Azure
    DevOps also accepts a PAT as the user. Three Layer-1 cases cover it.

- [x] **1. The agent ran as the agent user.** `id -un` printed `awf-agent`.

- [x] **2. The job's environment was unreadable.** `cat /proc/1/environ` exited 1
  with `Permission denied`.

- [x] **3. The Azure Pipelines agent was read-only to it.** `touch /azp/agent/x`
  exited 1 with `Permission denied`. `/azp/agent` and `/home/azp` are both
  `drwx------ azp azp`.

- [x] **4. No ADO credential in the agent's environment.** `env` listed no
  `AZURE_DEVOPS_EXT_PAT`, no `SYSTEM_ACCESSTOKEN` and no `SYSTEM_*` variables.
  It listed only the Claude CLI's own variables, `PATH`, `HOME` and the shell's.

- [x] **5. The reap passed.** The run was not refused for a surviving agent
  process, so `boundary_reap` returned 0. Its count goes to `/dev/null` and is
  not in the log.

- [x] **6. The rest of the run worked.** The driver pushed the agent's branch with
  its own header, opened the draft PR and linked the work item. The AI review
  approved.

## Side note

A run that refuses at the boundary removes the `ai-implement` tag. To re-run,
add the tag again after the fix. A manual queue with `workItemId` finds no tag
and does nothing.
