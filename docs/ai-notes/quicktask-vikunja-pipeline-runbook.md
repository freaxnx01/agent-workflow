# Runbook: Wire quicktask-vikunja into the agent-pipeline

> Handoff from a web session (scoped to `freaxnx01/agent-pipeline` only) to a
> local Claude Code CLI session that has access to **both** repos
> (`agent-pipeline` + `quicktask-vikunja`). This file is the source of truth for
> finishing the wiring and running the first Issue→PR pipeline run.

## TL;DR

`agent-pipeline` is the reusable-workflow pipeline. `quicktask-vikunja` is a
Flutter/Dart Android share-target app (the consumer). Goal: run a real
`ai-implement` Issue→PR pipeline run against quicktask-vikunja.

Remaining work is **all on the quicktask-vikunja side** (the web session could not
reach it). Three things: add a secret, commit the consumer stub, create+label an
issue.

## State already done (in agent-pipeline)

- ✅ A **`v1` branch** was created on `freaxnx01/agent-pipeline` pointing at
  `67e831b0c4c353770ce743c7038dd6b6a8d2e550` (main at handoff time).
  `uses: ...@v1` now resolves to it.
  - ⚠️ It is a **branch, not a SemVer tag**. The web session could not push tags
    (git proxy returned 403; the GitHub MCP has no create-tag tool). **Action for
    this CLI session (you have push access): replace the `v1` branch with real
    annotated tags** — see "Fix the v1 tag" below.

## Fix the v1 tag (do this first — you have push access)

The CI stack convention is "reusable workflows are versioned by git **tag**", with
a moving `vMAJOR` tag. Replace the stand-in branch with proper tags:

```bash
cd <agent-pipeline checkout>
git fetch origin
SHA=67e831b0c4c353770ce743c7038dd6b6a8d2e550   # or: git rev-parse origin/main, if unchanged

# delete the stand-in branch (locally + remote)
git push origin --delete v1
git branch -D v1 2>/dev/null || true

# create real annotated tags
git tag -a v1.0.0 "$SHA" -m "release: v1.0.0 — first stable Issue→PR pipeline"
git tag -a v1      "$SHA" -m "v1 → v1.0.0 (moving major tag)"
git push origin v1.0.0 v1
```

If main has advanced past `67e831b` and you want to release the newer tip, tag
`origin/main` instead and confirm CHANGELOG `[Unreleased]` is populated first
(it was empty at handoff).

> If you'd rather not bother with tags right now, the `v1` **branch** already works
> for `@v1` — skip this section and proceed. Just know it diverges from the CI
> conventions and "moving it forward" means a branch force-update, not `git tag -f`.

## Step 1 — Add the secret to quicktask-vikunja

Settings → Secrets and variables → Actions → New repository secret:

- **Name:** `CLAUDE_CODE_OAUTH_TOKEN`
- **Value:** generate via `claude setup-token` against your Max subscription.

(Public repo → GitHub-hosted runners only. Never attach a self-hosted runner here —
fork-PR attack surface. This is a non-negotiable constraint in agent-pipeline's
DESIGN.md.)

## Step 2 — Commit the consumer stub

Add `quicktask-vikunja/.github/workflows/claude.yml`:

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
      # ── REQUIRED for agent-pipeline consumers ──
      # The reusable workflow defaults pipeline-repo/ref to
      # freaxnx01/claude-pipeline@main (the project's original name). Override
      # both so the shared-scripts cross-repo checkout resolves to THIS pipeline.
      pipeline-repo: freaxnx01/agent-pipeline
      pipeline-ref: v1
      # auto-review omitted → draft-PR-only posture (safe first run)
```

### Why `pipeline-ref: v1` is not optional

The reusable workflow checks out its shared `scripts/` from
`pipeline-repo`@`pipeline-ref`. GitHub's `github.workflow_ref` refers to the
*caller's* workflow, so `@v1` in `uses:` does **not** propagate to that script
checkout — it must be set explicitly, or scripts default to
`freaxnx01/claude-pipeline@main` and the run breaks.

## Step 3 — (Optional) chain-dispatch stub

Only needed if you later enable auto-review/auto-merge and want `Blocked by:`
successors to fire on merge. **Skip for the first run.** When ready, add
`quicktask-vikunja/.github/workflows/chain-dispatch.yml`:

```yaml
name: Chain-dispatch on merged ai-implement PR
on:
  pull_request:
    types: [closed]

permissions:
  issues: read
  pull-requests: read
  actions: write

jobs:
  chain:
    if: >-
      github.event.pull_request.merged == true
      && contains(github.event.pull_request.labels.*.name, 'ai-implement')
    uses: freaxnx01/agent-pipeline/.github/workflows/chain-dispatch.yml@v1
    with:
      closed-pr-number: ${{ github.event.pull_request.number }}
      pipeline-repo: freaxnx01/agent-pipeline
      pipeline-ref: v1
    secrets:
      GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

## Step 4 — Create the first issue (deliberately trivial smoke test)

DESIGN.md says the first real run should be trivial to validate wiring before
trusting the pipeline with path-sensitive work. Paths below are certain in any
Flutter repo → zero path-discovery risk. Create the issue with this body, then
label it **`ai-implement`**:

```markdown
## Goal
Add a CONTRIBUTING.md to the repo root documenting how to run the app,
run tests, and the branch/commit conventions. Pure documentation — no
app code changes.

## Affected files (explicit paths)
- CONTRIBUTING.md — new file (primary change)
- README.md — add a one-line link to CONTRIBUTING.md near the top

## Out of scope
- DO NOT touch anything under lib/, test/, android/, windows/, or tool/
- DO NOT modify pubspec.yaml or any CI workflow
- DO NOT change app behaviour in any way

## Existing patterns to follow
- Mirror the tone/structure of the existing CLAUDE.md and
  PROJECT-OVERVIEW.md docs already in the repo
- This is greenfield for CONTRIBUTING.md — no prior version to mirror

## Acceptance criteria
- [ ] CONTRIBUTING.md exists at repo root with: setup, `flutter test`,
      branch naming, and Conventional Commits sections
- [ ] README.md links to it
- [ ] No files outside the two listed above are modified
- [ ] A draft PR is opened whose body contains "Closes #<this-issue>"

## Test expectations
No new tests. `flutter test` (if run) must still pass unchanged — this
change touches no Dart code.

## Constraints / context
Flutter/Dart Android share-target app for Vikunja. Keep all source
quotes paraphrased. Conventional Commits for the commit message.
```

Optional: run `bash scripts/ensure-issue-labels.sh` (from an agent-pipeline
checkout, against quicktask-vikunja) first to pre-create labels tidily. The
pipeline self-heals labels anyway.

## Step 5 — Run & observe

Applying the `ai-implement` label triggers the workflow. Expect:

- An Actions run on quicktask-vikunja (`Claude` workflow → `claude-implement.yml`).
- A **draft PR** whose body contains `Closes #<issue>`.
- A metrics comment on the issue: outcome, duration, turns, cost, tokens,
  cache-hit rate, context utilization, run link.
- Labels stamped: `ai:running` → `ai:done` / `ai:failed`, plus `ctx:*`.

Draft-only is intended (no `auto-review`). To enable auto-merge later, see
`agent-pipeline/docs/CONSUMER-SETUP.md §2` and wire a required vulnerable-dependency
status check first (ADR-002 gate 5).

## Reference docs (in agent-pipeline)

- `docs/CONSUMER-SETUP.md` — full consumer wiring (minimum stub, auto-review,
  OpenCode backend, chaining).
- `docs/DESIGN.md` — architecture, triggers, triage, retry, constraints.
- `docs/DECISIONS.md` — ADR-002 (auto-merge safety envelope), ADR-003 (chaining).

## Gotchas captured this session

1. The reusable workflow defaults `pipeline-repo`/`pipeline-ref` to
   `freaxnx01/claude-pipeline@main` — the **old project name**. agent-pipeline
   consumers MUST override both.
2. No tags existed on agent-pipeline; `@v1` works only because a `v1` *branch*
   was created. Promote to real tags (see "Fix the v1 tag").
3. quicktask-vikunja had **zero open issues** and **no consumer stub** at handoff
   — both created/added in Steps 2 & 4.
4. Public repo: GitHub-hosted runners only, draft PRs only for the first run.

## Discovered during the first real run (2026-06-01)

The CLI session ran it end-to-end. Two repo-settings traps the steps above
missed — both now documented canonically in `CONSUMER-SETUP.md §1`:

1. **Caller `permissions:` block is mandatory.** The first run died at
   `startup_failure` (zero jobs, no logs). quicktask-vikunja's default workflow
   `GITHUB_TOKEN` is read-only; the reusable jobs request
   `contents`/`pull-requests`/`issues: write`, and a reusable workflow can't be
   granted more than its caller. Fix: add to the stub
   ```yaml
   permissions:
     contents: write
     pull-requests: write
     issues: write
   ```
2. **"Allow GitHub Actions to create and approve pull requests" must be on.**
   With that toggle off, the agent implemented the change, pushed the branch with
   `Closes #N`, posted the metrics comment, and stamped `ai:done` — but its
   `gh pr create` failed (*"GitHub Actions is not permitted to create or approve
   pull requests"*) and the run still reported **success**. The draft PR was
   simply absent. Enable:
   `gh api -X PUT repos/<owner>/<repo>/actions/permissions/workflow -F can_approve_pull_request_reviews=true`.
3. **The metrics `cost` is notional under subscription auth.** The comment showed
   `$2.73`, but the run used a `claude setup-token` (Max subscription) token —
   nothing is billed per-token. The figure is Claude Code's `total_cost_usd`,
   computed from token counts × public API list prices irrespective of auth
   method. Read it as "equivalent API cost", not a charge.
4. **`v1` was promoted to real tags** (`v1.0.0` + moving `v1` at `67e831b`); the
   stand-in `v1` branch was deleted. `@v1` now resolves via the tag.
