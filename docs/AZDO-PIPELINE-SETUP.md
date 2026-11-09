# Azure DevOps Pipeline Agent Setup

How to run the hardened self-hosted Azure Pipelines agent that executes the
`ai-implement` trigger. The agent runs one job per container, from a pinned and
hash-verified agent version. Replace `<org>`, `<pool>`, `<project>`, `<name>`,
`<volume>`, `<image>` and `<agent-host>` throughout.

## 1. Build the image

From the repo root:

```bash
docker build -f docker/azp-agent/Dockerfile -t <image> .
```

The Dockerfile pins the base image digest, `AZP_AGENT_VERSION` and
`AZP_AGENT_SHA256`. Bump the version and its SHA-256 together, and the base
digest by hand.

## 2. Register the agent once

Registration needs a PAT with *Agent Pools (read, manage)*. Keep it out of the
long-running unit: register in a one-shot container, with the PAT in a mode-600
env file that is deleted afterwards, on a fresh volume.

```bash
(
  umask 077
  trap 'shred -u azp.env 2>/dev/null || rm -f azp.env' EXIT
  cat > azp.env <<'EOF'
AZP_URL=https://dev.azure.com/<org>
AZP_TOKEN=<pat>
AZP_POOL=<pool>
AZP_AGENT_NAME=<name>
EOF
  docker volume create <volume>
  docker run -d --rm --name <name>-reg --env-file azp.env -v <volume>:/azp/agent <image>
)
```

The `trap` is scoped to the subshell, so it deletes the env file as soon as
the block finishes. `docker run -d` returns once the container has started and
already holds its environment, so the file is not needed any longer. Confirm
with `ls azp.env` that it is gone.

The container registers the agent, then listens for a single job
(`run.sh --once`). Watch it until *Listening for Jobs* appears, then stop it:

```bash
docker logs -f <name>-reg
docker kill <name>-reg
```

The agent ignores SIGINT and SIGTERM, so Ctrl+C or a plain `docker stop` does
not end it promptly; `docker kill` does. If a job happened to be queued, it may
run in this container first, which is harmless. Either way the registration is
on the volume, and the unit's first start works without any `AZP_*` variable.
Revoke the PAT afterwards.

## 3. Install the unit

```bash
sudo cp docker/azp-agent/azp-agent.service.example /etc/systemd/system/<name>.service
sudoedit /etc/systemd/system/<name>.service   # fill in the placeholders
sudo systemctl daemon-reload
sudo systemctl enable --now <name>.service
```

The unit passes no `AZP_*` variable and no secret. Exit codes 64 (registration
or variable missing), 65 (SHA-256 mismatch) and 66 (version drift) stop the
restart loop; check `journalctl -u <name>`.

## 4. Pool setting

In *Organization settings > Agent pools > `<pool>` > Settings*, turn
**auto-update off**. The agent version is pinned by the image; an in-place
update would defeat the hash check and trip exit 66.

## 5. Repository permissions

Grant the project's build service identity on the repository:

- Contribute
- Create branch
- Contribute to pull requests

and on the work item area: **Edit work items in this node**.

## 6. Branch policy

On the default branch, **require a pull request** and give the build service
**no bypass** (no *Bypass policies when pushing / completing pull requests*).
The agent must only ever propose changes.

## 7. Pipeline variables

Set on the pipeline (not in YAML):

- `TAGGER_ALLOWLIST` — who may trigger the agent by tagging.
- `AGENT_WORKFLOW_REF` — the pinned agent-workflow commit SHA to clone.
- `CLAUDE_CODE_OAUTH_TOKEN` — mark **secret**.

Leave *Let users override this value when running this pipeline* **off** for
each of them.

## 8. Service hook and webhook connection

1. *Project settings > Service connections*: create an **Incoming WebHook**
   connection named `aiImplementHook`.
2. *Project settings > Service hooks*: create a subscription on
   **Work item updated**, with the field filter **Tags** and an area filter,
   targeting the webhook:

   ```text
   https://dev.azure.com/<org>/_apis/public/distributedtask/webhooks/aiImplementHook?api-version=6.0-preview
   ```

3. The pipeline YAML calls `scripts/azdo-pipeline-run.sh` and, on failure,
   `scripts/azdo-report-failure.sh`.

## 9. PR build validation

The agent opens a PR; this section makes a **build validation** run gate it
before a human merges. The pipeline is separate from the `ai-implement` one and
holds no secrets.

### 9.1 Add the pipeline file

Copy `templates/azdo/pr-validation.yml` to `azure-pipelines-pr.yml` in the repo
root and edit only the build/test step. Do this through a human PR: the agent
cannot change pipeline files (see 9.4).

### 9.2 Create the pipeline

1. *Pipelines > New pipeline > Azure Repos Git > Existing YAML file*, and pick
   `azure-pipelines-pr.yml`.
2. Create it with **no** variables and link **no** variable group. Never put
   `CLAUDE_CODE_OAUTH_TOKEN` here. Variables are per pipeline, so this one
   inherits nothing from the `ai-implement` pipeline.
3. Turn on *Project settings > Pipelines > Settings > Limit job authorization
   scope to current project*.

A build service token is still issued to the job, but no step sees it unless it
is mapped, and the template maps none.

### 9.3 Require it on the default branch

*Repos > Branches > `<default>` > Branch policies > Build validation > +*:

- pick the pipeline;
- set Trigger to **Automatic**;
- set Policy requirement to **Required**;
- set Build expiration to **Immediately when `<default>` is updated**.

`pr:` in YAML is ignored on Azure Repos, which is why the template says
`pr: none`. The branch policy is what queues the run.

### 9.4 Pipeline files are changed by humans

An `ai-implement` run whose changes touch any of these globs fails before the
push and opens no PR. Its log names the files:

- `azure-pipelines*.yml`
- `azure-pipelines*.yaml`
- `.azure-pipelines/**`
- `.azuredevops/**`

A glob without `/` matches the file name at any depth; a glob with `/` matches
the full repo-relative path. To protect more paths, set the pipeline variable
`PIPELINE_FILE_GLOBS` (comma-separated, for example
`build/*.yml,deploy/**`). It is additive only: it cannot remove the defaults.

Limitation: if the agent pushed the branch itself, the ref stays on the server,
but no PR is opened, so no validation run is queued.

### 9.5 Draft PRs

Whether the policy runs on a draft PR: to be confirmed by the live run.
