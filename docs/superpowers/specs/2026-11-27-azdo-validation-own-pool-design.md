# PR validation runs on its own agent pool (#703) — design

## Intent

Azure DevOps PR build validation (`docs/AZDO-PIPELINE-SETUP.md` §9) runs the
PR's own YAML and build steps on the self-hosted agent as the agent's user
`azp`. The same agent, with the same persistent volume at `/azp/agent`, also
takes the `ai-implement` jobs, whose driver holds the job token and whose
pipeline carries `CLAUDE_CODE_OAUTH_TOKEN`.

The issue names the tampering risk (PR code rewrites the agent binaries, and
the next job runs them). Recon on the sandbox agent, 2026-11-27, found the
larger one: `/azp/agent` is mode 0700 owned by `azp`, and so are the
registration files `.credentials` and `.credentials_rsaparams` (the agent's
private key). A validation step can **read** them, then impersonate the agent
from anywhere and receive the next `ai-implement` job, secrets included.
ADR-024 already names this ("one that copies them can impersonate the agent")
for the implement agent; the user boundary it built protects an implement run
from its own agent, not from an earlier validation job on the same
registration.

The goal is that no code from a PR ever runs on an agent registration that
takes `ai-implement` jobs.

## Goals

- Validation jobs run on a **separate pool** with their own agent registration,
  own volume and own systemd unit.
- The `ai-implement` pool admits **only** the `ai-implement` pipeline, enforced
  by Azure DevOps pool permissions, not by YAML. A PR that rewrites `pool:` in
  `azure-pipelines-pr.yml` to the implement pool gets no agent.
- The setup doc, the cutover runbook, the template and the unit example say
  this, and Layer-1 tests pin it.

## Non-goals

- No change to the driver scripts (`implement-azdo.sh`, the boundary entry
  points). The fix is operator setup, enforced by Azure DevOps.
- No start-time integrity check of the agent binaries, and no read-only mount
  (the agent writes `_diag/` at runtime, so `:ro` breaks it; neither helps
  against theft).
- No hardening of the validation agent itself. Its own credentials stay
  readable by PR code; what an attacker gets from them is validation jobs only.

## Anti-goals

- A separation that lives in the validation YAML (a `pool:` value, a demand, a
  `sudo` wrapper around the build step). The PR controls that YAML (§9.4), so
  such a separation is no boundary.

## Approaches

1. **Own pool, enforced by pool permissions (chosen).** Covers theft and
   tampering. Cost: a second agent container (the unit's `--memory 4g` cap) and
   a second one-shot registration.
2. **Own pool plus a start-time integrity check** of the agent binaries against
   a manifest baked into the image. Defence in depth against tampering only;
   more code and tests for a risk approach 1 already removes. Rejected.
3. **Document the risk only.** Cheap, leaves the hole open. Rejected.

Also considered and dropped: running the validation build step as `awf-agent`
(PR YAML can drop the wrapper) and a read-only volume mount (breaks the agent,
does not stop reading).

## Design

### Pools

- `<pool>` keeps its meaning: the pool of the `ai-implement` agent(s).
- New placeholder `<validation-pool>`: the pool of the validation agent(s).
- On `<pool>`: *Project settings > Agent pools > `<pool>` > Security >
  Pipeline permissions* lists **only** the `ai-implement` pipeline, and
  "Grant access permission to all pipelines" (open access) is **off**.
- On `<validation-pool>`: the validation pipeline is authorized (today's §9.2
  step 4, moved to this pool).
- Agent pools are organization-level with a project-level queue; the doc
  states the click path for the project-level pool security only, as §9.2
  already does.

### The validation agent

A second registration exactly as §10.1 describes for the dotnet agent: own
`<name>` (for example `<name>-validation`), own `AZP_AGENT_NAME`, own
`<volume>`, own one-shot registration (§2, with `AZP_POOL=<validation-pool>`),
own unit (§3). If the repo is .NET, it uses the dotnet image (§10), since
validation runs `dotnet build`/`dotnet test`. The §10.1 `--replace` warning
applies: never reuse the implement agent's name.

### Docs (`docs/AZDO-PIPELINE-SETUP.md`)

- **§9 intro:** one sentence that validation runs on its own pool, pointing to
  the new subsection.
- **§9.2 step 4:** authorize the validation pipeline on `<validation-pool>`,
  not `<pool>`.
- **New §9.6 "Run validation on its own pool"** (after §9.5 Draft PRs, or the
  next free number if #699 added one): why (the registration files are
  readable by any build step; theft means impersonation and the next
  `ai-implement` job), what to set up (second registration and unit, pool
  permissions on both pools, open access off on `<pool>`), the check (a
  validation PR whose YAML names `<pool>` never gets an agent; it stays
  waiting for authorization), and the residual risk (the validation agent's
  own identity is still exposed; with #699 that includes the feed-read token).
- **§10:** one line that the validation agent needs the dotnet image when the
  repo's validation builds .NET.
- **§13:** one line that the boundary covers the implement run's own agent,
  and that an earlier validation job is kept off this registration by §9.6.

### Template (`templates/azdo/pr-validation.yml`)

`pool: <pool>` becomes `pool: <validation-pool>`, with a comment that this
must be the validation pool and that the implement pool refuses this pipeline
(§9.6).

### Unit example (`docker/azp-agent/azp-agent.service.example`)

A header comment: one unit per agent; the validation agent has its own unit,
container name and volume, never the implement agent's volume.

### Cutover runbook (`docs/AZDO-CUTOVER.md`, step 6)

The §9 checklist item adds: on its own pool (`<validation-pool>`), and the
implement pool admits only the `ai-implement` pipeline.

### Decision record (`docs/DECISIONS.md`)

New ADR (next free number, ADR-026 on main as of 2026-11-27): "PR validation
runs on its own agent pool". Context: the recon finding above and ADR-024's
third bullet. Decision: separate pool, enforced by pool permissions. Rejected:
approaches 2 and 3, the `awf-agent` wrapper, the read-only mount.
Consequences as below.

### Tests (Layer 1)

- `tests/run-azdo-templates-tests.sh`: the template's pool placeholder is
  `pool: <validation-pool>` (replacing the `pool: <pool>` assertion) and the
  file does not contain `pool: <pool>`.
- `tests/run-azdo-cutover-doc-tests.sh` (or a new
  `tests/run-azdo-setup-doc-tests.sh` if the existing file is cutover-only in
  shape): the setup doc has the §9.6 heading, names `<validation-pool>`, and
  says the implement pool's pipeline permissions list only the `ai-implement`
  pipeline; the cutover step 6 names `<validation-pool>`.
- The existing leak checks keep passing: no organization, host or pool names.

### Layer 3 (operator, after merge — not part of the PR)

On the sandbox: register a second agent into a new validation pool, move
pipeline 3 to it, turn open access off on the implement pool and authorize only
pipeline 1 there. Then:

1. A normal `practice` PR validates green on the validation agent.
2. A `practice` PR whose `azure-pipelines-pr.yml` names the implement pool gets
   no agent (the run waits for or is refused pool authorization).
3. An `ai-implement` run still runs on the implement agent.

Record the result in `docs/ai-notes/`.

## Consequences

- Each consumer needs a second agent container; on a shared host that is
  another `--memory 4g` cap.
- A validation agent's identity can still be stolen by PR code. That yields
  validation jobs, and with #699 the build service's feed-read token those jobs
  carry. Separation lowers the blast radius, it does not remove it.
- Existing setups keep working until the operator applies §9.6; the template
  change only affects new copies.

## Left to the builder

- Exact wording and placement of the new doc paragraphs, anchored to section
  headings, since #699 rewrites parts of §9 and §14.
- Whether the setup-doc assertions extend the cutover test file or get their
  own file (follow whichever keeps each test file to one doc).
