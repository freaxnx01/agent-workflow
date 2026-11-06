# Azure Pipelines `ai-implement` Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the phase-1 PoC's accepted risks: an ephemeral agent per job, pinned and verified inputs, a revision-guarded tag write, a live exit-66 test and a protected default branch.

**Architecture:** The library's tag write gains an optional expected revision (json-patch `test` on `/rev`); the guard reads the revision first, judges, and retries a conflicting removal up to 3 times. The agent entrypoint downloads a pinned, hash-verified agent, refuses a version drift on every start and runs one job per container; a systemd template restarts a fresh `--rm` container after each job. Tasks 1–4 are Layer-1 code; Task 5 is the local-only live run.

**Tech Stack:** Bash 5, python3 (stdlib), curl, jq, Docker, systemd, Azure DevOps REST 7.1.

**Spec:** `docs/superpowers/specs/2026-11-02-azdo-pipeline-hardening-design.md`

## Global Constraints

- The repository is **public**: no host, pool or organisation names other than the personal sandbox org; use `<agent-host>`, `<pool>`.
- Bash prelude `set -euo pipefail` + `IFS=$'\n\t'`; exit codes are API and documented in each script header.
- Every new branch in a script gets a Layer-1 fixture test; no test reaches the network; external CLIs via `tests/mocks/`.
- A PAT or token never appears in argv, a log, or a fixture; curl gets credentials via `-K -` on stdin.
- The GitHub path is not touched.
- Retry cap for a revision conflict: **3** attempts.
- Pinned agent: version **5.281.1**, SHA-256 **c9579f76fd71a013e3b9010155454e20592d935134e4fcd04adc5283a820167e** (packages API `hashValue`, read 2026-11-02).
- Base image: `debian:13-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4` (index digest, read 2026-11-02).
- Live work (Task 5) is local-only, against the sandbox org `AndreasImboden0022`; credentials via `direnv exec ~/repos/ado/personal …`.

## Review Focus

1. A conflict response that is **not** a `/rev` test failure (any other 400) must stay an error, never a retry — pinned in Task 1 (`set_tags_other_400_is_failure`).
2. A conflict on the **last** attempt must not fall through to "proceed" — pinned in Task 2 (`guard_three_conflicts_exits_1_no_comment`).
3. A registered agent whose installed version differs from the pin must not start, even though no download happens — pinned in Task 3 (`start_version_drift_exits_66`).
4. A wrong SHA-256 must leave no agent files behind (no half-installed `config.sh`) — pinned in Task 3 (`start_sha_mismatch_exits_65_leaves_dir_empty`).
5. The PAT must not reach the download request now that the download is unauthenticated by construction — pinned in Task 3 (`start_download_sends_no_credentials`).

---

### Task 1: Revision-guarded tag write in the library

**Files:**
- Modify: `scripts/lib/azdo.sh` (`azdo_set_tags`, `_azdo_edit_tags`, `azdo_remove_tag`, new `azdo_latest_rev`, `_azdo_revision_scan` gains mode `latest`)
- Modify: `tests/mocks/curl` (new seam `CURL_MOCK_SEQUENCE`)
- Create: `tests/fixtures/azdo-set-tags-rev-conflict.json`, `tests/fixtures/azdo-set-tags-bad-request.json`
- Test: `tests/run-azdo-lib-tests.sh`

**Interfaces:**
- Produces: `azdo_set_tags <id> <tags> [expected_rev]` — with `expected_rev`, the body is `[{"op":"test","path":"/rev","value":<int>}, {"op":"replace","path":"/fields/System.Tags","value":<tags>}]`; without it, exactly today's body. Exit 0 replaced (echoes tags), 1 failed, 2 usage, **64 revision conflict** (response `typeKey` is `TestPatchOperationFailedException`; nothing echoed).
- Produces: `azdo_remove_tag <id> <tag> [expected_rev]` — passes `expected_rev` through; same exit codes.
- Produces: `azdo_latest_rev <id>` — echoes the highest `rev` among the item's revisions (paged read via `_azdo_revisions`); exit 0, 1 on read failure.
- Produces (test seam): `CURL_MOCK_SEQUENCE` — file of fixture paths, one per line; each call answers with the first line and removes it; the last remaining line is reused. Takes precedence over `CURL_MOCK_FIXTURE_MAP` when set.

- [ ] **Step 1: Write the failing tests** in `tests/run-azdo-lib-tests.sh`:
  - `set_tags_with_rev_sends_test_op_first` — body[0] == `{"op":"test","path":"/rev","value":12}`, body[1].op == `replace`.
  - `set_tags_without_rev_body_unchanged` — body has exactly one op, `replace`.
  - `set_tags_rev_conflict_exits_64` — fixture `{"$id":"1","message":"VS403351: Test Operation for path /rev failed, value 13 was not equal to test value 12.","typeKey":"TestPatchOperationFailedException","errorCode":0,"eventId":3000}` → exit 64, stdout empty.
  - `set_tags_other_400_is_failure` — fixture with `"typeKey":"InvalidArgumentValueException"` → exit 1.
  - `set_tags_rev_not_integer_exits_2` — `expected_rev=abc` → exit 2, no request.
  - `remove_tag_passes_rev_through` — body[0] is the test op with the given rev.
  - `latest_rev_echoes_highest` — on `azdo-revisions-tag-added.json` echoes that fixture's max `rev`.
  - `curl_mock_sequence_pops_in_order` — two calls return fixture A then B.
- [ ] **Step 2: Run** `bash tests/run-azdo-lib-tests.sh` — Expected: the new cases FAIL.
- [ ] **Step 3: Implement** the Interfaces block; update the `azdo_set_tags` header (exit codes, the #488 Step 5 evidence for the conflict shape) and the curl mock header.
- [ ] **Step 4: Run** `bash tests/run-azdo-lib-tests.sh` and `bash tests/run-script-tests.sh` — Expected: all pass. `shellcheck -x scripts/lib/azdo.sh tests/mocks/curl tests/run-azdo-lib-tests.sh` clean.
- [ ] **Step 5: Commit** `feat(azdo): make the tag write conditional on an expected revision (#573)`

### Task 2: Guard retries a conflicting removal

**Files:**
- Modify: `scripts/azdo-tag-guard.sh`
- Test: `tests/run-azdo-tag-guard-tests.sh` (and `sent_value` there: select the `replace` op, not `[0]`)

**Interfaces:**
- Consumes: `azdo_latest_rev`, `azdo_remove_tag <id> <tag> <rev>` (exit 64 = conflict) from Task 1.
- Produces: guard exit codes unchanged (0/64/65/66/1/2); header documents the retry.

Order per attempt: `azdo_latest_rev` → `has_tag` → editors → adder → allowlist checks → `azdo_remove_tag … "$rev"`. On 64, start the next attempt from `azdo_latest_rev`; after attempt 3 print `azdo-tag-guard: <id> kept changing while being checked — leaving the tag in place` and exit 1 (no comment). A tag that disappears on a re-read exits 64 as usual. The post-write `removed_tag_state` check and the comments stay as they are, after the loop.

- [ ] **Step 1: Write the failing tests:**
  - `guard_removal_sends_rev_test` — body[0].value == the revisions fixture's max rev.
  - `guard_one_conflict_then_proceeds_exits_0` — `CURL_MOCK_SEQUENCE` = conflict, replaced → exit 0, two PATCHes logged.
  - `guard_three_conflicts_exits_1_no_comment` — sequence = conflict ×3 → exit 1, three PATCHes, no `work-item update` in the az log.
  - `guard_conflict_then_stranger_exits_66` — first attempt conflicts; second attempt's judgement is a refusal → exit 66, one comment. (Revisions mock answers the same fixture each read; use the stranger fixture.)
  - `guard_latest_rev_read_failure_exits_1_keeps_tag` — revisions read fails → exit 1, no writes.
- [ ] **Step 2: Run** `bash tests/run-azdo-tag-guard-tests.sh` — Expected: new cases FAIL.
- [ ] **Step 3: Implement** the loop as described above; keep every existing case green.
- [ ] **Step 4: Run** `bash tests/run-azdo-tag-guard-tests.sh`, `bash tests/run-azdo-pipeline-run-tests.sh`, `bash tests/run-script-tests.sh` — all pass; shellcheck clean.
- [ ] **Step 5: Commit** `feat(azdo): retry the guard when the item changes during its check (#573)`

### Task 3: Ephemeral, pinned agent entrypoint

**Files:**
- Modify: `scripts/azp-agent-start.sh`
- Test: `tests/run-azp-agent-start-tests.sh`

**Interfaces:**
- Produces env contract: `AZP_AGENT_VERSION`, `AZP_AGENT_SHA256` required on **every** start (baked into the image by Task 4); `AZP_URL`/`AZP_TOKEN`/`AZP_POOL` only while unregistered, as today.
- Produces exit codes (header updated): `0`/other = `run.sh`'s own status (exec); `1` download or unpack failed; **`64`** registration needed and a required variable is missing or invalid (was `2`; `2` collides with the agent's own "retryable" exit, which must restart); **`65`** SHA-256 mismatch; **`66`** installed agent version differs from `AZP_AGENT_VERSION`. Task 4's unit lists `64 65 66` in `RestartPreventExitStatus=`.

Behaviour: download URL is `https://download.agent.dev.azure.com/agent/${AZP_AGENT_VERSION}/vsts-agent-linux-x64-${AZP_AGENT_VERSION}.tar.gz`, fetched without any credential; `sha256sum` checked before `tar`; the packages-API call (`fetch_download_url`) is deleted. On every start, after registration, compare `bin/Agent.Listener --version` (trimmed) with `AZP_AGENT_VERSION`; mismatch → 66. `config.sh … --work /azp/work` (off the `/azp/agent` volume). Hand-over is `exec ./run.sh --once`.

- [ ] **Step 1: Write the failing tests** (replace the packages-API cases; keep the token and env cases, with 2 → 64):
  - `start_download_url_from_pinned_version` — curl log contains the exact URL above for `AZP_AGENT_VERSION=5.281.1`.
  - `start_download_sends_no_credentials` — the download curl call has no `-K`, `-u` or `Authorization`, and is the only curl call.
  - `start_sha_mismatch_exits_65_leaves_dir_empty` — wrong `AZP_AGENT_SHA256` → exit 65, agent dir has no `config.sh`.
  - `start_sha_match_configures` — correct hash of the test-built tarball → `config.sh` invoked with `--work /azp/work`.
  - `start_version_drift_exits_66` — registered dir whose stub `bin/Agent.Listener --version` prints `5.280.0` → exit 66, `run.sh` not invoked.
  - `start_runs_once` — stub `run.sh` records its argv → `--once`.
  - `start_missing_pin_exits_64` — `AZP_AGENT_VERSION` unset → exit 64.
- [ ] **Step 2: Run** `bash tests/run-azp-agent-start-tests.sh` — Expected: new cases FAIL.
- [ ] **Step 3: Implement** per the Interfaces block.
- [ ] **Step 4: Run** `bash tests/run-azp-agent-start-tests.sh` and `bash tests/run-script-tests.sh` — pass; shellcheck clean.
- [ ] **Step 5: Commit** `feat(docker): run a pinned, hash-verified agent for one job per container (#573)`

### Task 4: Image pins, systemd template, setup doc

**Files:**
- Modify: `docker/azp-agent/Dockerfile`
- Create: `docker/azp-agent/azp-agent.service.example`
- Create: `docs/AZDO-PIPELINE-SETUP.md`

**Interfaces:**
- Consumes: Task 3's env contract and exit codes.

Content:
- Dockerfile: `FROM` with the Global Constraints digest (tag kept); `ENV AZP_AGENT_VERSION=5.281.1 AZP_AGENT_SHA256=<pinned>`; `mkdir -p /azp/agent /azp/work` owned by uid 1000; header comment: bump both pins together, and the digest by hand.
- Unit template: `Restart=always`, `RestartSec=5`, `RestartPreventExitStatus=64 65 66`, `ExecStartPre=-/usr/bin/docker rm -f <name>`, `ExecStart=/usr/bin/docker run --rm --name <name> --cpus 2 --memory 4g -v <volume>:/azp/agent <image>` — no `-e`, no env file, no secret; placeholders in `<…>`; comment pointing to the one-shot registration command in the setup doc.
- Setup doc, one section each: build the image; register once (one-shot container with `--env-file` from a mode-600 file deleted afterwards, fresh volume); install the unit; pool setting *auto-update off*; repository permissions for the build service (Contribute, Create branch, Contribute to pull requests; Edit work items in the area); **branch policy on the default branch: require a pull request, no bypass for the build service**; pipeline variables (`TAGGER_ALLOWLIST`, `AGENT_WORKFLOW_REF`, secret `CLAUDE_CODE_OAUTH_TOKEN`, override off); service hook + Incoming WebHook connection. Placeholders only.

- [ ] **Step 1:** Write the three files.
- [ ] **Step 2: Verify** `hadolint docker/azp-agent/Dockerfile` (or the repo's pre-commit Dockerfile hook) passes; `systemd-analyze verify` on a copy with placeholders substituted reports no errors; `pre-commit run --files <the three files>` passes; `git grep -n -E 'AZP_TOKEN=|PAT=' docker/azp-agent/azp-agent.service.example` finds nothing.
- [ ] **Step 3: Commit** `feat(docker): pin the agent image and ship an ephemeral-agent unit template (#573)`

### Task 5: Live hardening run (LOCAL-ONLY)

**Files:**
- Modify: `docs/ai-notes/2026-10-30-azdo-pipeline-poc-run.md` (new "Hardening (2026-11-02)" section)
- Private (not in this repo): `practice/azure-pipelines-edit-probe.yml`, `practice/docs/agent-host.md`

Outward actions need the maintainer's go-ahead before they start: rebuilding and replacing the agent on `<agent-host>`, the pool auto-update switch, the branch policy, the probe pipeline.

- [ ] **Step 1: Agent.** On `<agent-host>`, build the image from this branch's pinned commit; stop and remove the old container and its unit/restart policy; register once on a **fresh** volume; install the unit from the template. Check: agent online; `docker inspect` of the running container shows no `AZP_*` token; the old volume is kept until Step 6 passes, then removed.
- [ ] **Step 2: Pool and repo settings.** Pool auto-update off; branch policy on `practice` `main` (require PR, minimum 1 reviewer, build service without bypass). Check: a `git push` to `main` with the build service identity is refused (run it from a one-off pipeline step or record the policy evaluation).
- [ ] **Step 3: Probe pipeline** `practice-edit-probe` (manual, parameter `workItemId`, ≤5 lines inline bash: post one comment with `System.AccessToken`).
- [ ] **Step 4: Acceptance runs**, each recorded with run ids:
  - two consecutive jobs: different container IDs (log `hostname`), a marker file in `$HOME` written by job 1 absent in job 2;
  - happy path on a fresh item → draft PR still opens (feature-branch push allowed under the policy);
  - exit 66: tag an item outside the hook's area, run the probe on it, queue the main pipeline with `workItemId` → 66, tag removed, refusal comment; record how the build service identity appears in the revision;
  - `run.sh --once` exit status after a normal and a cancelled job;
  - wrong `AZP_AGENT_SHA256` in a throwaway container → exit 65 and the unit does not restart (or the equivalent `docker run` exit code).
- [ ] **Step 5: Docs.** Run-note section: results, the identity form, residual risks still open (tokens in the agent env; apt/pip transitive deps unpinned). Placeholders only.
- [ ] **Step 6: Leak grep** from the maintainer's notes over the branch's changed files and commit messages — zero hits. Then remove the old agent volume.
- [ ] **Step 7: Commit** `docs(azdo): record the hardening run (#573)`
