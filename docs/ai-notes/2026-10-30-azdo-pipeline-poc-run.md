# Live run of the Azure Pipelines `ai-implement` PoC (#573)

Run 2026-10-30 to 2026-11-02 against the sandbox org `AndreasImboden0022`,
project `agent-workflow-sandbox`, repository `practice`. Spec:
`docs/superpowers/specs/2026-10-30-azdo-pipeline-poc-design.md`.

**Headline: the phase-1 loop works.** Adding the `ai-implement` tag to a work
item ran the guard, the agent and the driver on a self-hosted agent and opened
a linked draft PR with a report comment. One tag gave exactly one agent run.

Infrastructure names are placeholders here on purpose: `<agent-host>` is a
maintainer-owned box, `<pool>` its agent pool. The real values live in the
private `practice` repository (`docs/agent-host.md`).

---

## Setup as run

| Piece | Shape |
|---|---|
| Agent | `docker/azp-agent` image on `<agent-host>`, `--cpus 2 --memory 4g`, registered once by a short-lived container holding the PAT; the long-running container's stored env is `PATH` only |
| Pipeline | `practice/azure-pipelines.yml`, pool `<pool>`, `resources.webhooks` trigger `aiImplementHook`, optional `workItemId` parameter for manual runs |
| Trigger | service hook *Work item updated*, field filter **Tags**, area `agent-workflow-sandbox\practice`, into an Incoming WebHook service connection |
| agent-workflow | cloned at a pinned SHA (`AGENT_WORKFLOW_REF`), entry point `scripts/azdo-pipeline-run.sh` |
| Claude | subscription token as secret pipeline variable `CLAUDE_CODE_OAUTH_TOKEN` |

## Success criteria

| Criterion | Run(s) | Result |
|---|---|---|
| Manual run on an untagged item | 1 | guard exit 64, nothing to do, green |
| Tag by the maintainer, no Claude token yet | 2 → 3 | guard accepted and removed the tag, agent failed `api_auth`, failure comment posted; run 3 (from the removal) exited 64 |
| Edit another field (title) | — | no run queued |
| Tagger not on the allowlist (allowlist set to an unrelated address) | 4 | guard exit 65, tag removed, refusal comment, no agent |
| Tag by the maintainer, build service without write rights | 6 → 7 | agent succeeded, push refused `TF401027 … GenericContribute`, failure comment posted; run 7 exited 64 |
| Same, after granting the build service *Contribute*, *Create branch*, *Contribute to pull requests* | 8 → 9 | **draft PR !5** (`HELLO.md`, exactly the test plan's line), work item linked, report comment; run 9 exited 64 |
| Manual run with `workItemId` on a tagged item outside the hook's area | 10 | **draft PR !6**, item linked, report comment; no hook run queued (area filter holds) |
| `docker stats` during an agent run | 10 | peak 71 % of one CPU, 376 MiB, within the 2 CPU / 4 GiB cap |
| Tag by a second, non-allowlisted identity; later edit by one (guard exit 66) | — | **not exercised** — the sandbox has one identity. Covered by Layer-1 fixtures only |

## Findings

1. **The build service needs write rights on the repository.** Reading the
   repo and editing work items works out of the box; pushing does not. Grant
   the project build service identity *Contribute*, *Create branch* and
   *Contribute to pull requests* on the target repository before the first
   run. The symptom is a successful agent followed by a 403 on push.
2. **A comment edit creates a work-item revision.** Adding a comment and then
   editing it moved the item from revision 8 to 9 to 10. The guard's
   later-editor check therefore also sees comment edits; no separate
   comment-timestamp check is needed.
3. **The hook fires again when the guard removes the tag.** Expected and
   harmless: the follow-up run finds no tag and exits 64 in seconds. It does
   occupy the single free parallel job for that time.
4. **The Incoming WebHook connection carries no HMAC secret.** Azure DevOps
   service hooks cannot sign their payloads. A forged post can only queue a
   run, and the guard re-reads all state from the API, so the worst case is a
   no-op run that blocks the job briefly.
5. **The area filter is the trigger scope.** An item tagged outside
   `agent-workflow-sandbox\practice` queued nothing; it ran only when queued by
   hand with `workItemId`.
6. **Pipeline runs report reason `manual`**, webhook-triggered ones included.
   Tell them apart by the run's trigger info, not the reason field.

## Accepted residual risks

Recorded here, not fixed in code, for the PoC:

- **Persistent agent home.** The agent container keeps its home directory
  between runs, so a compromised run could leave something for the next one.
  A per-job container is phase-2 material.
- **Tokens in the agent's environment.** `CLAUDE_CODE_OAUTH_TOKEN` and the job
  access token are in the agent process's env, as on the GitHub path.
- **No optimistic-concurrency test on the tag write.** The guard does not send
  a json-patch `test` on `/rev`. The single parallel job serialises runs, so
  the race needs two writers within seconds.
- **TOCTOU windows** between the guard's revision reads, and between the guard
  and the driver's read of the item. Exploiting either needs an actor inside a
  seconds-wide window.
- **Image not digest-pinned.** The base image and the agent tarball are
  fetched by tag and version.

---

## Hardening (2026-11-02)

The hardening from `docs/superpowers/specs/2026-11-02-azdo-pipeline-hardening-design.md`
was run live against the same sandbox. The agent was rebuilt from the branch,
registered once on a fresh volume, and is now run by the systemd unit from
`docker/azp-agent/azp-agent.service.example`. The pool's auto-update is off,
and `practice`'s `main` requires a pull request (1 reviewer; the creator's vote
counts, because the sandbox has one member).

| Check | Run(s) | Result |
|---|---|---|
| Two consecutive jobs | 12, 13 | different containers; a marker written to `$HOME` by job 1 is absent in job 2 |
| Work folder off the volume | 15 | the job ran its scripts from `/azp/work/_temp/…`, i.e. in the container layer, not on the volume; the `--rm` container is removed after the job |
| Long-running container holds no PAT | — | its env is `PATH`, `AZP_AGENT_VERSION`, `AZP_AGENT_SHA256` only; the unit holds no secret |
| Build service pushes to `main` directly | 14 | refused: `TF402455: Pushes to this branch are not permitted; you must use a pull request` |
| Guard exit 66, live | 15, 16 | build service commented after the maintainer's tag; the manual run refused it, removed the tag, posted the refusal comment, no agent |
| Happy path under the branch policy | 17 → 18 | **draft PR !8**, item linked, report comment; the follow-up run exited 64 |
| `run.sh --once` after a normal and a cancelled job | 12–18, 19 (cancelled), 20 | the unit's journal shows one restart per job and no non-zero main-process exit (systemd logs only those), so `run.sh --once` exited 0, cancelled job included; run 20 ran in a new container after the `ExecStop` fix |
| Wrong `AZP_AGENT_SHA256` | — | a throwaway `docker run` exited **65**; the agent directory on its test volume was empty afterwards (`ls -A` counted 0 entries). That the unit then stops restarting rests on `RestartPreventExitStatus=65`; it was not observed under the unit |

### Findings

1. **The build service identity has no mail address.** In revisions it is
   `Build\<project-id>`. The guard treats it as a uniqueName that is not on the
   allowlist, which is what made the exit-66 test work without a second person.
2. **The agent ignores SIGINT and SIGTERM.** Ctrl+C and `docker kill --signal
   INT` left it running for 40 s, with and without `docker run --init`;
   `docker stop` only ends it through its SIGKILL fallback (exit 137). The setup
   doc therefore stops the registration container with `docker kill`.
3. **`ExecStop` must ignore a failed stop.** After a job the `--rm` container is
   already gone, so `docker stop` fails; without the `-` prefix every normal
   restart was recorded as a unit failure. The template carries the prefix.
4. **Registering under the same agent name replaces the old agent**, and the
   new one waits until the old session ends ("A session for this agent already
   exists … Retrying until reconnected"). This happened to the registration
   container, because the old agent container was still connected. Stop the
   old container first.

### Risks still open

- **Tokens in the agent's environment** (`CLAUDE_CODE_OAUTH_TOKEN`, the job
  access token), as on the GitHub path. Out of scope by the spec.
- **apt packages and the Azure CLI's transitive Python dependencies** are not
  hash-locked; their top-level versions are.
- The window between the guard's tag removal and the driver's read of the item
  remains; any edit before the removal now forces a re-check.

The "persistent agent home", "no `/rev` test" and "image not digest-pinned"
risks listed above are closed by this hardening.

### Acceptance criteria

| Criterion | Status |
|---|---|
| Fresh container and empty home per job | shown live, runs 12, 13 |
| No PAT in the long-running container; no secret in the unit | shown live (container env), and by review of the template |
| Wrong SHA-256 fails before unpacking | Layer-1 test, and shown live with `docker run` (exit 65) |
| `FROM` carries a digest | in the Dockerfile; the image was built from it |
| Tag write sends a `test` on `/rev`; one conflict re-evaluates, three exit 1 | Layer-1 tests only. A real concurrent edit inside the guard's seconds-wide window was **not exercised** live; the happy path and exit-66 runs exercised the conditional write without a conflict |
| Exit 66 live | shown, runs 15, 16 |
| Build service cannot push to `main`; draft PR still opens | shown, runs 14 and 17 |
| Run note and setup docs (branch policy, auto-update) | this section; `docs/AZDO-PIPELINE-SETUP.md` |
| Full test suite and leak grep | `tests/run-script-tests.sh` 971/971 on the branch; leak grep over the branch's changed files and commit messages: no hits |

The old agent container and its volume were removed after these checks. The
unit's first start after the registration container was killed found no
leftover session: the agent was listening within about 40 s.
