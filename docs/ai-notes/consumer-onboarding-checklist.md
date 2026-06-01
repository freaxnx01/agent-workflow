# Onboarding a new consumer repo to the agent-pipeline

A repo-agnostic checklist for wiring any repo up as a consumer of the
`freaxnx01/agent-pipeline` reusable Issue→PR pipeline. Generalized from the
quicktask-vikunja onboarding (see
`quicktask-vikunja-pipeline-runbook.md` for the worked example).

Canonical reference: `../CONSUMER-SETUP.md`. This file is the short operator
checklist plus the gotchas that bit us in practice.

Throughout, replace `<owner>/<repo>` with the target consumer repo.

---

## 0. Pre-flight

- [ ] Decide **public vs private**. Public → GitHub-hosted runners only
      (`'["ubuntu-latest"]'`). **Never attach a self-hosted runner to a public
      repo** — fork-PR attack surface (agent-pipeline DESIGN.md, non-negotiable).
- [ ] Confirm the pipeline ref you'll pin. Use `@v1` once real tags exist; until
      then a `v1` branch on agent-pipeline also resolves for `uses: …@v1`.

## 1. Add the auth secret

The pipeline authenticates Claude via a Max-subscription OAuth token.

- [ ] Generate once (any logged-in Claude Code machine): `claude setup-token`
      → token valid ~1 year.
- [ ] Store it as a **repository secret** named exactly `CLAUDE_CODE_OAUTH_TOKEN`.

Set it without the value ever touching a transcript or shell history. From a
secrets manager (Passbolt example — adjust the CLI/field to yours):

```bash
passbolt get resource --id <RESOURCE_ID> --json \
  | jq -r '.password' \
  | gh secret set CLAUDE_CODE_OAUTH_TOKEN -R <owner>/<repo>
```

Or interactively (paste, then Ctrl-D):

```bash
gh secret set CLAUDE_CODE_OAUTH_TOKEN -R <owner>/<repo>
```

Verify (value is never displayed):

```bash
gh secret list -R <owner>/<repo>
```

- [ ] Only if using the OpenCode/OpenRouter backend: also set `OPENROUTER_API_KEY`.
      Skip for the Claude path.

> Secret hygiene: keep the token on the path secrets-manager → your shell →
> GitHub's encrypted store. Don't paste it into files, issues, commits, or an
> agent's chat context. There is no API/MCP tool exposed here to set Actions
> secrets — this step is always done by a human or a local CLI session.

## 2. Commit the consumer stub

Add `.github/workflows/claude.yml` (on a feature branch → PR, not direct to main):

```yaml
name: Claude
on:
  issues:
    types: [labeled]
  workflow_dispatch:            # lets retry-dispatch.sh re-kick a run
    inputs:
      issue-number:
        description: Issue number to implement
        type: number
        required: true

jobs:
  claude:
    if: >-
      (github.event_name == 'issues' && github.event.label.name == 'ai-implement')
      || github.event_name == 'workflow_dispatch'
    uses: freaxnx01/agent-pipeline/.github/workflows/claude-implement.yml@v1
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
    with:
      issue-number: ${{ github.event.issue.number || inputs.issue-number }}
      runner-labels: '["ubuntu-latest"]'      # public repo → GitHub-hosted only
      default-model: claude-opus-4-7
      # ── REQUIRED override (see gotcha #1) ──
      pipeline-repo: freaxnx01/agent-pipeline
      pipeline-ref: v1
      # auto-review omitted → draft-PR-only (safe default)
```

- [ ] If you want issue chaining later, also add `.github/workflows/chain-dispatch.yml`
      (see `../CONSUMER-SETUP.md §4`). Requires auto-review on. Skip for first run.

## 3. First run = a trivial smoke test

Always validate wiring with a near-zero-risk issue before trusting the pipeline
with path-sensitive work (agent-pipeline DESIGN.md). A good smoke test:

- touches only files certain to exist / be safe (e.g. a new `CONTRIBUTING.md`
  + a one-line `README.md` link),
- explicitly fences off source/test/build dirs in an **Out of scope** section,
- uses the spec template from DESIGN.md (Goal / Affected files / Out of scope /
  Existing patterns / Acceptance criteria / Test expectations / Constraints).

- [ ] Create the issue, then label it **`ai-implement`**.
- [ ] (Optional, tidy) pre-create labels: run agent-pipeline's
      `scripts/ensure-issue-labels.sh` against the repo. The pipeline self-heals
      labels regardless.

## 4. Observe

Applying `ai-implement` triggers the run. Expect:

- An Actions run (`Claude` → `claude-implement.yml`).
- A **draft PR** whose body contains `Closes #<issue>`.
- A metrics comment on the issue: outcome, duration, turns, cost, tokens,
  cache-hit rate, context utilization, run link.
- Labels stamped: `ai:running` → `ai:done` / `ai:failed`, plus `ctx:*`.

## 5. Graduating to auto-merge (later, per repo)

Only after several clean draft-only runs. Per `../CONSUMER-SETUP.md §2` +
DECISIONS.md ADR-002:

- [ ] Set `auto-review: true` at the call site **and** label issues
      `ai-auto-review` (both required).
- [ ] Enable repo settings: **Allow squash merging** + **Allow auto-merge**.
- [ ] Wire a **required** vulnerable-dependency status check on the default
      branch (ADR-002 gate 5 — the one thing between auto-merge and a
      supply-chain bump). Pick per stack (`npm audit`, `pip-audit`,
      `dotnet list package --vulnerable`, `cargo audit`, `govulncheck`, …).
- [ ] Optional: `.claude-auto-merge-blocklist` at repo root for extra path fences.

---

## Gotchas (learned the hard way)

1. **`pipeline-repo` / `pipeline-ref` MUST be overridden.** The reusable
   workflow defaults them to `freaxnx01/claude-pipeline@main` — the project's
   *old* name. The cross-repo checkout of shared `scripts/` uses these, and
   `@v1` in `uses:` does **not** propagate to that checkout (GitHub's
   `workflow_ref` points at the caller). Set both to
   `freaxnx01/agent-pipeline` / `v1` or the run breaks at the scripts step.

2. **`v1` may be a branch, not a tag (for now).** agent-pipeline had no tags at
   first onboarding; a `v1` branch was created so `@v1` resolves. `uses:`
   accepts either. Promote to real `v1.0.0` + moving `v1` tags when convenient
   (the web session couldn't push tags: git proxy 403 + no create-tag MCP tool).

3. **Public repos: hosted runners only.** No self-hosted, ever.

4. **Setting the secret is always a human/CLI step.** No exposed API/MCP tool
   sets Actions secrets, and you don't want a long-lived token flowing through
   an agent's context anyway.

5. **First run draft-only.** Don't enable auto-merge until you've watched the
   pipeline behave on the repo and the required vuln check is in place.
