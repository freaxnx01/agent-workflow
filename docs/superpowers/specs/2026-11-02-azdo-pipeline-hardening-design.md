# Azure Pipelines `ai-implement` hardening — Design

**Issue:** #573 (phase 1 follow-up) · **Date:** 2026-11-02 · **Status:** approved

The phase-1 PoC (#576) works end to end, and its run note
(`docs/ai-notes/2026-10-30-azdo-pipeline-poc-run.md`) lists the risks it
accepted to get there. This design closes the ones that matter before the
pipeline runs against a repository that is not a sandbox.

## Intent

A run must start from a known, verified state and leave nothing behind for the
next run. The trust gate must hold even when the item changes while it is
deciding, and its "someone else edited this" refusal must be proven live rather
than by fixtures only. Nothing a run does may change what the next run executes.

## Goals

1. **G1 — Fresh container per job.** No home directory, workspace or tool cache
   survives from one job to the next.
2. **G2 — Verified, pinned inputs.** The base image is pinned by digest and the
   agent tarball by version and SHA-256. A mismatch fails the start, loudly.
3. **G3 — The guard's tag write is conditional on the revision it judged.** A
   concurrent edit cannot slip between the guard's decision and its tag
   removal.
4. **G4 — Exit 66 proven live,** without a second human account.
5. **G5 — A run cannot change the pipeline that runs next.** The build service
   cannot push to the target repository's default branch, where the pipeline
   definition lives.

## Non-goals

- Splitting the Claude token and the job access token into separate steps. The
  agent keeps both in its environment, as on the GitHub path; recorded again,
  not fixed.
- Hash-locking apt packages or the Azure CLI's transitive Python dependencies.
  The top-level versions stay pinned as they are.
- Phase 2/3 features (retry, AI review, auto-merge).
- Rolling out to a non-sandbox organisation. That is the step after this one.

## Anti-goals

- A hardened agent that needs a PAT on every start. Registration stays a
  one-time step; the long-running pieces hold no PAT.
- Giving the agent container access to the host's Docker socket. That is root
  on the host, which is worse than the persistent home it would fix.

## Decisions

### D1 — Ephemeral agent: `run.sh --once` in a `--rm` container, restarted by the host

The container runs the agent with `--once`: it takes one job and exits.
`docker run --rm` discards the container, and a host-side supervisor starts a
fresh one from the image. The home directory and everything in the container
layer are new for every job.

What survives is only the agent's **registration** (`.agent`, `.credentials`,
`.credentials_rsaparams`) and the agent binaries, on the existing `/azp` volume.
The agent's **work folder moves off that volume** into the container layer (or
a tmpfs), so the checkout, `_temp` (where agent-workflow is cloned) and any
tool cache die with the container.

The supervisor is a systemd unit with `Restart=always` around
`docker run --rm …`. A template unit ships in `docker/azp-agent/`, with
placeholders for host-specific values; the real unit lives with the host's
private configuration, not in this repository.

**Migration: re-register once.** The current registration has its work folder
on the volume, baked into `.agent`. Rather than editing that file, the agent is
re-registered once on a fresh volume, with a PAT, in the same one-shot
registration container the PoC used. *(My call; the sandbox makes this cheap.)*

**Configuration errors stop the restart loop.** The start script exits with
distinct codes for a missing registration, a SHA-256 mismatch and an installed
version that differs from the pin; the unit lists them in
`RestartPreventExitStatus=`, so a bad pin stops loudly instead of crash-looping.
Whether `run.sh --once` exits 0 after a normal and a cancelled job is recorded
in the live run. *(My call.)*

Between jobs the agent is offline for the few seconds a container takes to
start. A job queued in that window waits; with one parallel job that costs
nothing.

**Rejected: container jobs** (`container:` in the YAML). They need the agent to
drive Docker, i.e. the host socket (anti-goal). **Rejected: a cleanup step at
the end of the job.** It does not run when the job is cancelled or the agent
dies, and it has to know everything a run might leave behind.

### D2 — The agent version and its SHA-256 are pinned; the download needs no credential

`azp-agent-start.sh` takes `AZP_AGENT_VERSION` and `AZP_AGENT_SHA256`
(required, with defaults kept in one place next to the Dockerfile, the same
pattern as `install-claude-cli.sh`'s `CLAUDE_CLI_VERSION`/`INSTALLER_SHA256`).
It builds the download URL from the version
(`https://download.agent.dev.azure.com/agent/<v>/vsts-agent-linux-x64-<v>.tar.gz`),
verifies the SHA-256 before unpacking, and refuses on mismatch. The SHA-256 is
checked on **download**; on **every start** the script compares the installed
agent's version with `AZP_AGENT_VERSION` and refuses to start on a mismatch
rather than silently re-extracting. *(My call.)*

The pinned values come from the packages API's `hashValue` for that version,
read once during the local-only live task, the same way as the image digest
(D3). Neither is fetched at run time.

This removes the packages-API call, so the PAT is used by `config.sh` only.

The pool's **agent auto-update is switched off**, so the pinned version is the
version that runs. Updating means bumping both values. If Azure DevOps ever
demands a newer agent, jobs fail with a clear message; that is the intended
signal.

### D3 — The base image is pinned by digest

`FROM debian:13-slim@sha256:<digest>`, with the tag kept for readability. The
digest is resolved once when this is implemented and bumped by hand.

### D4 — The guard's tag removal carries a json-patch `test` on `/rev`

The guard already reads the item's revisions to decide. Its tag removal gains a
`test` operation on `/rev` with the revision number that decision was based on.
The live write-back run (#488, Finding 6) showed the service honours it.

On a failed test (the item changed in between), the guard **re-evaluates from
scratch**: re-read the revisions, re-run every check, retry the conditional
removal. The conflict is recognisable: the service rejects the whole patch with
`typeKey=TestPatchOperationFailedException` (`VS403351`), and the accompanying
tag change does not apply (#488 live run, Step 5). Only that response triggers a
re-evaluation; every other error stays an error. The existing post-write check
that the tag is really gone stays, since it guards against a different failure.

After **3** failed attempts it exits 1 and the existing failure
comment fires. A conflict never falls through to "proceed".

`azdo_set_tags` (or a sibling) gains an optional expected-revision argument;
callers without one behave exactly as today.

### D5 — Exit 66 is proven with the build service as the "other person"

The guard already treats the build service as an outsider unless it is on the
allowlist. A small **probe pipeline** in the sandbox repository
(`practice-edit-probe`, manual only, parameter `workItemId`) posts one comment
on the item using `System.AccessToken`.

Live test: tag an item outside the hook's area, run the probe on it, then queue
the main pipeline manually with that `workItemId`. Expected: exit 66, tag
removed, refusal comment, no agent run.

Comment additions and edits create revisions (verified live in the PoC run,
finding 2). The probe's revision is attributed to the project build service; if
it shows up without a mail-shaped identity, the guard still refuses, because an
unidentified later editor is not on the allowlist. Which form it takes is
recorded in the live run.

The probe pipeline lives only in the sandbox; nothing in this repository
depends on it.

### D6 — The default branch is protected against the build service

A branch policy on the target repository's default branch (require a pull
request; the build service gets no bypass) keeps a run from changing
`azure-pipelines.yml` or anything else the next webhook run checks out. The
agent can still push its feature branch and open its draft PR.

The policy covers the default branch only, so the agent's push of its feature
branch is unaffected. This is configuration, not code: it becomes a required step in the consumer
setup documentation and is applied to the sandbox repository.

## Constraints

- **The repository is public.** No host, pool or organisation names other than
  the personal sandbox org. Placeholders `<agent-host>`, `<pool>`.
- Bash conventions and Layer-1 fixture tests as for the PoC; every new branch
  in a script gets a fixture. No test reaches the network.
- Live verification is local-only, against the sandbox, as for the PoC.
- The GitHub path is not touched.

## Acceptance criteria

- [ ] Two consecutive jobs on the agent see different container IDs and an
      empty home directory at start (a marker file written by job 1 is absent
      in job 2).
- [ ] The persistent agent container's stored env holds no PAT; the systemd
      template holds no secret.
- [ ] A wrong `AZP_AGENT_SHA256` makes the agent start fail before unpacking
      (fixture test); the agent starts with the right one (live).
- [ ] The Dockerfile's `FROM` carries a digest.
- [ ] The guard's tag write sends a `test` on `/rev`; a fixture where the test
      fails once re-evaluates and proceeds; one where it fails 3 times exits 1.
- [ ] Exit 66 observed live via the probe pipeline.
- [ ] The build service's direct push to the sandbox default branch is refused;
      a happy-path run still opens its draft PR.
- [ ] The run note gains a "hardening" section; consumer setup docs list the
      branch policy and the auto-update switch.
- [ ] The full script test suite passes; the leak grep is clean.

## Left to the builder

- Whether the work folder is a tmpfs mount or just the container layer.
- The supervisor's restart back-off, as long as a crash-looping agent does not
  spin faster than about once every few seconds.
- The exact shape of the expected-revision argument.
