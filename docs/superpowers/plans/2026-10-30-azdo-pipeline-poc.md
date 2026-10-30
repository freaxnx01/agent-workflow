# Azure DevOps ai-implement pipeline PoC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tag an Azure DevOps work item `ai-implement` and get a linked draft PR with no local session.

**Architecture:** A thin Azure Pipelines YAML (private, in the sandbox `practice` repo) calls one dispatcher script from a pinned clone of this repository. The dispatcher runs a tag guard (presence + allowlisted tagger, then tag removal) and, if it passes, the existing driver `scripts/implement-azdo.sh`, which gets its ADO token from a new one-verb CI-host adapter. The agent is the stock Azure Pipelines agent in a container built from a generic Dockerfile here.

**Tech Stack:** Bash 5, python3 (JSON parsing, as `scripts/lib/azdo.sh` already does), `az` + `azure-devops` extension, Docker, Azure Pipelines YAML.

**Spec:** `docs/superpowers/specs/2026-10-30-azdo-pipeline-poc-design.md`

## Global Constraints

- This repository is **public**: no hostname, IP, agent-pool name, or organization/project name other than the sandbox in any file, commit message, issue or PR. Use `<agent-host>`, `<pool>` placeholders.
- Writes only to the sandbox org's `agent-workflow-sandbox` project, `practice` repository. Never write to fixture work items 1–4 or probe item #6.
- Credentials never echoed or logged; never committed; never baked into an image.
- Every script: `#!/usr/bin/env bash`, `set -euo pipefail`, `IFS=$'\n\t'`, documented exit codes (0 ok, 1 error, 2 usage, 64+ task-specific), shellcheck-clean.
- Every new script has a Layer-1 runner `tests/run-<name>-tests.sh` (auto-discovered by `tests/run-all.sh`), external CLIs mocked via `tests/mocks/`, no network.
- `.github/workflows/agent-implement.yml` and the shared classifier scripts are **not modified**.
- Trigger tag: `ai-implement`. Allowlist variable: `TAGGER_ALLOWLIST` (comma-separated `uniqueName`s, compared case-insensitively).
- Live steps (Task 7) are **local-only**: CI has no ADO credential. Credentials via `direnv exec ~/repos/ado/personal …`; the agent host via `ssh <agent-host>`.

## Review Focus

- **The tag removal fires the hook again** — the follow-up run must see no tag and exit 0 without running the agent (Task 4 `guard_no_tag_exits_64`; Task 7 live check).
- **Tag was added, removed, re-added by different people** — the tagger is the identity of the **most recent** revision that introduced the tag (Task 3 `tag_adder_uses_latest_addition`).
- **Revisions read fails** — the guard must not proceed and must not remove the tag (Task 4 `guard_revision_read_failure_exits_1_keeps_tag`).
- **`System.AccessToken` not mapped into the step env** — the adapter fails with a message naming the fix, not a silent unauthenticated run (Task 1 `token_pipelines_without_accesstoken_fails`).
- **Allowlist entry differs only in case / surrounding spaces** — still matches (Task 4 `guard_allowlist_case_and_space_insensitive`).

---

## File Structure

| File | Responsibility |
|---|---|
| `scripts/lib/ci-host.sh` (new) | CI-host adapter: `ci_host`, `ci_host_token` |
| `scripts/lib/azdo.sh` (modify) | add `azdo_tag_adder` |
| `scripts/azdo-tag-guard.sh` (new) | trigger guard: tag present? tagger allowed? remove tag |
| `scripts/azdo-pipeline-run.sh` (new) | dispatcher the YAML calls: guard → driver |
| `scripts/azdo-report-failure.sh` (new) | failure comment on the work item |
| `scripts/implement-azdo.sh` (modify) | take the token from the adapter when on a CI host |
| `scripts/lib/agent-cmd-claude-implement.sh` (modify) | header: name the tagger gate |
| `docker/azp-agent/Dockerfile` (new) | agent image with the driver toolchain |
| `scripts/azp-agent-start.sh` (new) | download/configure agent, drop PAT, exec run |
| `docs/DECISIONS.md` (modify) | ADR-017 amendment |
| `docs/ai-notes/2026-10-30-azdo-pipeline-poc-run.md` (new) | live run record |

---

### Task 1: CI-host adapter (identity)

**Files:**
- Create: `scripts/lib/ci-host.sh`
- Test: `tests/run-ci-host-tests.sh`

**Interfaces:**
- Produces:
  - `ci_host` → echoes `pipelines` when `TF_BUILD` is `True` (case-insensitive), `actions` when `GITHUB_ACTIONS` is `true`, else `local`. Exit 0.
  - `ci_host_token` → echoes the CI identity token: `pipelines` → `$SYSTEM_ACCESSTOKEN`; `actions` → `$GITHUB_TOKEN`. Exit 0. Empty token on a CI host → exit 1, stderr names the variable and, for pipelines, says `map System.AccessToken into the step env (env: SYSTEM_ACCESSTOKEN: $(System.AccessToken))`. On `local` → exit 64 ("no CI identity; caller supplies its own credential"), nothing on stdout.
  - Sourced, not executed; no side effects at source time.

- [ ] **Step 1: Write the failing tests** in `tests/run-ci-host-tests.sh` (copy the harness shape of `tests/run-azdo-lib-tests.sh`; each case in a subshell with a scrubbed env via `env -i PATH="$PATH" bash -c 'source …; …'`):
  - `host_pipelines_when_tf_build_true`: `TF_BUILD=True` → `pipelines`
  - `host_actions_when_github_actions_true`: `GITHUB_ACTIONS=true` → `actions`
  - `host_local_when_neither` → `local`
  - `token_pipelines_returns_system_accesstoken`: `TF_BUILD=True SYSTEM_ACCESSTOKEN=abc` → stdout `abc`, rc 0
  - `token_pipelines_without_accesstoken_fails`: `TF_BUILD=True` → rc 1, stderr contains `System.AccessToken`
  - `token_actions_returns_github_token`: → `ghs_x`
  - `token_local_exits_64_empty_stdout`

- [ ] **Step 2: Run** `bash tests/run-ci-host-tests.sh` — Expected: FAIL (library missing).
- [ ] **Step 3: Implement** `scripts/lib/ci-host.sh` per the Interfaces block, header comment listing both verbs and exit codes, and a line that `set-output` and re-dispatch are deliberately absent (spec D5).
- [ ] **Step 4: Run** `bash tests/run-ci-host-tests.sh` — Expected: all pass. `shellcheck -x scripts/lib/ci-host.sh tests/run-ci-host-tests.sh` clean.
- [ ] **Step 5: Commit** `feat(ci-host): add a one-verb CI-host identity adapter (#573)`

---

### Task 2: Driver takes its token from the adapter

**Files:**
- Modify: `scripts/implement-azdo.sh` (the `AZURE_DEVOPS_EXT_PAT` requirement near line 55; header "Required environment")
- Test: `tests/run-implement-azdo-tests.sh` (new)

**Interfaces:**
- Consumes: `ci_host`, `ci_host_token` (Task 1).
- Produces: `implement-azdo.sh` behaviour: if `AZURE_DEVOPS_EXT_PAT` is unset and `ci_host` is not `local`, export `AZURE_DEVOPS_EXT_PAT="$(ci_host_token)"`; if still unset, exit 2 with the existing message. A set `AZURE_DEVOPS_EXT_PAT` always wins. Never print the token.

- [ ] **Step 1: Write the failing tests.** Run the script with `DRY_RUN=1`, `ISSUE_NUMBER=7`, `PATH` with `tests/mocks` first, and a temp git repo whose `origin` is an ADO URL (`https://dev.azure.com/contoso/MyProject/_git/my-repo`); `az` mock fixture is an existing work-item fixture from `tests/fixtures/` that `forge_export_issue` already accepts in `run-forge-adapter-tests.sh`.
  - `pipelines_token_used_when_pat_unset`: `TF_BUILD=True SYSTEM_ACCESSTOKEN=tok`, no PAT → rc 0, output contains `DRY_RUN=1`
  - `explicit_pat_wins`: `AZURE_DEVOPS_EXT_PAT=pat TF_BUILD=True SYSTEM_ACCESSTOKEN=tok` → rc 0 (the PAT is not overwritten; with `DRY_RUN=1` rc is the observable)
  - `local_without_pat_exits_2`: neither → rc 2, stderr contains `AZURE_DEVOPS_EXT_PAT must be set`
  - `token_never_printed`: stdout+stderr of the pipelines case do not contain `tok`
- [ ] **Step 2: Run** — Expected: `pipelines_token_used_when_pat_unset` FAILS (rc 2).
- [ ] **Step 3: Implement** the Interfaces behaviour; source `lib/ci-host.sh` beside the other libs; update the header's "Required environment" to say the PAT may come from the CI host.
- [ ] **Step 4: Run** the new runner and `bash tests/run-all.sh` — all pass.
- [ ] **Step 5: Commit** `feat(implement-azdo): take the ADO token from the CI host when unset (#573)`

---

### Task 3: `azdo_tag_adder` — who added the tag

**Files:**
- Modify: `scripts/lib/azdo.sh` (new function after `azdo_remove_tag`; header list at top)
- Create: `tests/fixtures/azdo-revisions-tag-added.json`, `tests/fixtures/azdo-revisions-tag-readded.json`, `tests/fixtures/azdo-revisions-no-tag.json`
- Test: `tests/run-azdo-lib-tests.sh` (new section)

**Interfaces:**
- Produces: `azdo_tag_adder <id> <tag>` → echoes the `uniqueName` of the identity on the **most recent** revision whose `System.Tags` contains `<tag>` while the previous revision's did not (first revision counts if it already has it). Exit 0 found; 64 the tag is in no revision; 1 the read failed; 2 usage.
- Call: `az devops invoke --org "$(azdo_org_url)" --area wit --resource revisions --route-parameters project="$AZDO_PROJECT" id="$id" --api-version 7.1 --output json --only-show-errors`, parsed in python3. Tags split on `;`, trimmed, compared case-insensitively (ADO tags are case-insensitive). `System.ChangedBy` may be an object (`uniqueName`) or a string `Name <mail>` — take `uniqueName`, else the text inside `<…>`.

- [ ] **Step 1: Write fixtures** (`{"count":N,"value":[{"rev":1,"fields":{"System.Tags":"…","System.ChangedBy":{"uniqueName":"…"}}}, …]}`):
  - `tag-added`: rev1 no tags by `alice@example.com`; rev2 `ai-implement` by `owner@example.com`; rev3 `ai-implement; parked` by `bob@example.com`
  - `tag-readded`: rev2 adds by `owner@example.com`, rev3 removes by `owner@example.com`, rev4 re-adds by `mallory@example.com`
  - `no-tag`: two revisions, tags `parked` only
- [ ] **Step 2: Write the failing tests:**
  - `tag_adder_returns_adding_identity`: `tag-added` → `owner@example.com` (not `bob`, who only edited after)
  - `tag_adder_uses_latest_addition`: `tag-readded` → `mallory@example.com`
  - `tag_adder_case_insensitive`: `tag-added` with tag `AI-Implement` → `owner@example.com`
  - `tag_adder_absent_exits_64`: `no-tag` → rc 64, empty stdout
  - `tag_adder_read_failure_exits_1`: `.txt` error fixture → rc 1
  - `tag_adder_usage_exits_2`: no args → rc 2
- [ ] **Step 3: Run** `bash tests/run-azdo-lib-tests.sh` — new cases FAIL.
- [ ] **Step 4: Implement** per Interfaces.
- [ ] **Step 5: Run** the runner — all pass (36 existing + 6 new).
- [ ] **Step 6: Commit** `feat(azdo): find the identity that added a tag (#573)`

---

### Task 4: Tag guard

**Files:**
- Create: `scripts/azdo-tag-guard.sh`
- Test: `tests/run-azdo-tag-guard-tests.sh`

**Interfaces:**
- Consumes: `azdo_fields`, `azdo_tag_adder` (Task 3), `azdo_remove_tag`, `azdo_comment` from `scripts/lib/azdo.sh`; `resolve_azdo_context` from `scripts/lib/detect-forge.sh`.
- Produces: `scripts/azdo-tag-guard.sh` — env `WORK_ITEM_ID` (required), `TAGGER_ALLOWLIST` (required), `TRIGGER_TAG` (default `ai-implement`). Exit codes:
  - `0` tag present, adder allowlisted, **tag removed** → proceed
  - `64` tag absent → do nothing, write nothing
  - `65` adder not allowlisted → tag removed, one comment: `ai-implement ignored: the tag was added by <uniqueName>, who is not on this pipeline's allowlist.`
  - `1` any read or write failed (tag left in place if the failure precedes removal)
  - `2` missing env
- Order matters: read tags → (absent: 64) → `azdo_tag_adder` (fail: 1, tag untouched) → allowlist check → `azdo_remove_tag` → comment (65 only).

- [ ] **Step 1: Write the failing tests** with `AZ_MOCK_MAP` routing `workitemsbatch`, `revisions`, `work-item update` to fixtures and `AZ_MOCK_LOG` to assert writes:
  - `guard_allowlisted_exits_0_and_removes_tag`: log contains a tags write without `ai-implement`
  - `guard_no_tag_exits_64`: log contains no `work-item update` and no PATCH
  - `guard_not_allowlisted_exits_65_removes_tag_and_comments`: log contains `--discussion` with `not on this pipeline's allowlist`
  - `guard_allowlist_case_and_space_insensitive`: `TAGGER_ALLOWLIST=" Owner@Example.com ,x@y"` → 0
  - `guard_revision_read_failure_exits_1_keeps_tag`: revisions → `.txt` fixture; log has no write
  - `guard_missing_env_exits_2`
- [ ] **Step 2: Run** — FAIL (script missing).
- [ ] **Step 3: Implement** per Interfaces; header documents each exit code and why the tag is removed before the agent runs (spec D1).
- [ ] **Step 4: Run** the runner and `bash tests/run-all.sh` — all pass; shellcheck clean.
- [ ] **Step 5: Commit** `feat(azdo): guard the ai-implement trigger by tag and tagger (#573)`

---

### Task 5: Dispatcher, failure report, wrapper header

**Files:**
- Create: `scripts/azdo-pipeline-run.sh`, `scripts/azdo-report-failure.sh`
- Modify: `scripts/lib/agent-cmd-claude-implement.sh` (PERMISSIONS header paragraph only)
- Test: `tests/run-azdo-pipeline-run-tests.sh`

**Interfaces:**
- Consumes: `ci_host`, `ci_host_token` (Task 1), `scripts/azdo-tag-guard.sh` (Task 4), `scripts/implement-azdo.sh` (Task 2), `forge_issue_comment` (`scripts/lib/forge.sh`).
- Produces:
  - Both scripts, before any ADO call: if `AZURE_DEVOPS_EXT_PAT` is unset and `ci_host` is not `local`, export it from `ci_host_token` (Task 1); never print it.
  - `azdo-pipeline-run.sh` — env as the guard. Runs the guard; `0` → `exec` `implement-azdo.sh` with `ISSUE_NUMBER=$WORK_ITEM_ID`; `64`/`65` → print the reason, exit 0 (a skipped run is a green run); anything else → exit with that code. Script paths overridable by `GUARD_CMD` / `DRIVER_CMD` for tests only.
  - `azdo-report-failure.sh` — env `WORK_ITEM_ID`, `RUN_URL`. Posts `ai-implement run failed: <RUN_URL>. The ai-implement tag was removed when the run started; re-add it to retry.` via `forge_issue_comment`. Exit 0 posted, 1 failed, 2 missing env.

- [ ] **Step 1: Write the failing tests** (guard/driver replaced by stub scripts in a temp dir that exit with a set code and log their env):
  - `run_guard_0_execs_driver_with_issue_number`: driver log has `ISSUE_NUMBER=7`
  - `run_guard_64_exits_0_without_driver`
  - `run_guard_65_exits_0_without_driver`
  - `run_guard_1_propagates_1_without_driver`
  - `run_driver_failure_propagates`: guard 0, driver 1 → rc 1
  - `report_failure_posts_run_url`: `az` log `--discussion` contains the URL
  - `report_failure_missing_env_exits_2`
  - `run_exports_pipelines_token_to_guard`: `TF_BUILD=True SYSTEM_ACCESSTOKEN=tok`, no PAT → guard stub's env log has `AZURE_DEVOPS_EXT_PAT` set (assert presence, not value)
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** both scripts.
- [ ] **Step 4: Amend** the wrapper's PERMISSIONS paragraph: keep the local-terminal justification and add that the one unattended caller, `azdo-pipeline-run.sh`, is acceptable only behind `azdo-tag-guard.sh`'s tagger allowlist; any other unattended caller still must not use it.
- [ ] **Step 5: Run** the runner and `bash tests/run-all.sh` — all pass; shellcheck clean.
- [ ] **Step 6: Commit** `feat(azdo): add the pipeline dispatcher and failure report (#573)`

---

### Task 6: Agent image

**Files:**
- Create: `docker/azp-agent/Dockerfile`, `scripts/azp-agent-start.sh`
- Test: `tests/run-azp-agent-start-tests.sh`

**Interfaces:**
- Produces:
  - `scripts/azp-agent-start.sh` — env `AZP_URL`, `AZP_TOKEN`, `AZP_POOL` (required), `AZP_AGENT_NAME` (default hostname), `AZP_AGENT_DIR` (default `/azp/agent`). If `$AZP_AGENT_DIR/config.sh` is absent, download the latest linux-x64 agent from `$AZP_URL/_apis/distributedtask/packages/agent?platform=linux-x64&top=1` (PAT via `curl -K -` on stdin, never argv) and unpack. If `.agent` is absent, run `config.sh --unattended --url "$AZP_URL" --auth pat --pool "$AZP_POOL" --agent "$AZP_AGENT_NAME" --replace --acceptTeeEula --work _work` with the token supplied as env `VSTS_AGENT_INPUT_TOKEN` (the agent reads `--token` from that variable), never as a `--token` argument. Then `unset AZP_TOKEN VSTS_AGENT_INPUT_TOKEN` and `exec ./run.sh`. Exit 2 on missing env.
  - `docker/azp-agent/Dockerfile` — base `debian:13-slim`; installs bash, git, jq, python3, curl, ca-certificates, `az` + `azure-devops` extension, Node LTS, the Claude CLI via the repo's `scripts/install-claude-cli.sh`; non-root user `azp`; copies `scripts/azp-agent-start.sh` as entrypoint. Build context is the repo root. No `ENV` holding a credential.
- [ ] **Step 1: Write the failing tests** (pre-populate a temp `AZP_AGENT_DIR` with stub `config.sh`/`run.sh` that log argv and env, so no download happens; `curl` mocked):
  - `start_missing_env_exits_2`
  - `start_configures_once`: no `.agent` → `config.sh` called with `--pool p --agent a --replace`
  - `start_skips_config_when_configured`: `.agent` present → `config.sh` not called
  - `start_token_not_in_argv`: config log contains no token value
  - `start_run_sees_no_token`: `run.sh` env log has neither `AZP_TOKEN` nor `VSTS_AGENT_INPUT_TOKEN`
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** script and Dockerfile.
- [ ] **Step 4: Run** the runner, `bash tests/run-all.sh`, shellcheck, and `pre-commit run --files docker/azp-agent/Dockerfile` (hadolint) — all clean. Then `docker build -f docker/azp-agent/Dockerfile -t azp-agent:poc .` succeeds and `docker run --rm --entrypoint bash azp-agent:poc -c 'az version && claude --version && jq --version'` prints versions.
- [ ] **Step 5: Commit** `feat(docker): add a container image for an Azure Pipelines agent (#573)`

---

### Task 7: LIVE (local-only) — sandbox setup and PoC run

Prerequisite: the maintainer has widened the PAT (spec, "Prerequisites"). Verify first, read-only: `az repos list`, `az pipelines list`, `az pipelines pool list` all succeed. If any fails, stop and report.

**Files:**
- Create (in the private `practice` ADO repo, never here): `azure-pipelines.yml`, `docs/agent-host.md` (the `docker run` line, caps, pool name), a small spec + plan for the test item.
- Create (here): `docs/ai-notes/2026-10-30-azdo-pipeline-poc-run.md`
- Modify (here): `docs/DECISIONS.md` (ADR-017 amendment)

Steps — each ends with its check:

- [ ] **Step 1: Repo and Area Path.** Create repo `practice` and child Area Path `agent-workflow-sandbox\practice`. Check: both listed.
- [ ] **Step 2: Agent pool and agent.** Create pool `<pool>`; on `<agent-host>` build the image from a pinned clone and run it with `--cpus 2 --memory 4g --restart unless-stopped`, its own named volume for `/azp`, `AZP_TOKEN` passed via `--env-file` from a mode-600 file that is deleted after first start. Check: agent shows **Online** in the pool; `docker inspect` shows no `AZP_TOKEN`.
- [ ] **Step 3: Permissions and variables.** Grant the project build service identity *Contribute*, *Create branch*, *Contribute to pull requests* on `practice` and *Edit work items in this node* on the Area Path. Pipeline variables: `TAGGER_ALLOWLIST` (maintainer's uniqueName), `AGENT_WORKFLOW_REF` (pinned SHA of this repo's merged `main`), secret `CLAUDE_CODE_OAUTH_TOKEN`.
- [ ] **Step 4: Webhook plumbing.** Incoming WebHook service connection `aiImplementHook`; service-hook subscription *Work item updated*, field filter **Tags**, area `agent-workflow-sandbox\practice`, posting to `https://dev.azure.com/<org>/_apis/public/distributedtask/webhooks/aiImplementHook?api-version=6.0-preview`.
- [ ] **Step 5: Pipeline YAML** in `practice` — shape (≤5 lines of inline bash per step):

```yaml
trigger: none
pr: none
parameters:
  - name: workItemId
    type: string
    default: ''
resources:
  webhooks:
    - webhook: aiImplementHook
      connection: aiImplementHook
pool: <pool>
steps:
  - checkout: self
    persistCredentials: true
    clean: true
  - bash: git clone --depth 1 https://github.com/freaxnx01/agent-workflow "$(Agent.TempDirectory)/aw" && git -C "$(Agent.TempDirectory)/aw" fetch --depth 1 origin "$(AGENT_WORKFLOW_REF)" && git -C "$(Agent.TempDirectory)/aw" checkout -q FETCH_HEAD
    displayName: fetch agent-workflow (pinned)
  - bash: '"$(Agent.TempDirectory)/aw/scripts/azdo-pipeline-run.sh"'
    displayName: guard + implement
    env:
      WORK_ITEM_ID: ${{ coalesce(parameters.workItemId, parameters.aiImplementHook.resource.workItemId) }}
      TAGGER_ALLOWLIST: $(TAGGER_ALLOWLIST)
      SYSTEM_ACCESSTOKEN: $(System.AccessToken)
      CLAUDE_CODE_OAUTH_TOKEN: $(CLAUDE_CODE_OAUTH_TOKEN)
  - bash: '"$(Agent.TempDirectory)/aw/scripts/azdo-report-failure.sh"'
    condition: failed()
    env:
      WORK_ITEM_ID: ${{ coalesce(parameters.workItemId, parameters.aiImplementHook.resource.workItemId) }}
      RUN_URL: $(System.CollectionUri)$(System.TeamProject)/_build/results?buildId=$(Build.BuildId)
      SYSTEM_ACCESSTOKEN: $(System.AccessToken)
```

If the webhook payload path for the work-item id differs, record the real one in the run note and fix the YAML; do not guess further.

- [ ] **Step 6: Test item.** Commit a small spec + plan to `practice` (e.g. "add a `HELLO.md` with one line"); create a work item in the `practice` area whose description points at them (ADR-017 shape, via `azdo_set_description`).
- [ ] **Step 7: Run the success criteria**, recording each outcome (run ids, PR number) in the run note:
  - tag by maintainer → exactly one agent run, draft PR linked, report comment; the hook's follow-up run exits early
  - edit another field → no agent run
  - tag by a non-allowlisted identity (if a second identity is available; otherwise record "not exercised" honestly) → comment, no agent
  - force a failure by setting `CLAUDE_CODE_OAUTH_TOKEN` to an invalid value for one run → failure comment on the item (not an invalid `AGENT_WORKFLOW_REF`: that fails before the report script exists)
  - manual run with `workItemId` → works
  - `docker stats` during a run stays within 2 CPUs / 4 GB
- [ ] **Step 8: Docs here.** Write the run note (no host/pool/BI names; `<agent-host>`, `<pool>`), amend ADR-017 per spec D6, run the private-term leak grep from the maintainer's notes on the branch — zero hits.
- [ ] **Step 9: Commit** `docs(azdo): record the pipeline PoC run and amend ADR-017 (#573)`
