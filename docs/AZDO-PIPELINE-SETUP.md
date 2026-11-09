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

A build with no `--target` is the default image, unchanged. The `dotnet`
variant adds a pinned .NET SDK on top of it:

```bash
docker build -f docker/azp-agent/Dockerfile --target dotnet -t <image>-dotnet .
```

The variant is a superset of the default image. It sets
`AWF_TOOLCHAIN=dotnet`, which section 10 uses to route jobs to it.

Bump `DOTNET_SDK_VERSION` and `DOTNET_SDK_SHA512` together. Read both from the
channel's `releases.json`: in `releases[].sdk.files[]` (also
`releases[].sdks[].files[]`), the entry named `dotnet-sdk-linux-x64.tar.gz`,
field `hash` (SHA-512). A mismatch fails the build.

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

For the unit of a second, dotnet agent, see section 10.

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

Do **not** grant it *Queue builds* on any pipeline. That is the default:
verified live, a queue attempt with the job token was refused with `TF215106`.
With that permission the agent could run any pipeline's YAML from a branch it
pushed itself, which bypasses the CI-trigger override in sections 7 and 9.2.

## 6. Branch policy

On the default branch, **require a pull request** and give the build service
**no bypass** (no *Bypass policies when pushing / completing pull requests*).
The agent must only ever propose changes.

## 7. Pipeline variables

Set on the pipeline (not in YAML):

- `TAGGER_ALLOWLIST` — who may trigger the agent by tagging.
- `AGENT_WORKFLOW_REF` — the pinned agent-workflow commit SHA to clone.
- `CLAUDE_CODE_OAUTH_TOKEN` — mark **secret**.
- `MAX_ATTEMPTS` — optional, default 2. See section 11.
- `IMPLEMENT_TIMEOUT_MIN` — optional, default 45. See section 11.

Leave *Let users override this value when running this pipeline* **off** for
each of them.

Also override the YAML CI trigger on this pipeline: *Pipelines > (pipeline) >
Edit > ... > Triggers > Continuous integration*, tick **Override the YAML
continuous integration trigger from here** and leave **Enable continuous
integration** unticked. Without it, the pipeline's CI trigger is read from the
YAML on the pushed branch, so a branch the agent pushed could queue this
pipeline with its own YAML, and this pipeline holds the Claude token. The
webhook resource trigger is not the CI trigger and is unaffected.

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
root and edit only the build/test step. Do this through a human PR: the
driver refuses to push or open a PR for agent changes to pipeline files
(see 9.4).

### 9.2 Create the pipeline

1. *Pipelines > New pipeline > Azure Repos Git > Existing YAML file*, and pick
   `azure-pipelines-pr.yml`.
2. Create it with **no** variables and link **no** variable group. Never put
   `CLAUDE_CODE_OAUTH_TOKEN` here. Variables are per pipeline, so this one
   inherits nothing from the `ai-implement` pipeline.
3. Turn on *Project settings > Pipelines > Settings > Limit job authorization
   scope to current project*.
4. Authorize the pipeline on the agent pool: *Project settings > Agent pools >
   `<pool>` > Security > Pipeline permissions*, or approve the prompt on its
   first run. Until it is authorized, every validation build stays *not
   started*, and the policy waits on it indefinitely.
5. *Pipelines > (pipeline) > Edit > ... > Triggers > Continuous integration*:
   tick **Override the YAML continuous integration trigger from here** and
   leave **Enable continuous integration** unticked. Through the REST API this
   means removing the `continuousIntegration` entry from the build definition's
   `triggers`. Otherwise the CI trigger is read from the YAML on the pushed
   branch, and an agent-pushed branch could queue this pipeline with no PR.

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

Files pulled in with `template:` are as privileged as the root YAML, so add
their paths to `PIPELINE_FILE_GLOBS`. It must be a plain (non-secret)
variable: secret variables are not mapped into the script's environment, so a
secret value is silently ignored.

The work-item failure comment only links the run; the offending files are named
in the run log. The run also fails, closed, when the diff against the default
branch cannot be computed (guard return code 2).

Limitation: with the CI-trigger override from 9.2 and section 7 in place, a
branch the agent pushed itself queues no pipeline, and the build service cannot
queue one (section 5). The residual risk is a PR from such a branch, because
build validation runs the PR's YAML. A human may open that PR, or the agent may
open one itself, since section 5 grants it *Contribute to pull requests*. Its
drafts are not validated until a human publishes them (9.5). So check a PR's
diff for pipeline files before publishing it. The exposure is small: the
validation job holds no secret beyond the build-service token the agent already
has.

### 9.5 Draft PRs

The policy does **not** queue a build while the PR is a draft. Its status stays
*queued* with no build attached. Publishing the PR queues the build at once.
This was observed live: the agent's draft PR had no build after several
minutes, and the build started as soon as the PR was published.

The agent's PRs are always drafts, so validation runs when a human publishes
the PR, which is also when the policy starts to gate completion. This is
intended. Do not let the agent publish its own PRs to get an earlier build.

## 10. Route .NET jobs to the dotnet agent

Jobs that need the .NET SDK demand it in the pipeline YAML, which lives in the
consumer repo:

```yaml
pool:
  name: <pool>
  demands:
    - AWF_TOOLCHAIN -equals dotnet
```

The agent advertises its environment variables as capabilities, so the
`dotnet` image (which sets `AWF_TOOLCHAIN=dotnet`) matches this demand and the
default image does not. There are two ways to run the variant.

### 10.1 A second registration

Give the dotnet agent its own `<name>` (for example `<name>-dotnet`), so it
gets its own `AZP_AGENT_NAME`, unit file and container name, plus its own
`<volume>`, its own one-shot registration from section 2 and its own unit from
section 3, using `<image>-dotnet`. One pool
then holds mixed agents: default jobs run on either, .NET jobs only on the
dotnet one.

> **Warning:** `scripts/azp-agent-start.sh` registers with `--replace`. Reusing
> an existing agent's name silently replaces that agent in the pool, and the
> first agent stops connecting.

### 10.2 Switch the existing agent

Change the unit's `<image>` to the dotnet image and restart it. Because the
variant is a superset, default jobs still run. The registration on the volume
is reused, so no new registration is needed.

### 10.3 No SDK install at job time

The SDK is baked into the image, never installed while a job runs. Do not add
`UseDotNet@2` to a pipeline: the version is pinned and hash-verified at build
time.

## 11. Retry, attempt cap and job timeout

A failed attempt is retried inside the same job. The retry policy lives in
`scripts/lib/retry-policy.sh`.

### 11.1 Retry policy

| Class | Attempts in one run | Delay before the retry |
|---|---|---|
| `rate_limit` | 3 | 300 s |
| `transient` (including a timed-out attempt) | 3 | 10 s, 20 s |
| `task_failure` | 2 | 10 s |
| anything else | no retry | — |

A timed-out attempt (exit 124 or 137) is classed `transient`. The per-class
limits can be tuned with `MAX_RETRIES_RATE`, `MAX_RETRIES_TRANS` and
`MAX_RETRIES_TASK`.

### 11.2 Attempt cap

`MAX_ATTEMPTS` real attempts are allowed per work item. They are counted from
the `## ai-implement run` reports across runs. A human re-tag counts toward the
cap. The cap is checked before every attempt, so it usually ends a run before
the per-class limit does.

Before posting a "retrying" report, the driver previews the cap. If the next
attempt would hit it, the report says `next: stopping (attempt cap reached)`
and the item is parked without waiting.

### 11.3 Workspace

Every retry starts from `origin/<default>`, after `git clean -ffdx`. Pipeline
runs do this; local runs keep ignored files.

A remote branch that a failed attempt pushed is left in place and named in its
report. The driver reuses a remote branch only if its tip is the attempt's own
commit. If a later attempt ends on the same branch name with different commits,
it pushes with `--force-with-lease` against the tip it saw, so the PR always
carries the successful attempt's commits.

### 11.4 Timeouts

`IMPLEMENT_TIMEOUT_MIN` bounds each agent attempt. It accepts decimals. `0`
disables the per-attempt limit (GNU `timeout` semantics), and the job's
`timeoutInMinutes` is then the only bound. The agent gets SIGKILL 30 s after
the limit.

Set the job limit above the worst-case total:

```yaml
jobs:
  - job: implement
    timeoutInMinutes: 240
```

Budget:

- 3 × 45 min of attempts;
- 10 min of delays;
- 2 × (20 + 10) min of review and self-fix;
- about 205 min in total.

### 11.5 Unpark a work item

1. Remove the `parked` tag.
2. If the cap is the reason, raise `MAX_ATTEMPTS` on the pipeline.
3. Re-add `ai-implement`.
