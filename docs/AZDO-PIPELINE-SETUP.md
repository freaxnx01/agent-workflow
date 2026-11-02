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
umask 077
(
  trap 'shred -u azp.env 2>/dev/null || rm -f azp.env' EXIT
  cat > azp.env <<'EOF'
AZP_URL=https://dev.azure.com/<org>
AZP_TOKEN=<pat>
AZP_POOL=<pool>
EOF
  docker volume create <volume>
  docker run --rm --env-file azp.env -v <volume>:/azp/agent <image>
)
```

The `trap` is scoped to the subshell, so it deletes the env file as soon as
the block finishes, including after a failed or interrupted `docker run`.
Confirm with `ls azp.env` that it is gone.

The container registers the agent, then listens for a single job and exits
after it (`run.sh --once`). Either let it run one job, which is fine for a
one-shot container, or stop it with Ctrl+C once *Listening for Jobs* appears
if no job should run there. Either way the registration is on the volume, and
the unit's first start works without any `AZP_*` variable. Revoke the PAT
afterwards.

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
